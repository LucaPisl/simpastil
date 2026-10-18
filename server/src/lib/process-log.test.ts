import { afterEach, describe, expect, it, vi } from 'vitest';
import { logProcessEvent, logProcessFailure } from './process-log.js';

function captured() {
  const lines: Record<string, unknown>[] = [];
  vi.spyOn(console, 'log').mockImplementation((line: string) => { lines.push(JSON.parse(line)); });
  vi.spyOn(console, 'error').mockImplementation((line: string) => { lines.push(JSON.parse(line)); });
  return lines;
}

afterEach(() => vi.restoreAllMocks());

describe('process log lines', () => {
  it('puts a fixed sentence right after the event name', () => {
    const lines = captured();
    logProcessEvent('info', 'process.shutdown_started', { signal: 'SIGTERM' });
    expect(Object.keys(lines[0]!)).toEqual(['event', 'msg', 'signal']);
    expect(lines[0]).toMatchObject({
      msg: 'Shutdown requested; finishing active work before exiting',
      signal: 'SIGTERM',
    });
  });

  it('explains an unknown event from its name and ignores a caller-supplied msg', () => {
    const lines = captured();
    logProcessEvent('info', 'backup.something_happened', { msg: 'injected sentence canary' });
    expect(lines[0]).toMatchObject({ msg: 'Backup something happened' });
    expect(JSON.stringify(lines)).not.toContain('canary');
  });

  it('adds the cause of a failure to the sentence and the fields, never its message', () => {
    const lines = captured();
    logProcessFailure('provision.command_failed', Object.assign(
      new Error('password authentication failed for user "canary-user"'), { code: '28P01', severity: 'FATAL' },
    ));
    expect(lines[0]).toMatchObject({
      event: 'provision.command_failed',
      causeKind: 'postgres',
      causeCode: '28P01',
    });
    expect(lines[0]!['msg']).toMatch(/^The provisioning command failed \(database error 28P01/);
    expect(JSON.stringify(lines)).not.toContain('canary-user');
  });

  it('drops a cause field that fails its rule', () => {
    const lines = captured();
    logProcessEvent('error', 'token_gc.periodic_purge_failed', { causeKind: 'postgres', causeCode: 'bad code; canary' });
    expect(lines[0]).toMatchObject({ causeKind: 'postgres' });
    expect(lines[0]).not.toHaveProperty('causeCode');
    expect(JSON.stringify(lines)).not.toContain('canary');
  });

  it('names a delivery category and its cause in the outbox sentences', () => {
    const lines = captured();
    logProcessEvent('info', 'outbox.retry_scheduled', {
      category: 'smtp_transient', causeKind: 'smtp', causeCode: '451', attempt: 2,
    });
    expect(lines[0]!['msg']).toBe(
      'Delivering a queued message failed; a retry is scheduled (smtp_transient; mail server error 451)',
    );
  });
});
