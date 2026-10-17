import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import { eq } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, truncateAll, createUnclaimedKey } from '../helpers/db-helpers.js';
import { apiKeys } from '../../db/schema.js';
import type { Db } from '../../db/client.js';

let app: FastifyInstance;
let superDb: Db;
let appDb: Db;
let cleanup: () => Promise<void>;
let keyA: string;

const EMAIL_A = 'alice@example.com';
const EMAIL_B = 'bob@example.com';
const PASSWORD = 'correct-horse-battery';

function register(apiKey: string, email: string) {
  return app.inject({
    method: 'POST',
    url: '/api/v1/auth/register',
    headers: { 'x-api-key': apiKey },
    payload: { email, password: PASSWORD },
  });
}

function login(apiKey: string, email: string, password = PASSWORD) {
  return app.inject({
    method: 'POST',
    url: '/api/v1/auth/login',
    headers: { 'x-api-key': apiKey },
    payload: { email, password },
  });
}

async function keyRowByLabel(label: string) {
  const rows = await superDb.select().from(apiKeys).where(eq(apiKeys.label, label));
  return rows[0];
}

beforeAll(async () => {
  ({ superDb, appDb, cleanup } = createDbs());
  app = await buildApp({
    db: appDb,
    privateKey: process.env['JWT_PRIVATE_KEY']!,
    publicKey: process.env['JWT_PUBLIC_KEY']!,
    ttlSeconds: 5,
  });
  keyA = await createUnclaimedKey(superDb, 'key-a');
});

afterEach(async () => {
  await truncateAll(superDb);
  keyA = await createUnclaimedKey(superDb, 'key-a');
});

afterAll(async () => {
  await app.close();
  await cleanup();
});

describe('login key binding', () => {
  it('logs in with an unclaimed key and binds it to the user', async () => {
    // Alice claims key A by registering; her "second device" gets fresh key B.
    const regRes = await register(keyA, EMAIL_A);
    const aliceId = regRes.json<{ userId: string }>().userId;
    const keyB = await createUnclaimedKey(superDb, 'key-b');

    const res = await login(keyB, EMAIL_A);
    expect(res.statusCode).toBe(200);
    const body = res.json<{ accessToken: string; refreshToken: string }>();
    expect(body.accessToken).toBeTruthy();
    expect(body.refreshToken).toBeTruthy();

    const row = await keyRowByLabel('key-b');
    expect(row?.userId).toBe(aliceId);
  });

  it('rejects login with a key owned by a different user', async () => {
    await register(keyA, EMAIL_A);
    const keyB = await createUnclaimedKey(superDb, 'key-b');
    await register(keyB, EMAIL_B);

    const res = await login(keyA, EMAIL_B); // Bob using Alice's key
    expect(res.statusCode).toBe(403);
  });

  it('still logs in with the user own claimed key', async () => {
    await register(keyA, EMAIL_A);
    const res = await login(keyA, EMAIL_A);
    expect(res.statusCode).toBe(200);
  });

  it('does not bind the key when credentials are wrong', async () => {
    await register(keyA, EMAIL_A);
    const keyB = await createUnclaimedKey(superDb, 'key-b');

    const res = await login(keyB, EMAIL_A, 'totally-wrong-password');
    expect(res.statusCode).toBe(401);

    const row = await keyRowByLabel('key-b');
    expect(row?.userId).toBeNull();
  });

  it('accepts forgot-password with an unclaimed key', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/forgot-password',
      headers: { 'x-api-key': keyA },
      payload: { email: EMAIL_A },
    });
    expect(res.statusCode).toBe(200);
  });

  it('still rejects register with an already-claimed key', async () => {
    await register(keyA, EMAIL_A);
    const res = await register(keyA, EMAIL_B);
    expect(res.statusCode).toBe(409);
  });

  it('rejects login with a revoked key and does not bind it', async () => {
    await register(keyA, EMAIL_A);
    const keyB = await createUnclaimedKey(superDb, 'key-b');
    await superDb
      .update(apiKeys)
      .set({ revokedAt: new Date() })
      .where(eq(apiKeys.label, 'key-b'));

    const res = await login(keyB, EMAIL_A);
    expect(res.statusCode).toBe(401);

    const row = await keyRowByLabel('key-b');
    expect(row?.userId).toBeNull();
  });
});
