import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, truncateAll, createUnclaimedKey } from '../helpers/db-helpers.js';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';

const EMAIL    = 'racetest@example.com';
const PASSWORD = 'password1234';

describe('concurrent refresh — reuse detection', () => {
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
      withErrorHandler: true,
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

  async function refresh(refreshToken: string) {
    return app.inject({
      method: 'POST', url: '/api/v1/auth/refresh',
      headers: { 'X-Api-Key': apiKey },
      payload: { refreshToken },
    });
  }

  it('concurrent refresh — one succeeds, other gets AUTH_TOKEN_REUSE', async () => {
    await register();
    const { refreshToken } =
      (await login()).json<{ accessToken: string; refreshToken: string }>();

    const [r1, r2] = await Promise.all([
      refresh(refreshToken),
      refresh(refreshToken),
    ]);

    const statuses = [r1.statusCode, r2.statusCode].sort();
    expect(statuses).toEqual([200, 401]);

    const winner = r1.statusCode === 200 ? r1 : r2;
    const body = winner.json<{ accessToken: string; refreshToken: string }>();
    expect(body.accessToken).toBeTruthy();
    expect(body.refreshToken).toBeTruthy();

    const loser = r1.statusCode === 401 ? r1 : r2;
    const errBody = loser.json<{ error: string; code: string }>();
    expect(errBody.code).toBe('AUTH_TOKEN_REUSE');
  });

  it('after concurrent race, the winner successor is revoked with the refresh family', async () => {
    await register();
    const { refreshToken } =
      (await login()).json<{ accessToken: string; refreshToken: string }>();

    const [r1, r2] = await Promise.all([
      refresh(refreshToken),
      refresh(refreshToken),
    ]);

    const winner = r1.statusCode === 200 ? r1 : r2;
    const winnerToken = winner.json<{ refreshToken: string }>().refreshToken;

    const followUp = await refresh(winnerToken);
    expect(followUp.statusCode).toBe(401);
    expect(followUp.json<{ code: string }>().code).toBe('AUTH_TOKEN_REUSE');
  });

  it('reuse detection returns structured error with AUTH_TOKEN_REUSE code', async () => {
    await register();
    const { refreshToken: rt1 } =
      (await login()).json<{ accessToken: string; refreshToken: string }>();

    await refresh(rt1);

    const reuse = await refresh(rt1);
    expect(reuse.statusCode).toBe(401);
    const body = reuse.json<{ error: string; code: string }>();
    expect(body.code).toBe('AUTH_TOKEN_REUSE');
    expect(body.error).toBeTruthy();
  });
});

describe('rate-limit retryAfter response shape', () => {
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
      withErrorHandler: true,
      rateLimitMax: 2,
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

  it('429 response includes retryAfter (number) and RATE_LIMIT_EXCEEDED code', async () => {
    await app.inject({
      method: 'POST', url: '/api/v1/auth/register',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: 'rl@example.com', password: 'password1234' },
    });

    // Exhaust the 2-request limit
    for (let i = 0; i < 2; i++) {
      await app.inject({
        method: 'POST', url: '/api/v1/auth/login',
        headers: { 'X-Api-Key': apiKey },
        payload: { email: 'rl@example.com', password: 'password1234' },
      });
    }

    // Third request should be rate-limited
    const res = await app.inject({
      method: 'POST', url: '/api/v1/auth/login',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: 'rl@example.com', password: 'password1234' },
    });

    expect(res.statusCode).toBe(429);
    const body = res.json<{ error: string; code: string; retryAfter: number }>();
    expect(body.code).toBe('RATE_LIMIT_EXCEEDED');
    expect(body.retryAfter).toBeTypeOf('number');
    expect(body.retryAfter).toBeGreaterThan(0);
    expect(body.error).toBe('Too Many Requests');
  });
});
