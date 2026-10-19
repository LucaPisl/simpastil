/**
 * Scheduled backups, run by the long-running `scheduled-backup` Compose service.
 *
 * It writes the same restorable bundle as the pre-migration backup (shared
 * `writeBackupBundle`), but on a timer and unconditionally: a scheduled backup
 * is taken even when nothing is pending. Bundles go to the `scheduled/`
 * subfolder of BACKUP_DIR, named `scheduled-<UTC time>`. Pruning only ever
 * looks at that subfolder and only at names of exactly that form, so the
 * pre-migration bundles at the top level (`pre-<count>-<UTC>`) are never touched.
 *
 * The loop derives its schedule from the newest bundle on disk, so a container
 * restart does not take an extra backup (and rotate good ones out). A failed
 * backup is retried after at most 15 minutes and never ends the process. A
 * small status file lets the container health check tell a working schedule
 * from a silent one.
 *
 * SIMPASTIL_SCHEDULED_BACKUP=off makes the process idle forever instead of
 * exiting, so `restart: unless-stopped` does not restart it in a loop.
 */
import { lstat, mkdir, readdir, rename, rm, stat, writeFile, readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import postgres from 'postgres';
import { ConfigError, loadDatabaseConfig, readRuntimeEnvironment } from '../config/app-config.js';
import { installProcessGuards } from '../lib/process-guards.js';
import { logProcessEvent, logProcessFailure } from '../lib/process-log.js';
import {
  timestamp,
  writeBackupBundle,
  type CryptoMaterialPaths,
} from './premigrate-backup.js';

export const SCHEDULED_DIR = 'scheduled';
export const SCHEDULED_PREFIX = 'scheduled-';
export const DEFAULT_INTERVAL = '24h';
export const MIN_INTERVAL_SECONDS = 3600;
export const MAX_INTERVAL_SECONDS = 31 * 86_400;
export const DEFAULT_KEEP = 7;
/** How long after start the service is healthy without a successful backup yet. */
export const START_GRACE_SECONDS = 1800;
/** A failed backup is retried after the interval or this long, whichever is shorter. */
export const RETRY_SECONDS = 900;
/** A staging directory this old belongs to a backup that can no longer be running. */
const STALE_STAGING_MS = 3_600_000;

const SCHEDULED_NAME_RE = /^scheduled-(\d{8})T(\d{6})Z$/;
const STAGING_NAME_RE = /^\.staging-scheduled-\d{8}T\d{6}Z$/;
const UNIT_SECONDS: Readonly<Record<string, number>> = { s: 1, m: 60, h: 3600, d: 86_400 };

export type ScheduledMode = 'on' | 'off';

/** `on` (the default when unset or empty) or `off`; anything else is a configuration error. */
export function parseScheduledMode(raw: string | undefined): ScheduledMode {
  const value = (raw ?? '').trim().toLowerCase();
  if (value === '' || value === 'on') return 'on';
  if (value === 'off') return 'off';
  throw new ConfigError('SIMPASTIL_SCHEDULED_BACKUP must be on or off');
}

/**
 * Parses an interval such as `24h`, `90m` or `7d` into seconds. `minimumSeconds`
 * is 1 hour in production; only tests lower it.
 */
export function parseInterval(raw: string | undefined, minimumSeconds = MIN_INTERVAL_SECONDS): number {
  const text = (raw ?? '').trim().toLowerCase() || DEFAULT_INTERVAL;
  const match = /^(\d{1,6})([smhd])$/.exec(text);
  const seconds = match ? Number(match[1]) * UNIT_SECONDS[match[2]!]! : NaN;
  if (!Number.isInteger(seconds) || seconds < minimumSeconds || seconds > MAX_INTERVAL_SECONDS) {
    const minimum = minimumSeconds % 3600 === 0 ? `${minimumSeconds / 3600}h` : `${minimumSeconds}s`;
    throw new ConfigError(`SIMPASTIL_BACKUP_INTERVAL must be a number followed by m, h or d (for example 24h), from ${minimum} to 31d`);
  }
  return seconds;
}

/** How many scheduled bundles to keep: an integer from 1 to 100 (default 7). */
export function parseKeep(raw: string | undefined): number {
  const text = (raw ?? '').trim();
  if (text === '') return DEFAULT_KEEP;
  const keep = Number(text);
  if (!/^\d+$/.test(text) || keep < 1 || keep > 100) {
    throw new ConfigError('SIMPASTIL_SCHEDULED_BACKUP_KEEP must be an integer from 1 to 100');
  }
  return keep;
}

/** The UTC time a scheduled bundle was named for, or null for any other name. */
export function scheduledBundleTime(name: string): Date | null {
  const match = SCHEDULED_NAME_RE.exec(name);
  if (!match) return null;
  const [, day, clock] = match;
  const iso = `${day!.slice(0, 4)}-${day!.slice(4, 6)}-${day!.slice(6, 8)}T`
    + `${clock!.slice(0, 2)}:${clock!.slice(2, 4)}:${clock!.slice(4, 6)}Z`;
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? null : date;
}

/** Newest scheduled bundle time among `names`, or null when there is none. */
export function newestScheduledTime(names: readonly string[]): Date | null {
  let newest: Date | null = null;
  for (const name of names) {
    const time = scheduledBundleTime(name);
    if (time && (newest === null || time > newest)) newest = time;
  }
  return newest;
}

/**
 * Scheduled bundles to delete so that only the newest `keep` remain. Only names
 * of the exact form `scheduled-<UTC>` qualify: pre-migration bundles, staging
 * directories and anything an operator put there are never returned.
 */
export function scheduledBundlesToPrune(names: readonly string[], keep: number): string[] {
  const bundles = names.filter((name) => scheduledBundleTime(name) !== null).sort();
  return bundles.slice(0, Math.max(0, bundles.length - keep));
}

/** Milliseconds until the next backup is due, given the newest existing bundle. */
export function nextRunDelayMs(newest: Date | null, now: Date, intervalSeconds: number): number {
  if (newest === null) return 0;
  return Math.max(0, newest.getTime() + intervalSeconds * 1000 - now.getTime());
}

export interface ScheduledStatus {
  formatVersion: 1;
  mode: ScheduledMode;
  intervalSeconds: number;
  startedAt: string;
  lastSuccessAt?: string;
  lastFailureAt?: string;
}

export interface HealthVerdict {
  healthy: boolean;
  reason: 'disabled' | 'recent-backup' | 'starting' | 'backup-overdue' | 'no-status';
}

/**
 * Healthy while the schedule is switched off, while the last successful backup
 * is younger than two intervals, and for a grace period after start (the first
 * backup of a fresh install, or a catch-up after downtime).
 */
export function evaluateHealth(
  status: ScheduledStatus | null,
  now: Date,
  graceSeconds = START_GRACE_SECONDS,
): HealthVerdict {
  if (status === null) return { healthy: false, reason: 'no-status' };
  if (status.mode === 'off') return { healthy: true, reason: 'disabled' };
  if (status.lastSuccessAt) {
    const age = now.getTime() - Date.parse(status.lastSuccessAt);
    if (age < 2 * status.intervalSeconds * 1000) return { healthy: true, reason: 'recent-backup' };
  }
  if (now.getTime() - Date.parse(status.startedAt) < graceSeconds * 1000) {
    return { healthy: true, reason: 'starting' };
  }
  return { healthy: false, reason: 'backup-overdue' };
}

function parseStatus(text: string): ScheduledStatus | null {
  try {
    const value = JSON.parse(text) as Partial<ScheduledStatus>;
    const validTime = (field: unknown) => typeof field === 'string' && !Number.isNaN(Date.parse(field));
    if (value.formatVersion !== 1 || (value.mode !== 'on' && value.mode !== 'off')
      || typeof value.intervalSeconds !== 'number' || !validTime(value.startedAt)) return null;
    if (value.lastSuccessAt !== undefined && !validTime(value.lastSuccessAt)) return null;
    return value as ScheduledStatus;
  } catch {
    return null;
  }
}

export async function readStatusFile(path: string): Promise<ScheduledStatus | null> {
  try {
    return parseStatus(await readFile(path, 'utf8'));
  } catch {
    return null;
  }
}

async function writeStatusFile(path: string, status: ScheduledStatus): Promise<void> {
  const temporary = `${path}.tmp`;
  await writeFile(temporary, `${JSON.stringify(status)}\n`, { mode: 0o644 });
  await rename(temporary, path);
}

/** Creates `<backupDir>/scheduled` (mode 0700, owned by the running user) when it is missing. */
export async function ensureScheduledDir(backupDir: string): Promise<string> {
  const directory = join(backupDir, SCHEDULED_DIR);
  await mkdir(directory, { mode: 0o700, recursive: true });
  const info = await lstat(directory);
  if (!info.isDirectory()) throw new Error('the scheduled backup directory is not a directory');
  return directory;
}

/** Removes staging directories left by a backup that was killed mid-way. */
async function removeStaleStaging(directory: string, now: Date): Promise<void> {
  for (const name of await readdir(directory)) {
    if (!STAGING_NAME_RE.test(name)) continue;
    const info = await stat(join(directory, name)).catch(() => null);
    if (info && now.getTime() - info.mtimeMs > STALE_STAGING_MS) {
      await rm(join(directory, name), { recursive: true, force: true });
    }
  }
}

export interface ScheduledBackupOptions {
  databaseUrl: string;
  backupDir: string;
  keep: number;
  roleGrantsSql: string;
  crypto: CryptoMaterialPaths;
  now?: () => Date;
  signal?: AbortSignal;
}

export interface ScheduledBackupResult {
  bundle: string;
  pruned: string[];
}

/** Takes one scheduled backup now, whatever the migration state, then prunes old ones. */
export async function scheduledBackup(options: ScheduledBackupOptions): Promise<ScheduledBackupResult> {
  const now = options.now ?? (() => new Date());
  const directory = await ensureScheduledDir(options.backupDir);
  await removeStaleStaging(directory, now());
  const sql = postgres(options.databaseUrl, { max: 1, connect_timeout: 10, onnotice: () => {} });
  const bundle = `${SCHEDULED_PREFIX}${timestamp(now())}`;
  try {
    await writeBackupBundle(sql, options, directory, bundle, options.signal);
  } finally {
    await sql.end();
  }
  const pruned = scheduledBundlesToPrune(await readdir(directory), options.keep);
  for (const old of pruned) await rm(join(directory, old), { recursive: true, force: true });
  return { bundle, pruned };
}

export interface ScheduleDeps {
  intervalSeconds: number;
  now: () => Date;
  /** Resolves after `ms`, or early when the signal aborts. */
  sleep: (ms: number, signal: AbortSignal) => Promise<void>;
  listBundles: () => Promise<string[]>;
  takeBackup: (signal: AbortSignal) => Promise<ScheduledBackupResult>;
  onStatus: (update: Pick<ScheduledStatus, 'lastSuccessAt' | 'lastFailureAt'>) => Promise<void> | void;
  logCreated: (result: ScheduledBackupResult) => void;
  logFailed: (error: unknown, retryInSeconds: number) => void;
  signal: AbortSignal;
}

/**
 * The schedule: wait until the newest bundle is one interval old (immediately
 * when there is none), take a backup, repeat. A failure is logged and retried
 * soon; only the abort signal ends the loop.
 */
export async function runSchedule(deps: ScheduleDeps): Promise<void> {
  const retrySeconds = Math.min(deps.intervalSeconds, RETRY_SECONDS);
  while (!deps.signal.aborted) {
    try {
      const names = await deps.listBundles();
      const newest = newestScheduledTime(names);
      if (newest) await deps.onStatus({ lastSuccessAt: newest.toISOString() });
      const wait = nextRunDelayMs(newest, deps.now(), deps.intervalSeconds);
      if (wait > 0) {
        await deps.sleep(wait, deps.signal);
        continue;
      }
      const result = await deps.takeBackup(deps.signal);
      await deps.onStatus({ lastSuccessAt: deps.now().toISOString() });
      deps.logCreated(result);
    } catch (error) {
      if (deps.signal.aborted) return;
      await deps.onStatus({ lastFailureAt: deps.now().toISOString() });
      deps.logFailed(error, retrySeconds);
      await deps.sleep(retrySeconds * 1000, deps.signal);
    }
  }
}

/** A sleep that survives the 24.8 day setTimeout limit and ends early on abort. */
export function abortableSleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolvePromise) => {
    if (signal.aborted) { resolvePromise(); return; }
    let remaining = ms;
    let timer: NodeJS.Timeout;
    const finish = () => {
      clearTimeout(timer);
      signal.removeEventListener('abort', finish);
      resolvePromise();
    };
    const step = () => {
      const chunk = Math.min(remaining, 12 * 3_600_000);
      remaining -= chunk;
      timer = setTimeout(remaining > 0 ? step : finish, chunk);
    };
    signal.addEventListener('abort', finish, { once: true });
    step();
  });
}

function statusPath(): string {
  return process.env['SCHEDULED_BACKUP_STATUS_FILE'] ?? '/tmp/scheduled-backup-status.json';
}

/** `--healthcheck`: exit 0 while the schedule is healthy, 1 otherwise. */
async function healthcheck(): Promise<void> {
  const verdict = evaluateHealth(await readStatusFile(statusPath()), new Date());
  if (!verdict.healthy) console.error(`scheduled backup unhealthy: ${verdict.reason}`);
  process.exitCode = verdict.healthy ? 0 : 1;
}

async function main(): Promise<void> {
  if (process.argv.includes('--healthcheck')) {
    await healthcheck();
    return;
  }
  installProcessGuards('command');
  const mode = parseScheduledMode(process.env['SIMPASTIL_SCHEDULED_BACKUP']);
  const stop = new AbortController();
  for (const signal of ['SIGTERM', 'SIGINT'] as const) process.on(signal, () => stop.abort());

  if (mode === 'off') {
    // Idle quietly, even with a bad interval or keep value: exiting would make
    // `restart: unless-stopped` start the container again and again.
    await writeStatusFile(statusPath(), {
      formatVersion: 1, mode, intervalSeconds: MIN_INTERVAL_SECONDS, startedAt: new Date().toISOString(),
    });
    logProcessEvent('info', 'scheduled_backup.disabled');
    const idle = setInterval(() => undefined, 2 ** 30);
    await new Promise<void>((done) => stop.signal.addEventListener('abort', () => done(), { once: true }));
    clearInterval(idle);
    return;
  }

  const intervalSeconds = parseInterval(
    process.env['SIMPASTIL_BACKUP_INTERVAL'],
    process.env['SCHEDULED_BACKUP_MIN_INTERVAL_SECONDS'] === undefined
      ? MIN_INTERVAL_SECONDS : Number(process.env['SCHEDULED_BACKUP_MIN_INTERVAL_SECONDS']),
  );
  const keep = parseKeep(process.env['SIMPASTIL_SCHEDULED_BACKUP_KEEP']);
  const status: ScheduledStatus = {
    formatVersion: 1, mode, intervalSeconds, startedAt: new Date().toISOString(),
  };
  const publish = async (update: Partial<ScheduledStatus> = {}) => {
    Object.assign(status, update);
    await writeStatusFile(statusPath(), status);
  };
  await publish();

  const environment = readRuntimeEnvironment();
  const database = loadDatabaseConfig(environment, 'migrate');
  const backupDir = process.env['BACKUP_DIR'] ?? '/backups';
  const options: ScheduledBackupOptions = {
    databaseUrl: database.url,
    backupDir,
    keep,
    roleGrantsSql: process.env['ROLE_GRANTS_SQL'] ?? '/ops/role-grants-rls.sql',
    crypto: {
      jwtPublicKey: '/run/secrets/jwt_public_key',
      totpKey: '/run/secrets/totp_encryption_key',
      outboxKey: '/run/secrets/delivery_payload_key',
      tlsCert: '/run/secrets/tls_cert',
    },
  };
  logProcessEvent('info', 'scheduled_backup.started', { intervalSeconds, keep });
  await runSchedule({
    intervalSeconds,
    now: () => new Date(),
    sleep: abortableSleep,
    listBundles: async () => {
      const directory = await ensureScheduledDir(backupDir);
      return readdir(directory);
    },
    takeBackup: (signal) => scheduledBackup({ ...options, signal }),
    onStatus: (update) => publish(update),
    logCreated: (result) => logProcessEvent('info', 'scheduled_backup.created', {
      bundle: result.bundle, pruned: result.pruned.length,
    }),
    logFailed: (error, retryInSeconds) => logProcessFailure('scheduled_backup.failed', error, { retryInSeconds }),
    signal: stop.signal,
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error: unknown) => {
    logProcessFailure('scheduled_backup.crashed', error);
    process.exitCode = 1;
  });
}
