import { execFileSync, spawnSync } from 'node:child_process';
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, rmSync, statSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { CryptoMaterialPaths } from '../../commands/premigrate-backup.js';
import { scheduledBackup } from '../../commands/scheduled-backup.js';
import { describeBackupTools } from '../helpers/backup-tools.js';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../../..');

describeBackupTools('scheduled backup bundle', () => {
  const superUrl = process.env['TEST_DATABASE_URL_SUPER']!;
  let work: string;
  let backupDir: string;
  let crypto: CryptoMaterialPaths;

  beforeAll(() => {
    work = mkdtempSync(join(tmpdir(), 'scheduled-backup-'));
    backupDir = join(work, 'backups');
    mkdirSync(backupDir, { mode: 0o700 });
    // Pre-migration bundles live at the top level and must survive every prune.
    mkdirSync(join(backupDir, 'pre-25-20260101T000000Z'), { mode: 0o700 });
    mkdirSync(join(backupDir, 'pre-24-20250101T000000Z'), { mode: 0o700 });
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

  const options = (now: Date, keep = 2) => ({
    databaseUrl: superUrl,
    backupDir,
    keep,
    roleGrantsSql: join(repoRoot, 'scripts/backup/role-grants-rls.sql'),
    crypto,
    now: () => now,
  });

  it('always backs up into scheduled/ even though no migration is pending', async () => {
    const result = await scheduledBackup(options(new Date('2026-10-19T10:00:00Z')));
    expect(result).toEqual({ bundle: 'scheduled-20261019T100000Z', pruned: [] });
    const scheduled = join(backupDir, 'scheduled');
    expect(statSync(scheduled).mode & 0o777).toBe(0o700);
    const bundle = join(scheduled, 'scheduled-20261019T100000Z');
    const verify = spawnSync('bash', ['-c', 'source "$1/scripts/lib/backup-common.sh" && backup_verify_bundle "$2"',
      'verify', repoRoot, bundle], { encoding: 'utf8' });
    expect(verify.stderr).toBe('');
    expect(verify.status).toBe(0);
  });

  it('prunes only old scheduled bundles and never a pre-migration bundle', async () => {
    await scheduledBackup(options(new Date('2026-10-19T11:00:00Z')));
    const result = await scheduledBackup(options(new Date('2026-10-19T12:00:00Z')));
    expect(result.pruned).toEqual(['scheduled-20261019T100000Z']);
    expect(readdirSync(join(backupDir, 'scheduled')).sort()).toEqual([
      'scheduled-20261019T110000Z', 'scheduled-20261019T120000Z',
    ]);
    expect(readdirSync(backupDir).sort()).toEqual([
      'pre-24-20250101T000000Z', 'pre-25-20260101T000000Z', 'scheduled',
    ]);
  });

  it('removes a stale staging directory and leaves no partial bundle after a failure', async () => {
    const stale = join(backupDir, 'scheduled', '.staging-scheduled-20261019T010000Z');
    mkdirSync(stale);
    const old = new Date('2026-10-18T00:00:00Z');
    utimesSync(stale, old, old);
    const badKey = join(work, 'bad-key');
    writeFileSync(badKey, 'not-a-key');
    await expect(scheduledBackup({ ...options(new Date('2026-10-19T13:00:00Z')),
      crypto: { ...crypto, totpKey: badKey } })).rejects.toThrow('TOTP/API-key encryption key');
    const names = readdirSync(join(backupDir, 'scheduled'));
    expect(names.filter((name) => name.startsWith('.staging'))).toEqual([]);
    expect(names.sort()).toEqual(['scheduled-20261019T110000Z', 'scheduled-20261019T120000Z']);
  });

  it.skipIf(process.getuid?.() === 0)('reports a prune failure separately and still counts the backup as taken', async () => {
    // An old bundle that cannot be deleted: its inner directory is read-only.
    const old = join(backupDir, 'scheduled', 'scheduled-20200101T000000Z');
    const inner = join(old, 'locked');
    mkdirSync(inner, { recursive: true });
    writeFileSync(join(inner, 'file'), 'x');
    chmodSync(inner, 0o500);
    try {
      const result = await scheduledBackup(options(new Date('2026-10-19T12:30:00Z'), 2));
      expect(result.bundle).toBe('scheduled-20261019T123000Z');
      expect(result.pruneError).toBeDefined();
      // The other old bundles were still removed; only the locked one remains.
      expect(readdirSync(join(backupDir, 'scheduled')).sort()).toEqual([
        'scheduled-20200101T000000Z', 'scheduled-20261019T120000Z', 'scheduled-20261019T123000Z',
      ]);
    } finally {
      chmodSync(inner, 0o700);
      rmSync(old, { recursive: true, force: true });
      rmSync(join(backupDir, 'scheduled', 'scheduled-20261019T123000Z'), { recursive: true, force: true });
    }
  });
});
