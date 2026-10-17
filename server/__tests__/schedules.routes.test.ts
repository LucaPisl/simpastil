import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import postgres from 'postgres';
import { randomUUID } from 'node:crypto';
import { buildTestApp, setTenantContext, signTestToken } from './helpers/app.js';
import schedulesRoutes from '../src/modules/schedules/schedules.routes.js';

const SUPER_URL = process.env['DATABASE_URL_SUPER'];
if (!SUPER_URL) throw new Error('DATABASE_URL_SUPER must be set');

let superSql: postgres.Sql;
let app: Awaited<ReturnType<typeof buildTestApp>>['app'];
let pgClient: Awaited<ReturnType<typeof buildTestApp>>['pgClient'];

const USER_A = '30000000-0000-4000-8000-0000000000a1';
const USER_B = '30000000-0000-4000-8000-0000000000b2';
const PROFILE_A = '30000000-0000-0001-0000-000000000aa1';
const PROFILE_B = '30000000-0000-0001-0000-000000000bb2';
const PILL_A = '30000000-0000-0002-0000-000000000aa1';
const PILL_B = '30000000-0000-0002-0000-000000000bb2';

beforeAll(async () => {
  superSql = postgres(SUPER_URL, { max: 1 });

  await superSql`
    INSERT INTO users (id, email, password_hash) VALUES
      (${USER_A}, 'sched-test-a@example.com', 'hash-a'),
      (${USER_B}, 'sched-test-b@example.com', 'hash-b')
    ON CONFLICT (id) DO NOTHING
  `;
  await superSql`
    INSERT INTO profiles (id, user_id, name) VALUES
      (${PROFILE_A}, ${USER_A}, 'Profile A'),
      (${PROFILE_B}, ${USER_B}, 'Profile B')
    ON CONFLICT (id) DO NOTHING
  `;
  await setTenantContext(superSql, USER_A);
  await superSql`INSERT INTO pills (id, profile_id, name) VALUES (${PILL_A}, ${PROFILE_A}, 'Pill A') ON CONFLICT (id) DO NOTHING`;
  await setTenantContext(superSql, USER_B);
  await superSql`INSERT INTO pills (id, profile_id, name) VALUES (${PILL_B}, ${PROFILE_B}, 'Pill B') ON CONFLICT (id) DO NOTHING`;
  await setTenantContext(superSql, USER_A);

  ({ app, pgClient } = await buildTestApp(schedulesRoutes));
});

afterAll(async () => {
  // The suite runs against disposable PostgreSQL; cascading revisioned rows
  // emits immutable sync publications, so fixture users are discarded with it.
  await superSql.end();
  await pgClient.end();
  await app.close();
});

describe('POST /pills/:pillId/schedules', () => {
  it('creates a daily schedule and returns 201', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'POST',
      url: `/pills/${PILL_A}/schedules`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), hour: 8, minute: 30, frequency: 'daily', timeZone: 'UTC' },
    });
    expect(res.statusCode).toBe(201);
    const body = res.json();
    expect(body.hour).toBe(8);
    expect(body.minute).toBe(30);
    expect(body.frequency).toBe('daily');
    expect(body.pillId).toBe(PILL_A);
  });

  it('creates a weekly schedule with one frequencyDay', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'POST',
      url: `/pills/${PILL_A}/schedules`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), hour: 9, minute: 0, frequency: 'weekly', frequencyDays: [1], timeZone: 'UTC' },
    });
    expect(res.statusCode).toBe(201);
    expect(res.json().frequencyDays).toEqual([1]);
  });

  it('returns 400 for weekly schedule with multiple days', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'POST',
      url: `/pills/${PILL_A}/schedules`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), hour: 9, minute: 0, frequency: 'weekly', frequencyDays: [1, 3], timeZone: 'UTC' },
    });
    expect(res.statusCode).toBe(400);
  });

  it('returns 400 for custom schedule with no frequencyDays', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'POST',
      url: `/pills/${PILL_A}/schedules`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), hour: 9, minute: 0, frequency: 'custom', timeZone: 'UTC' },
    });
    expect(res.statusCode).toBe(400);
  });

  it('returns 400 for hour out of range', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'POST',
      url: `/pills/${PILL_A}/schedules`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), hour: 25, minute: 0, frequency: 'daily', timeZone: 'UTC' },
    });
    expect(res.statusCode).toBe(400);
  });

  it('returns 404 when User B tries to create a schedule for User A\'s pill (ownership)', async () => {
    const tokenB = signTestToken(app, USER_B);
    const res = await app.inject({
      method: 'POST',
      url: `/pills/${PILL_A}/schedules`,
      headers: { authorization: `Bearer ${tokenB}` },
      body: { mutationId: randomUUID(), hour: 8, minute: 0, frequency: 'daily', timeZone: 'UTC' },
    });
    expect(res.statusCode).toBe(404);
  });

  it('returns 401 without a token', async () => {
    const res = await app.inject({
      method: 'POST',
      url: `/pills/${PILL_A}/schedules`,
      body: { mutationId: randomUUID(), hour: 8, minute: 0, frequency: 'daily', timeZone: 'UTC' },
    });
    expect(res.statusCode).toBe(401);
  });
});

describe('GET /pills/:pillId/schedules', () => {
  it('returns schedules for the pill', async () => {
    await setTenantContext(superSql, USER_A);
    const [sched] = await superSql`
      INSERT INTO schedules (pill_id, hour, minute, frequency, time_zone)
      VALUES (${PILL_A}, 10, 0, 'daily', 'UTC') RETURNING id
    `;
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'GET',
      url: `/pills/${PILL_A}/schedules`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().schedules.map((s: { id: string }) => s.id)).toContain(sched!.id);
  });

  it('returns 404 when User B accesses User A\'s pill schedules (ownership)', async () => {
    const tokenB = signTestToken(app, USER_B);
    const res = await app.inject({
      method: 'GET',
      url: `/pills/${PILL_A}/schedules`,
      headers: { authorization: `Bearer ${tokenB}` },
    });
    expect(res.statusCode).toBe(404);
  });
});

describe('PATCH /pills/:pillId/schedules/:id', () => {
  it('returns 404 for cross-user update (ownership)', async () => {
    await setTenantContext(superSql, USER_A);
    const [sched] = await superSql`
      INSERT INTO schedules (pill_id, hour, minute, frequency, time_zone)
      VALUES (${PILL_A}, 11, 0, 'daily', 'UTC') RETURNING id
    `;
    const tokenB = signTestToken(app, USER_B);
    const res = await app.inject({
      method: 'PATCH',
      url: `/pills/${PILL_A}/schedules/${sched!.id}`,
      headers: { authorization: `Bearer ${tokenB}` },
      body: { mutationId: randomUUID(), baseRevision: '1', isActive: false },
    });
    expect(res.statusCode).toBe(404);
  });

  it('updates own schedule', async () => {
    await setTenantContext(superSql, USER_A);
    const [sched] = await superSql`
      INSERT INTO schedules (pill_id, hour, minute, frequency, time_zone)
      VALUES (${PILL_A}, 14, 0, 'daily', 'UTC') RETURNING id
    `;
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'PATCH',
      url: `/pills/${PILL_A}/schedules/${sched!.id}`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), baseRevision: '1', isActive: false },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().isActive).toBe(false);
  });

  it('returns 404 for non-existent schedule id', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'PATCH',
      url: `/pills/${PILL_A}/schedules/00000000-0000-0000-0000-000000000000`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), baseRevision: '1', isActive: false },
    });
    expect(res.statusCode).toBe(404);
  });
});

describe('DELETE /pills/:pillId/schedules/:id', () => {
  it('returns 404 for cross-user delete (ownership)', async () => {
    await setTenantContext(superSql, USER_A);
    const [sched] = await superSql`
      INSERT INTO schedules (pill_id, hour, minute, frequency, time_zone)
      VALUES (${PILL_A}, 12, 0, 'daily', 'UTC') RETURNING id
    `;
    const tokenB = signTestToken(app, USER_B);
    const res = await app.inject({
      method: 'DELETE',
      url: `/pills/${PILL_A}/schedules/${sched!.id}`,
      headers: { authorization: `Bearer ${tokenB}` },
      body: { mutationId: randomUUID(), baseRevision: '1' },
    });
    expect(res.statusCode).toBe(404);
  });

  it('deletes own schedule and returns 204', async () => {
    await setTenantContext(superSql, USER_A);
    const [sched] = await superSql`
      INSERT INTO schedules (pill_id, hour, minute, frequency, time_zone)
      VALUES (${PILL_A}, 13, 0, 'daily', 'UTC') RETURNING id
    `;
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'DELETE',
      url: `/pills/${PILL_A}/schedules/${sched!.id}`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), baseRevision: '1' },
    });
    expect(res.statusCode).toBe(204);
  });

  it('returns 404 for non-existent schedule id', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'DELETE',
      url: `/pills/${PILL_A}/schedules/00000000-0000-0000-0000-000000000000`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), baseRevision: '1' },
    });
    expect(res.statusCode).toBe(404);
  });
});
