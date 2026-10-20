import { spawn } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  abortableSleep,
  ensureScheduledDir,
  evaluateHealth,
  minimumIntervalSeconds,
  newestScheduledTime,
  nextRunDelayMs,
  parseInterval,
  parseKeep,
  parseScheduledMode,
  runSchedule,
  scheduledBundleTime,
  scheduledBundlesToPrune,
  type ScheduleDeps,
  type ScheduledStatus,
} from './scheduled-backup.js';
import { bundlesToPrune } from './premigrate-backup.js';

const HOUR = 3600;

describe('interval, keep and mode parsing', () => {
  it('defaults to 24 hours and accepts minutes, hours and days', () => {
    expect(parseInterval(undefined)).toBe(24 * HOUR);
    expect(parseInterval('')).toBe(24 * HOUR);
    expect(parseInterval('12h')).toBe(12 * HOUR);
    expect(parseInterval('90m')).toBe(90 * 60);
    expect(parseInterval('7d')).toBe(7 * 86_400);
    expect(parseInterval(' 6H ')).toBe(6 * HOUR);
  });

  it('refuses anything below one hour, above 31 days or malformed', () => {
    for (const bad of ['59m', '0h', '30s', '32d', '1.5h', '-1h', '24', 'h', 'daily', '1h30m', '24 h']) {
      expect(() => parseInterval(bad), bad).toThrow('SIMPASTIL_BACKUP_INTERVAL');
    }
    expect(parseInterval('1h')).toBe(HOUR);
    expect(parseInterval('31d')).toBe(31 * 86_400);
  });

  it('lets a test lower the minimum', () => {
    expect(parseInterval('20s', 10)).toBe(20);
    expect(() => parseInterval('5s', 10)).toThrow('SIMPASTIL_BACKUP_INTERVAL');
  });

  it('honors the minimum-interval override only in a test run and only when valid', () => {
    expect(minimumIntervalSeconds({})).toBe(HOUR);
    expect(minimumIntervalSeconds({ NODE_ENV: 'test' })).toBe(HOUR);
    expect(minimumIntervalSeconds({ NODE_ENV: 'test', SCHEDULED_BACKUP_MIN_INTERVAL_SECONDS: '10' })).toBe(10);
    // Production ignores the variable, whatever it holds.
    expect(minimumIntervalSeconds({ NODE_ENV: 'production', SCHEDULED_BACKUP_MIN_INTERVAL_SECONDS: '10' })).toBe(HOUR);
    expect(minimumIntervalSeconds({ SCHEDULED_BACKUP_MIN_INTERVAL_SECONDS: 'abc' })).toBe(HOUR);
    for (const bad of ['abc', '', '0', '-5', '1.5', ' ', 'NaN', '1e3']) {
      expect(() => minimumIntervalSeconds({ NODE_ENV: 'test', SCHEDULED_BACKUP_MIN_INTERVAL_SECONDS: bad }), bad)
        .toThrow('SCHEDULED_BACKUP_MIN_INTERVAL_SECONDS');
    }
  });

  it('keeps 7 bundles by default and validates the count', () => {
    expect(parseKeep(undefined)).toBe(7);
    expect(parseKeep('')).toBe(7);
    expect(parseKeep('1')).toBe(1);
    expect(parseKeep('100')).toBe(100);
    for (const bad of ['0', '101', '-1', '2.5', 'many']) {
      expect(() => parseKeep(bad), bad).toThrow('SIMPASTIL_SCHEDULED_BACKUP_KEEP');
    }
  });

  it('is on unless set to off, and rejects other values', () => {
    expect(parseScheduledMode(undefined)).toBe('on');
    expect(parseScheduledMode('')).toBe('on');
    expect(parseScheduledMode('on')).toBe('on');
    expect(parseScheduledMode('OFF')).toBe('off');
    expect(() => parseScheduledMode('false')).toThrow('SIMPASTIL_SCHEDULED_BACKUP');
  });
});

describe('scheduled bundle names and pruning', () => {
  it('reads the time from the name and nothing else', () => {
    expect(scheduledBundleTime('scheduled-20261019T063000Z')?.toISOString()).toBe('2026-10-19T06:30:00.000Z');
    for (const other of ['pre-25-20261019T063000Z', '.staging-scheduled-20261019T063000Z', 'scheduled',
      'scheduled-20261019T063000Z.bak', 'scheduled-20261399T063000Z']) {
      expect(scheduledBundleTime(other), other).toBeNull();
    }
    expect(newestScheduledTime(['scheduled-20261001T000000Z', 'scheduled-20261003T000000Z', 'x'])?.toISOString())
      .toBe('2026-10-03T00:00:00.000Z');
    expect(newestScheduledTime(['pre-25-20261003T000000Z'])).toBeNull();
  });

  it('prunes only the oldest scheduled bundles beyond the keep count', () => {
    const names = [
      'scheduled-20261003T000000Z', 'scheduled-20261001T000000Z', 'scheduled-20261002T000000Z',
      '.staging-scheduled-20261004T000000Z', 'scheduled-20261004T000000Z', 'notes.txt',
    ];
    expect(scheduledBundlesToPrune(names, 2)).toEqual(['scheduled-20261001T000000Z', 'scheduled-20261002T000000Z']);
    expect(scheduledBundlesToPrune(names, 4)).toEqual([]);
    expect(scheduledBundlesToPrune(names, 9)).toEqual([]);
  });

  it('never returns a pre-migration bundle, even for keep 1, and the pre- pruner ignores scheduled ones', () => {
    const top = ['pre-23-20261001T000000Z', 'pre-24-20261002T000000Z', 'pre-25-20261003T000000Z', 'scheduled'];
    expect(scheduledBundlesToPrune(top, 1)).toEqual([]);
    const mixed = [...top, 'scheduled-20261001T000000Z', 'scheduled-20261002T000000Z'];
    expect(scheduledBundlesToPrune(mixed, 1)).toEqual(['scheduled-20261001T000000Z']);
    expect(bundlesToPrune(mixed, 1)).toEqual(['pre-23-20261001T000000Z', 'pre-24-20261002T000000Z']);
  });

  it('schedules from the newest bundle', () => {
    const now = new Date('2026-10-19T12:00:00Z');
    expect(nextRunDelayMs(null, now, 24 * HOUR)).toBe(0);
    expect(nextRunDelayMs(new Date('2026-10-19T06:00:00Z'), now, 24 * HOUR)).toBe(18 * HOUR * 1000);
    expect(nextRunDelayMs(new Date('2026-10-18T12:00:00Z'), now, 24 * HOUR)).toBe(0);
    expect(nextRunDelayMs(new Date('2026-10-01T12:00:00Z'), now, 24 * HOUR)).toBe(0);
  });
});

describe('health', () => {
  const now = new Date('2026-10-19T12:00:00Z');
  const status = (overrides: Partial<ScheduledStatus>): ScheduledStatus => ({
    formatVersion: 1, mode: 'on', intervalSeconds: 24 * HOUR, startedAt: '2026-10-10T00:00:00Z', ...overrides,
  });

  it('is healthy while the last success is younger than two intervals', () => {
    expect(evaluateHealth(status({ lastSuccessAt: '2026-10-18T00:00:00Z' }), now))
      .toEqual({ healthy: true, reason: 'recent-backup' });
    expect(evaluateHealth(status({ lastSuccessAt: '2026-10-17T12:00:01Z' }), now).healthy).toBe(true);
  });

  it('is unhealthy once two intervals pass without a success', () => {
    expect(evaluateHealth(status({ lastSuccessAt: '2026-10-17T12:00:00Z' }), now))
      .toEqual({ healthy: false, reason: 'backup-overdue' });
    expect(evaluateHealth(status({}), now)).toEqual({ healthy: false, reason: 'backup-overdue' });
    expect(evaluateHealth(status({ lastFailureAt: '2026-10-19T11:59:00Z' }), now).healthy).toBe(false);
  });

  it('allows a grace period after start before the first backup', () => {
    const fresh = status({ startedAt: '2026-10-19T11:45:00Z' });
    expect(evaluateHealth(fresh, now)).toEqual({ healthy: true, reason: 'starting' });
    expect(evaluateHealth(status({ startedAt: '2026-10-19T11:29:59Z' }), now).healthy).toBe(false);
    // An old bundle does not cancel the grace of a restart that is catching up.
    expect(evaluateHealth({ ...fresh, lastSuccessAt: '2026-09-01T00:00:00Z' }, now).healthy).toBe(true);
  });

  it('is healthy when switched off and unhealthy without a status', () => {
    expect(evaluateHealth(status({ mode: 'off', startedAt: '2020-01-01T00:00:00Z' }), now))
      .toEqual({ healthy: true, reason: 'disabled' });
    expect(evaluateHealth(null, now)).toEqual({ healthy: false, reason: 'no-status' });
  });
});

describe('runSchedule', () => {
  function harness(initial: string[]) {
    let clock = new Date('2026-10-19T12:00:00Z');
    const stop = new AbortController();
    const names = [...initial];
    const calls: string[] = [];
    const statuses: Partial<ScheduledStatus>[] = [];
    let failures = 0;
    const deps: ScheduleDeps = {
      intervalSeconds: 24 * HOUR,
      now: () => clock,
      listBundles: async () => [...names],
      takeBackup: async () => {
        calls.push('backup');
        if (failures > 0) { failures -= 1; throw new Error('pg_dump exited with 1'); }
        const bundle = `scheduled-${clock.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z')}`;
        names.push(bundle);
        return { bundle, pruned: [] };
      },
      sleep: async (ms) => {
        calls.push(`sleep:${ms}`);
        clock = new Date(clock.getTime() + ms);
        if (calls.filter((call) => call.startsWith('sleep')).length >= 2) stop.abort();
      },
      onStatus: (update) => { statuses.push(update); },
      logCreated: () => calls.push('created'),
      logFailed: (_error, retry) => calls.push(`failed:${retry}`),
      signal: stop.signal,
    };
    return { deps, calls, statuses, stop, setFailures: (count: number) => { failures = count; } };
  }

  it('backs up at once when there is no bundle, then waits a full interval', async () => {
    const { deps, calls } = harness([]);
    await runSchedule(deps);
    expect(calls.slice(0, 3)).toEqual(['backup', 'created', `sleep:${24 * HOUR * 1000}`]);
  });

  it('does not back up on a restart while the newest bundle is younger than the interval', async () => {
    const { deps, calls, statuses } = harness(['scheduled-20261019T060000Z']);
    await runSchedule(deps);
    expect(calls[0]).toBe(`sleep:${18 * HOUR * 1000}`);
    expect(statuses[0]).toEqual({ lastSuccessAt: '2026-10-19T06:00:00.000Z' });
  });

  it('backs up at once when the newest bundle is older than the interval', async () => {
    const { deps, calls } = harness(['scheduled-20261010T060000Z']);
    await runSchedule(deps);
    expect(calls.slice(0, 2)).toEqual(['backup', 'created']);
  });

  it('retries a failure after at most 15 minutes and keeps running', async () => {
    const { deps, calls, statuses, setFailures } = harness([]);
    setFailures(1);
    await runSchedule(deps);
    expect(calls.slice(0, 4)).toEqual(['backup', 'failed:900', 'sleep:900000', 'backup']);
    expect(statuses.some((update) => update.lastFailureAt === '2026-10-19T12:00:00.000Z')).toBe(true);
    expect(statuses.some((update) => update.lastSuccessAt !== undefined)).toBe(true);
  });

  it('retries sooner than 15 minutes when the interval is shorter', async () => {
    const { deps, calls, setFailures } = harness([]);
    setFailures(1);
    await runSchedule({ ...deps, intervalSeconds: 600 });
    expect(calls.slice(0, 2)).toEqual(['backup', 'failed:600']);
  });

  it('stops when aborted during a backup without reporting a failure', async () => {
    const { deps, calls, stop } = harness([]);
    await runSchedule({ ...deps, takeBackup: async () => { stop.abort(); throw new Error('aborted'); } });
    expect(calls).toEqual([]);
  });
});

describe('abortableSleep', () => {
  afterEach(() => vi.useRealTimers());

  it('resolves after the delay, in chunks beyond the timer limit, and early on abort', async () => {
    vi.useFakeTimers();
    const stop = new AbortController();
    let done = false;
    void abortableSleep(30 * 86_400_000, stop.signal).then(() => { done = true; });
    await vi.advanceTimersByTimeAsync(29 * 86_400_000);
    expect(done).toBe(false);
    await vi.advanceTimersByTimeAsync(86_400_000);
    expect(done).toBe(true);

    const aborting = new AbortController();
    let early = false;
    void abortableSleep(86_400_000, aborting.signal).then(() => { early = true; });
    aborting.abort();
    await vi.advanceTimersByTimeAsync(0);
    expect(early).toBe(true);
  });
});

describe('scheduled directory', () => {
  let work: string;
  beforeEach(() => { work = mkdtempSync(join(tmpdir(), 'scheduled-dir-')); });
  afterEach(() => rmSync(work, { recursive: true, force: true }));

  it('creates scheduled/ with mode 0700 and leaves pre-migration bundles alone', async () => {
    mkdirSync(join(work, 'pre-25-20261001T000000Z'), { mode: 0o700 });
    const directory = await ensureScheduledDir(work);
    expect(directory).toBe(join(work, 'scheduled'));
    expect(statSync(directory).mode & 0o777).toBe(0o700);
    expect(await ensureScheduledDir(work)).toBe(directory);
  });
});

describe('scheduled-backup process', () => {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const tsx = join(root, 'node_modules/.bin/tsx');
  const entry = join(root, 'src/commands/scheduled-backup.ts');
  let work: string;
  beforeEach(() => { work = mkdtempSync(join(tmpdir(), 'scheduled-proc-')); });
  afterEach(() => rmSync(work, { recursive: true, force: true }));

  function start(args: string[], env: Record<string, string>) {
    const child = spawn(tsx, [entry, ...args], {
      env: { PATH: process.env['PATH'] ?? '', SCHEDULED_BACKUP_STATUS_FILE: join(work, 'status.json'), ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let output = '';
    child.stdout.on('data', (chunk: Buffer) => { output += chunk.toString(); });
    child.stderr.on('data', (chunk: Buffer) => { output += chunk.toString(); });
    const exit = new Promise<number | null>((done) => child.on('close', done));
    return { child, exit, output: () => output };
  }

  async function waitFor(condition: () => boolean): Promise<void> {
    for (let attempt = 0; attempt < 200 && !condition(); attempt += 1) {
      await new Promise((done) => setTimeout(done, 50));
    }
    expect(condition()).toBe(true);
  }

  it('idles quietly when off, is healthy, needs no database, and exits 0 on SIGTERM', async () => {
    const running = start([], { SIMPASTIL_SCHEDULED_BACKUP: 'off' });
    const statusFile = join(work, 'status.json');
    await waitFor(() => running.output().includes('scheduled_backup.disabled'));
    expect(JSON.parse(readFileSync(statusFile, 'utf8'))).toMatchObject({ mode: 'off' });
    const check = start(['--healthcheck'], {});
    expect(await check.exit).toBe(0);
    await new Promise((done) => setTimeout(done, 300));
    expect(running.child.exitCode).toBeNull();
    running.child.kill('SIGTERM');
    expect(await running.exit).toBe(0);
  }, 30_000);

  it('idles when off even with an invalid interval, rather than exiting', async () => {
    const running = start([], { SIMPASTIL_SCHEDULED_BACKUP: 'off', SIMPASTIL_BACKUP_INTERVAL: 'soon' });
    await waitFor(() => running.output().includes('scheduled_backup.disabled'));
    running.child.kill('SIGTERM');
    expect(await running.exit).toBe(0);
  }, 30_000);

  it('exits non-zero with a plain message on an invalid interval', async () => {
    const running = start([], { SIMPASTIL_BACKUP_INTERVAL: '5m' });
    expect(await running.exit).toBe(1);
    expect(running.output()).toContain('SIMPASTIL_BACKUP_INTERVAL');
  }, 30_000);

  it('reports unhealthy without a status file and for a stale on-schedule', async () => {
    expect(await start(['--healthcheck'], {}).exit).toBe(1);
    writeFileSync(join(work, 'status.json'), JSON.stringify({
      formatVersion: 1, mode: 'on', intervalSeconds: 3600, startedAt: '2026-01-01T00:00:00Z',
      lastSuccessAt: '2026-01-01T00:00:00Z',
    }));
    expect(await start(['--healthcheck'], {}).exit).toBe(1);
  }, 30_000);
});
