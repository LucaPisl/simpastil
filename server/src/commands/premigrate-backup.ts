/**
 * Automatic pre-migration backup, run by the one-shot `premigrate-backup`
 * Compose service before `provision` and `migrate`.
 *
 * It skips an empty database and a database that already has every migration
 * this image bundles. Otherwise it writes a bundle in the exact layout
 * scripts/restore.sh accepts, verifies it, keeps the newest bundles and exits
 * non-zero on any failure, so Compose stops before anything is migrated.
 */
import { spawn } from 'node:child_process';
import { createHash, createPublicKey, X509Certificate } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { chmod, mkdir, readdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import postgres from 'postgres';
import { ConfigError, loadDatabaseConfig, readRuntimeEnvironment } from '../config/app-config.js';
import { logProcessFailure } from '../lib/process-log.js';
import { installProcessGuards } from '../lib/process-guards.js';
import { readBundledMigrationHead, type BundledMigrationHead } from '../modules/health/readiness.service.js';
import { readDeploymentManifest } from './export-deployment-manifest.js';

export const BUNDLE_PREFIX = 'pre-';

/** A failure this command raises itself; `code` is a fixed name that is safe to log. */
class BackupStepError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
    this.name = 'BackupStepError';
  }
}

const TOOL_FAILURE_CODES: Readonly<Record<string, string>> = {
  pg_dump: 'BACKUP_PG_DUMP_FAILED',
  psql: 'BACKUP_PSQL_FAILED',
};

const ARTIFACTS = [
  'crypto-material-inventory.json',
  'database.dump',
  'deployment-manifest.json',
  'role-grants-rls.json',
] as const;

export interface CryptoMaterialPaths {
  jwtPublicKey: string;
  totpKey: string;
  outboxKey: string;
  tlsCert: string;
}

export interface PremigrateBackupOptions {
  databaseUrl: string;
  backupDir: string;
  keep: number;
  roleGrantsSql: string;
  crypto: CryptoMaterialPaths;
  bundled?: BundledMigrationHead;
  now?: () => Date;
  log?: (event: Record<string, unknown>) => void;
}

export type PremigrateBackupResult =
  | { outcome: 'skipped'; reason: 'empty-database' | 'nothing-pending' }
  | { outcome: 'created'; bundle: string; pruned: string[] };

/** Decides whether this upgrade needs a backup, from the applied migration count. */
export function backupDecision(appliedCount: number | null, bundledCount: number):
  'empty-database' | 'nothing-pending' | 'backup' {
  if (appliedCount === null || appliedCount === 0) return 'empty-database';
  if (appliedCount >= bundledCount) return 'nothing-pending';
  return 'backup';
}

/** Bundles to delete so that only the newest `keep` remain, ordered by their UTC time. */
export function bundlesToPrune(names: readonly string[], keep: number): string[] {
  const time = (name: string) => name.slice(name.lastIndexOf('-') + 1);
  const bundles = names
    .filter((name) => /^pre-\d+-\d{8}T\d{6}Z$/.test(name))
    .sort((a, b) => time(a).localeCompare(time(b)) || a.localeCompare(b));
  return bundles.slice(0, Math.max(0, bundles.length - keep));
}

const sha256 = (bytes: Buffer | string) => createHash('sha256').update(bytes).digest('hex');

async function fileSha256(path: string): Promise<string> {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk as Buffer);
  return hash.digest('hex');
}

/** Same fingerprints, format and field order as scripts/crypto-material-inventory.sh. */
export async function cryptoMaterialInventory(paths: CryptoMaterialPaths): Promise<string> {
  const symmetricKey = async (path: string, label: string) => {
    const encoded = (await readFile(path, 'utf8')).replace(/\r?\n$/, '');
    if (!/^[a-fA-F0-9]{64}$/.test(encoded)) {
      throw new BackupStepError('BACKUP_KEY_INVALID', `${label} must contain exactly 32 bytes as 64 hexadecimal characters`);
    }
    return sha256(Buffer.from(encoded, 'hex'));
  };
  const jwt = sha256(createPublicKey(await readFile(paths.jwtPublicKey)).export({ format: 'der', type: 'spki' }));
  const totp = await symmetricKey(paths.totpKey, 'TOTP/API-key encryption key');
  const outbox = await symmetricKey(paths.outboxKey, 'Outbox envelope key');
  const tls = sha256(new X509Certificate(await readFile(paths.tlsCert)).raw);
  const material = (fingerprint: string) => ({ keyId: `sha256:${fingerprint}`, sha256: fingerprint });
  return `${JSON.stringify({
    formatVersion: 1,
    materials: {
      jwtVerificationKey: material(jwt),
      totpAndApiKeyEncryption: material(totp),
      outboxEnvelopeEncryption: material(outbox),
      tlsLeafCertificate: material(tls),
    },
  }, null, 2)}\n`;
}

/**
 * Splits the password out of a libpq URL so it reaches pg_dump and psql through
 * PGPASSWORD, never through argv where any process listing would show it.
 */
export function libpqConnection(databaseUrl: string): { dbname: string; env: NodeJS.ProcessEnv } {
  const url = new URL(databaseUrl);
  const password = decodeURIComponent(url.password);
  url.password = '';
  const env: NodeJS.ProcessEnv = { ...process.env };
  delete env['PGPASSWORD'];
  if (password !== '') env['PGPASSWORD'] = password;
  return { dbname: url.toString(), env };
}

function run(command: string, args: string[], env: NodeJS.ProcessEnv, stdoutPath?: string,
  signal?: AbortSignal): Promise<void> {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, { env, signal, stdio: ['ignore', stdoutPath ? 'pipe' : 'ignore', 'inherit'] });
    // Resolve only after the process exited cleanly and its captured output is flushed.
    let pending = stdoutPath ? 2 : 1;
    const done = () => { pending -= 1; if (pending === 0) resolvePromise(); };
    if (stdoutPath && child.stdout) {
      const output = createWriteStream(stdoutPath, { mode: 0o600, flags: 'wx' });
      output.on('error', reject);
      output.on('finish', done);
      child.stdout.pipe(output);
    }
    child.on('error', reject);
    child.on('close', (code) => (code === 0 ? done() : reject(new BackupStepError(TOOL_FAILURE_CODES[command] ?? 'BACKUP_TOOL_FAILED', `${command} exited with ${code}`))));
  });
}

export function timestamp(date: Date): string {
  return date.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
}

/**
 * Writes one verified, restorable bundle named `name` under `parentDir`. It is
 * built in a hidden staging directory and renamed into place only once every
 * checksum re-reads correctly, so a failure never leaves a half-written bundle.
 */
export async function writeBackupBundle(
  sql: postgres.Sql,
  options: Pick<PremigrateBackupOptions, 'databaseUrl' | 'roleGrantsSql' | 'crypto'>,
  parentDir: string,
  name: string,
  signal?: AbortSignal,
): Promise<void> {
  const staging = join(parentDir, `.staging-${name}`);
  const final = join(parentDir, name);
  await mkdir(staging, { mode: 0o700 });
  try {
    await writeFile(join(staging, 'crypto-material-inventory.json'), await cryptoMaterialInventory(options.crypto),
      { mode: 0o600, flag: 'wx' });
    const connection = libpqConnection(options.databaseUrl);
    await run('pg_dump', [`--dbname=${connection.dbname}`, '--format=custom', '--compress=6',
      `--file=${join(staging, 'database.dump')}`], connection.env, undefined, signal);
    await run('psql', [`--dbname=${connection.dbname}`, '--no-psqlrc', '--set=ON_ERROR_STOP=1', '--no-align',
      '--tuples-only', `--file=${options.roleGrantsSql}`], connection.env, join(staging, 'role-grants-rls.json'), signal);
    const deploymentText = await readDeploymentManifest(sql);
    await writeFile(join(staging, 'deployment-manifest.json'), deploymentText, { mode: 0o600, flag: 'wx' });

    const files: { name: string; sha256: string }[] = [];
    for (const artifact of ARTIFACTS) {
      const info = await stat(join(staging, artifact));
      if (!info.isFile() || info.size === 0) throw new BackupStepError('BACKUP_ARTIFACT_EMPTY', `backup artifact ${artifact} is empty`);
      files.push({ name: artifact, sha256: await fileSha256(join(staging, artifact)) });
    }
    const deployment = JSON.parse(deploymentText) as {
      releaseId: string; serverImageDigest: string; schemaVersion: number;
      contractVersion: string | number; migration: { headHash: string };
    };
    const restoreManifest = `${JSON.stringify({
      formatVersion: 1,
      createdAt: new Date().toISOString(),
      sensitive: true,
      encryption: 'not-encrypted-by-this-command',
      externalProtectionRequired: true,
      storage: 'operator-managed-outside-repository',
      source: {
        releaseId: deployment.releaseId,
        imageDigest: deployment.serverImageDigest,
        schemaVersion: deployment.schemaVersion,
        contractVersion: String(deployment.contractVersion),
        migrationHead: deployment.migration.headHash,
      },
      files,
    }, null, 2)}\n`;
    await writeFile(join(staging, 'restore-manifest.json'), restoreManifest, { mode: 0o600, flag: 'wx' });
    files.push({ name: 'restore-manifest.json', sha256: sha256(restoreManifest) });
    await writeFile(join(staging, 'checksums.sha256'),
      `${files.map((file) => `${file.sha256}  ${file.name}`).join('\n')}\n`, { mode: 0o600, flag: 'wx' });

    // Re-read every artifact before the bundle counts as taken.
    for (const file of files.slice(0, ARTIFACTS.length)) {
      if (await fileSha256(join(staging, file.name)) !== file.sha256) throw new BackupStepError('BACKUP_CHECKSUM_MISMATCH', 'backup checksum mismatch');
    }
    await rename(staging, final);
    await chmod(final, 0o700);
  } catch (error) {
    await rm(staging, { recursive: true, force: true });
    throw error;
  }
}

export async function premigrateBackup(options: PremigrateBackupOptions): Promise<PremigrateBackupResult> {
  const log = options.log ?? ((event) => console.log(JSON.stringify(event)));
  const bundled = options.bundled ?? readBundledMigrationHead();
  const sql = postgres(options.databaseUrl, { max: 1, connect_timeout: 10, onnotice: () => {} });
  try {
    const journal = await sql.unsafe<{ present: boolean }[]>(
      `SELECT pg_catalog.to_regclass('drizzle.__drizzle_migrations') IS NOT NULL AS present`,
    );
    const applied = journal[0]?.present === true
      ? Number((await sql.unsafe<{ count: string }[]>(
        'SELECT count(*)::text AS count FROM drizzle.__drizzle_migrations',
      ))[0]?.count ?? 0)
      : null;
    const decision = backupDecision(applied, bundled.count);
    if (decision !== 'backup') {
      log({ event: 'premigrate_backup.skipped', reason: decision, applied, bundled: bundled.count });
      return { outcome: 'skipped', reason: decision };
    }

    const name = `${BUNDLE_PREFIX}${applied}-${timestamp(options.now?.() ?? new Date())}`;
    await writeBackupBundle(sql, options, options.backupDir, name);

    const pruned = bundlesToPrune(await readdir(options.backupDir), options.keep);
    for (const old of pruned) await rm(join(options.backupDir, old), { recursive: true, force: true });
    log({ event: 'premigrate_backup.created', bundle: name, applied, bundled: bundled.count, pruned });
    return { outcome: 'created', bundle: name, pruned };
  } finally {
    await sql.end();
  }
}

async function main(): Promise<void> {
  installProcessGuards('command');
  const environment = readRuntimeEnvironment();
  const database = loadDatabaseConfig(environment, 'migrate');
  const keep = Number(process.env['BACKUP_KEEP'] ?? '5');
  if (!Number.isInteger(keep) || keep < 1 || keep > 100) throw new ConfigError('BACKUP_KEEP must be an integer from 1 to 100');
  await premigrateBackup({
    databaseUrl: database.url,
    backupDir: process.env['BACKUP_DIR'] ?? '/backups',
    keep,
    roleGrantsSql: process.env['ROLE_GRANTS_SQL'] ?? '/ops/role-grants-rls.sql',
    crypto: {
      jwtPublicKey: '/run/secrets/jwt_public_key',
      totpKey: '/run/secrets/totp_encryption_key',
      outboxKey: '/run/secrets/delivery_payload_key',
      tlsCert: '/run/secrets/tls_cert',
    },
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error: unknown) => {
    logProcessFailure('premigrate_backup.failed', error);
    process.exitCode = 1;
  });
}
