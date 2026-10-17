import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import { TOTP, Secret } from 'otpauth';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, prepareBootstrapProof, truncateAll, createUnclaimedKey } from '../helpers/db-helpers.js';
import { users, auditLogs } from '../../db/schema.js';
import { eq, desc } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';

const EMAIL = 'totp-user@example.com';
const PASSWORD = 'password1234';
const ADMIN_PASSWORD = 'adminpassword1234';

describe('user TOTP 2FA', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;
  let apiKey: string;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    app = await buildApp({
      db: appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey: process.env['JWT_PUBLIC_KEY']!,
      ttlSeconds: 60,
    });
    apiKey = await createUnclaimedKey(superDb);
  });

  afterAll(async () => { await app.close(); await cleanup(); });
  afterEach(async () => {
    await truncateAll(superDb);
    apiKey = await createUnclaimedKey(superDb);
  });

  async function register() {
    return app.inject({
      method: 'POST', url: '/api/v1/auth/register',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    });
  }

  async function login() {
    return app.inject({
      method: 'POST', url: '/api/v1/auth/login',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    });
  }

  function generateCode(secret: string): string {
    const totp = new TOTP({ issuer: 'Simpastil', label: EMAIL, secret: Secret.fromBase32(secret), digits: 6, period: 30 });
    return totp.generate();
  }

  async function fullSetupAndEnable(token: string): Promise<{ secret: string; backupCodes: string[] }> {
    const setupRes = await app.inject({
      method: 'POST', url: '/api/v1/auth/2fa/setup',
      headers: { Authorization: `Bearer ${token}`, 'X-Api-Key': apiKey },
    });
    const { secret } = setupRes.json<{ secret: string }>();
    const code = generateCode(secret);
    const enableRes = await app.inject({
      method: 'POST', url: '/api/v1/auth/2fa/enable',
      headers: { Authorization: `Bearer ${token}`, 'X-Api-Key': apiKey },
      payload: { code },
    });
    const { backupCodes } = enableRes.json<{ backupCodes: string[] }>();
    return { secret, backupCodes };
  }

  // ── 2FA stays optional ──────────────────────────────────────────────────

  it('login returns tokens directly when 2FA is not enabled', async () => {
    await register();
    const res = await login();
    expect(res.statusCode).toBe(200);
    const body = res.json<Record<string, unknown>>();
    expect(body.accessToken).toBeTruthy();
    expect(body.refreshToken).toBeTruthy();
    expect(body.requires2fa).toBeUndefined();
  });

  // ── Setup → Enable → Challenge flow ────────────────────────────────────

  it('setup returns secret and otpauthUri', async () => {
    await register();
    const { accessToken } = (await login()).json<{ accessToken: string }>();
    const res = await app.inject({
      method: 'POST', url: '/api/v1/auth/2fa/setup',
      headers: { Authorization: `Bearer ${accessToken}`, 'X-Api-Key': apiKey },
    });
    expect(res.statusCode).toBe(200);
    const body = res.json<{ secret: string; otpauthUri: string }>();
    expect(body.secret).toBeTruthy();
    expect(body.otpauthUri).toContain('otpauth://totp/');
  });

  it('enable validates TOTP code and returns backup codes', async () => {
    await register();
    const { accessToken } = (await login()).json<{ accessToken: string }>();
    const { backupCodes } = await fullSetupAndEnable(accessToken);
    expect(backupCodes).toHaveLength(8);
    expect(backupCodes[0]).toMatch(/^[0-9a-f]{8}$/);
  });

  it('enable rejects invalid TOTP code', async () => {
    await register();
    const { accessToken } = (await login()).json<{ accessToken: string }>();
    await app.inject({
      method: 'POST', url: '/api/v1/auth/2fa/setup',
      headers: { Authorization: `Bearer ${accessToken}`, 'X-Api-Key': apiKey },
    });
    const res = await app.inject({
      method: 'POST', url: '/api/v1/auth/2fa/enable',
      headers: { Authorization: `Bearer ${accessToken}`, 'X-Api-Key': apiKey },
      payload: { code: '000000' },
    });
    expect(res.statusCode).toBe(400);
    expect(res.json<{ code: string }>().code).toBe('TOTP_INVALID_CODE');
  });

  it('login returns requires2fa + challengeToken when 2FA is enabled', async () => {
    await register();
    const { accessToken } = (await login()).json<{ accessToken: string }>();
    await fullSetupAndEnable(accessToken);

    const res = await login();
    expect(res.statusCode).toBe(200);
    const body = res.json<{ requires2fa: boolean; challengeToken: string }>();
    expect(body.requires2fa).toBe(true);
    expect(body.challengeToken).toBeTruthy();
  });

  it('challenge with valid TOTP code returns tokens', async () => {
    await register();
    const { accessToken } = (await login()).json<{ accessToken: string }>();
    const { secret } = await fullSetupAndEnable(accessToken);

    const { challengeToken } = (await login()).json<{ challengeToken: string }>();
    const code = generateCode(secret);
    const res = await app.inject({
      method: 'POST', url: '/api/v1/auth/2fa/challenge',
      headers: { 'X-Api-Key': apiKey },
      payload: { challengeToken, code },
    });
    expect(res.statusCode).toBe(200);
    const body = res.json<{ accessToken: string; refreshToken: string }>();
    expect(body.accessToken).toBeTruthy();
    expect(body.refreshToken).toBeTruthy();
  });

  it('challenge with invalid code returns 400', async () => {
    await register();
    const { accessToken } = (await login()).json<{ accessToken: string }>();
    await fullSetupAndEnable(accessToken);

    const { challengeToken } = (await login()).json<{ challengeToken: string }>();
    const res = await app.inject({
      method: 'POST', url: '/api/v1/auth/2fa/challenge',
      headers: { 'X-Api-Key': apiKey },
      payload: { challengeToken, code: '000000' },
    });
    expect(res.statusCode).toBe(400);
    expect(res.json<{ code: string }>().code).toBe('TOTP_INVALID_CODE');
  });

  // ── Backup codes ───────────────────────────────────────────────────────

  it('backup code works for challenge and is single-use', async () => {
    await register();
    const { accessToken } = (await login()).json<{ accessToken: string }>();
    const { backupCodes } = await fullSetupAndEnable(accessToken);

    const code = backupCodes[0]!;

    // First use — should succeed
    const { challengeToken: ct1 } = (await login()).json<{ challengeToken: string }>();
    const res1 = await app.inject({
      method: 'POST', url: '/api/v1/auth/2fa/challenge',
      headers: { 'X-Api-Key': apiKey },
      payload: { challengeToken: ct1, code },
    });
    expect(res1.statusCode).toBe(200);
    expect(res1.json<{ accessToken: string }>().accessToken).toBeTruthy();

    // Second use of same backup code — should fail
    const { challengeToken: ct2 } = (await login()).json<{ challengeToken: string }>();
    const res2 = await app.inject({
      method: 'POST', url: '/api/v1/auth/2fa/challenge',
      headers: { 'X-Api-Key': apiKey },
      payload: { challengeToken: ct2, code },
    });
    expect(res2.statusCode).toBe(400);
    expect(res2.json<{ code: string }>().code).toBe('TOTP_INVALID_CODE');
  });

  // ── Disable ────────────────────────────────────────────────────────────

  it('disable reverts login to direct token flow', async () => {
    await register();
    const { accessToken } = (await login()).json<{ accessToken: string }>();
    const { secret, backupCodes } = await fullSetupAndEnable(accessToken);

    // Enabling 2FA invalidates the pre-enable access token. Complete a fresh
    // challenge before disabling, and use a backup code so replay protection
    // does not reject the same TOTP step twice.
    const { challengeToken } = (await login()).json<{ challengeToken: string }>();
    const challengeRes = await app.inject({
      method: 'POST', url: '/api/v1/auth/2fa/challenge',
      headers: { 'X-Api-Key': apiKey },
      payload: { challengeToken, code: generateCode(secret) },
    });
    expect(challengeRes.statusCode).toBe(200);
    const freshAccessToken = challengeRes.json<{ accessToken: string }>().accessToken;

    // Disable with a valid, single-use backup code.
    const disableRes = await app.inject({
      method: 'POST', url: '/api/v1/auth/2fa/disable',
      headers: { Authorization: `Bearer ${freshAccessToken}`, 'X-Api-Key': apiKey },
      payload: { code: backupCodes[0] },
    });
    expect(disableRes.statusCode).toBe(200);

    const staleAfterDisable = await app.inject({
      method: 'GET', url: '/api/v1/profiles',
      headers: { Authorization: `Bearer ${freshAccessToken}`, 'X-Api-Key': apiKey },
    });
    expect(staleAfterDisable.statusCode).toBe(401);

    // Login should now return tokens directly again
    const loginRes = await login();
    expect(loginRes.statusCode).toBe(200);
    const body = loginRes.json<Record<string, unknown>>();
    expect(body.accessToken).toBeTruthy();
    expect(body.requires2fa).toBeUndefined();
  });
});

describe('admin TOTP 2FA', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    app = await buildApp({
      db: appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey: process.env['JWT_PUBLIC_KEY']!,
      ttlSeconds: 60,
    });
  });

  afterAll(async () => { await app.close(); await cleanup(); });
  afterEach(async () => { await truncateAll(superDb); });

  async function adminSetup() {
    const proof = await prepareBootstrapProof(superDb);
    return app.inject({ method: 'POST', url: '/api/v1/admin/setup', payload: { email: 'admin@test.com', password: ADMIN_PASSWORD, proof } });
  }

  async function adminLogin() {
    return app.inject({ method: 'POST', url: '/api/v1/admin/auth/login', payload: { password: ADMIN_PASSWORD } });
  }

  function generateAdminCode(secret: string): string {
    const totp = new TOTP({ issuer: 'Simpastil', label: 'admin@test.com', secret: Secret.fromBase32(secret), digits: 6, period: 30 });
    return totp.generate();
  }

  it('admin login returns tokens directly when 2FA is not enabled', async () => {
    await adminSetup();
    const res = await adminLogin();
    expect(res.statusCode).toBe(200);
    const body = res.json<Record<string, unknown>>();
    expect(body.accessToken).toBeTruthy();
    expect(body.requires2fa).toBeUndefined();
  });

  it('admin 2FA setup → enable → challenge flow works end-to-end', async () => {
    await adminSetup();
    const { accessToken } = (await adminLogin()).json<{ accessToken: string }>();

    // Setup
    const setupRes = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/2fa/setup',
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    expect(setupRes.statusCode).toBe(200);
    const { secret } = setupRes.json<{ secret: string; otpauthUri: string }>();

    // Enable
    const code = generateAdminCode(secret);
    const enableRes = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/2fa/enable',
      headers: { Authorization: `Bearer ${accessToken}` },
      payload: { code },
    });
    expect(enableRes.statusCode).toBe(200);
    const { backupCodes } = enableRes.json<{ backupCodes: string[] }>();
    expect(backupCodes).toHaveLength(8);

    // Login now requires 2FA
    const loginRes = await adminLogin();
    expect(loginRes.statusCode).toBe(200);
    const { requires2fa, challengeToken } = loginRes.json<{ requires2fa: boolean; challengeToken: string }>();
    expect(requires2fa).toBe(true);

    // Challenge with valid code
    const code2 = generateAdminCode(secret);
    const challengeRes = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/2fa/challenge',
      payload: { challengeToken, code: code2 },
    });
    expect(challengeRes.statusCode).toBe(200);
    expect(challengeRes.json<{ accessToken: string }>().accessToken).toBeTruthy();
  });
});

describe('audit logging', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    app = await buildApp({
      db: appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey: process.env['JWT_PUBLIC_KEY']!,
    });
  });

  afterAll(async () => { await app.close(); await cleanup(); });
  afterEach(async () => { await truncateAll(superDb); });

  async function adminSetup() {
    const proof = await prepareBootstrapProof(superDb);
    return app.inject({ method: 'POST', url: '/api/v1/admin/setup', payload: { email: 'admin@test.com', password: ADMIN_PASSWORD, proof } });
  }

  async function adminLogin() {
    return app.inject({ method: 'POST', url: '/api/v1/admin/auth/login', payload: { password: ADMIN_PASSWORD } });
  }

  it('admin login creates an audit log entry', async () => {
    await adminSetup();
    await adminLogin();

    const logs = await superDb.select().from(auditLogs).orderBy(desc(auditLogs.createdAt));
    const loginLogs = logs.filter((l) => l.action === 'admin.login');
    expect(loginLogs.length).toBeGreaterThanOrEqual(1);
    expect(loginLogs[0]!.actor).toBe('admin');
    expect(loginLogs[0]!.targetType).toBe('admin');
  });

  it('GET /admin/audit-logs returns paginated entries', async () => {
    await adminSetup();
    const { accessToken } = (await adminLogin()).json<{ accessToken: string }>();

    const res = await app.inject({
      method: 'GET', url: '/api/v1/admin/audit-logs?limit=10&offset=0',
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    expect(res.statusCode).toBe(200);
    const body = res.json<{ logs: unknown[] }>();
    expect(body.logs.length).toBeGreaterThanOrEqual(1);
  });

  it('GET /admin/audit-logs filters by action', async () => {
    await adminSetup();
    const { accessToken } = (await adminLogin()).json<{ accessToken: string }>();

    // Create a key to generate a different audit action
    await app.inject({
      method: 'POST', url: '/api/v1/admin/keys',
      headers: { Authorization: `Bearer ${accessToken}` },
      payload: { label: 'audit-test-key' },
    });

    const res = await app.inject({
      method: 'GET', url: '/api/v1/admin/audit-logs?limit=50&offset=0&action=key.create',
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    expect(res.statusCode).toBe(200);
    const body = res.json<{ logs: Array<{ action: string }> }>();
    expect(body.logs.length).toBe(1);
    expect(body.logs[0]!.action).toBe('key.create');
  });

  it('GET /admin/audit-logs requires admin auth', async () => {
    const res = await app.inject({ method: 'GET', url: '/api/v1/admin/audit-logs?limit=10&offset=0' });
    expect(res.statusCode).toBe(401);
  });
});
