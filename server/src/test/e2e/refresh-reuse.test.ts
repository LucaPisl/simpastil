import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import { eq, sql as drizzleSql } from 'drizzle-orm';
import { randomUUID } from 'node:crypto';
import { startTokenGc } from '../../lib/token-gc.js';
import { buildApp } from '../helpers/app-factory.js';
import {
  createDbs,
  createUnclaimedKey,
  truncateAll,
  waitForBlockedQuery,
} from '../helpers/db-helpers.js';
import { refreshTokens, users } from '../../db/schema.js';
import { sha256Hex } from '../../lib/crypto.js';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';

const EMAIL = 'refresh-reuse@example.invalid';
const PASSWORD = 'password1234';

describe('opaque refresh-family rotation', () => {
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

  async function login() {
    await app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      headers: { 'x-api-key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    });
    return app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      headers: { 'x-api-key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    });
  }

  it('keeps refresh credentials opaque and rolls them for thirty days', async () => {
    const response = await login();
    const body = response.json<{ refreshToken: string }>();
    expect(body.refreshToken).toMatch(/^[0-9a-f]{64}$/);
    expect(body.refreshToken.split('.')).toHaveLength(1);

    const [row] = await superDb
      .select({ expiresAt: refreshTokens.expiresAt })
      .from(refreshTokens);
    expect(row?.expiresAt.getTime()).toBeGreaterThan(Date.now() + 29 * 24 * 60 * 60 * 1000);
  });

  it('permits one concurrent successor and revokes the family on predecessor replay', async () => {
    const initial = (await login()).json<{ refreshToken: string }>();
    const attempts = await Promise.all([
      app.inject({
        method: 'POST',
        url: '/api/v1/auth/refresh',
        headers: { 'x-api-key': apiKey },
        payload: { refreshToken: initial.refreshToken },
      }),
      app.inject({
        method: 'POST',
        url: '/api/v1/auth/refresh',
        headers: { 'x-api-key': apiKey },
        payload: { refreshToken: initial.refreshToken },
      }),
    ]);
    expect(attempts.map((response) => response.statusCode).sort()).toEqual([200, 401]);

    const successor = attempts.find((response) => response.statusCode === 200)!
      .json<{ refreshToken: string }>().refreshToken;
    // The losing concurrent request must have committed family revocation
    // before returning; the successor is not allowed one more use.
    const familyReplay = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/refresh',
      headers: { 'x-api-key': apiKey },
      payload: { refreshToken: successor },
    });
    expect(familyReplay.statusCode).toBe(401);

    const replay = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/refresh',
      headers: { 'x-api-key': apiKey },
      payload: { refreshToken: initial.refreshToken },
    });
    expect(replay.statusCode).toBe(401);
  });

  it('checks expiry after waiting for the user session lock', async () => {
    const initial = (await login()).json<{ refreshToken: string }>();
    const tokenHash = sha256Hex(initial.refreshToken);
    const [user] = await superDb.select({ id: users.id }).from(users).where(eq(users.email, EMAIL));
    await superDb
      .update(refreshTokens)
      .set({ expiresAt: new Date(Date.now() + 75) })
      .where(eq(refreshTokens.tokenHash, tokenHash));

    let release!: () => void;
    let locked!: () => void;
    const releaseGate = new Promise<void>((resolve) => { release = resolve; });
    const lockGate = new Promise<void>((resolve) => { locked = resolve; });
    const heldLock = superDb.transaction(async (tx) => {
      await tx.execute(drizzleSql`SELECT id FROM users WHERE id = ${user!.id} FOR UPDATE`);
      locked();
      await releaseGate;
    });
    await lockGate;

    const refreshPromise = app.inject({
      method: 'POST',
      url: '/api/v1/auth/refresh',
      headers: { 'X-Api-Key': apiKey },
      payload: { refreshToken: initial.refreshToken },
    });
    await waitForBlockedQuery(superDb, 'users');
    const [{ now }] = await superDb.execute<{ now: Date | string }>(drizzleSql`SELECT clock_timestamp() AS now`);
    await superDb
      .update(refreshTokens)
      .set({ expiresAt: new Date(new Date(now).getTime() + 50) })
      .where(eq(refreshTokens.tokenHash, tokenHash));
    await new Promise((resolve) => setTimeout(resolve, 100));
    release();
    await heldLock;
    expect((await refreshPromise).statusCode).toBe(401);
  });

  it('derives a rolling successor deadline after acquiring the token lock', async () => {
    const initial = (await login()).json<{ refreshToken: string }>();
    await superDb
      .update(refreshTokens)
      .set({ expiresAt: new Date(Date.now() + 60 * 1000) })
      .where(eq(refreshTokens.tokenHash, sha256Hex(initial.refreshToken)));

    const rotated = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/refresh',
      headers: { 'X-Api-Key': apiKey },
      payload: { refreshToken: initial.refreshToken },
    });
    expect(rotated.statusCode).toBe(200);
    const successor = rotated.json<{ refreshToken: string }>().refreshToken;
    const [row] = await superDb
      .select({ expiresAt: refreshTokens.expiresAt })
      .from(refreshTokens)
      .where(eq(refreshTokens.tokenHash, sha256Hex(successor)));
    expect(row?.expiresAt.getTime()).toBeGreaterThan(Date.now() + 29 * 24 * 60 * 60 * 1000);
  });
});

describe('token garbage collection', () => {
  let superDb: Db;
  let cleanup: () => Promise<void>;

  beforeAll(() => {
    ({ superDb, cleanup } = createDbs());
  });

  afterAll(async () => {
    await cleanup();
  });

  afterEach(async () => {
    await truncateAll(superDb);
  });

  it('leaves old soft-deleted dose logs untouched and still purges expired refresh tokens', async () => {
    const userId = randomUUID();
    const profileId = randomUUID();
    const pillId = randomUUID();
    const scheduleId = randomUUID();
    const doseId = randomUUID();
    const familyId = randomUUID();
    const longAgo = new Date(Date.now() - 400 * 86400_000);

    await superDb.transaction(async (tx) => {
      await tx.execute(drizzleSql`SELECT set_config('app.current_user_id', ${userId}, true)`);
      await tx.execute(drizzleSql`INSERT INTO users (id, email, password_hash) VALUES (${userId}, 'gc@example.invalid', 'fixture-hash')`);
      await tx.execute(drizzleSql`INSERT INTO profiles (id, user_id, name) VALUES (${profileId}, ${userId}, 'Fixture person')`);
      await tx.execute(drizzleSql`INSERT INTO pills (id, profile_id, name) VALUES (${pillId}, ${profileId}, 'Fixture medication')`);
      await tx.execute(drizzleSql`INSERT INTO schedules (id, pill_id, hour, minute, frequency, is_active, time_zone_status, time_zone) VALUES (${scheduleId}, ${pillId}, 8, 0, 'daily', true, 'known', 'Europe/Bucharest')`);
      await tx.execute(drizzleSql`INSERT INTO dose_logs (id, schedule_id, scheduled_at, status, deleted_at) VALUES (${doseId}, ${scheduleId}, ${longAgo.toISOString()}, 'missed', ${longAgo.toISOString()})`);
      await tx.insert(refreshTokens).values({
        userId,
        tokenHash: 'fixture-expired-token-hash',
        familyId,
        expiresAt: longAgo,
        revoked: true,
        createdAt: longAgo,
      });
    });

    const errors: unknown[] = [];
    const original = console.error;
    console.error = (...args: unknown[]) => { errors.push(args); };
    try {
      const gc = startTokenGc(superDb);
      expect(await gc.drain(Date.now() + 5000)).toBe(true);
    } finally {
      console.error = original;
    }

    expect(errors).toEqual([]);
    const doses = await superDb.execute(drizzleSql`SELECT id FROM dose_logs WHERE id = ${doseId}`);
    expect(doses).toHaveLength(1);
    expect(await superDb.select().from(refreshTokens)).toHaveLength(0);
  });
});
