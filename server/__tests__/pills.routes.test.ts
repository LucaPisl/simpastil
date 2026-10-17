import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import postgres from 'postgres';
import { randomUUID } from 'node:crypto';
import { buildTestApp, setTenantContext, signTestToken } from './helpers/app.js';
import pillsRoutes from '../src/modules/pills/pills.routes.js';

const SUPER_URL = process.env['DATABASE_URL_SUPER'];
if (!SUPER_URL) throw new Error('DATABASE_URL_SUPER must be set');

let superSql: postgres.Sql;
let app: Awaited<ReturnType<typeof buildTestApp>>['app'];
let pgClient: Awaited<ReturnType<typeof buildTestApp>>['pgClient'];

const USER_A = '20000000-0000-0000-0000-000000000aa1';
const USER_B = '20000000-0000-0000-0000-000000000bb2';
const PROFILE_A = '20000000-0000-0001-0000-000000000aa1';
const PROFILE_B = '20000000-0000-0001-0000-000000000bb2';

beforeAll(async () => {
  superSql = postgres(SUPER_URL, { max: 1 });

  await superSql`
    INSERT INTO users (id, email, password_hash) VALUES
      (${USER_A}, 'pill-test-a@example.com', 'hash-a'),
      (${USER_B}, 'pill-test-b@example.com', 'hash-b')
    ON CONFLICT (id) DO NOTHING
  `;
  await setTenantContext(superSql, USER_A);
  await superSql`
    INSERT INTO profiles (id, user_id, name) VALUES
      (${PROFILE_A}, ${USER_A}, 'Profile A'),
      (${PROFILE_B}, ${USER_B}, 'Profile B')
    ON CONFLICT (id) DO NOTHING
  `;

  ({ app, pgClient } = await buildTestApp(pillsRoutes));
});

afterAll(async () => {
  // The suite runs against disposable PostgreSQL; cascading revisioned rows
  // emits immutable sync publications, so fixture users are discarded with it.
  await superSql.end();
  await pgClient.end();
  await app.close();
});

describe('POST /profiles/:profileId/pills', () => {
  it('creates a pill and returns 201', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'POST',
      url: `/profiles/${PROFILE_A}/pills`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), name: 'Aspirin', dosage: '100mg', color: '#FF0000' },
    });
    expect(res.statusCode).toBe(201);
    const body = res.json();
    expect(body.name).toBe('Aspirin');
    expect(body.dosage).toBe('100mg');
    expect(body.profileId).toBe(PROFILE_A);
    expect(body.isPrn).toBe(false);
  });

  it('creates a PRN pill with isPrn flag', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'POST',
      url: `/profiles/${PROFILE_A}/pills`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), name: 'Ibuprofen PRN', isPrn: true },
    });
    expect(res.statusCode).toBe(201);
    const body = res.json();
    expect(body.isPrn).toBe(true);
  });

  it('accepts explicit nulls for unset optional fields and keeps replay semantics', async () => {
    // Build-2 clients journal unset dosage/notes/color as null in create payloads.
    const token = signTestToken(app, USER_A);
    const mutationId = randomUUID();
    const id = randomUUID();
    const send = (body: Record<string, unknown>) => app.inject({
      method: 'POST',
      url: `/profiles/${PROFILE_A}/pills`,
      headers: { authorization: `Bearer ${token}` },
      body,
    });
    const withNulls = {
      mutationId, id, name: 'Nullable', dosage: null, notes: null, color: null,
      lowStockThreshold: null, isPrn: false,
    };

    const first = await send(withNulls);
    expect(first.statusCode).toBe(201);
    expect(first.json()).toMatchObject({ id, dosage: null, notes: null, color: null });

    const replay = await send(withNulls);
    expect(replay.statusCode).toBe(201);
    expect(replay.json()).toEqual(first.json());

    // Null and absent are the same unset value, so the omitted form replays too.
    const omitted = await send({ mutationId, id, name: 'Nullable', isPrn: false });
    expect(omitted.statusCode).toBe(201);
    expect(omitted.json()).toEqual(first.json());

    const reused = await send({ ...withNulls, notes: 'different' });
    expect(reused.statusCode).toBe(409);
    expect(reused.json().error.code).toBe('CONFLICT_MUTATION_REUSE');
  });

  it('still requires a mutationId on create', async () => {
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'POST',
      url: `/profiles/${PROFILE_A}/pills`,
      headers: { authorization: `Bearer ${token}` },
      body: { name: 'No receipt key' },
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().error.code).toBe('VALIDATION_ERROR');
  });

  it('returns 404 if the profile does not belong to the user (ownership)', async () => {
    const tokenB = signTestToken(app, USER_B);
    const res = await app.inject({
      method: 'POST',
      url: `/profiles/${PROFILE_A}/pills`,
      headers: { authorization: `Bearer ${tokenB}` },
      body: { mutationId: randomUUID(), name: 'Stolen' },
    });
    expect(res.statusCode).toBe(404);
  });

  it('returns 401 without token', async () => {
    const res = await app.inject({
      method: 'POST',
      url: `/profiles/${PROFILE_A}/pills`,
      body: { name: 'Test' },
    });
    expect(res.statusCode).toBe(401);
  });
});

describe('GET /profiles/:profileId/pills', () => {
  it('returns only pills for the specified profile', async () => {
    await setTenantContext(superSql, USER_A);
    const [pill] = await superSql`
      INSERT INTO pills (profile_id, name) VALUES (${PROFILE_A}, 'Listed Pill')
      RETURNING id
    `;
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'GET',
      url: `/profiles/${PROFILE_A}/pills`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.statusCode).toBe(200);
    const ids = res.json().pills.map((p: { id: string }) => p.id);
    expect(ids).toContain(pill!.id);
  });

  it('returns 404 if the profile belongs to another user (ownership)', async () => {
    const tokenB = signTestToken(app, USER_B);
    const res = await app.inject({
      method: 'GET',
      url: `/profiles/${PROFILE_A}/pills`,
      headers: { authorization: `Bearer ${tokenB}` },
    });
    expect(res.statusCode).toBe(404);
  });
});

describe('PATCH /profiles/:profileId/pills/:id', () => {
  it('returns 404 when User B patches User A\'s pill (ownership)', async () => {
    await setTenantContext(superSql, USER_A);
    const [pill] = await superSql`
      INSERT INTO pills (profile_id, name) VALUES (${PROFILE_A}, 'A Pill')
      RETURNING id
    `;
    const tokenB = signTestToken(app, USER_B);
    const res = await app.inject({
      method: 'PATCH',
      url: `/profiles/${PROFILE_A}/pills/${pill!.id}`,
      headers: { authorization: `Bearer ${tokenB}` },
      body: { mutationId: randomUUID(), baseRevision: '1', name: 'Hacked' },
    });
    expect(res.statusCode).toBe(404);
  });

  it('updates own pill', async () => {
    await setTenantContext(superSql, USER_A);
    const [pill] = await superSql`
      INSERT INTO pills (profile_id, name) VALUES (${PROFILE_A}, 'Old Name')
      RETURNING id
    `;
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'PATCH',
      url: `/profiles/${PROFILE_A}/pills/${pill!.id}`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), baseRevision: '1', name: 'New Name' },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().name).toBe('New Name');
  });
});

describe('PATCH /profiles/:profileId/pills/:id — isPrn round-trip (H-3 fix)', () => {
  it('updates isPrn from false to true', async () => {
    await setTenantContext(superSql, USER_A);
    const [pill] = await superSql`
      INSERT INTO pills (profile_id, name, is_prn) VALUES (${PROFILE_A}, 'Aspirin RT', false)
      RETURNING id
    `;
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'PATCH',
      url: `/profiles/${PROFILE_A}/pills/${pill!.id}`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), baseRevision: '1', isPrn: true },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().isPrn).toBe(true);
  });

  it('updates isPrn from true to false', async () => {
    await setTenantContext(superSql, USER_A);
    const [pill] = await superSql`
      INSERT INTO pills (profile_id, name, is_prn) VALUES (${PROFILE_A}, 'Ibuprofen RT', true)
      RETURNING id
    `;
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'PATCH',
      url: `/profiles/${PROFILE_A}/pills/${pill!.id}`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), baseRevision: '1', isPrn: false },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().isPrn).toBe(false);
  });
});

describe('PATCH /profiles/:profileId/pills/:id — revision conflicts', () => {
  it('returns a conflict for a stale base revision', async () => {
    await setTenantContext(superSql, USER_A);
    const [pill] = await superSql`
      INSERT INTO pills (profile_id, name, updated_at) VALUES
        (${PROFILE_A}, 'Stale Pill', NOW())
      RETURNING id
    `;
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'PATCH',
      url: `/profiles/${PROFILE_A}/pills/${pill!.id}`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), baseRevision: '2', name: 'Updated' },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe('CONFLICT_REVISION');
  });
});

describe('DELETE /profiles/:profileId/pills/:id', () => {
  it('returns 404 when User B deletes User A\'s pill (ownership)', async () => {
    await setTenantContext(superSql, USER_A);
    const [pill] = await superSql`
      INSERT INTO pills (profile_id, name) VALUES (${PROFILE_A}, 'A Pill')
      RETURNING id
    `;
    const tokenB = signTestToken(app, USER_B);
    const res = await app.inject({
      method: 'DELETE',
      url: `/profiles/${PROFILE_A}/pills/${pill!.id}`,
      headers: { authorization: `Bearer ${tokenB}` },
      body: { mutationId: randomUUID(), baseRevision: '1' },
    });
    expect(res.statusCode).toBe(404);
  });

  it('deletes own pill and returns 204', async () => {
    await setTenantContext(superSql, USER_A);
    const [pill] = await superSql`
      INSERT INTO pills (profile_id, name) VALUES (${PROFILE_A}, 'To Delete')
      RETURNING id
    `;
    const token = signTestToken(app, USER_A);
    const res = await app.inject({
      method: 'DELETE',
      url: `/profiles/${PROFILE_A}/pills/${pill!.id}`,
      headers: { authorization: `Bearer ${token}` },
      body: { mutationId: randomUUID(), baseRevision: '1' },
    });
    expect(res.statusCode).toBe(204);
  });
});
