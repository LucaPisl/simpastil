import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { TOTP, Secret } from 'otpauth';
import { eq, sql as drizzleSql } from 'drizzle-orm';
import { createHash } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, prepareBootstrapProof, truncateAll } from '../helpers/db-helpers.js';
import { runProvisionCommand } from '../../db/provision.js';
import { adminConfig, adminRefreshTokens, auditLogs, backupCodes, users } from '../../db/schema.js';
import type { Db } from '../../db/client.js';

const OLD_PASSWORD = 'adminpassword1234';
const NEW_PASSWORD = 'a-brand-new-password-5678';

interface Tokens { accessToken: string; refreshToken: string }

/** The real `provision reset-admin` path as the superuser, like the Compose provision service. */
describe('provision reset-admin command', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;
  let stdout: ReturnType<typeof vi.spyOn>;
  let stderr: ReturnType<typeof vi.spyOn>;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    app = await buildApp({
      db: appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey: process.env['JWT_PUBLIC_KEY']!,
      ttlSeconds: 900,
    });
  });

  afterAll(async () => {
    await app.close();
    await cleanup();
  });

  beforeEach(() => {
    vi.stubEnv('DATABASE_URL_SUPER', process.env['TEST_DATABASE_URL_SUPER']!);
    stdout = vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
    stderr = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
  });

  afterEach(async () => {
    stdout.mockRestore();
    stderr.mockRestore();
    vi.unstubAllEnvs();
    await truncateAll(superDb);
  });

  const printed = () => stdout.mock.calls.map((call) => String(call[0])).join('');
  const errors = () => stderr.mock.calls.map((call) => String(call[0])).join('');

  async function setupAdmin(password = OLD_PASSWORD, email = 'admin@test.com'): Promise<void> {
    const proof = await prepareBootstrapProof(superDb);
    const res = await app.inject({
      method: 'POST', url: '/api/v1/admin/setup', payload: { email, password, proof },
    });
    expect(res.statusCode).toBe(201);
  }

  const login = (password: string) => app.inject({
    method: 'POST', url: '/api/v1/admin/auth/login', payload: { password },
  });
  const listKeys = (token: string) => app.inject({
    method: 'GET', url: '/api/v1/admin/keys', headers: { authorization: `Bearer ${token}` },
  });
  const refresh = (refreshToken: string) => app.inject({
    method: 'POST', url: '/api/v1/admin/auth/refresh', payload: { refreshToken },
  });

  const code = (secret: string, offsetSteps = 0) => new TOTP({
    issuer: 'Simpastil', label: 'admin@test.com', secret: Secret.fromBase32(secret), digits: 6, period: 30,
  }).generate({ timestamp: Date.now() + offsetSteps * 30_000 });

  /** Turns on two-factor and returns a session earned through the challenge. */
  async function enableTwoFactor(): Promise<Tokens> {
    const first = (await login(OLD_PASSWORD)).json<Tokens>();
    const bearer = { authorization: `Bearer ${first.accessToken}` };
    const setup = await app.inject({ method: 'POST', url: '/api/v1/admin/auth/2fa/setup', headers: bearer });
    const { secret } = setup.json<{ secret: string }>();
    const enable = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/2fa/enable', headers: bearer, payload: { code: code(secret) },
    });
    expect(enable.statusCode).toBe(200);
    const challenge = await login(OLD_PASSWORD);
    const { challengeToken } = challenge.json<{ challengeToken: string }>();
    const done = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/2fa/challenge',
      payload: { challengeToken, code: code(secret, 1) },
    });
    expect(done.statusCode).toBe(200);
    return done.json<Tokens>();
  }

  async function runReset(): Promise<{ proof: string; generation: string; expiresAt: string }> {
    await runProvisionCommand('reset-admin');
    return JSON.parse(printed().trim()) as { proof: string; generation: string; expiresAt: string };
  }

  it('refuses without the privileged database context and changes nothing', async () => {
    await setupAdmin();
    vi.stubEnv('DATABASE_URL_SUPER', process.env['TEST_DATABASE_URL_APP']!);

    await expect(runProvisionCommand('reset-admin')).rejects.toThrow('Privileged command requires DATABASE_URL_SUPER');

    expect(await superDb.select().from(adminConfig)).toHaveLength(1);
    expect((await login(OLD_PASSWORD)).statusCode).toBe(200);
  });

  it('refuses in environment-managed admin mode with a clear message', async () => {
    await setupAdmin();
    vi.stubEnv('ADMIN_EMAIL', 'env-admin@example.invalid');
    vi.stubEnv('ADMIN_PASSWORD', 'environment-managed-password-123');

    await expect(runProvisionCommand('reset-admin')).rejects.toThrow('reset-admin refused');

    expect(errors()).toContain('ADMIN_EMAIL and ADMIN_PASSWORD');
    expect(printed()).toBe('');
    expect(await superDb.select().from(adminConfig)).toHaveLength(1);
    expect(await superDb.select().from(auditLogs).where(eq(auditLogs.action, 'admin.access_reset'))).toHaveLength(0);
  });

  it('refuses when no database-backed administrator exists', async () => {
    await expect(runProvisionCommand('reset-admin')).rejects.toThrow('reset-admin refused');

    expect(errors()).toContain('rotate-bootstrap');
    expect(printed()).toBe('');
    expect(await superDb.select().from(auditLogs)).toHaveLength(0);
  });

  it('recovers an administrator whose authenticator and backup codes are lost', async () => {
    await setupAdmin();
    const twoFactorSession = await enableTwoFactor();
    expect((await listKeys(twoFactorSession.accessToken)).statusCode).toBe(200);

    // A person's own backup code must survive: only user_id IS NULL rows belong to the admin.
    const [account] = await superDb.insert(users)
      .values({ email: 'person@example.invalid', passwordHash: 'x', totpEnabled: true })
      .returning({ id: users.id });
    await superDb.insert(backupCodes).values({ userId: account!.id, codeHash: 'user-code-hash' });
    const adminCodesBefore = await superDb.execute(drizzleSql`SELECT 1 FROM backup_codes WHERE user_id IS NULL`);
    expect(adminCodesBefore.length).toBeGreaterThan(0);

    const output = await runReset();

    expect(output.proof).toMatch(/^[0-9a-f]{64}$/);
    expect(new Date(output.expiresAt).getTime() - Date.now()).toBeGreaterThan(29 * 60_000);
    expect(new Date(output.expiresAt).getTime() - Date.now()).toBeLessThanOrEqual(30 * 60_000);

    // The administrator, its second factor and every admin backup code are gone.
    expect(await superDb.select().from(adminConfig)).toHaveLength(0);
    expect(await superDb.execute(drizzleSql`SELECT 1 FROM backup_codes WHERE user_id IS NULL`)).toHaveLength(0);
    expect(await superDb.select().from(backupCodes).where(eq(backupCodes.userId, account!.id))).toHaveLength(1);
    expect(await superDb.select().from(users)).toHaveLength(1);

    // Every earlier session is dead, and sign-in is closed until setup runs again.
    expect((await listKeys(twoFactorSession.accessToken)).statusCode).toBe(401);
    expect((await refresh(twoFactorSession.refreshToken)).statusCode).toBe(401);
    expect((await login(OLD_PASSWORD)).statusCode).toBe(401);
    expect(await superDb.select().from(adminRefreshTokens).where(eq(adminRefreshTokens.revoked, false))).toHaveLength(0);

    // The proof is stored only as a hash and the authority guard is untouched.
    const [state] = await superDb.execute<{ token_hash: string; consumed_at: Date | null }>(
      drizzleSql`SELECT token_hash, consumed_at FROM admin_bootstrap_state`,
    );
    expect(state?.token_hash).toBe(createHash('sha256').update(output.proof).digest('hex'));
    expect(state?.consumed_at).toBeNull();
    await expect(superDb.execute(drizzleSql`UPDATE admin_bootstrap_state SET generation = generation + 1`))
      .rejects.toThrow();

    // Setup with the new proof creates a fresh administrator without two-factor.
    const setup = await app.inject({
      method: 'POST', url: '/api/v1/admin/setup',
      payload: { email: 'recovered@test.com', password: NEW_PASSWORD, proof: output.proof },
    });
    expect(setup.statusCode).toBe(201);
    const [recovered] = await superDb.select().from(adminConfig);
    expect(recovered?.email).toBe('recovered@test.com');
    expect(recovered?.totpEnabled).toBe(false);
    expect(recovered?.totpSecret).toBeNull();

    expect((await login(OLD_PASSWORD)).statusCode).toBe(401);
    const fresh = await login(NEW_PASSWORD);
    expect(fresh.statusCode).toBe(200);
    expect(fresh.json()).toHaveProperty('accessToken');
    expect((await listKeys(fresh.json<Tokens>().accessToken)).statusCode).toBe(200);

    // Even though the new administrator starts at session version 1 again, the old sign-in stays dead.
    expect((await listKeys(twoFactorSession.accessToken)).statusCode).toBe(401);
    expect((await refresh(twoFactorSession.refreshToken)).statusCode).toBe(401);

    // The consumed proof cannot be replayed.
    const replay = await app.inject({
      method: 'POST', url: '/api/v1/admin/setup',
      payload: { email: 'again@test.com', password: NEW_PASSWORD, proof: output.proof },
    });
    expect(replay.statusCode).toBeGreaterThanOrEqual(400);
  }, 60_000);

  it('recovers a forgotten password the same way', async () => {
    await setupAdmin();
    const session = (await login(OLD_PASSWORD)).json<Tokens>();

    const output = await runReset();

    expect((await listKeys(session.accessToken)).statusCode).toBe(401);
    const setup = await app.inject({
      method: 'POST', url: '/api/v1/admin/setup',
      payload: { email: 'admin@test.com', password: NEW_PASSWORD, proof: output.proof },
    });
    expect(setup.statusCode).toBe(201);
    expect((await login(NEW_PASSWORD)).statusCode).toBe(200);
  });

  it('records one audit entry that carries no secret', async () => {
    await setupAdmin();

    const output = await runReset();

    const entries = await superDb.select().from(auditLogs).where(eq(auditLogs.action, 'admin.access_reset'));
    expect(entries).toHaveLength(1);
    const [entry] = entries;
    expect(entry?.actor).toBe('provision');
    expect(entry?.targetType).toBe('admin');
    const serialized = JSON.stringify(entry);
    expect(serialized).not.toContain(output.proof);
    expect(serialized).not.toContain('admin@test.com');
    expect(serialized).not.toContain(OLD_PASSWORD);
  });

  it('rolls everything back when a later step fails', async () => {
    await setupAdmin();
    const session = (await login(OLD_PASSWORD)).json<Tokens>();
    await superDb.execute(drizzleSql`
      ALTER TABLE audit_logs ADD CONSTRAINT zz_reset_admin_test_failure CHECK (action <> 'admin.access_reset')
    `);
    try {
      await expect(runProvisionCommand('reset-admin')).rejects.toThrow();
    } finally {
      await superDb.execute(drizzleSql`ALTER TABLE audit_logs DROP CONSTRAINT zz_reset_admin_test_failure`);
    }

    expect(printed()).toBe('');
    expect(await superDb.select().from(adminConfig)).toHaveLength(1);
    expect((await listKeys(session.accessToken)).statusCode).toBe(200);
  });
});
