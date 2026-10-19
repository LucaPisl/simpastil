import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import { TOTP, Secret } from 'otpauth';
import { desc } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, prepareBootstrapProof, truncateAll } from '../helpers/db-helpers.js';
import { auditLogs } from '../../db/schema.js';
import type { Db } from '../../db/client.js';

const ADMIN_PASSWORD = 'adminpassword1234';

interface Status { available: boolean; enabled: boolean; backupCodesRemaining: number }

describe('admin two-factor status and console flows', () => {
  let app: FastifyInstance;
  let envApp: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    const keys = { privateKey: process.env['JWT_PRIVATE_KEY']!, publicKey: process.env['JWT_PUBLIC_KEY']! };
    app = await buildApp({ db: appDb, ...keys, ttlSeconds: 120 });
    envApp = await buildApp({
      db: appDb, ...keys, ttlSeconds: 120,
      adminCredentials: { email: 'env-admin@example.invalid', password: ADMIN_PASSWORD },
    });
  });

  afterAll(async () => {
    await app.close();
    await envApp.close();
    await cleanup();
  });
  afterEach(async () => { await truncateAll(superDb); });

  async function adminToken(): Promise<string> {
    const proof = await prepareBootstrapProof(superDb);
    await app.inject({
      method: 'POST', url: '/api/v1/admin/setup',
      payload: { email: 'admin@test.com', password: ADMIN_PASSWORD, proof },
    });
    return login();
  }

  async function login(): Promise<string> {
    const res = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/login', payload: { password: ADMIN_PASSWORD },
    });
    return res.json().accessToken as string;
  }

  const code = (secret: string, offsetSteps = 0) => new TOTP({
    issuer: 'Simpastil', label: 'admin@test.com', secret: Secret.fromBase32(secret), digits: 6, period: 30,
  }).generate({ timestamp: Date.now() + offsetSteps * 30_000 });

  const status = (token: string, target: FastifyInstance = app) => target.inject({
    method: 'GET', url: '/api/v1/admin/auth/2fa/status', headers: { authorization: `Bearer ${token}` },
  });

  async function enableTwoFactor(token: string): Promise<{ secret: string; backupCodes: string[] }> {
    const setup = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/2fa/setup', headers: { authorization: `Bearer ${token}` },
    });
    expect(setup.statusCode).toBe(200);
    expect(setup.headers['cache-control']).toBe('no-store');
    const { secret } = setup.json<{ secret: string }>();
    const enable = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/2fa/enable',
      headers: { authorization: `Bearer ${token}` }, payload: { code: code(secret) },
    });
    expect(enable.statusCode).toBe(200);
    expect(enable.headers['cache-control']).toBe('no-store');
    return { secret, backupCodes: enable.json<{ backupCodes: string[] }>().backupCodes };
  }

  /** Enabling revokes every session, so a new one is earned through the challenge. */
  async function signInWithTwoFactor(secret: string, offsetSteps = 1): Promise<string> {
    const first = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/login', payload: { password: ADMIN_PASSWORD },
    });
    const { challengeToken } = first.json<{ challengeToken: string }>();
    const res = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/2fa/challenge',
      payload: { challengeToken, code: code(secret, offsetSteps) },
    });
    expect(res.statusCode).toBe(200);
    return res.json().accessToken as string;
  }

  it('requires an admin access token', async () => {
    expect((await app.inject({ method: 'GET', url: '/api/v1/admin/auth/2fa/status' })).statusCode).toBe(401);
  });

  it('reports availability, enablement and the backup codes left', async () => {
    const token = await adminToken();
    const before = await status(token);
    expect(before.statusCode).toBe(200);
    expect(before.headers['cache-control']).toBe('no-store');
    expect(before.json<Status>()).toEqual({ available: true, enabled: false, backupCodesRemaining: 0 });

    const { secret, backupCodes } = await enableTwoFactor(token);
    expect(backupCodes).toHaveLength(8);
    const fresh = await signInWithTwoFactor(secret);
    expect((await status(fresh)).json<Status>()).toEqual({ available: true, enabled: true, backupCodesRemaining: 8 });
  });

  it('counts a spent backup code and never lists any code', async () => {
    const token = await adminToken();
    const { secret, backupCodes } = await enableTwoFactor(token);
    const first = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/login', payload: { password: ADMIN_PASSWORD },
    });
    const challenge = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/2fa/challenge',
      payload: { challengeToken: first.json().challengeToken, code: backupCodes[0] },
    });
    expect(challenge.statusCode).toBe(200);
    const res = await status(challenge.json().accessToken);
    expect(res.json<Status>().backupCodesRemaining).toBe(7);
    expect(Object.keys(res.json())).toEqual(['available', 'enabled', 'backupCodesRemaining']);
    expect(secret).toBeTruthy();
  });

  it('rejects a two-factor challenge token as an access token', async () => {
    const token = await adminToken();
    const { secret } = await enableTwoFactor(token);
    const first = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/login', payload: { password: ADMIN_PASSWORD },
    });
    const { challengeToken } = first.json<{ challengeToken: string }>();
    expect((await status(challengeToken)).statusCode).toBe(401);
    expect(secret).toBeTruthy();
  });

  it('is unavailable for an environment-managed administrator', async () => {
    const res = await envApp.inject({
      method: 'POST', url: '/api/v1/admin/auth/login', payload: { password: ADMIN_PASSWORD },
    });
    expect(res.statusCode).toBe(200);
    const result = await status(res.json().accessToken, envApp);
    expect(result.json<Status>()).toEqual({ available: false, enabled: false, backupCodesRemaining: 0 });
  });

  it('rotating backup codes is audited, replaces the set and returns no-store', async () => {
    const token = await adminToken();
    const { secret, backupCodes } = await enableTwoFactor(token);
    const fresh = await signInWithTwoFactor(secret);

    const rotate = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/2fa/backup-codes',
      headers: { authorization: `Bearer ${fresh}` }, payload: { code: code(secret) },
    });
    expect(rotate.statusCode).toBe(200);
    expect(rotate.headers['cache-control']).toBe('no-store');
    const rotated = rotate.json<{ backupCodes: string[] }>().backupCodes;
    expect(rotated).toHaveLength(8);
    expect(rotated.some((c) => backupCodes.includes(c))).toBe(false);

    const actions = (await superDb.select().from(auditLogs).orderBy(desc(auditLogs.createdAt))).map((l) => l.action);
    expect(actions).toContain('admin.2fa_enable');
    expect(actions).toContain('admin.2fa_backup_codes');
    const rows = await superDb.select().from(auditLogs);
    expect(JSON.stringify(rows)).not.toContain(rotated[0]);
  });
});
