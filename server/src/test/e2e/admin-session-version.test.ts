import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import { TOTP, Secret } from 'otpauth';
import { eq, sql as drizzleSql } from 'drizzle-orm';
import { buildApp } from '../helpers/app-factory.js';
import {
  createDbs,
  prepareBootstrapProof,
  truncateAll,
  waitForBlockedQuery,
} from '../helpers/db-helpers.js';
import { adminConfig, adminRefreshTokens } from '../../db/schema.js';
import { sha256Hex } from '../../lib/crypto.js';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';

const ADMIN_EMAIL = 'session-admin@example.invalid';
const ADMIN_PASSWORD = 'adminpassword1234';
const CHANGED_PASSWORD = 'changed-admin-password1234';

describe('admin session version invalidation', () => {
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
      ttlSeconds: 900,
    });
  });

  afterAll(async () => {
    await app.close();
    await cleanup();
  });

  afterEach(async () => {
    await truncateAll(superDb);
  });

  async function setupAdmin() {
    const proof = await prepareBootstrapProof(superDb);
    const response = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/setup',
      payload: { email: ADMIN_EMAIL, password: ADMIN_PASSWORD, proof },
    });
    expect(response.statusCode).toBe(201);
  }

  async function login(password = ADMIN_PASSWORD) {
    return app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/login',
      payload: { password },
    });
  }

  function decode(token: string): Record<string, unknown> {
    return JSON.parse(Buffer.from(token.split('.')[1]!, 'base64url').toString());
  }

  it('binds access tokens to a session version and invalidates access plus refresh on password change', async () => {
    await setupAdmin();
    const loginResponse = await login();
    const original = loginResponse.json<{ accessToken: string; refreshToken: string }>();
    const claims = decode(original.accessToken);
    expect(claims['sessionVersion']).toBeDefined();
    expect(claims['exp']).toEqual(expect.any(Number));
    expect((claims['exp'] as number) - (claims['iat'] as number)).toBe(900);

    const changed = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/change-password',
      headers: { authorization: `Bearer ${original.accessToken}` },
      payload: { newPassword: CHANGED_PASSWORD },
    });
    expect(changed.statusCode).toBe(200);

    const staleAccess = await app.inject({
      method: 'GET',
      url: '/api/v1/admin/keys',
      headers: { authorization: `Bearer ${original.accessToken}` },
    });
    expect(staleAccess.statusCode).toBe(401);

    const staleRefresh = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/refresh',
      payload: { refreshToken: original.refreshToken },
    });
    expect(staleRefresh.statusCode).toBe(401);

    const fresh = await login(CHANGED_PASSWORD);
    expect(fresh.statusCode).toBe(200);
    expect(decode(fresh.json<{ accessToken: string }>().accessToken)['sessionVersion'])
      .not.toEqual(claims['sessionVersion']);
  });

  it('supports an explicit admin logout-all transition', async () => {
    await setupAdmin();
    const original = (await login()).json<{ accessToken: string; refreshToken: string }>();

    const logoutAll = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/logout-all',
      headers: { authorization: `Bearer ${original.accessToken}` },
    });
    expect(logoutAll.statusCode).toBe(204);

    const staleRefresh = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/refresh',
      payload: { refreshToken: original.refreshToken },
    });
    expect(staleRefresh.statusCode).toBe(401);
  });

  it('revokes an admin refresh family before reporting concurrent reuse', async () => {
    await setupAdmin();
    const original = (await login()).json<{ refreshToken: string }>();
    const attempts = await Promise.all([
      app.inject({
        method: 'POST',
        url: '/api/v1/admin/auth/refresh',
        payload: { refreshToken: original.refreshToken },
      }),
      app.inject({
        method: 'POST',
        url: '/api/v1/admin/auth/refresh',
        payload: { refreshToken: original.refreshToken },
      }),
    ]);
    expect(attempts.map((response) => response.statusCode).sort()).toEqual([200, 401]);

    const successor = attempts.find((response) => response.statusCode === 200)!
      .json<{ refreshToken: string }>().refreshToken;
    const successorReplay = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/refresh',
      payload: { refreshToken: successor },
    });
    expect(successorReplay.statusCode).toBe(401);
  });

  it('checks admin refresh expiry after waiting for the admin row lock', async () => {
    await setupAdmin();
    const initial = (await login()).json<{ refreshToken: string }>();
    const tokenHash = sha256Hex(initial.refreshToken);
    await superDb
      .update(adminRefreshTokens)
      .set({ expiresAt: new Date(Date.now() + 75) })
      .where(eq(adminRefreshTokens.tokenHash, tokenHash));

    let release!: () => void;
    let locked!: () => void;
    const releaseGate = new Promise<void>((resolve) => { release = resolve; });
    const lockGate = new Promise<void>((resolve) => { locked = resolve; });
    const heldLock = superDb.transaction(async (tx) => {
      await tx.execute(drizzleSql`SELECT id FROM admin_config FOR UPDATE`);
      locked();
      await releaseGate;
    });
    await lockGate;

    const refreshPromise = app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/refresh',
      payload: { refreshToken: initial.refreshToken },
    });
    await waitForBlockedQuery(superDb, 'admin_config');
    const [{ now }] = await superDb.execute<{ now: Date | string }>(drizzleSql`SELECT clock_timestamp() AS now`);
    await superDb
      .update(adminRefreshTokens)
      .set({ expiresAt: new Date(new Date(now).getTime() + 50) })
      .where(eq(adminRefreshTokens.tokenHash, tokenHash));
    await new Promise((resolve) => setTimeout(resolve, 100));
    release();
    await heldLock;
    expect((await refreshPromise).statusCode).toBe(401);
  });

  it('derives a rolling admin successor deadline after acquiring the token lock', async () => {
    await setupAdmin();
    const initial = (await login()).json<{ refreshToken: string }>();
    await superDb
      .update(adminRefreshTokens)
      .set({ expiresAt: new Date(Date.now() + 60 * 1000) })
      .where(eq(adminRefreshTokens.tokenHash, sha256Hex(initial.refreshToken)));

    const rotated = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/refresh',
      payload: { refreshToken: initial.refreshToken },
    });
    expect(rotated.statusCode).toBe(200);
    const successor = rotated.json<{ refreshToken: string }>().refreshToken;
    const [row] = await superDb
      .select({ expiresAt: adminRefreshTokens.expiresAt })
      .from(adminRefreshTokens)
      .where(eq(adminRefreshTokens.tokenHash, sha256Hex(successor)));
    expect(row?.expiresAt.getTime()).toBeGreaterThan(Date.now() + 29 * 24 * 60 * 60 * 1000);
  });

  it('invalidates admin access across backup-code regeneration and 2FA disable', async () => {
    await setupAdmin();
    const original = (await login()).json<{ accessToken: string }>();
    const setup = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/2fa/setup',
      headers: { authorization: `Bearer ${original.accessToken}` },
    });
    const secret = setup.json<{ secret: string }>().secret;
    const totp = new TOTP({
      issuer: 'Simpastil',
      label: ADMIN_EMAIL,
      secret: Secret.fromBase32(secret),
      digits: 6,
      period: 30,
    });
    const enabled = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/2fa/enable',
      headers: { authorization: `Bearer ${original.accessToken}` },
      payload: { code: totp.generate() },
    });
    expect(enabled.statusCode).toBe(200);
    const firstChallenge = (await login()).json<{ challengeToken: string }>();
    const completed = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/2fa/challenge',
      payload: { challengeToken: firstChallenge.challengeToken, code: totp.generate() },
    });
    const fresh = completed.json<{ accessToken: string }>();

    const regenerated = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/2fa/backup-codes',
      headers: { authorization: `Bearer ${fresh.accessToken}` },
      payload: { code: totp.generate() },
    });
    expect(regenerated.statusCode).toBe(200);
    const replacementCodes = regenerated.json<{ backupCodes: string[] }>().backupCodes;

    const staleAfterRegeneration = await app.inject({
      method: 'GET',
      url: '/api/v1/admin/keys',
      headers: { authorization: `Bearer ${fresh.accessToken}` },
    });
    expect(staleAfterRegeneration.statusCode).toBe(401);

    const secondChallenge = (await login()).json<{ challengeToken: string }>();
    const completedAgain = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/2fa/challenge',
      payload: { challengeToken: secondChallenge.challengeToken, code: replacementCodes[0] },
    });
    const beforeDisable = completedAgain.json<{ accessToken: string }>();
    const disabled = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/2fa/disable',
      headers: { authorization: `Bearer ${beforeDisable.accessToken}` },
      payload: { code: replacementCodes[1] },
    });
    expect(disabled.statusCode).toBe(200);

    const staleAfterDisable = await app.inject({
      method: 'GET',
      url: '/api/v1/admin/keys',
      headers: { authorization: `Bearer ${beforeDisable.accessToken}` },
    });
    expect(staleAfterDisable.statusCode).toBe(401);
  });

  it('advances environment-managed generations on logout-all and restart', async () => {
    const credentials = { email: 'managed-admin@example.invalid', password: ADMIN_PASSWORD };
    let managedApp: FastifyInstance | undefined = await buildApp({
      db: appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey: process.env['JWT_PUBLIC_KEY']!,
      ttlSeconds: 900,
      adminCredentials: credentials,
    });
    let restartedApp: FastifyInstance | undefined;
    try {
      const proof = await prepareBootstrapProof(superDb);
      const setup = await managedApp.inject({
        method: 'POST',
        url: '/api/v1/admin/setup',
        payload: { email: credentials.email, password: ADMIN_PASSWORD, proof },
      });
      expect(setup.statusCode).toBe(400);
      expect(setup.json<{ code: string }>().code).toBe('ADMIN_ENV_MANAGED');
      expect(await superDb.select({ id: adminConfig.id }).from(adminConfig)).toHaveLength(0);

      const original = (await managedApp.inject({
        method: 'POST',
        url: '/api/v1/admin/auth/login',
        payload: { password: ADMIN_PASSWORD },
      })).json<{ accessToken: string; refreshToken: string }>();

      const logoutAll = await managedApp.inject({
        method: 'POST',
        url: '/api/v1/admin/auth/logout-all',
        headers: { authorization: `Bearer ${original.accessToken}` },
      });
      expect(logoutAll.statusCode).toBe(204);

      const staleAfterLogout = await managedApp.inject({
        method: 'GET',
        url: '/api/v1/admin/keys',
        headers: { authorization: `Bearer ${original.accessToken}` },
      });
      expect(staleAfterLogout.statusCode).toBe(401);
      const staleRefreshAfterLogout = await managedApp.inject({
        method: 'POST',
        url: '/api/v1/admin/auth/refresh',
        payload: { refreshToken: original.refreshToken },
      });
      expect(staleRefreshAfterLogout.statusCode).toBe(401);

      const fresh = (await managedApp.inject({
        method: 'POST',
        url: '/api/v1/admin/auth/login',
        payload: { password: ADMIN_PASSWORD },
      })).json<{ accessToken: string; refreshToken: string }>();
      const [racingLogout, racingRefresh] = await Promise.all([
        managedApp.inject({
          method: 'POST',
          url: '/api/v1/admin/auth/logout-all',
          headers: { authorization: `Bearer ${fresh.accessToken}` },
        }),
        managedApp.inject({
          method: 'POST',
          url: '/api/v1/admin/auth/refresh',
          payload: { refreshToken: fresh.refreshToken },
        }),
      ]);
      expect(racingLogout.statusCode).toBe(204);
      if (racingRefresh.statusCode === 200) {
        const successor = racingRefresh.json<{ refreshToken: string }>().refreshToken;
        const successorAfterLogout = await managedApp.inject({
          method: 'POST',
          url: '/api/v1/admin/auth/refresh',
          payload: { refreshToken: successor },
        });
        expect(successorAfterLogout.statusCode).toBe(401);
      } else {
        expect(racingRefresh.statusCode).toBe(401);
      }
      const restartCandidate = (await managedApp.inject({
        method: 'POST',
        url: '/api/v1/admin/auth/login',
        payload: { password: ADMIN_PASSWORD },
      })).json<{ accessToken: string; refreshToken: string }>();
      await managedApp.close();
      managedApp = undefined;

      restartedApp = await buildApp({
        db: appDb,
        privateKey: process.env['JWT_PRIVATE_KEY']!,
        publicKey: process.env['JWT_PUBLIC_KEY']!,
        ttlSeconds: 900,
        adminCredentials: credentials,
      });
      const staleAfterRestart = await restartedApp.inject({
        method: 'GET',
        url: '/api/v1/admin/keys',
        headers: { authorization: `Bearer ${restartCandidate.accessToken}` },
      });
      expect(staleAfterRestart.statusCode).toBe(401);
      const staleRefreshAfterRestart = await restartedApp.inject({
        method: 'POST',
        url: '/api/v1/admin/auth/refresh',
        payload: { refreshToken: restartCandidate.refreshToken },
      });
      expect(staleRefreshAfterRestart.statusCode).toBe(401);
    } finally {
      if (restartedApp) await restartedApp.close();
      if (managedApp) await managedApp.close();
    }
  });

  it('revokes a fresh persisted-admin family when environment-managed startup restarts', async () => {
    await setupAdmin();
    const beforeRestart = (await login()).json<{ accessToken: string; refreshToken: string }>();
    const credentials = { email: ADMIN_EMAIL, password: ADMIN_PASSWORD };
    const managedApp = await buildApp({
      db: appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey: process.env['JWT_PUBLIC_KEY']!,
      ttlSeconds: 900,
      adminCredentials: credentials,
    });
    try {
      const staleAccess = await managedApp.inject({
        method: 'GET',
        url: '/api/v1/admin/keys',
        headers: { authorization: `Bearer ${beforeRestart.accessToken}` },
      });
      expect(staleAccess.statusCode).toBe(401);
      const staleRefresh = await managedApp.inject({
        method: 'POST',
        url: '/api/v1/admin/auth/refresh',
        payload: { refreshToken: beforeRestart.refreshToken },
      });
      expect(staleRefresh.statusCode).toBe(401);
    } finally {
      await managedApp.close();
    }
  });
});
