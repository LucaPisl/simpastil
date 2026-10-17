import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, truncateAll, createUnclaimedKey } from '../helpers/db-helpers.js';
import { refreshTokens } from '../../db/schema.js';
import { randomBytes } from 'node:crypto';
import { eq } from 'drizzle-orm';
import { sha256Hex } from '../../lib/crypto.js';
import { startTokenGc } from '../../lib/token-gc.js';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';

const EMAIL    = 'alice@example.com';
const PASSWORD = 'password1234';

describe('auth lifecycle', () => {
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
      publicKey:  process.env['JWT_PUBLIC_KEY']!,
      ttlSeconds: 5,
    });
    apiKey = await createUnclaimedKey(superDb);
  });

  afterAll(async () => {
    await app.close();
    await cleanup();
  });

  afterEach(async () => {
    await truncateAll(superDb);
    apiKey = await createUnclaimedKey(superDb);
  });

  // ── helpers ──────────────────────────────────────────────────────────────

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

  function decodeJwt(token: string): Record<string, unknown> {
    const payload = token.split('.')[1]!;
    return JSON.parse(Buffer.from(payload, 'base64url').toString());
  }

  // ── tests ─────────────────────────────────────────────────────────────────

  it('recovers a lost rotation response without creating another successor', async () => {
    await register();
    const { refreshToken } = (await login()).json<{ refreshToken: string }>();
    const nextRefreshToken = randomBytes(32).toString('hex');
    const rotate = () => app.inject({
      method: 'POST', url: '/api/v1/auth/refresh/recoverable',
      headers: { 'X-Api-Key': apiKey },
      payload: { refreshToken, nextRefreshToken },
    });
    const first = await rotate();
    expect(first.statusCode).toBe(200);
    // Treat the first response as lost. Only the original durable pair survives.
    const recovered = await rotate();
    expect(recovered.statusCode).toBe(200);
    expect(recovered.json().refreshToken).toBe(nextRefreshToken);
    expect((await superDb.select().from(refreshTokens))).toHaveLength(2);

    const logout = await app.inject({
      method: 'POST', url: '/api/v1/auth/logout',
      headers: { 'X-Api-Key': apiKey },
      payload: { refreshToken }, // Lost response: logout knows only predecessor.
    });
    expect(logout.statusCode).toBe(204);
    expect((await rotate()).statusCode).toBe(401);
  });

  it('concurrent exact recovery pairs share one successor; another pair revokes the family', async () => {
    await register();
    const { refreshToken } = (await login()).json<{ refreshToken: string }>();
    const nextRefreshToken = randomBytes(32).toString('hex');
    const rotate = (next: string) => app.inject({
      method: 'POST', url: '/api/v1/auth/refresh/recoverable',
      headers: { 'X-Api-Key': apiKey },
      payload: { refreshToken, nextRefreshToken: next },
    });
    const results = await Promise.all([rotate(nextRefreshToken), rotate(nextRefreshToken)]);
    expect(results.map((r) => r.statusCode)).toEqual([200, 200]);
    expect((await superDb.select().from(refreshTokens))).toHaveLength(2);
    expect((await rotate(randomBytes(32).toString('hex'))).statusCode).toBe(401);
    expect((await rotate(nextRefreshToken)).statusCode).toBe(401);
    expect((await superDb.select().from(refreshTokens)).every((row) => row.revoked)).toBe(true);
  });

  it('does not revive an expired or subsequently rotated successor', async () => {
    await register();
    const { refreshToken } = (await login()).json<{ refreshToken: string }>();
    const nextRefreshToken = randomBytes(32).toString('hex');
    const recover = () => app.inject({
      method: 'POST', url: '/api/v1/auth/refresh/recoverable',
      headers: { 'X-Api-Key': apiKey }, payload: { refreshToken, nextRefreshToken },
    });
    expect((await recover()).statusCode).toBe(200);
    await superDb.update(refreshTokens).set({ expiresAt: new Date(0) })
      .where(eq(refreshTokens.tokenHash, sha256Hex(nextRefreshToken)));
    expect((await recover()).statusCode).toBe(401);
    await superDb.update(refreshTokens).set({ expiresAt: new Date(Date.now() + 60_000) })
      .where(eq(refreshTokens.tokenHash, sha256Hex(nextRefreshToken)));
    const rotated = await app.inject({
      method: 'POST', url: '/api/v1/auth/refresh',
      headers: { 'X-Api-Key': apiKey }, payload: { refreshToken: nextRefreshToken },
    });
    expect(rotated.statusCode).toBe(200);
    expect((await recover()).statusCode).toBe(401);
    // Repeating the exact old receipt cannot revoke a valid later generation.
    expect((await superDb.select().from(refreshTokens)).filter((t) => !t.revoked)).toHaveLength(1);
  });

  it('retains a recently rotated receipt even when its predecessor was created long ago', async () => {
    await register();
    const { refreshToken } = (await login()).json<{ refreshToken: string }>();
    await superDb.update(refreshTokens).set({ createdAt: new Date(Date.now() - 20 * 86400_000) });
    const nextRefreshToken = randomBytes(32).toString('hex');
    const recover = () => app.inject({
      method: 'POST', url: '/api/v1/auth/refresh/recoverable',
      headers: { 'X-Api-Key': apiKey }, payload: { refreshToken, nextRefreshToken },
    });
    expect((await recover()).statusCode).toBe(200);
    const gc = startTokenGc(superDb);
    expect(await gc.drain(Date.now() + 5000)).toBe(true);
    expect((await superDb.select().from(refreshTokens))).toHaveLength(2);
    expect((await recover()).statusCode).toBe(200);
  });

  it('registers a new user and returns 201 with userId', async () => {
    const res = await register();
    expect(res.statusCode).toBe(201);
    expect(res.json<{ userId: string }>().userId).toMatch(
      /^[0-9a-f-]{36}$/,
    );
  });

  it('logs in and returns accessToken + refreshToken', async () => {
    await register();
    const res = await login();
    expect(res.statusCode).toBe(200);
    const body = res.json<{ accessToken: string; refreshToken: string }>();
    expect(body.accessToken).toBeTruthy();
    expect(body.refreshToken).toBeTruthy();
  });

  it('accessToken sub claim matches the registered userId', async () => {
    const regRes = await register();
    const { userId } = regRes.json<{ userId: string }>();
    const loginRes = await login();
    const { accessToken } = loginRes.json<{ accessToken: string; refreshToken: string }>();
    const payload = decodeJwt(accessToken);
    expect(payload['sub']).toBe(userId);
  });

  it('refreshes tokens — old token is revoked, new tokens are returned', async () => {
    await register();
    const { refreshToken } = (await login()).json<{ accessToken: string; refreshToken: string }>();

    const refreshRes = await app.inject({
      method: 'POST', url: '/api/v1/auth/refresh',
      headers: { 'X-Api-Key': apiKey },
      payload: { refreshToken },
    });
    expect(refreshRes.statusCode).toBe(200);
    const body = refreshRes.json<{ accessToken: string; refreshToken: string }>();
    expect(body.refreshToken).not.toBe(refreshToken);

    // After one rotation: 2 rows total — original (revoked) + new (not revoked yet).
    const rows = await superDb
      .select({ revoked: refreshTokens.revoked })
      .from(refreshTokens);
    expect(rows).toHaveLength(2);
    expect(rows.filter((r) => r.revoked)).toHaveLength(1);
  });

  it('logout revokes the refresh token', async () => {
    await register();
    const { accessToken, refreshToken } =
      (await login()).json<{ accessToken: string; refreshToken: string }>();

    const logoutRes = await app.inject({
      method: 'POST', url: '/api/v1/auth/logout',
      headers: { authorization: `Bearer ${accessToken}`, 'X-Api-Key': apiKey },
      payload: { refreshToken },
    });
    expect(logoutRes.statusCode).toBe(204);

    const rows = await superDb
      .select({ revoked: refreshTokens.revoked })
      .from(refreshTokens);
    expect(rows.every((r) => r.revoked)).toBe(true);
  });

  it('using a revoked refresh token returns 401 and invalidates the whole family', async () => {
    await register();
    const { refreshToken: rt1 } =
      (await login()).json<{ accessToken: string; refreshToken: string }>();

    // Rotate once to get rt2.
    const { refreshToken: rt2 } =
      (await app.inject({
        method: 'POST', url: '/api/v1/auth/refresh',
        headers: { 'X-Api-Key': apiKey },
        payload: { refreshToken: rt1 },
      })).json<{ accessToken: string; refreshToken: string }>();

    // Replay the already-used rt1 — should trigger family invalidation.
    const reuseRes = await app.inject({
      method: 'POST', url: '/api/v1/auth/refresh',
      headers: { 'X-Api-Key': apiKey },
      payload: { refreshToken: rt1 },
    });
    expect(reuseRes.statusCode).toBe(401);

    // rt2 should also be revoked (family invalidation).
    const newAttempt = await app.inject({
      method: 'POST', url: '/api/v1/auth/refresh',
      headers: { 'X-Api-Key': apiKey },
      payload: { refreshToken: rt2 },
    });
    expect(newAttempt.statusCode).toBe(401);
  });

  it('duplicate registration returns 409', async () => {
    await register();
    // After first register, key is claimed — register again with a NEW unclaimed key
    // for the same email. The service should return 409 (email already registered).
    const anotherKey = await createUnclaimedKey(superDb);
    const res = await app.inject({
      method: 'POST', url: '/api/v1/auth/register',
      headers: { 'X-Api-Key': anotherKey },
      payload: { email: EMAIL, password: PASSWORD },
    });
    expect(res.statusCode).toBe(409);
  });

  it('wrong password returns 401', async () => {
    await register();
    const res = await app.inject({
      method: 'POST', url: '/api/v1/auth/login',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: EMAIL, password: 'wrongpassword1' },
    });
    expect(res.statusCode).toBe(401);
  });

  it('unknown refresh token returns 401', async () => {
    // Need a claimed key for apiKeyGuardRegistered — register first
    await register();
    const res = await app.inject({
      method: 'POST', url: '/api/v1/auth/refresh',
      headers: { 'X-Api-Key': apiKey },
      payload: { refreshToken: 'a'.repeat(64) },
    });
    expect(res.statusCode).toBe(401);
  });

  it('authenticate plugin rejects JWT with sub=admin', async () => {
    // Register to get a claimed key
    const key = await createUnclaimedKey(superDb);
    await app.inject({ method: 'POST', url: '/api/v1/auth/register', headers: { 'X-Api-Key': key }, payload: { email: EMAIL, password: PASSWORD } });

    const adminToken = app.jwt.sign({ sub: 'admin', role: 'admin' });
    const res = await app.inject({
      method: 'GET', url: '/api/v1/profiles',
      headers: { Authorization: `Bearer ${adminToken}`, 'X-Api-Key': key },
    });
    expect(res.statusCode).toBe(401);
  });

  it('authenticate plugin rejects any JWT with non-UUID sub', async () => {
    // Register to get a claimed key
    const key = await createUnclaimedKey(superDb);
    await app.inject({ method: 'POST', url: '/api/v1/auth/register', headers: { 'X-Api-Key': key }, payload: { email: EMAIL, password: PASSWORD } });

    for (const sub of ['service-account', '', 'null', '1234']) {
      const token = app.jwt.sign({ sub });
      const res = await app.inject({
        method: 'GET',
        url: '/api/v1/profiles',
        headers: { Authorization: `Bearer ${token}`, 'X-Api-Key': key },
      });
      expect(res.statusCode, `sub=${JSON.stringify(sub)}`).toBe(401);
    }
  });
});
