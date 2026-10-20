import { execFileSync, spawnSync } from 'node:child_process';
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { mkdtempSync, readdirSync, rmSync, statSync, writeFileSync, mkdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  backupDecision,
  bundlesToPrune,
  libpqConnection,
  premigrateBackup,
  run,
  type CryptoMaterialPaths,
} from '../../commands/premigrate-backup.js';
import { readBundledMigrationHead } from '../../modules/health/readiness.service.js';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../../..');
const hasTool = (tool: string) => spawnSync(tool, ['--version'], { stdio: 'ignore' }).status === 0;
const canDump = hasTool('pg_dump') && hasTool('psql') && hasTool('openssl') && hasTool('bash');

describe('premigrate backup decisions', () => {
  it('skips an empty database and one with nothing pending', () => {
    expect(backupDecision(null, 25)).toBe('empty-database');
    expect(backupDecision(0, 25)).toBe('empty-database');
    expect(backupDecision(25, 25)).toBe('nothing-pending');
    expect(backupDecision(26, 25)).toBe('nothing-pending');
    expect(backupDecision(24, 25)).toBe('backup');
  });

  it('prunes only the oldest bundles beyond the keep count', () => {
    const names = [
      'pre-23-20261001T000000Z', 'pre-24-20261003T000000Z', 'pre-24-20261002T000000Z',
      '.staging-pre-25-20261004T000000Z', 'manual-backup', 'pre-25-20261004T000000Z',
    ];
    expect(bundlesToPrune(names, 2)).toEqual(['pre-23-20261001T000000Z', 'pre-24-20261002T000000Z']);
    expect(bundlesToPrune(names, 5)).toEqual([]);
    expect(bundlesToPrune(['pre-99-20261001T000000Z', 'pre-100-20261002T000000Z'], 1)).toEqual([
      'pre-99-20261001T000000Z',
    ]);
  });

  it('kills a tool that outlives its time limit and fails with a fixed code', async () => {
    const started = Date.now();
    await expect(run('sleep', ['30'], process.env, undefined, undefined, 150))
      .rejects.toMatchObject({ code: 'BACKUP_TOOL_TIMEOUT' });
    expect(Date.now() - started).toBeLessThan(5000);
    await expect(run('true', [], process.env, undefined, undefined, 5000)).resolves.toBeUndefined();
    await expect(run('false', [], process.env)).rejects.toMatchObject({ code: 'BACKUP_TOOL_FAILED' });
  });

  it('keeps the database password out of pg_dump and psql arguments', () => {
    const connection = libpqConnection('postgresql://postgres:p%40ss%3Aword@postgres:5432/simpastil?sslmode=disable');
    expect(connection.dbname).toBe('postgresql://postgres@postgres:5432/simpastil?sslmode=disable');
    expect(connection.env['PGPASSWORD']).toBe('p@ss:word');
  });
});

describe.skipIf(!canDump)('premigrate backup bundle', () => {
  const superUrl = process.env['TEST_DATABASE_URL_SUPER']!;
  const bundled = readBundledMigrationHead();
  let work: string;
  let backupDir: string;
  let crypto: CryptoMaterialPaths;

  beforeAll(() => {
    work = mkdtempSync(join(tmpdir(), 'premigrate-backup-'));
    backupDir = join(work, 'backups');
    mkdirSync(backupDir, { mode: 0o700 });
    const { publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
    crypto = {
      jwtPublicKey: join(work, 'jwt_public.pem'),
      totpKey: join(work, 'totp'),
      outboxKey: join(work, 'outbox'),
      tlsCert: join(work, 'cert.pem'),
    };
    writeFileSync(crypto.jwtPublicKey, publicKey.export({ format: 'pem', type: 'spki' }));
    writeFileSync(crypto.totpKey, `${randomBytes(32).toString('hex')}\n`);
    writeFileSync(crypto.outboxKey, randomBytes(32).toString('hex'));
    execFileSync('openssl', ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes',
      '-keyout', join(work, 'key.pem'), '-out', crypto.tlsCert, '-days', '1', '-subj', '/CN=localhost'],
    { stdio: 'ignore' });
  });

  afterAll(() => {
    rmSync(work, { recursive: true, force: true });
  });

  const options = (now: Date, count = bundled.count + 1) => ({
    databaseUrl: superUrl,
    backupDir,
    keep: 2,
    roleGrantsSql: join(repoRoot, 'scripts/backup/role-grants-rls.sql'),
    crypto,
    bundled: { ...bundled, count },
    now: () => now,
    log: () => {},
  });

  it('skips when the image bundles nothing new', async () => {
    const result = await premigrateBackup(options(new Date('2026-10-16T10:00:00Z'), bundled.count));
    expect(result).toEqual({ outcome: 'skipped', reason: 'nothing-pending' });
    expect(readdirSync(backupDir)).toEqual([]);
  });

  it('writes a bundle that the restore script verifies and matches the host inventory', async () => {
    const result = await premigrateBackup(options(new Date('2026-10-16T10:00:00Z')));
    expect(result.outcome).toBe('created');
    const bundle = join(backupDir, `pre-${bundled.count}-20261016T100000Z`);
    const verify = spawnSync('bash', ['-c', 'source "$1/scripts/lib/backup-common.sh" && backup_verify_bundle "$2"',
      'verify', repoRoot, bundle], { encoding: 'utf8' });
    expect(verify.stderr).toBe('');
    expect(verify.status).toBe(0);

    // pg_dump uses the process umask; every bundle file must still be owner-only.
    for (const name of readdirSync(bundle)) {
      expect(statSync(join(bundle, name)).mode & 0o777, name).toBe(0o600);
    }

    const hostInventory = join(work, 'host-inventory.json');
    execFileSync(join(repoRoot, 'scripts/crypto-material-inventory.sh'), [
      '--jwt-public-key', crypto.jwtPublicKey, '--totp-key', crypto.totpKey,
      '--outbox-key', crypto.outboxKey, '--tls-cert', crypto.tlsCert, '--output', hostInventory,
    ]);
    expect(readFileSync(join(bundle, 'crypto-material-inventory.json'), 'utf8'))
      .toBe(readFileSync(hostInventory, 'utf8'));
  });

  it('keeps only the newest bundles and leaves no staging directory behind', async () => {
    await premigrateBackup(options(new Date('2026-10-16T11:00:00Z')));
    const result = await premigrateBackup(options(new Date('2026-10-16T12:00:00Z')));
    expect(result).toMatchObject({ outcome: 'created', pruned: [`pre-${bundled.count}-20261016T100000Z`] });
    expect(readdirSync(backupDir).sort()).toEqual([
      `pre-${bundled.count}-20261016T110000Z`,
      `pre-${bundled.count}-20261016T120000Z`,
    ]);
  });

  it('fails without leaving a partial bundle when key material is invalid', async () => {
    const badKey = join(work, 'bad-key');
    writeFileSync(badKey, 'not-a-key');
    await expect(premigrateBackup({ ...options(new Date('2026-10-16T13:00:00Z')), crypto: { ...crypto, totpKey: badKey } }))
      .rejects.toThrow('TOTP/API-key encryption key');
    expect(readdirSync(backupDir).filter((name) => name.includes('20261016T130000Z'))).toEqual([]);
  });
});
