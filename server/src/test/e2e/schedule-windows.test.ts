import { randomUUID } from 'node:crypto';
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { sql } from 'drizzle-orm';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, createUnclaimedKey, truncateAll } from '../helpers/db-helpers.js';
import { addLocalDays, localDateAt } from '../../modules/medication/occurrence-materializer.js';
import { SCHEDULE_WINDOWS_MIN_CLIENT_BUILD } from '../../modules/schedules/schedule-windows.js';

type Headers = Record<string, string>;
const ZONE = 'Europe/Bucharest';
let counter = 0;

describe('schedule windows over the API', () => {
  let app: FastifyInstance;
  let cleanup: () => Promise<void>;
  let superDb: Awaited<ReturnType<typeof createDbs>>['superDb'];
  let apiKey: string;

  async function registerUser(): Promise<{ userId: string; headers: (build: number) => Headers }> {
    const key = await createUnclaimedKey(superDb);
    apiKey = key;
    const email = `windows_${Date.now()}_${++counter}@test.com`;
    const register = await app.inject({
      method: 'POST', url: '/api/v1/auth/register', headers: { 'X-Api-Key': key },
      payload: { email, password: 'password1234' },
    });
    expect(register.statusCode).toBe(201);
    const login = await app.inject({
      method: 'POST', url: '/api/v1/auth/login', headers: { 'X-Api-Key': key },
      payload: { email, password: 'password1234' },
    });
    const token = login.json<{ accessToken: string }>().accessToken;
    const [row] = await superDb.execute<{ id: string }>(sql`SELECT id FROM users WHERE email = ${email}`);
    return {
      userId: row!.id,
      headers: (build) => ({
        authorization: `Bearer ${token}`, 'X-Api-Key': key, 'X-Simpastil-Client-Build': String(build),
      }),
    };
  }

  beforeAll(async () => {
    const dbs = createDbs();
    superDb = dbs.superDb;
    cleanup = dbs.cleanup;
    app = await buildApp({
      db: dbs.appDb, privateKey: process.env['JWT_PRIVATE_KEY']!, publicKey: process.env['JWT_PUBLIC_KEY']!,
      ttlSeconds: 600,
    });
  });
  afterEach(async () => truncateAll(superDb));
  afterAll(async () => {
    await app.close();
    await cleanup();
  });

  async function pillFor(headers: Headers): Promise<string> {
    const profile = await app.inject({
      method: 'POST', url: '/api/v1/profiles', headers,
      payload: { mutationId: randomUUID(), name: 'Windows profile' },
    });
    expect(profile.statusCode).toBe(201);
    const pill = await app.inject({
      method: 'POST', url: `/api/v1/profiles/${profile.json<{ id: string }>().id}/pills`, headers,
      payload: { mutationId: randomUUID(), name: 'Windows pill' },
    });
    expect(pill.statusCode).toBe(201);
    return pill.json<{ id: string }>().id;
  }

  const create = (headers: Headers, pillId: string, extra: Record<string, unknown>) => app.inject({
    method: 'POST', url: `/api/v1/pills/${pillId}/schedules`, headers,
    payload: { mutationId: randomUUID(), hour: 8, minute: 30, frequency: 'daily', timeZone: ZONE, ...extra },
  });

  const minimumBuild = async (userId: string) => (await superDb.execute<{ minimum_client_build: number }>(
    sql`SELECT minimum_client_build FROM users WHERE id = ${userId}`))[0]!.minimum_client_build;

  it('advertises scheduleWindows and movedHistory', async () => {
    const response = await app.inject({ method: 'GET', url: '/api/v1/capabilities', headers: { 'X-Api-Key': apiKey ?? '' } });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({ scheduleWindows: true, movedHistory: true, recordedMiss: true });
  });

  it('leaves a plain schedule alone: no gate change and the original sync payload', async () => {
    const user = await registerUser();
    const pillId = await pillFor(user.headers(6));
    const created = await create(user.headers(6), pillId, {});
    expect(created.statusCode).toBe(201);
    expect(await minimumBuild(user.userId)).toBe(1);
    const [change] = await superDb.execute<{ payload: { payload: Record<string, unknown> } }>(sql`
      SELECT payload FROM sync_changes WHERE user_id = ${user.userId} AND entity_type = 'schedule'`);
    expect(change!.payload.payload).not.toHaveProperty('everyDays');
    expect(change!.payload.payload).not.toHaveProperty('startDate');
    // Build 6 keeps working.
    expect((await create(user.headers(6), pillId, {})).statusCode).toBe(201);
  });

  it('holds only the account that stores an interval or dated routine to build 7', async () => {
    const user = await registerUser();
    const other = await registerUser();
    const pillId = await pillFor(user.headers(6));
    const otherPill = await pillFor(other.headers(6));

    const interval = await create(user.headers(SCHEDULE_WINDOWS_MIN_CLIENT_BUILD), pillId, {
      frequency: 'interval', everyDays: 3, anchorDate: localDateAt(new Date(), ZONE),
    });
    expect(interval.statusCode).toBe(201);
    expect(interval.json()).toMatchObject({ frequency: 'interval', everyDays: 3, frequencyDays: null, startDate: null, endDate: null });
    expect(await minimumBuild(user.userId)).toBe(SCHEDULE_WINDOWS_MIN_CLIENT_BUILD);

    // Build 6 is now refused for this account on every gated route...
    const stale = await create(user.headers(6), pillId, {});
    expect(stale.statusCode).toBe(426);
    expect(stale.json().error.code).toBe('CLIENT_UPGRADE_REQUIRED');
    const staleMoved = await app.inject({
      method: 'POST', url: '/api/v1/medication/moved-history', headers: user.headers(6),
      payload: { scheduleId: interval.json<{ id: string }>().id, items: [] },
    });
    expect(staleMoved.statusCode).toBe(426);
    // ...build 7 passes, and another account on build 6 is untouched.
    expect((await create(user.headers(7), pillId, {})).statusCode).toBe(201);
    expect((await create(other.headers(6), otherPill, {})).statusCode).toBe(201);
    expect(await minimumBuild(other.userId)).toBe(1);

    // The change reaches sync with all four keys, and a pull re-parses it.
    const pull = await app.inject({
      method: 'GET', url: '/api/v1/sync/stable?contractVersion=2', headers: user.headers(7),
    });
    expect(pull.statusCode).toBe(200);
    const schedules = (pull.json().items as Array<{ change: { payload: Record<string, unknown> } }>)
      .map((item) => item.change.payload).filter((payload) => payload['kind'] === 'schedule');
    const intervalPayload = schedules.find((payload) => payload['frequency'] === 'interval')!;
    expect(intervalPayload).toMatchObject({ everyDays: 3, startDate: null, endDate: null });
    expect(Object.keys(intervalPayload)).toEqual(expect.arrayContaining(['everyDays', 'anchorDate', 'startDate', 'endDate']));
    const plain = schedules.find((payload) => payload['frequency'] === 'daily')!;
    expect(plain).not.toHaveProperty('everyDays');
  });

  it('raises the floor for a dated routine too, but never lowers it', async () => {
    const user = await registerUser();
    const pillId = await pillFor(user.headers(6));
    const dated = await create(user.headers(6), pillId, { startDate: '2026-01-01', endDate: '2026-12-31' });
    expect(dated.statusCode).toBe(201);
    expect(await minimumBuild(user.userId)).toBe(SCHEDULE_WINDOWS_MIN_CLIENT_BUILD);
    const { id, revision } = dated.json<{ id: string; revision: string }>();
    const cleared = await app.inject({
      method: 'PATCH', url: `/api/v1/pills/${pillId}/schedules/${id}`, headers: user.headers(7),
      payload: { mutationId: randomUUID(), baseRevision: revision, startDate: null, endDate: null },
    });
    expect(cleared.statusCode).toBe(200);
    expect(cleared.json()).toMatchObject({ startDate: null, endDate: null });
    expect(await minimumBuild(user.userId)).toBe(SCHEDULE_WINDOWS_MIN_CLIENT_BUILD);
  });

  it('rejects an invalid interval or window with a validation error', async () => {
    const user = await registerUser();
    const pillId = await pillFor(user.headers(7));
    for (const extra of [
      { frequency: 'interval', everyDays: 3 },
      { frequency: 'daily', everyDays: 3 },
      { frequency: 'prn', startDate: '2026-01-01' },
      { startDate: '2026-02-01', endDate: '2026-01-01' },
    ]) {
      const response = await create(user.headers(7), pillId, extra);
      expect(response.statusCode, JSON.stringify(extra)).toBe(400);
    }
    expect(await minimumBuild(user.userId)).toBe(1);
  });

  it('materializes interval days as version 3 occurrences and serves moved history over HTTP', async () => {
    const user = await registerUser();
    const headers = user.headers(7);
    const pillId = await pillFor(headers);
    const today = localDateAt(new Date(), ZONE);
    const created = await create(headers, pillId, {
      hour: 0, minute: 0, frequency: 'interval', everyDays: 2, anchorDate: today,
    });
    expect(created.statusCode).toBe(201);
    const scheduleId = created.json<{ id: string }>().id;

    const request = {
      scheduleId,
      items: [1, 2].map((daysAgo) => ({
        occurrenceId: randomUUID(),
        plannedLocalDate: addLocalDays(today, -daysAgo),
        plannedLocalTime: '08:00',
        timeZone: ZONE,
        routine: { frequency: 'interval', frequencyDays: null, everyDays: 2, anchorDate: addLocalDays(today, -10), startDate: null, endDate: null },
      })),
    };
    const first = await app.inject({ method: 'POST', url: '/api/v1/medication/moved-history', headers, payload: request });
    expect(first.statusCode).toBe(200);
    expect(first.json()).toEqual({
      items: request.items.map((item, index) => ({
        occurrenceId: item.occurrenceId,
        occurrenceKey: first.json().items[index].occurrenceKey,
        stateVersion: '0',
        created: true,
      })),
    });
    const replay = await app.inject({ method: 'POST', url: '/api/v1/medication/moved-history', headers, payload: request });
    expect(replay.statusCode).toBe(200);
    expect(replay.json().items.map((row: { created: boolean }) => row.created)).toEqual([false, false]);

    const versions = await superDb.execute<{ snapshot_version: number }>(sql`
      SELECT DISTINCT snapshot_version FROM medication_occurrences WHERE schedule_id = ${scheduleId}`);
    expect(versions.map((row) => row.snapshot_version)).toEqual([3]);

    const future = await app.inject({
      method: 'POST', url: '/api/v1/medication/moved-history', headers,
      payload: { ...request, items: [{ ...request.items[0]!, occurrenceId: randomUUID(), plannedLocalDate: addLocalDays(today, 3) }] },
    });
    expect(future.statusCode).toBe(400);
    const clash = await app.inject({
      method: 'POST', url: '/api/v1/medication/moved-history', headers,
      payload: { ...request, items: [{ ...request.items[0]!, plannedLocalDate: addLocalDays(today, -4) }] },
    });
    expect(clash.statusCode).toBe(409);
  });
});
