import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, prepareBootstrapProof, truncateAll, createUnclaimedKey, createApiKey, waitForBlockedQuery } from '../helpers/db-helpers.js';
import { users } from '../../db/schema.js';
import { refreshTokens } from '../../db/schema.js';
import { sha256Hex } from '../../lib/crypto.js';
import { eq } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';

const ADMIN_PASSWORD = 'adminpassword1234';

type RefreshBarrier = {
  entered: Promise<void>;
  markEntered: () => void;
  gate: Promise<void>;
  release: () => void;
};

describe('admin ops work under RLS', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;
  let refreshBarrier: RefreshBarrier | null = null;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    app = await buildApp({
      db: appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey: process.env['JWT_PUBLIC_KEY']!,
      ttlSeconds: 60,
      authTestHooks: {
        afterRefreshSessionLock: async () => {
          const barrier = refreshBarrier;
          if (!barrier) return;
          barrier.markEntered();
          await barrier.gate;
        },
      },
    });
  });

  afterAll(async () => { await app.close(); await cleanup(); });
  afterEach(async () => { await truncateAll(superDb); });

  async function getAdminToken(): Promise<string> {
    const proof = await prepareBootstrapProof(superDb);
    await app.inject({
      method: 'POST', url: '/api/v1/admin/setup',
      payload: { email: 'admin@test.com', password: ADMIN_PASSWORD, proof },
    });
    const res = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/login',
      payload: { password: ADMIN_PASSWORD },
    });
    return res.json().accessToken as string;
  }

  async function createTestUser(): Promise<string> {
    const apiKey = await createUnclaimedKey(superDb);
    const res = await app.inject({
      method: 'POST', url: '/api/v1/auth/register',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: `user-${Date.now()}@test.com`, password: 'password1234' },
    });
    return res.json().userId as string;
  }

  it('admin delete-user actually deletes the user row', async () => {
    const adminToken = await getAdminToken();
    const userId = await createTestUser();

    const res = await app.inject({
      method: 'DELETE', url: `/api/v1/admin/users/${userId}`,
      headers: { Authorization: `Bearer ${adminToken}` },
    });

    expect(res.statusCode).toBe(204);

    const [row] = await superDb.select().from(users).where(eq(users.id, userId));
    expect(row).toBeUndefined();
  });

  it('admin delete-user returns 404 for nonexistent user', async () => {
    const adminToken = await getAdminToken();

    const res = await app.inject({
      method: 'DELETE', url: '/api/v1/admin/users/00000000-0000-0000-0000-000000000000',
      headers: { Authorization: `Bearer ${adminToken}` },
    });

    expect(res.statusCode).toBe(404);
  });

  it('admin logout-device returns 404 for nonexistent device', async () => {
    const adminToken = await getAdminToken();
    const userId = await createTestUser();

    const res = await app.inject({
      method: 'DELETE', url: `/api/v1/admin/users/${userId}/devices/00000000-0000-0000-0000-000000000000`,
      headers: { Authorization: `Bearer ${adminToken}` },
    });

    expect(res.statusCode).toBe(404);
  });

  it('serializes device logout against refresh so no successor survives', async () => {
    const adminToken = await getAdminToken();
    const apiKey = await createUnclaimedKey(superDb);
    const user = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: 'device-race@test.com', password: 'password1234' },
    });
    const userId = user.json<{ userId: string }>().userId;
    const login = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: 'device-race@test.com', password: 'password1234' },
    });
    const original = login.json<{ refreshToken: string }>();
    const [device] = await superDb
      .select({ familyId: refreshTokens.familyId })
      .from(refreshTokens)
      .where(eq(refreshTokens.tokenHash, sha256Hex(original.refreshToken)));
    expect(device?.familyId).toBeTruthy();

    let markEntered!: () => void;
    let release!: () => void;
    const entered = new Promise<void>((resolve) => { markEntered = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    refreshBarrier = { entered, markEntered, gate, release };
    try {
      const refreshPromise = app.inject({
        method: 'POST',
        url: '/api/v1/auth/refresh',
        headers: { 'X-Api-Key': apiKey },
        payload: { refreshToken: original.refreshToken },
      });
      // The refresh transaction owns the user lock and is paused before it
      // can inspect or mutate the refresh row. Device logout must contend on
      // that same principal lock before the refresh is released.
      await entered;
      const logoutPromise = app.inject({
        method: 'DELETE',
        url: `/api/v1/admin/users/${userId}/devices/${device!.familyId}`,
        headers: { Authorization: `Bearer ${adminToken}` },
      });
      await waitForBlockedQuery(superDb, 'users');
      release();

      const [logout, refresh] = await Promise.all([logoutPromise, refreshPromise]);
      expect(logout.statusCode).toBe(204);
      expect(refresh.statusCode).toBe(200);
      const successor = refresh.json<{ refreshToken: string }>().refreshToken;
      const afterLogout = await app.inject({
        method: 'POST',
        url: '/api/v1/auth/refresh',
        headers: { 'X-Api-Key': apiKey },
        payload: { refreshToken: successor },
      });
      expect(afterLogout.statusCode).toBe(401);
    } finally {
      refreshBarrier = null;
      release();
    }
  });
});
