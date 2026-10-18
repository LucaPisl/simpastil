import { describe, expect, it } from 'vitest';
import { z } from 'zod';
import { ConfigError } from '../config/app-config.js';
import { WorkerConfigError } from '../outbox/worker-config.js';
import { SmtpDeliveryError } from '../outbox/smtp-delivery.js';
import { describeFailure } from './failure-cause.js';

class PostgresError extends Error {
  constructor(message: string, readonly code: string) {
    super(message);
    this.name = 'PostgresError';
  }
}

/** Mimics `DrizzleQueryError`: the SQL and its parameters are in the message. */
class DrizzleQueryError extends Error {
  constructor(message: string, cause: unknown) {
    super(message, { cause });
    this.name = 'DrizzleQueryError';
  }
}

function coded(message: string, code: string, name = 'Error'): Error {
  return Object.assign(new Error(message), { code, name });
}

describe('describeFailure', () => {
  it('names a PostgreSQL failure by SQLSTATE without carrying its message', () => {
    const cause = describeFailure(new PostgresError('duplicate key value (canary-medication-name)', '23505'));
    expect(cause).toMatchObject({ causeKind: 'postgres', causeCode: '23505', errorClass: 'PostgresError' });
    expect(JSON.stringify(cause)).not.toContain('canary-medication-name');
  });

  it('looks through a wrapper to the database error underneath', () => {
    const cause = describeFailure(new DrizzleQueryError(
      'Failed query: insert into pills (name) values ($1) params: canary-medication-name',
      new PostgresError('deadlock detected', '40P01'),
    ));
    expect(cause).toMatchObject({ causeKind: 'postgres', causeCode: '40P01', errorClass: 'PostgresError' });
    expect(JSON.stringify(cause)).not.toContain('canary-medication-name');
    expect(JSON.stringify(cause)).not.toContain('insert into');
  });

  it('does not mistake a five-letter system code for a SQLSTATE', () => {
    const cause = describeFailure(coded('operation not permitted', 'EPERM'));
    expect(cause.causeKind).not.toBe('postgres');
    expect(cause.causeCode).toBe('EPERM');
  });

  it.each([
    ['ECONNREFUSED', 'network'],
    ['ENOTFOUND', 'network'],
    ['ECONNRESET', 'network'],
    ['CONNECTION_CLOSED', 'network'],
    ['CONNECT_TIMEOUT', 'timeout'],
    ['ETIMEDOUT', 'timeout'],
  ] as const)('classifies %s as %s and keeps the symbolic code', (code, kind) => {
    expect(describeFailure(coded('connect failed to 10.0.0.1:5432 as canary-user', code)))
      .toMatchObject({ causeKind: kind, causeCode: code });
  });

  it('reports the SMTP reply code of a delivery failure', () => {
    const error = new SmtpDeliveryError('smtp_recipient_rejected', { responseCode: 550 });
    expect(describeFailure(error)).toMatchObject({
      causeKind: 'smtp', causeCode: '550', errorClass: 'SmtpDeliveryError',
    });
  });

  it('classifies a transport-level mail failure as smtp with its symbolic code', () => {
    const error = Object.assign(new Error('connect ECONNREFUSED mail.example.invalid'), {
      code: 'ECONNECTION', command: 'CONN',
    });
    expect(describeFailure(error)).toMatchObject({ causeKind: 'smtp', causeCode: 'ECONNECTION' });
  });

  it.each([
    [new ConfigError('DATABASE_URL is required for the api role'), 'DATABASE_URL', 'required'],
    [new ConfigError('PUBLIC_APP_URL must not be blank'), 'PUBLIC_APP_URL', 'blank'],
    [new ConfigError('PUBLIC_APP_URL must be a valid URL'), 'PUBLIC_APP_URL', 'invalid'],
    [new ConfigError('JWT_PRIVATE_KEY_FILE could not be read'), 'JWT_PRIVATE_KEY_FILE', 'unreadable'],
    [new WorkerConfigError('DELIVERY_PAYLOAD_KEY must be exactly 64 hexadecimal characters'), 'DELIVERY_PAYLOAD_KEY', 'invalid'],
  ] as const)('reads the variable and problem out of %s', (error, variable, problem) => {
    expect(describeFailure(error)).toMatchObject({
      causeKind: 'config', configVariable: variable, configProblem: problem,
    });
  });

  it('gives a configuration error without a leading variable name no variable', () => {
    const cause = describeFailure(new ConfigError('Runtime environment must be a string record'));
    expect(cause.causeKind).toBe('config');
    expect(cause.configVariable).toBeUndefined();
    expect(cause.configProblem).toBe('invalid');
  });

  it('reports the field path of a validation failure, collapsing array positions', () => {
    const schema = z.object({ items: z.array(z.object({ amount: z.number() })) });
    const result = schema.safeParse({ items: [{ amount: 'canary-medication-name' }] });
    expect(result.success).toBe(false);
    if (result.success) return;
    const cause = describeFailure(result.error);
    expect(cause).toMatchObject({ causeKind: 'validation', validationPath: 'items[].amount' });
    expect(JSON.stringify(cause)).not.toContain('canary-medication-name');
  });

  it('drops the whole path when any segment is not a plain field name', () => {
    const schema = z.record(z.number());
    const result = schema.safeParse({ 'drop table; canary': 'x' });
    expect(result.success).toBe(false);
    if (result.success) return;
    const cause = describeFailure(result.error);
    expect(cause.causeKind).toBe('validation');
    expect(cause.validationPath).toBeUndefined();
  });

  it('calls a TypeError a bug and an unrecognised error unknown', () => {
    expect(describeFailure(new TypeError('x is not a function')))
      .toMatchObject({ causeKind: 'bug', errorClass: 'TypeError' });
    expect(describeFailure(new Error('something odd canary')))
      .toMatchObject({ causeKind: 'unknown', errorClass: 'Error' });
    expect(describeFailure('a thrown string canary')).toEqual({ causeKind: 'unknown' });
    expect(describeFailure(undefined)).toEqual({ causeKind: 'unknown' });
  });

  it('points at the first in-app stack frame as a dist-relative file and line', () => {
    const error = new Error('boom');
    error.stack = [
      'Error: boom',
      '    at parse (file:///app/node_modules/zod/lib/index.js:10:5)',
      '    at handler (file:///app/dist/modules/pills/pills.service.js:88:19)',
      '    at later (file:///app/dist/modules/other.js:1:1)',
    ].join('\n');
    expect(describeFailure(error).where).toBe('dist/modules/pills/pills.service.js:88');
  });

  it('prefers a dist or src segment over a checkout path that happens to contain src', () => {
    const error = new Error('boom');
    error.stack = 'Error: boom\n    at f (/srv/src/simpastil/server/dist/app.js:5:1)';
    expect(describeFailure(error).where).toBe('dist/app.js:5');
  });

  it('cannot be tricked into naming a frame by text inside the message', () => {
    const forged = 'harmless\n    at evil (file:///app/dist/secret-medication.js:1:1)';
    const error = new Error(forged);
    error.stack = `Error: ${forged}\n    at real (file:///app/dist/modules/real.js:7:3)`;
    expect(describeFailure(error).where).toBe('dist/modules/real.js:7');
  });

  it('gives no location when the message cannot be separated from the stack', () => {
    const error = new Error('original');
    error.message = 'changed after capture\n    at evil (file:///app/dist/secret.js:1:1)';
    error.stack = 'Error: original\n    at real (file:///app/dist/real.js:2:2)\n    at evil (file:///app/dist/secret.js:1:1)';
    expect(describeFailure(error).where).toBeUndefined();
  });

  it('stops following a cause chain that loops', () => {
    const a: Error & { cause?: unknown } = new Error('a');
    const b: Error & { cause?: unknown } = new Error('b');
    a.cause = b;
    b.cause = a;
    expect(describeFailure(a).causeKind).toBe('unknown');
  });

  it('never returns a value that fails its own field rules', () => {
    const hostile = coded('x', 'bad code; drop table', 'Name With Spaces; canary');
    const cause = describeFailure(hostile);
    expect(cause.causeCode).toBeUndefined();
    // The invalid name is ignored; the class name from the code is used.
    expect(cause.errorClass).toBe('Error');
    expect(JSON.stringify(cause)).not.toContain('canary');
    expect(JSON.stringify(cause)).not.toContain('drop table');
  });
});
