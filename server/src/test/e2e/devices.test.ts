import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import { eq } from 'drizzle-orm';
import { sha256Hex } from '../../lib/crypto.js';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, truncateAll, createUnclaimedKey } from '../helpers/db-helpers.js';
import { refreshTokens } from '../../db/schema.js';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';

describe('device name endpoints', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    app = await buildApp({ db: appDb, privateKey: process.env['JWT_PRIVATE_KEY']!, publicKey: process.env['JWT_PUBLIC_KEY']!, ttlSeconds: 60 });
  });
  afterAll(async () => { await app.close(); await cleanup(); });
  afterEach(async () => { await truncateAll(superDb); });

  async function setup() {
    const apiKey = await createUnclaimedKey(superDb);
    await app.inject({ method: 'POST', url: '/api/v1/auth/register', headers: { 'X-Api-Key': apiKey }, payload: { email: 'u@test.com', password: 'password1234' } });
    const loginRes = await app.inject({ method: 'POST', url: '/api/v1/auth/login', headers: { 'X-Api-Key': apiKey }, payload: { email: 'u@test.com', password: 'password1234' } });
    const { refreshToken, accessToken } = loginRes.json<{ refreshToken: string; accessToken: string }>();
    return { apiKey, refreshToken, accessToken };
  }

  it('POST /auth/device sets deviceName', async () => {
    const { apiKey, refreshToken, accessToken } = await setup();
    const res = await app.inject({
      method: 'POST', url: '/api/v1/auth/device',
      headers: { 'X-Api-Key': apiKey, Authorization: `Bearer ${accessToken}` },
      payload: { refreshToken, deviceName: 'SM-N975F' },
    });
    expect(res.statusCode).toBe(200);
    const [row] = await superDb
      .select({ deviceName: refreshTokens.deviceName })
      .from(refreshTokens)
      .where(eq(refreshTokens.tokenHash, sha256Hex(refreshToken)));
    expect(row?.deviceName).toBe('SM-N975F');
  });

  it('PATCH /auth/device updates deviceName', async () => {
    const { apiKey, refreshToken, accessToken } = await setup();
    await app.inject({ method: 'POST', url: '/api/v1/auth/device', headers: { 'X-Api-Key': apiKey, Authorization: `Bearer ${accessToken}` }, payload: { refreshToken, deviceName: 'old-name' } });
    const res = await app.inject({
      method: 'PATCH', url: '/api/v1/auth/device',
      headers: { 'X-Api-Key': apiKey, Authorization: `Bearer ${accessToken}` },
      payload: { refreshToken, deviceName: 'new-name' },
    });
    expect(res.statusCode).toBe(200);
    const [row] = await superDb
      .select({ deviceName: refreshTokens.deviceName })
      .from(refreshTokens)
      .where(eq(refreshTokens.tokenHash, sha256Hex(refreshToken)));
    expect(row?.deviceName).toBe('new-name');
  });

  it('deviceName persists after token rotation', async () => {
    const { apiKey, refreshToken, accessToken } = await setup();
    await app.inject({ method: 'POST', url: '/api/v1/auth/device', headers: { 'X-Api-Key': apiKey, Authorization: `Bearer ${accessToken}` }, payload: { refreshToken, deviceName: 'Pixel 9 Pro' } });
    const refreshRes = await app.inject({ method: 'POST', url: '/api/v1/auth/refresh', headers: { 'X-Api-Key': apiKey }, payload: { refreshToken } });
    const { refreshToken: newToken } = refreshRes.json<{ refreshToken: string }>();
    // Verify new token row has deviceName = 'Pixel 9 Pro'
    const [row] = await superDb
      .select({ deviceName: refreshTokens.deviceName })
      .from(refreshTokens)
      .where(eq(refreshTokens.tokenHash, sha256Hex(newToken)));
    expect(row?.deviceName).toBe('Pixel 9 Pro');
  });
});
