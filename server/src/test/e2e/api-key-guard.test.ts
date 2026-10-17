import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import { eq } from 'drizzle-orm';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, truncateAll, createUnclaimedKey } from '../helpers/db-helpers.js';
import { apiKeys } from '../../db/schema.js';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';

const EMAIL    = 'alice@example.com';
const PASSWORD = 'password1234';

describe('apiKeyGuard', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    app = await buildApp({ db: appDb, privateKey: process.env['JWT_PRIVATE_KEY']!, publicKey: process.env['JWT_PUBLIC_KEY']!, ttlSeconds: 5 });
  });
  afterAll(async () => { await app.close(); await cleanup(); });
  afterEach(async () => { await truncateAll(superDb); });

  async function registerAndLogin(apiKey: string) {
    await app.inject({ method: 'POST', url: '/api/v1/auth/register', headers: { 'X-Api-Key': apiKey }, payload: { email: EMAIL, password: PASSWORD } });
    return app.inject({ method: 'POST', url: '/api/v1/auth/login', headers: { 'X-Api-Key': apiKey }, payload: { email: EMAIL, password: PASSWORD } });
  }

  it('returns 401 when X-Api-Key header is missing', async () => {
    const res = await app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email: EMAIL, password: PASSWORD } });
    expect(res.statusCode).toBe(401);
  });

  it('returns 401 for an unknown key', async () => {
    const res = await app.inject({ method: 'POST', url: '/api/v1/auth/login', headers: { 'X-Api-Key': 'deadbeef'.repeat(8) }, payload: { email: EMAIL, password: PASSWORD } });
    expect(res.statusCode).toBe(401);
  });

  it('returns 401 for a revoked key', async () => {
    const rawKey = await createUnclaimedKey(superDb);
    await app.inject({ method: 'POST', url: '/api/v1/auth/register', headers: { 'X-Api-Key': rawKey }, payload: { email: EMAIL, password: PASSWORD } });
    // Revoke via Drizzle (superDb bypasses RLS)
    const { createHash } = await import('node:crypto');
    const keyHash = createHash('sha256').update(rawKey).digest('hex');
    await superDb.update(apiKeys).set({ revokedAt: new Date() }).where(eq(apiKeys.keyHash, keyHash));
    const res = await app.inject({ method: 'POST', url: '/api/v1/auth/login', headers: { 'X-Api-Key': rawKey }, payload: { email: EMAIL, password: PASSWORD } });
    expect(res.statusCode).toBe(401);
  });

  it('allows request with a valid key', async () => {
    const unclaimedKey = await createUnclaimedKey(superDb);
    const loginRes = await registerAndLogin(unclaimedKey);
    expect(loginRes.statusCode).toBe(200);
  });

  it('health check requires no API key', async () => {
    const res = await app.inject({ method: 'GET', url: '/api/v1/health' });
    expect(res.statusCode).toBe(200);
  });
});
