import { describe, expect, it } from 'vitest';
import { SafeLogger, type SafeLogRecord } from './safe-logger.js';

describe('SafeLogger', () => {
  it('emits only bounded allowlisted fields and never serializes privacy canaries', () => {
    const records: SafeLogRecord[] = [];
    const logger = new SafeLogger({
      info: (record) => records.push(record),
      warn: (record) => records.push(record),
      error: (record) => records.push(record),
    });

    logger.error('request.error', {
      correlationId: 'corr-123',
      method: 'POST',
      route: '/api/v1/auth/reset-password',
      statusCode: 400,
      errorCode: 'VALIDATION_ERROR',
      // Deliberately hostile fields: the type does not expose these, and the
      // runtime guard must reject them when an untyped boundary supplies them.
      authorization: 'eyJhbGciOiJSUzI1NiJ9.jwt-secret-sentinel',
      apiKey: 'sk_live_api-key-sentinel',
      resetToken: 'reset-fragment-sentinel',
      email: 'person@example.invalid',
      profileName: 'profile-sentinel',
      pillName: 'pill-sentinel',
      body: 'raw-body-sentinel',
      nested: { secret: 'nested-body-sentinel' },
    } as never);

    const serialized = JSON.stringify(records);
    expect(serialized).toContain('request.error');
    expect(serialized).toContain('corr-123');
    expect(serialized).toContain('VALIDATION_ERROR');
    for (const sentinel of [
      'jwt-secret-sentinel',
      'api-key-sentinel',
      'reset-fragment-sentinel',
      'person@example.invalid',
      'profile-sentinel',
      'pill-sentinel',
      'raw-body-sentinel',
      'nested-body-sentinel',
    ]) {
      expect(serialized).not.toContain(sentinel);
    }
  });

  it('drops untyped event names and unbounded route templates before reaching the sink', () => {
    const records: SafeLogRecord[] = [];
    const logger = new SafeLogger({
      info: (record) => records.push(record),
      warn: (record) => records.push(record),
      error: (record) => records.push(record),
    });

    logger.error('request.error', {
      route: `/api/v1/${'x'.repeat(10_000)}`,
    });
    logger.error({ event: 'attacker-controlled-event' } as never, {
      route: '/api/v1/profiles/:id',
    });

    expect(records).toEqual([{ event: 'request.error', msg: 'Request failed' }]);
  });

  it('keeps sync diagnostics only when they are a known component and a bounded sequence', () => {
    const records: SafeLogRecord[] = [];
    const sink = (record: SafeLogRecord) => records.push(record);
    const logger = new SafeLogger({ info: sink, warn: sink, error: sink });
    logger.error('request.error', { syncComponent: 'stable', serverSequence: '42' });
    logger.error('request.error', { syncComponent: 'person@example.invalid', serverSequence: '4 2; DROP' });
    expect(records[0]).toMatchObject({ syncComponent: 'stable', serverSequence: '42' });
    expect(records[1]).toEqual({ event: 'request.error', msg: 'Request failed' });
  });

  it('keeps valid update fields and drops invalid ones individually', () => {
    const records: SafeLogRecord[] = [];
    const logger = new SafeLogger({
      info: (record) => records.push(record),
      warn: (record) => records.push(record),
      error: (record) => records.push(record),
    });
    logger.info('update.available', {
      currentServerVersion: '1.0.0',
      latestServerVersion: '1.1.0',
      latestClientBuild: 4,
      releaseUrl: 'https://github.com/LucaPisl/simpastil/releases/tag/v1.1.0',
    });
    logger.info('update.available', {
      currentServerVersion: '1.0.0',
      latestServerVersion: '1.0.0; rm',
      latestClientBuild: -1,
      releaseUrl: 'https://evil.example/x',
    });
    expect(records[0]).toEqual({
      event: 'update.available',
      msg: 'A newer Simpastil release is available: 1.1.0 (this server runs 1.0.0)',
      currentServerVersion: '1.0.0',
      latestServerVersion: '1.1.0',
      latestClientBuild: 4,
      releaseUrl: 'https://github.com/LucaPisl/simpastil/releases/tag/v1.1.0',
    });
    expect(records[1]).toEqual({
      event: 'update.available',
      msg: 'A newer Simpastil release is available: unknown (this server runs 1.0.0)',
      currentServerVersion: '1.0.0',
    });
  });

  describe('failure causes and sentences', () => {
    function capture() {
      const records: SafeLogRecord[] = [];
      const sink = (record: SafeLogRecord) => records.push(record);
      return { records, logger: new SafeLogger({ info: sink, warn: sink, error: sink }) };
    }

    it('writes a fixed sentence that names the status, code, cause and route', () => {
      const { records, logger } = capture();
      logger.error('request.error', {
        correlationId: 'corr-1',
        method: 'POST',
        route: '/api/v1/pills',
        statusCode: 500,
        errorCode: 'INTERNAL',
        causeKind: 'postgres',
        causeCode: '40001',
        errorClass: 'PostgresError',
        where: 'dist/modules/pills/pills.service.js:88',
      });
      expect(records[0]?.msg).toBe(
        'Request failed: 500 INTERNAL (database error 40001 at dist/modules/pills/pills.service.js:88)'
        + ' on POST /api/v1/pills',
      );
      expect(records[0]).toMatchObject({ causeKind: 'postgres', causeCode: '40001', errorClass: 'PostgresError' });
    });

    it('calls a client error rejected rather than failed and names the invalid field', () => {
      const { records, logger } = capture();
      logger.error('request.error', {
        method: 'PUT', route: '/api/v1/pills/:id', statusCode: 400, errorCode: 'VALIDATION_ERROR',
        causeKind: 'validation', validationPath: 'currentStock',
      });
      expect(records[0]?.msg).toBe(
        'Request rejected: 400 VALIDATION_ERROR (invalid field currentStock) on PUT /api/v1/pills/:id',
      );
    });

    it('drops cause values that fail their rules, so the sentence cannot carry free text', () => {
      const { records, logger } = capture();
      logger.error('request.error', {
        statusCode: 500,
        causeKind: 'canary-kind',
        causeCode: 'duplicate key (canary-medication-name)',
        errorClass: 'Not A Class; canary',
        where: '/etc/passwd:1',
        configVariable: 'lowercase',
        configProblem: 'canary-problem',
        validationPath: 'a.b; canary',
        readinessReason: 'canary-reason',
      } as never);
      const serialized = JSON.stringify(records);
      expect(serialized).not.toContain('canary');
      expect(serialized).not.toContain('passwd');
      expect(records[0]).toEqual({ event: 'request.error', msg: 'Request failed: 500', statusCode: 500 });
    });

    it('explains readiness changes from the closed reason list', () => {
      const { records, logger } = capture();
      logger.warn('readiness.not_ready', {
        readinessReason: 'database_unreachable', causeKind: 'network', causeCode: 'ECONNREFUSED',
      });
      logger.info('readiness.recovered');
      expect(records[0]?.msg).toBe(
        'Server is not ready: the database cannot be reached or did not answer the readiness query'
        + ' (network error ECONNREFUSED)',
      );
      expect(records[1]).toEqual({ event: 'readiness.recovered', msg: 'Server is ready again' });
    });
  });
});
