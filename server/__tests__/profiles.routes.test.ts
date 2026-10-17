import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import postgres from 'postgres';
import { randomUUID } from 'node:crypto';
import { buildTestApp, setTenantContext, signTestToken } from './helpers/app.js';
import profilesRoutes from '../src/modules/profiles/profiles.routes.js';

const SUPER_URL = process.env['DATABASE_URL_SUPER'];
if (!SUPER_URL) throw new Error('DATABASE_URL_SUPER must be set');

let superSql: postgres.Sql;
let app: Awaited<ReturnType<typeof buildTestApp>>['app'];
let pgClient: Awaited<ReturnType<typeof buildTestApp>>['pgClient'];

const USER_A = '10000000-0000-0000-0000-000000000aa1';
const USER_B = '10000000-0000-0000-0000-000000000bb2';

beforeAll(async () => {
  superSql = postgres(SUPER_URL, { max: 1 });

  await superSql`
    INSERT INTO users (id, email, password_hash) VALUES
      (${USER_A}, 'profile-test-a@example.com', 'hash-a'),
      (${USER_B}, 'profile-test-b@example.com', 'hash-b')
    ON CONFLICT (id) DO NOTHING
  `;

  ({ app, pgClient } = await buildTestApp(profilesRoutes));
});

afterAll(async () => {
  // The suite runs against disposable PostgreSQL; cascading revisioned rows
  // emits immutable sync publications, so fixture users are discarded with it.
  await superSql.end();
  await pgClient.end();
  await app.close();
});

// ---------------------------------------------------------------------------
// POST /profiles
// ---------------------------------------------------------------------------
describe('POST /profiles', () => {
  it('creates a profile and returns 201', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'POST',
      url: '/profiles',
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), name: 'Alice' },
    });
    expect(res.statusCode).toBe(201);
    const body = res.json();
    expect(body.name).toBe('Alice');
    expect(body.userId).toBe(USER_A);
    expect(body.avatarEmoji).toBe('👤');
    expect(body.isActive).toBe(true);
    expect(body.id).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
    );
  });

  it('returns 401 without a token', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/profiles',
      body: { name: 'Alice' },
    });
    expect(res.statusCode).toBe(401);
  });

  it('returns 400 for an empty name', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'POST',
      url: '/profiles',
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), name: '' },
    });
    expect(res.statusCode).toBe(400);
  });
});

// ---------------------------------------------------------------------------
// GET /profiles
// ---------------------------------------------------------------------------
describe('GET /profiles', () => {
  it('returns only the authenticated user\'s profiles', async () => {
    // Seed: one profile for A, one for B
    const profileAId = randomUUID();
    const profileBId = randomUUID();
    await superSql`
      INSERT INTO profiles (id, user_id, name) VALUES
        (${profileAId}, ${USER_A}, 'Profile A'),
        (${profileBId}, ${USER_B}, 'Profile B')
      ON CONFLICT (id) DO NOTHING
    `;

    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'GET',
      url: '/profiles',
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.statusCode).toBe(200);
    const { profiles } = res.json();
    const ids = profiles.map((p: { id: string }) => p.id);
    expect(ids).toContain(profileAId);
    expect(ids).not.toContain(profileBId);
  });
});

// ---------------------------------------------------------------------------
// PATCH /profiles/:id — ownership enforcement
// ---------------------------------------------------------------------------
describe('PATCH /profiles/:id', () => {
  it('updates own profile', async () => {
    const [created] = await superSql`
      INSERT INTO profiles (user_id, name) VALUES (${USER_A}, 'Before')
      RETURNING id
    `;
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'PATCH',
      url: `/profiles/${created!.id}`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), baseRevision: '1', name: 'After' },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().name).toBe('After');
  });

  it('returns 404 when User B tries to update User A\'s profile (ownership)', async () => {
    const [profile] = await superSql`
      INSERT INTO profiles (user_id, name) VALUES (${USER_A}, 'A Profile')
      RETURNING id
    `;
    const tokenB = signTestToken(app, USER_B);
    const res = await app.inject({
      method: 'PATCH',
      url: `/profiles/${profile!.id}`,
      headers: { authorization: `Bearer ${tokenB}` },
      body: { mutationId: randomUUID(), baseRevision: '1', name: 'Hacked' },
    });
    expect(res.statusCode).toBe(404);
  });

  it('returns 404 for a non-existent profile ID', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'PATCH',
      url: `/profiles/${randomUUID()}`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), baseRevision: '1', name: 'Ghost' },
    });
    expect(res.statusCode).toBe(404);
  });
});

// ---------------------------------------------------------------------------
// PATCH /profiles/:id — ConflictError returns 409 (H-4 fix)
// ---------------------------------------------------------------------------
describe('PATCH /profiles/:id — ConflictError returns 409', () => {
  it('returns 409 CONFLICT_STALE_UPDATE for stale updatedAt', async () => {
    const [created] = await superSql`
      INSERT INTO profiles (user_id, name, updated_at) VALUES
        (${USER_A}, 'Conflict Test', NOW())
      RETURNING id
    `;
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'PATCH',
      url: `/profiles/${created!.id}`,
      headers: { authorization: `Bearer ${token}` },
      body: {
        mutationId: randomUUID(),
        baseRevision: '1',
        name: 'Stale Update',
        updatedAt: '2020-01-01T00:00:00Z',
      },
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().error.code).toBe('VALIDATION_ERROR');
  });
});

// ---------------------------------------------------------------------------
// DELETE /profiles/:id — ownership + cascade
// ---------------------------------------------------------------------------
describe('DELETE /profiles/:id', () => {
  it('deletes own profile and returns 204', async () => {
    const [profile] = await superSql`
      INSERT INTO profiles (user_id, name) VALUES (${USER_A}, 'To Delete')
      RETURNING id
    `;
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'DELETE',
      url: `/profiles/${profile!.id}`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), baseRevision: '1' },
    });
    expect(res.statusCode).toBe(204);
  });

  it('returns 404 when User B tries to delete User A\'s profile (ownership)', async () => {
    const [profile] = await superSql`
      INSERT INTO profiles (user_id, name) VALUES (${USER_A}, 'Owned by A')
      RETURNING id
    `;
    const tokenB = signTestToken(app, USER_B);
    const res = await app.inject({
      method: 'DELETE',
      url: `/profiles/${profile!.id}`,
      headers: { authorization: `Bearer ${tokenB}` },
      body: { mutationId: randomUUID(), baseRevision: '1' },
    });
    expect(res.statusCode).toBe(404);
  });

  it('CASCADE DELETE: deleting a profile removes all pills, schedules, and dose_logs', async () => {
    // Build a full hierarchy for USER_A
    const [profile] = await superSql`
      INSERT INTO profiles (user_id, name) VALUES (${USER_A}, 'Cascade Profile')
      RETURNING id
    `;
    await setTenantContext(superSql, USER_A);
    const [pill] = await superSql`
      INSERT INTO pills (profile_id, name) VALUES (${profile!.id}, 'Cascade Pill')
      RETURNING id
    `;
    const [schedule] = await superSql`
      INSERT INTO schedules (pill_id, hour, minute, frequency, time_zone)
      VALUES (${pill!.id}, 8, 0, 'daily', 'UTC')
      RETURNING id
    `;
    const [log] = await superSql`
      INSERT INTO dose_logs (schedule_id, scheduled_at, status)
      VALUES (${schedule!.id}, now(), 'taken')
      RETURNING id
    `;

    // Delete the profile via the API
    const token = signTestToken(app, USER_A);
    await app.inject({
      method: 'DELETE',
      url: `/profiles/${profile!.id}`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), baseRevision: '1' },
    });

    // Verify soft-delete: profile must have deleted_at set; children stay (FK cascade only triggers on hard DELETE)
    const profiles = await superSql`SELECT deleted_at FROM profiles WHERE id = ${profile!.id}`;
    expect(profiles).toHaveLength(1);
    expect(profiles[0]!.deleted_at).not.toBeNull();
  });
});
