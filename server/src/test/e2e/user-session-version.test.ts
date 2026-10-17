import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import { TOTP, Secret } from 'otpauth';
import { randomBytes } from 'node:crypto';
import { buildApp } from '../helpers/app-factory.js';
import {
  createDbs,
  createUnclaimedKey,
  truncateAll,
} from '../helpers/db-helpers.js';
import { eq } from 'drizzle-orm';
import { passwordResetTokens, users } from '../../db/schema.js';
import { sha256Hex } from '../../lib/crypto.js';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';

const EMAIL = 'session-user@example.invalid';
const PASSWORD = 'password1234';
const CHANGED_PASSWORD = 'changed-password1234';

describe('user session version invalidation', () => {
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
      ttlSeconds: 900,
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

  async function registerAndLogin(password = PASSWORD) {
    if (password === PASSWORD) {
      await app.inject({
        method: 'POST',
        url: '/api/v1/auth/register',
        headers: { 'x-api-key': apiKey },
        payload: { email: EMAIL, password: PASSWORD },
      });
    }
    return app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      headers: { 'x-api-key': apiKey },
      payload: { email: EMAIL, password },
    });
  }

  function decode(token: string): Record<string, unknown> {
    return JSON.parse(Buffer.from(token.split('.')[1]!, 'base64url').toString());
  }

  it('binds access tokens to a version and invalidates access plus refresh on password change', async () => {
    const login = (await registerAndLogin()).json<{ accessToken: string; refreshToken: string }>();
    const claims = decode(login.accessToken);
    expect(claims['sessionVersion']).toBeDefined();
    expect(claims['exp']).toEqual(expect.any(Number));

    const nextRefreshToken = randomBytes(32).toString('hex');
    const recover = () => app.inject({
      method: 'POST', url: '/api/v1/auth/refresh/recoverable',
      headers: { 'x-api-key': apiKey },
      payload: { refreshToken: login.refreshToken, nextRefreshToken },
    });
    expect((await recover()).statusCode).toBe(200);

    const changed = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/change-password',
      headers: { authorization: `Bearer ${login.accessToken}`, 'x-api-key': apiKey },
      payload: { currentPassword: PASSWORD, newPassword: CHANGED_PASSWORD },
    });
    expect(changed.statusCode).toBe(200);
    expect((await recover()).statusCode).toBe(401);

    const staleAccess = await app.inject({
      method: 'GET',
      url: '/api/v1/profiles',
      headers: { authorization: `Bearer ${login.accessToken}`, 'x-api-key': apiKey },
    });
    expect(staleAccess.statusCode).toBe(401);

    const staleRefresh = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/refresh',
      headers: { 'x-api-key': apiKey },
      payload: { refreshToken: login.refreshToken },
    });
    expect(staleRefresh.statusCode).toBe(401);

    const fresh = await registerAndLogin(CHANGED_PASSWORD);
    expect(fresh.statusCode).toBe(200);
    expect(decode(fresh.json<{ accessToken: string }>().accessToken)['sessionVersion'])
      .not.toEqual(claims['sessionVersion']);
  });

  it('invalidates the old access token when 2FA is enabled', async () => {
    const login = (await registerAndLogin()).json<{ accessToken: string }>();
    const setup = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/2fa/setup',
      headers: { authorization: `Bearer ${login.accessToken}`, 'x-api-key': apiKey },
    });
    const secret = setup.json<{ secret: string }>().secret;
    const code = new TOTP({
      issuer: 'Simpastil',
      label: EMAIL,
      secret: Secret.fromBase32(secret),
      digits: 6,
      period: 30,
    }).generate();
    const enabled = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/2fa/enable',
      headers: { authorization: `Bearer ${login.accessToken}`, 'x-api-key': apiKey },
      payload: { code },
    });
    expect(enabled.statusCode).toBe(200);

    const staleAccess = await app.inject({
      method: 'GET',
      url: '/api/v1/profiles',
      headers: { authorization: `Bearer ${login.accessToken}`, 'x-api-key': apiKey },
    });
    expect(staleAccess.statusCode).toBe(401);
  });

  it('rejects a challenge token after a later session-version transition', async () => {
    const login = (await registerAndLogin()).json<{ accessToken: string }>();
    const setup = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/2fa/setup',
      headers: { authorization: `Bearer ${login.accessToken}`, 'x-api-key': apiKey },
    });
    const secret = setup.json<{ secret: string }>().secret;
    const enableCode = new TOTP({
      issuer: 'Simpastil',
      label: EMAIL,
      secret: Secret.fromBase32(secret),
      digits: 6,
      period: 30,
    }).generate();
    const enabled = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/2fa/enable',
      headers: { authorization: `Bearer ${login.accessToken}`, 'x-api-key': apiKey },
      payload: { code: enableCode },
    });
    expect(enabled.statusCode).toBe(200);
    const backupCode = enabled.json<{ backupCodes: string[] }>().backupCodes[0]!;

    const challenge = (await app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      headers: { 'x-api-key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    })).json<{ challengeToken: string }>();
    const completed = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/2fa/challenge',
      headers: { 'x-api-key': apiKey },
      payload: {
        challengeToken: challenge.challengeToken,
        code: backupCode,
      },
    });
    expect(completed.statusCode).toBe(200);
    const current = completed.json<{ accessToken: string }>();
    const laterChallenge = (await app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      headers: { 'x-api-key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    })).json<{ challengeToken: string }>();
    const logoutAll = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/logout-all',
      headers: { authorization: `Bearer ${current.accessToken}`, 'x-api-key': apiKey },
    });
    expect(logoutAll.statusCode).toBe(204);

    const stale = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/2fa/challenge',
      headers: { 'x-api-key': apiKey },
      payload: {
        challengeToken: laterChallenge.challengeToken,
        code: new TOTP({
          issuer: 'Simpastil',
          label: EMAIL,
          secret: Secret.fromBase32(secret),
          digits: 6,
          period: 30,
        }).generate(),
      },
    });
    expect(stale.statusCode).toBe(400);
    expect(stale.json<{ code: string }>().code).toBe('TOTP_CHALLENGE_INVALID');
  });

  it('invalidates access and refresh across backup-code regeneration', async () => {
    const original = (await registerAndLogin()).json<{ accessToken: string }>();
    const setup = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/2fa/setup',
      headers: { authorization: `Bearer ${original.accessToken}`, 'x-api-key': apiKey },
    });
    const secret = setup.json<{ secret: string }>().secret;
    const totp = new TOTP({
      issuer: 'Simpastil',
      label: EMAIL,
      secret: Secret.fromBase32(secret),
      digits: 6,
      period: 30,
    });
    const enabled = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/2fa/enable',
      headers: { authorization: `Bearer ${original.accessToken}`, 'x-api-key': apiKey },
      payload: { code: totp.generate() },
    });
    expect(enabled.statusCode).toBe(200);
    const challenge = (await app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      headers: { 'x-api-key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    })).json<{ challengeToken: string }>();
    const completed = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/2fa/challenge',
      headers: { 'x-api-key': apiKey },
      payload: { challengeToken: challenge.challengeToken, code: totp.generate() },
    });
    const fresh = completed.json<{ accessToken: string; refreshToken: string }>();

    const regenerated = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/2fa/backup-codes',
      headers: { authorization: `Bearer ${fresh.accessToken}`, 'x-api-key': apiKey },
      payload: { code: totp.generate() },
    });
    expect(regenerated.statusCode).toBe(200);

    const staleAccess = await app.inject({
      method: 'GET',
      url: '/api/v1/profiles',
      headers: { authorization: `Bearer ${fresh.accessToken}`, 'x-api-key': apiKey },
    });
    expect(staleAccess.statusCode).toBe(401);
    const staleRefresh = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/refresh',
      headers: { 'x-api-key': apiKey },
      payload: { refreshToken: fresh.refreshToken },
    });
    expect(staleRefresh.statusCode).toBe(401);
  });

  it('invalidates sessions when a password reset is redeemed', async () => {
    const original = (await registerAndLogin()).json<{ accessToken: string; refreshToken: string }>();
    const [user] = await superDb
      .select({ id: users.id })
      .from(users)
      .where(eq(users.email, EMAIL));
    const rawResetToken = 'a'.repeat(64);
    await superDb.insert(passwordResetTokens).values({
      userId: user!.id,
      tokenHash: sha256Hex(rawResetToken),
      expiresAt: new Date(Date.now() + 60 * 60 * 1000),
      used: false,
    });

    const reset = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/reset-password',
      payload: { token: rawResetToken, newPassword: CHANGED_PASSWORD },
    });
    expect(reset.statusCode).toBe(200);

    const staleAccess = await app.inject({
      method: 'GET',
      url: '/api/v1/profiles',
      headers: { authorization: `Bearer ${original.accessToken}`, 'x-api-key': apiKey },
    });
    expect(staleAccess.statusCode).toBe(401);
    const staleRefresh = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/refresh',
      headers: { 'x-api-key': apiKey },
      payload: { refreshToken: original.refreshToken },
    });
    expect(staleRefresh.statusCode).toBe(401);
  });

  it('supports an explicit user logout-all transition', async () => {
    const login = (await registerAndLogin()).json<{ accessToken: string; refreshToken: string }>();
    const logoutAll = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/logout-all',
      headers: { authorization: `Bearer ${login.accessToken}`, 'x-api-key': apiKey },
    });
    expect(logoutAll.statusCode).toBe(204);

    const staleRefresh = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/refresh',
      headers: { 'x-api-key': apiKey },
      payload: { refreshToken: login.refreshToken },
    });
    expect(staleRefresh.statusCode).toBe(401);
  });
});
