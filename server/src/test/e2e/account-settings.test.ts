import { randomUUID } from 'node:crypto';
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { sql } from 'drizzle-orm';
import { vi } from 'vitest';
import { AccountSettingsService } from '../../modules/account-settings/account-settings.service.js';
import { constraintOf } from '../../lib/pg-errors.js';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, createUnclaimedKey, truncateAll } from '../helpers/db-helpers.js';

type Headers = Record<string, string>;
interface Change { key: string; value: unknown; baseRevision: number; ifAbsent?: boolean }
interface PutResponse { revision: number; results: Array<Record<string, unknown>> }
interface PageResponse { revision: number; hasMore: boolean; items: Array<{ key: string; value: unknown; revision: number; updatedAt: string }> }
let counter = 0;

describe('account settings over the API', () => {
  let app: FastifyInstance;
  let limitedApp: FastifyInstance;
  let cleanup: () => Promise<void>;
  let superDb: Awaited<ReturnType<typeof createDbs>>['superDb'];
  let appDb: Awaited<ReturnType<typeof createDbs>>['appDb'];

  async function registerUser(): Promise<{ userId: string; headers: Headers }> {
    const key = await createUnclaimedKey(superDb);
    const email = `settings_${Date.now()}_${++counter}@test.com`;
    await app.inject({
      method: 'POST', url: '/api/v1/auth/register', headers: { 'X-Api-Key': key },
      payload: { email, password: 'password1234' },
    });
    const login = await app.inject({
      method: 'POST', url: '/api/v1/auth/login', headers: { 'X-Api-Key': key },
      payload: { email, password: 'password1234' },
    });
    const [row] = await superDb.execute<{ id: string }>(sql`SELECT id FROM users WHERE email = ${email}`);
    return {
      userId: row!.id,
      headers: { authorization: `Bearer ${login.json<{ accessToken: string }>().accessToken}`, 'X-Api-Key': key, 'X-Simpastil-Client-Build': '9' },
    };
  }

  beforeAll(async () => {
    const dbs = createDbs();
    superDb = dbs.superDb;
    appDb = dbs.appDb;
    cleanup = dbs.cleanup;
    const keys = { privateKey: process.env['JWT_PRIVATE_KEY']!, publicKey: process.env['JWT_PUBLIC_KEY']! };
    app = await buildApp({ db: dbs.appDb, ...keys, ttlSeconds: 600 });
    limitedApp = await buildApp({ db: dbs.appDb, ...keys, ttlSeconds: 600, rateLimitMax: 3 });
  });
  afterEach(async () => truncateAll(superDb));
  afterAll(async () => {
    await app.close();
    await limitedApp.close();
    await cleanup();
  });

  const put = (headers: Headers, changes: Change[], target: FastifyInstance = app) => target.inject({
    method: 'PUT', url: '/api/v1/account/settings', headers, payload: { changes },
  });
  const get = (headers: Headers, afterRevision?: number) => app.inject({
    method: 'GET', url: `/api/v1/account/settings${afterRevision === undefined ? '' : `?afterRevision=${afterRevision}`}`, headers,
  });
  const set = (key: string, value: unknown, baseRevision = 0): Change => ({ key, value, baseRevision });

  it('advertises the accountSettings capability', async () => {
    const response = await app.inject({ method: 'GET', url: '/api/v1/capabilities' });
    expect(response.json<{ contracts: Record<string, number> }>().contracts['accountSettings']).toBe(1);
  });

  it('starts empty and stores, returns and pages values with distinct revisions', async () => {
    const { headers } = await registerUser();
    expect((await get(headers)).json()).toEqual({ revision: 0, items: [], hasMore: false });

    const written = await put(headers, [set('language', 'ro'), set('asNeeded.inStats', true), set('reminders.snoozeMinutes', 15)]);
    expect(written.statusCode).toBe(200);
    const body = written.json<PutResponse>();
    expect(body.revision).toBe(3);
    expect(body.results).toEqual([
      { key: 'language', status: 'applied', revision: 1 },
      { key: 'asNeeded.inStats', status: 'applied', revision: 2 },
      { key: 'reminders.snoozeMinutes', status: 'applied', revision: 3 },
    ]);

    const all = (await get(headers)).json<PageResponse>();
    expect(all.revision).toBe(3);
    expect(all.items.map((item) => [item.key, item.value, item.revision])).toEqual([
      ['language', 'ro', 1], ['asNeeded.inStats', true, 2], ['reminders.snoozeMinutes', 15, 3],
    ]);
    expect(new Date(all.items[0]!.updatedAt).toISOString()).toBe(all.items[0]!.updatedAt);

    const later = (await get(headers, 2)).json<PageResponse>();
    expect(later.items.map((item) => item.key)).toEqual(['reminders.snoozeMinutes']);
  });

  it('applies a change against the right base revision and keeps the server value on a stale one', async () => {
    const { headers } = await registerUser();
    await put(headers, [set('language', 'ro')]);
    const stale = (await put(headers, [set('language', 'system', 0)])).json<PutResponse>();
    expect(stale.results[0]).toEqual({ key: 'language', status: 'conflict', current: { value: 'ro', revision: 1 } });
    expect(stale.revision).toBe(1);
    expect((await get(headers)).json<PageResponse>().items[0]!.value).toBe('ro');

    const fresh = (await put(headers, [set('language', 'system', 1)])).json<PutResponse>();
    expect(fresh.results[0]).toEqual({ key: 'language', status: 'applied', revision: 2 });
  });

  it('reports a base revision that points at a key the account never held as a conflict', async () => {
    const { headers } = await registerUser();
    const result = (await put(headers, [set('language', 'ro', 4)])).json<PutResponse>();
    expect(result.results[0]).toEqual({ key: 'language', status: 'conflict', current: { value: null, revision: 0 } });
    expect(result.revision).toBe(0);
  });

  it('seeds only keys the account never had (ifAbsent) and keeps the rest', async () => {
    const { headers } = await registerUser();
    const first = (await put(headers, [
      { ...set('language', 'ro'), ifAbsent: true },
      { ...set('asNeeded.inStats', false), ifAbsent: true },
    ])).json<PutResponse>();
    expect(first.results.map((r) => r['status'])).toEqual(['applied', 'applied']);

    const second = (await put(headers, [
      { ...set('language', 'system'), ifAbsent: true },
      { ...set('medications.siblingDetection', 'perPill'), ifAbsent: true },
    ])).json<PutResponse>();
    expect(second.results[0]).toEqual({ key: 'language', status: 'kept', current: { value: 'ro', revision: 1 } });
    expect(second.results[1]).toMatchObject({ key: 'medications.siblingDetection', status: 'applied' });
    const stored = (await get(headers)).json<PageResponse>().items.map((item) => [item.key, item.value]);
    expect(stored).toEqual([['language', 'ro'], ['asNeeded.inStats', false], ['medications.siblingDetection', 'perPill']]);
  });

  it('lets two devices seed at the same time without losing either one', async () => {
    const { headers } = await registerUser();
    const seed = (value: string) => put(headers, [{ ...set('language', value), ifAbsent: true }]);
    const [a, b] = await Promise.all([seed('ro'), seed('en')]);
    const statuses = [a, b].map((response) => response.json<PutResponse>().results[0]!['status']).sort();
    expect(statuses).toEqual(['applied', 'kept']);
    expect((await get(headers)).json<PageResponse>().items).toHaveLength(1);
  });

  it('clears a key with null, hides it from a first pull and still shows it to a later one', async () => {
    const { headers } = await registerUser();
    await put(headers, [set('language', 'ro')]);
    await put(headers, [set('language', null, 1)]);
    expect((await get(headers)).json<PageResponse>().items).toEqual([]);
    const later = (await get(headers, 1)).json<PageResponse>();
    expect(later.items).toMatchObject([{ key: 'language', value: null, revision: 2 }]);
    // A cleared key counts as one the account held: a seed keeps it cleared.
    const seed = (await put(headers, [{ ...set('language', 'en'), ifAbsent: true }])).json<PutResponse>();
    expect(seed.results[0]).toMatchObject({ status: 'kept', current: { value: null, revision: 2 } });
  });

  it('pages 500 at a time and loses nothing across the page boundary', async () => {
    const { headers, userId } = await registerUser();
    const ids = Array.from({ length: 600 }, () => randomUUID());
    for (let start = 0; start < ids.length; start += 100) {
      const batch = ids.slice(start, start + 100).map((id) => set(`reminders.person.${id}`, { enabled: true }));
      expect((await put(headers, batch)).statusCode).toBe(200);
    }
    const first = (await get(headers)).json<PageResponse>();
    expect(first.items).toHaveLength(500);
    expect(first.hasMore).toBe(true);
    expect(first.revision).toBe(600);
    const second = (await get(headers, first.items.at(-1)!.revision)).json<PageResponse>();
    expect(second.items).toHaveLength(100);
    expect(second.hasMore).toBe(false);
    const seen = new Set([...first.items, ...second.items].map((item) => item.key));
    expect(seen.size).toBe(600);
    const [count] = await superDb.execute<{ n: number }>(sql`SELECT count(*)::int AS n FROM account_settings WHERE user_id = ${userId}`);
    expect(count!.n).toBe(600);
  });

  describe('validation', () => {
    it('refuses an unknown key with SETTINGS_KEY_UNKNOWN and writes nothing from the batch', async () => {
      const { headers } = await registerUser();
      const response = await put(headers, [set('language', 'ro'), set('theme.mode', 'dark')]);
      expect(response.statusCode).toBe(400);
      expect(response.json().error.code).toBe('SETTINGS_KEY_UNKNOWN');
      expect((await get(headers)).json<PageResponse>().items).toEqual([]);
    });

    it('refuses a wrong value, a duplicate key and an empty batch with VALIDATION_ERROR', async () => {
      const { headers } = await registerUser();
      for (const changes of [
        [set('reminders.snoozeMinutes', 0)],
        [set('language', 'ro'), set('language', 'system')],
        [],
      ]) {
        const response = await put(headers, changes);
        expect(response.statusCode).toBe(400);
        expect(response.json().error.code).toBe('VALIDATION_ERROR');
      }
    });

    it('refuses an oversized value with 413 SETTINGS_VALUE_TOO_LARGE', async () => {
      const { headers } = await registerUser();
      const response = await put(headers, [set('appearance.colors', { light: {}, dark: {}, padding: 'x'.repeat(9000) })]);
      expect(response.statusCode).toBe(413);
      expect(response.json().error.code).toBe('SETTINGS_VALUE_TOO_LARGE');
    });

    it('measures the size the way the database does, jsonb text with its spaces', async () => {
      const { headers } = await registerUser();
      // About 7.3 KB compact, about 8.9 KB once jsonb prints ", " and ": ".
      const padding: Record<string, number> = {};
      for (let i = 0; i < 800; i += 1) padding[`k${String(i).padStart(4, '0')}`] = 1;
      const value = { light: {}, dark: {}, padding };
      expect(JSON.stringify(value).length).toBeLessThan(8192);
      const response = await put(headers, [set('appearance.colors', value)]);
      expect(response.statusCode).toBe(413);
      expect(response.json().error.code).toBe('SETTINGS_VALUE_TOO_LARGE');
    });

    it('answers 413, not 500, when the database size check is the one that refuses', async () => {
      const { headers, userId } = await registerUser();
      // A real violation of the real constraint, as Drizzle wraps it: the
      // constraint name lives on error.cause, not in the message text.
      let violation: unknown;
      try {
        await superDb.execute(sql`
          INSERT INTO account_settings (user_id, key, value, revision)
          VALUES (${userId}::uuid, 'appearance.colors', to_jsonb(repeat('x', 9000)), 1)`);
      } catch (error) {
        violation = error;
      }
      expect(constraintOf(violation)).toBe('account_settings_value_size_check');
      expect(String(violation)).not.toContain('account_settings_value_size_check');
      const spy = vi.spyOn(AccountSettingsService.prototype as unknown as { writeBatch: () => Promise<never> }, 'writeBatch')
        .mockRejectedValueOnce(violation);
      try {
        const response = await put(headers, [set('language', 'ro')]);
        expect(response.statusCode).toBe(413);
        expect(response.json().error.code).toBe('SETTINGS_VALUE_TOO_LARGE');
      } finally {
        spy.mockRestore();
      }
    });

    it('rethrows a check violation of another constraint instead of answering 413', async () => {
      const { headers } = await registerUser();
      const other = Object.assign(new Error('violates check constraint'), { code: '23514', constraint_name: 'some_other_check' });
      const spy = vi.spyOn(AccountSettingsService.prototype as unknown as { writeBatch: () => Promise<never> }, 'writeBatch')
        .mockRejectedValueOnce(other);
      try {
        const response = await put(headers, [set('language', 'ro')]);
        expect(response.statusCode).toBe(500);
        expect(response.json().error?.code ?? response.json().code).not.toBe('SETTINGS_VALUE_TOO_LARGE');
      } finally {
        spy.mockRestore();
      }
    });

    it('refuses a key beyond the 2000-key cap but still lets an existing one change', async () => {
      const { headers, userId } = await registerUser();
      await superDb.execute(sql`
        INSERT INTO account_settings (user_id, key, value, revision)
        SELECT ${userId}::uuid, 'reminders.person.' || gen_random_uuid()::text, '{"enabled":true}'::jsonb, g
        FROM generate_series(1, 2000) AS g`);
      await superDb.execute(sql`INSERT INTO account_settings_heads (user_id, revision) VALUES (${userId}, 2000)`);
      const refused = await put(headers, [set('language', 'ro')]);
      expect(refused.statusCode).toBe(400);
      expect(refused.json().error.code).toBe('SETTINGS_TOO_MANY_KEYS');
      const [row] = await superDb.execute<{ key: string; revision: number }>(sql`SELECT key, revision FROM account_settings WHERE user_id = ${userId} AND revision = 7`);
      const changed = await put(headers, [set(row!.key, { enabled: false }, Number(row!.revision))]);
      expect(changed.statusCode).toBe(200);
    });
  });

  describe('tenant isolation', () => {
    it('never shows or touches another account settings', async () => {
      const a = await registerUser();
      const b = await registerUser();
      await put(a.headers, [set('language', 'ro')]);
      expect((await get(b.headers)).json<PageResponse>()).toEqual({ revision: 0, items: [], hasMore: false });
      const own = (await put(b.headers, [set('language', 'en')])).json<PutResponse>();
      expect(own.results[0]).toEqual({ key: 'language', status: 'applied', revision: 1 });
      expect((await get(a.headers)).json<PageResponse>().items[0]!.value).toBe('ro');
    });

    it('is enforced by the database: the API role sees nothing without a tenant and cannot write another one', async () => {
      const a = await registerUser();
      const b = await registerUser();
      await put(a.headers, [set('language', 'ro')]);
      const visible = await appDb.execute<{ n: number }>(sql`SELECT count(*)::int AS n FROM account_settings`);
      expect(visible[0]!.n).toBe(0);
      await expect(appDb.transaction(async (tx) => {
        await tx.execute(sql`SELECT set_config('app.current_user_id', ${b.userId}, true)`);
        await tx.execute(sql`INSERT INTO account_settings (user_id, key, value, revision) VALUES (${a.userId}, 'language', '"en"'::jsonb, 9)`);
      })).rejects.toThrow();
      await expect(appDb.transaction(async (tx) => {
        await tx.execute(sql`SELECT set_config('app.current_user_id', ${a.userId}, true)`);
        await tx.execute(sql`DELETE FROM account_settings`);
      })).rejects.toThrow();
    });

    it('requires a signed-in user', async () => {
      const { headers } = await registerUser();
      const anonymous = { 'X-Api-Key': headers['X-Api-Key']! };
      expect((await get(anonymous)).statusCode).toBe(401);
      expect((await put(anonymous, [set('language', 'ro')])).statusCode).toBe(401);
    });
  });

  it('removes a routine and a person setting when the record is deleted', async () => {
    const { headers } = await registerUser();
    const profile = (await app.inject({ method: 'POST', url: '/api/v1/profiles', headers, payload: { mutationId: randomUUID(), name: 'Someone' } })).json<{ id: string; revision: string }>();
    const pill = (await app.inject({ method: 'POST', url: `/api/v1/profiles/${profile.id}/pills`, headers, payload: { mutationId: randomUUID(), name: 'Pill' } })).json<{ id: string }>();
    const schedule = (await app.inject({
      method: 'POST', url: `/api/v1/pills/${pill.id}/schedules`, headers,
      payload: { mutationId: randomUUID(), hour: 8, minute: 0, frequency: 'daily', timeZone: 'Europe/Bucharest' },
    })).json<{ id: string; revision: string }>();
    await put(headers, [
      set(`reminders.routine.${schedule.id}`, { enabled: true, followUpMinutes: [10] }),
      set(`reminders.person.${profile.id}`, { enabled: true }),
      set('language', 'ro'),
    ]);

    const removed = await app.inject({
      method: 'DELETE', url: `/api/v1/pills/${pill.id}/schedules/${schedule.id}`, headers,
      payload: { mutationId: randomUUID(), baseRevision: schedule.revision },
    });
    expect(removed.statusCode).toBe(204);
    let page = (await get(headers, 3)).json<PageResponse>();
    expect(page.items).toMatchObject([{ key: `reminders.routine.${schedule.id}`, value: null, revision: 4 }]);

    const gone = await app.inject({
      method: 'DELETE', url: `/api/v1/profiles/${profile.id}`, headers,
      payload: { mutationId: randomUUID(), baseRevision: profile.revision },
    });
    expect(gone.statusCode).toBe(204);
    page = (await get(headers, 4)).json<PageResponse>();
    expect(page.items).toMatchObject([{ key: `reminders.person.${profile.id}`, value: null, revision: 5 }]);
    expect(page.revision).toBe(5);
    // Everything else stays.
    expect((await get(headers)).json<PageResponse>().items.map((item) => item.key)).toEqual(['language']);
  });

  it('removes the reminder choices of a medication\'s routines when the medication is deleted', async () => {
    const { headers } = await registerUser();
    const profile = (await app.inject({ method: 'POST', url: '/api/v1/profiles', headers, payload: { mutationId: randomUUID(), name: 'Someone' } })).json<{ id: string }>();
    const pill = (await app.inject({ method: 'POST', url: `/api/v1/profiles/${profile.id}/pills`, headers, payload: { mutationId: randomUUID(), name: 'Pill' } })).json<{ id: string; revision: string }>();
    const ids: string[] = [];
    for (const hour of [8, 20]) {
      const schedule = (await app.inject({
        method: 'POST', url: `/api/v1/pills/${pill.id}/schedules`, headers,
        payload: { mutationId: randomUUID(), hour, minute: 0, frequency: 'daily', timeZone: 'Europe/Bucharest' },
      })).json<{ id: string }>();
      ids.push(schedule.id);
    }
    await put(headers, [
      ...ids.map((id) => set(`reminders.routine.${id}`, { enabled: true, followUpMinutes: [10] })),
      set('language', 'ro'),
    ]);

    const removed = await app.inject({
      method: 'DELETE', url: `/api/v1/profiles/${profile.id}/pills/${pill.id}`, headers,
      payload: { mutationId: randomUUID(), baseRevision: pill.revision },
    });
    expect(removed.statusCode).toBe(204);
    const page = (await get(headers, 3)).json<PageResponse>();
    expect(page.items.map((item) => [item.key, item.value]).sort()).toEqual(
      ids.map((id) => [`reminders.routine.${id}`, null]).sort(),
    );
    expect((await get(headers)).json<PageResponse>().items.map((item) => item.key)).toEqual(['language']);
  });

  it('removes the routine settings of a person\'s medications when the person is deleted', async () => {
    const { headers } = await registerUser();
    const profile = (await app.inject({ method: 'POST', url: '/api/v1/profiles', headers, payload: { mutationId: randomUUID(), name: 'Someone' } })).json<{ id: string; revision: string }>();
    const pill = (await app.inject({ method: 'POST', url: `/api/v1/profiles/${profile.id}/pills`, headers, payload: { mutationId: randomUUID(), name: 'Pill' } })).json<{ id: string }>();
    const schedule = (await app.inject({
      method: 'POST', url: `/api/v1/pills/${pill.id}/schedules`, headers,
      payload: { mutationId: randomUUID(), hour: 8, minute: 0, frequency: 'daily', timeZone: 'Europe/Bucharest' },
    })).json<{ id: string }>();
    await put(headers, [
      set(`reminders.routine.${schedule.id}`, { enabled: true, followUpMinutes: [10] }),
      set(`reminders.person.${profile.id}`, { enabled: true }),
      set('language', 'ro'),
    ]);
    const gone = await app.inject({
      method: 'DELETE', url: `/api/v1/profiles/${profile.id}`, headers,
      payload: { mutationId: randomUUID(), baseRevision: profile.revision },
    });
    expect(gone.statusCode).toBe(204);
    const page = (await get(headers, 3)).json<PageResponse>();
    expect(page.items.map((item) => [item.key, item.value]).sort()).toEqual([
      [`reminders.person.${profile.id}`, null],
      [`reminders.routine.${schedule.id}`, null],
    ].sort());
    expect((await get(headers)).json<PageResponse>().items.map((item) => item.key)).toEqual(['language']);
  });

  it('leaves a second person\'s keys alone when a person is deleted, and clears the soft-deleted ones', async () => {
    const { headers } = await registerUser();
    const makeProfile = async (name: string) => (await app.inject({
      method: 'POST', url: '/api/v1/profiles', headers, payload: { mutationId: randomUUID(), name },
    })).json<{ id: string; revision: string }>();
    const makePill = async (profileId: string) => (await app.inject({
      method: 'POST', url: `/api/v1/profiles/${profileId}/pills`, headers, payload: { mutationId: randomUUID(), name: 'Pill' },
    })).json<{ id: string }>();
    const makeSchedule = async (pillId: string, hour: number) => (await app.inject({
      method: 'POST', url: `/api/v1/pills/${pillId}/schedules`, headers,
      payload: { mutationId: randomUUID(), hour, minute: 0, frequency: 'daily', timeZone: 'Europe/Bucharest' },
    })).json<{ id: string }>();

    const gonePerson = await makeProfile('Leaving');
    const keptPerson = await makeProfile('Staying');
    const livePill = await makePill(gonePerson.id);
    const softPill = await makePill(gonePerson.id);
    const keptPill = await makePill(keptPerson.id);
    const liveRoutine = await makeSchedule(livePill.id, 8);
    const softRoutine = await makeSchedule(livePill.id, 9);
    const onSoftPill = await makeSchedule(softPill.id, 10);
    const keptRoutine = await makeSchedule(keptPill.id, 11);
    const keptSoftRoutine = await makeSchedule(keptPill.id, 12);
    // Soft-deleted rows, set directly so no other path tombstones their keys first.
    await superDb.execute(sql`UPDATE schedules SET deleted_at = now() WHERE id IN (${softRoutine.id}::uuid, ${keptSoftRoutine.id}::uuid)`);
    await superDb.execute(sql`UPDATE pills SET deleted_at = now() WHERE id = ${softPill.id}::uuid`);

    const routineKey = (id: string) => `reminders.routine.${id}`;
    const value = { enabled: true, followUpMinutes: [10] };
    await put(headers, [
      set(routineKey(liveRoutine.id), value), set(routineKey(softRoutine.id), value), set(routineKey(onSoftPill.id), value),
      set(routineKey(keptRoutine.id), value), set(routineKey(keptSoftRoutine.id), value),
      set(`reminders.person.${gonePerson.id}`, { enabled: true }), set(`reminders.person.${keptPerson.id}`, { enabled: true }),
    ]);

    const gone = await app.inject({
      method: 'DELETE', url: `/api/v1/profiles/${gonePerson.id}`, headers,
      payload: { mutationId: randomUUID(), baseRevision: gonePerson.revision },
    });
    expect(gone.statusCode).toBe(204);

    const live = (await get(headers)).json<PageResponse>().items.map((item) => item.key).sort();
    expect(live).toEqual([
      routineKey(keptRoutine.id), routineKey(keptSoftRoutine.id), `reminders.person.${keptPerson.id}`,
    ].sort());
    const tombstones = (await get(headers, 7)).json<PageResponse>().items;
    expect(tombstones.map((item) => item.key).sort()).toEqual([
      routineKey(liveRoutine.id), routineKey(softRoutine.id), routineKey(onSoftPill.id), `reminders.person.${gonePerson.id}`,
    ].sort());
    expect(tombstones.every((item) => item.value === null)).toBe(true);
  });

  it('limits writes per client address with the standard rate-limit error', async () => {
    const { headers } = await registerUser();
    for (let i = 0; i < 3; i += 1) {
      expect((await put(headers, [set('language', 'ro', i === 0 ? 0 : i)], limitedApp)).statusCode).toBe(200);
    }
    const limited = await put(headers, [set('language', 'en', 3)], limitedApp);
    expect(limited.statusCode).toBe(429);
    expect(limited.json().code).toBe('RATE_LIMIT_EXCEEDED');
  });
});
