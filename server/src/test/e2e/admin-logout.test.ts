import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import { desc, eq } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, prepareBootstrapProof, truncateAll } from '../helpers/db-helpers.js';
import { adminRefreshTokens, auditLogs } from '../../db/schema.js';
import type { Db } from '../../db/client.js';

const ADMIN_PASSWORD = 'adminpassword1234';

interface Tokens { accessToken: string; refreshToken: string }

describe('admin sign-out', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    const keys = { privateKey: process.env['JWT_PRIVATE_KEY']!, publicKey: process.env['JWT_PUBLIC_KEY']! };
    app = await buildApp({ db: appDb, ...keys, ttlSeconds: 600 });
  });

  afterAll(async () => {
    await app.close();
    await cleanup();
  });
  afterEach(async () => { await truncateAll(superDb); });

  async function setupAdmin(): Promise<void> {
    const proof = await prepareBootstrapProof(superDb);
    const res = await app.inject({
      method: 'POST', url: '/api/v1/admin/setup',
      payload: { email: 'admin@test.com', password: ADMIN_PASSWORD, proof },
    });
    expect(res.statusCode).toBe(201);
  }

  async function login(): Promise<Tokens> {
    const res = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/login', payload: { password: ADMIN_PASSWORD },
    });
    expect(res.statusCode).toBe(200);
    return res.json<Tokens>();
  }

  const get = (token: string) => app.inject({
    method: 'GET', url: '/api/v1/admin/keys', headers: { authorization: `Bearer ${token}` },
  });
  const logout = (token: string) => app.inject({
    method: 'POST', url: '/api/v1/admin/auth/logout', headers: { authorization: `Bearer ${token}` },
  });
  const refresh = (refreshToken: string) => app.inject({
    method: 'POST', url: '/api/v1/admin/auth/refresh', payload: { refreshToken },
  });
  const actions = async () => (await appDb.select().from(auditLogs).orderBy(desc(auditLogs.createdAt)))
    .map((row) => row.action);

  it('ends only this sign-in and makes its access and refresh tokens unusable', async () => {
    await setupAdmin();
    const mine = await login();
    const other = await login();
    expect((await get(mine.accessToken)).statusCode).toBe(200);

    const res = await logout(mine.accessToken);
    expect(res.statusCode).toBe(204);

    // The access token is still inside its lifetime but no longer works.
    expect((await get(mine.accessToken)).statusCode).toBe(401);
    expect((await refresh(mine.refreshToken)).statusCode).toBe(401);
    // Another browser's sign-in is untouched.
    expect((await get(other.accessToken)).statusCode).toBe(200);
    expect((await refresh(other.refreshToken)).statusCode).toBe(200);

    expect(await actions()).toContain('admin.logout');
  });

  it('revokes the whole rotation family, not only the newest token', async () => {
    await setupAdmin();
    const first = await login();
    const rotated = (await refresh(first.refreshToken)).json<Tokens>();
    // The token minted before rotation names the same sign-in.
    expect((await get(first.accessToken)).statusCode).toBe(200);

    expect((await logout(rotated.accessToken)).statusCode).toBe(204);
    expect((await get(first.accessToken)).statusCode).toBe(401);
    expect((await get(rotated.accessToken)).statusCode).toBe(401);
    expect((await refresh(rotated.refreshToken)).statusCode).toBe(401);
    const live = await appDb.select().from(adminRefreshTokens).where(eq(adminRefreshTokens.revoked, false));
    expect(live).toHaveLength(0);
  });

  it('is idempotent: repeating it is a quiet 204', async () => {
    await setupAdmin();
    const session = await login();
    expect((await logout(session.accessToken)).statusCode).toBe(204);
    expect((await logout(session.accessToken)).statusCode).toBe(204);
  });

  it('rejects an unauthenticated, forged or challenge token', async () => {
    await setupAdmin();
    expect((await app.inject({ method: 'POST', url: '/api/v1/admin/auth/logout' })).statusCode).toBe(401);
    expect((await logout('not-a-token')).statusCode).toBe(401);
    const challenge = app.jwt.sign({ sub: 'admin', role: 'admin', sessionVersion: '1', purpose: '2fa-challenge' }, { expiresIn: 60 });
    expect((await logout(challenge)).statusCode).toBe(401);
    expect(await actions()).not.toContain('admin.logout');
  });

  it('refuses a token from before a global sign-out', async () => {
    await setupAdmin();
    const session = await login();
    expect((await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/logout-all', headers: { authorization: `Bearer ${session.accessToken}` },
    })).statusCode).toBe(204);
    expect((await get(session.accessToken)).statusCode).toBe(401);
    expect((await logout(session.accessToken)).statusCode).toBe(401);
    expect((await refresh(session.refreshToken)).statusCode).toBe(401);
    expect(await actions()).toContain('admin.logout_all');
  });

  it('ends a sign-in whose refresh token is replayed after rotation', async () => {
    await setupAdmin();
    const first = await login();
    const rotated = (await refresh(first.refreshToken)).json<Tokens>();
    // Reuse of a spent refresh token revokes the family, and its access token with it.
    expect((await refresh(first.refreshToken)).statusCode).toBe(401);
    expect((await get(rotated.accessToken)).statusCode).toBe(401);
  });

  it('keeps accepting access tokens minted without a sign-in claim until they expire', async () => {
    await setupAdmin();
    const session = await login();
    const decoded = app.jwt.decode<{ sessionVersion: string }>(session.accessToken)!;
    const legacy = app.jwt.sign({ sub: 'admin', role: 'admin', sessionVersion: decoded.sessionVersion }, { expiresIn: 60 });
    expect((await get(legacy)).statusCode).toBe(200);
    const withBadSid = app.jwt.sign({ sub: 'admin', role: 'admin', sessionVersion: decoded.sessionVersion, sid: 7 }, { expiresIn: 60 });
    expect((await get(withBadSid)).statusCode).toBe(401);
    const unknownSid = app.jwt.sign({
      sub: 'admin', role: 'admin', sessionVersion: decoded.sessionVersion, sid: '00000000-0000-4000-8000-000000000000',
    }, { expiresIn: 60 });
    expect((await get(unknownSid)).statusCode).toBe(401);
  });
});
