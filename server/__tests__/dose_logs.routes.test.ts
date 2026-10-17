
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import postgres from 'postgres';
import { buildTestApp, setTenantContext, signTestToken } from './helpers/app.js';
import doseLogsRoutes from '../src/modules/dose_logs/dose_logs.routes.js';

const SUPER_URL = process.env['DATABASE_URL_SUPER'];
if (!SUPER_URL) throw new Error('DATABASE_URL_SUPER must be set');

let superSql: postgres.Sql;
let app: Awaited<ReturnType<typeof buildTestApp>>['app'];
let pgClient: Awaited<ReturnType<typeof buildTestApp>>['pgClient'];

const USER_A = '40000000-0000-0000-0000-000000000aa1';
const USER_B = '40000000-0000-0000-0000-000000000bb2';
const PROFILE_A = '40000000-0000-0001-0000-000000000aa1';
const PROFILE_B = '40000000-0000-0001-0000-000000000bb2';
const PILL_A = '40000000-0000-0002-0000-000000000aa1';
const PILL_B = '40000000-0000-0002-0000-000000000bb2';
const SCHEDULE_A = '40000000-0000-0003-0000-000000000aa1';
const SCHEDULE_B = '40000000-0000-0003-0000-000000000bb2'; // owned by USER_B

beforeAll(async () => {
  superSql = postgres(SUPER_URL, { max: 1 });

  await superSql`
    INSERT INTO users (id, email, password_hash) VALUES
      (${USER_A}, 'log-test-a@example.com', 'hash-a'),
      (${USER_B}, 'log-test-b@example.com', 'hash-b')
    ON CONFLICT (id) DO NOTHING
  `;
  await setTenantContext(superSql, USER_A);
  await superSql`
    INSERT INTO profiles (id, user_id, name)
    VALUES (${PROFILE_A}, ${USER_A}, 'Profile A')
    ON CONFLICT (id) DO NOTHING
  `;
  await setTenantContext(superSql, USER_B);
  await superSql`
    INSERT INTO profiles (id, user_id, name)
    VALUES (${PROFILE_B}, ${USER_B}, 'Profile B')
    ON CONFLICT (id) DO NOTHING
  `;
  await setTenantContext(superSql, USER_A);
  await superSql`
    INSERT INTO pills (id, profile_id, name)
    VALUES (${PILL_A}, ${PROFILE_A}, 'Pill A')
    ON CONFLICT (id) DO NOTHING
  `;
  await setTenantContext(superSql, USER_B);
  await superSql`
    INSERT INTO pills (id, profile_id, name)
    VALUES (${PILL_B}, ${PROFILE_B}, 'Pill B')
    ON CONFLICT (id) DO NOTHING
  `;
  await setTenantContext(superSql, USER_A);
  await superSql`
    INSERT INTO schedules (id, pill_id, hour, minute, frequency, time_zone)
    VALUES (${SCHEDULE_A}, ${PILL_A}, 8, 0, 'daily', 'UTC')
    ON CONFLICT (id) DO NOTHING
  `;
  await setTenantContext(superSql, USER_B);
  await superSql`
    INSERT INTO schedules (id, pill_id, hour, minute, frequency, time_zone)
    VALUES (${SCHEDULE_B}, ${PILL_B}, 9, 0, 'daily', 'UTC')
    ON CONFLICT (id) DO NOTHING
  `;

  ({ app, pgClient } = await buildTestApp(doseLogsRoutes));
});

afterAll(async () => {
  // The suite's database is disposable; deleting users cascades through
  // revisioned rows whose audit triggers intentionally publish changes.
  await superSql.end();
  await pgClient.end();
  await app.close();
});

async function seedDoseLog(
  scheduledAt: string,
  status: 'taken' | 'missed' | 'skipped' = 'taken',
): Promise<string> {
  await setTenantContext(superSql, USER_A);
  const [row] = await superSql`
    INSERT INTO dose_logs (schedule_id, scheduled_at, status)
    VALUES (${SCHEDULE_A}, ${scheduledAt}, ${status})
    RETURNING id
  `;
  return row!.id as string;
}

// ---------------------------------------------------------------------------
// POST /logs/:scheduleId
// ---------------------------------------------------------------------------
describe('POST /logs/:scheduleId', () => {
  it('rejects a split dose write with the bridge-required contract', async () => {
    const token = signTestToken(app, USER_A);
    const scheduledAt = new Date('2026-03-21T08:00:00Z').toISOString();
    const res = await app.inject({
      method: 'POST',
      url: `/logs/${SCHEDULE_A}`,
      headers: { authorization: `Bearer ${token}` },
      body: { scheduledAt, status: 'taken' },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
  });

  it('rejects split dose writes with notes using the same bridge-required contract', async () => {
    const token = signTestToken(app, USER_A);
    const scheduledAt = new Date('2026-03-21T07:30:00Z').toISOString();
    const res = await app.inject({
      method: 'POST',
      url: `/logs/${SCHEDULE_A}`,
      headers: { authorization: `Bearer ${token}` },
      body: { scheduledAt, status: 'taken', note: 'Took with food' },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
  });

  it('does not expose ownership through the retired split-write route', async () => {
    const tokenB = signTestToken(app, USER_B);
    const scheduledAt = new Date('2026-03-21T09:00:00Z').toISOString();
    const res = await app.inject({
      method: 'POST',
      url: `/logs/${SCHEDULE_A}`,
      headers: { authorization: `Bearer ${tokenB}` },
      body: { scheduledAt, status: 'taken' },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
  });

  it('returns 400 for invalid status value', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'POST',
      url: `/logs/${SCHEDULE_A}`,
      headers: { authorization: `Bearer ${token}` },
      body: {
        scheduledAt: new Date('2026-03-21T10:00:00Z').toISOString(),
        status: 'invalid',
      },
    });
    expect(res.statusCode).toBe(400);
  });

  it('returns 401 without a token', async () => {
    const res = await app.inject({
      method: 'POST',
      url: `/logs/${SCHEDULE_A}`,
      body: { scheduledAt: new Date('2026-03-21T11:00:00Z').toISOString(), status: 'taken' },
    });
    expect(res.statusCode).toBe(401);
  });

  it('rejects repeated split writes without creating a legacy log', async () => {
    const token = signTestToken(app, USER_A);
    const scheduledAt = new Date('2026-06-11T08:00:00Z').toISOString();
    await setTenantContext(superSql, USER_A);
    const before = await superSql`SELECT count(*)::int AS count FROM dose_logs`;
    const first = await app.inject({
      method: 'POST',
      url: `/logs/${SCHEDULE_A}`,
      headers: { authorization: `Bearer ${token}` },
      body: { scheduledAt, status: 'missed' },
    });
    expect(first.statusCode).toBe(409);
    expect(first.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');

    const second = await app.inject({
      method: 'POST',
      url: `/logs/${SCHEDULE_A}`,
      headers: { authorization: `Bearer ${token}` },
      body: { scheduledAt, status: 'taken' },
    });
    expect(second.statusCode).toBe(409);
    expect(second.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
    const after = await superSql`SELECT count(*)::int AS count FROM dose_logs`;
    expect(after[0]!.count).toBe(before[0]!.count);
  });
});

// ---------------------------------------------------------------------------
// GET /profiles/:profileId/logs — date range queries
// ---------------------------------------------------------------------------
describe('GET /profiles/:profileId/logs — date range', () => {
  // Seed three logs on different days
  const DAY_1 = '2026-01-10';
  const DAY_2 = '2026-01-11';
  const DAY_3 = '2026-01-12';
  let logId1: string;
  let logId2: string;
  let logId3: string;

  beforeAll(async () => {
    logId1 = await seedDoseLog('2026-01-10T08:00:00Z', 'taken');
    logId2 = await seedDoseLog('2026-01-11T08:00:00Z', 'missed');
    logId3 = await seedDoseLog('2026-01-12T08:00:00Z', 'skipped');
  });

  it('?date=X returns only logs for that day', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'GET',
      url: `/profiles/${PROFILE_A}/logs?date=${DAY_2}`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.statusCode).toBe(200);
    const ids = res.json().logs.map((l: { id: string }) => l.id);
    expect(ids).toContain(logId2);
    expect(ids).not.toContain(logId1);
    expect(ids).not.toContain(logId3);
  });

  it('?from=X&to=Y returns inclusive range', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'GET',
      url: `/profiles/${PROFILE_A}/logs?from=${DAY_1}&to=${DAY_2}`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.statusCode).toBe(200);
    const ids = res.json().logs.map((l: { id: string }) => l.id);
    expect(ids).toContain(logId1);
    expect(ids).toContain(logId2);
    expect(ids).not.toContain(logId3);
  });

  it('omitting date params returns all logs for the profile', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'GET',
      url: `/profiles/${PROFILE_A}/logs`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.statusCode).toBe(200);
    const ids = res.json().logs.map((l: { id: string }) => l.id);
    expect(ids).toContain(logId1);
    expect(ids).toContain(logId2);
    expect(ids).toContain(logId3);
  });

  it('returns 404 when User B accesses User A\'s logs (ownership)', async () => {
    const tokenB = signTestToken(app, USER_B);
    const res = await app.inject({
      method: 'GET',
      url: `/profiles/${PROFILE_A}/logs`,
      headers: { authorization: `Bearer ${tokenB}` },
    });
    expect(res.statusCode).toBe(404);
  });

  it('returns 401 without a token', async () => {
    const res = await app.inject({
      method: 'GET',
      url: `/profiles/${PROFILE_A}/logs`,
    });
    expect(res.statusCode).toBe(401);
  });

  it('returns 400 for invalid date query (?date combined with ?from)', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'GET',
      url: `/profiles/${PROFILE_A}/logs?date=2026-01-10&from=2026-01-10`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.statusCode).toBe(400);
  });
});

// ---------------------------------------------------------------------------
// PATCH /logs/:id
// ---------------------------------------------------------------------------
describe('PATCH /logs/:id', () => {
  it('rejects a valid split update with the bridge-required contract', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'PATCH',
      url: '/logs/00000000-0000-4000-8000-000000000001',
      headers: { authorization: `Bearer ${token}` },
      body: { status: 'skipped' },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
  });

  it('does not expose ownership through the retired split-update route', async () => {
    const tokenB = signTestToken(app, USER_B);
    const res = await app.inject({
      method: 'PATCH',
      url: '/logs/00000000-0000-4000-8000-000000000002',
      headers: { authorization: `Bearer ${tokenB}` },
      body: { status: 'skipped' },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
  });

  it('returns the bridge-required contract for a valid update of an absent id', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'PATCH',
      url: `/logs/00000000-0000-0000-0000-000000000000`,
      headers: { authorization: `Bearer ${token}` },
      body: { status: 'skipped' },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
  });

  it('returns 400 for invalid status value', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'PATCH',
      url: '/logs/00000000-0000-4000-8000-000000000003',
      headers: { authorization: `Bearer ${token}` },
      body: { status: 'invalid' },
    });
    expect(res.statusCode).toBe(400);
  });

  it('rejects a valid takenAt update through the split-write route', async () => {
    const takenAt = '2026-08-01T08:05:00.000Z';
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'PATCH',
      url: '/logs/00000000-0000-4000-8000-000000000004',
      headers: { authorization: `Bearer ${token}` },
      body: { takenAt },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
  });

  it('rejects a valid takenAt clear through the split-write route', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'PATCH',
      url: '/logs/00000000-0000-4000-8000-000000000005',
      headers: { authorization: `Bearer ${token}` },
      body: { takenAt: null },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
  });

  it('rejects a valid note update through the split-write route', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'PATCH',
      url: '/logs/00000000-0000-4000-8000-000000000006',
      headers: { authorization: `Bearer ${token}` },
      body: { note: 'Felt dizzy' },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
  });

  it('rejects a valid note clear through the split-write route', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'PATCH',
      url: '/logs/00000000-0000-4000-8000-000000000007',
      headers: { authorization: `Bearer ${token}` },
      body: { note: null },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
  });

  it('returns 401 without a token', async () => {
    const res = await app.inject({
      method: 'PATCH',
      url: `/logs/00000000-0000-0000-0000-000000000000`,
      body: { status: 'skipped' },
    });
    expect(res.statusCode).toBe(401);
  });
});
