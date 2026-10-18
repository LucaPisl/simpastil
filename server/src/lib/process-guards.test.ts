import { afterEach, describe, expect, it, vi } from 'vitest';
import { installProcessGuards, type GuardedProcess } from './process-guards.js';

function fakeProcess() {
  const listeners = new Map<string, (reason: unknown) => void>();
  const exit = vi.fn();
  const target: GuardedProcess = {
    on: (event, listener) => { listeners.set(event, listener); return target; },
    exit,
  };
  return { target, listeners, exit };
}

afterEach(() => vi.restoreAllMocks());

describe('installProcessGuards', () => {
  it('logs one explained line for an uncaught exception and exits non-zero', () => {
    const errors = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    const { target, listeners, exit } = fakeProcess();
    installProcessGuards('api', target);

    listeners.get('uncaughtException')!(Object.assign(
      new Error('connect ECONNREFUSED 10.20.30.40:5432 canary-user'), { code: 'ECONNREFUSED' },
    ));

    expect(exit).toHaveBeenCalledWith(1);
    expect(errors).toHaveBeenCalledTimes(1);
    const line = JSON.parse(String(errors.mock.calls[0]![0])) as Record<string, string>;
    expect(line).toMatchObject({
      event: 'process.crashed',
      role: 'api',
      causeKind: 'network',
      causeCode: 'ECONNREFUSED',
    });
    expect(line['msg']).toMatch(/^The api process stopped on an unhandled error and is exiting \(network error ECONNREFUSED/);
    expect(JSON.stringify(line)).not.toContain('10.20.30.40');
    expect(JSON.stringify(line)).not.toContain('canary-user');
  });

  it('treats an unhandled rejection the same way, even for a non-error reason', () => {
    const errors = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    const { target, listeners, exit } = fakeProcess();
    installProcessGuards('outbox', target);

    listeners.get('unhandledRejection')!('a thrown string canary-medication-name');

    expect(exit).toHaveBeenCalledWith(1);
    const line = JSON.parse(String(errors.mock.calls[0]![0])) as Record<string, string>;
    expect(line).toMatchObject({ event: 'process.crashed', role: 'outbox', causeKind: 'unknown' });
    expect(JSON.stringify(line)).not.toContain('canary-medication-name');
  });

  it('logs only the first failure when a second one arrives while exiting', () => {
    const errors = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    const { target, listeners, exit } = fakeProcess();
    installProcessGuards('migrate', target);

    listeners.get('uncaughtException')!(new TypeError('first'));
    listeners.get('unhandledRejection')!(new TypeError('second'));

    expect(errors).toHaveBeenCalledTimes(1);
    expect(exit).toHaveBeenCalledTimes(1);
  });

  it('registers once per process however often it is installed', () => {
    const { target } = fakeProcess();
    const on = vi.spyOn(target, 'on');
    installProcessGuards('api', target);
    installProcessGuards('api', target);
    expect(on).toHaveBeenCalledTimes(2); // uncaughtException and unhandledRejection, once each
  });

  it('still exits when logging itself throws', () => {
    vi.spyOn(console, 'error').mockImplementation(() => { throw new Error('stderr closed'); });
    const { target, listeners, exit } = fakeProcess();
    installProcessGuards('command', target);
    expect(() => listeners.get('uncaughtException')!(new Error('boom'))).toThrow('stderr closed');
    expect(exit).toHaveBeenCalledWith(1);
  });
});
