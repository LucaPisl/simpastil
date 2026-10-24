import { randomUUID } from 'node:crypto';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, createUnclaimedKey, truncateAll } from '../helpers/db-helpers.js';

interface PillChange {
  change?: { payload?: Record<string, unknown> };
}

let emailCounter = 0;

describe('the picked medication shape travels with the pill', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let cleanup: () => Promise<void>;
  let bearer: Record<string, string>;
  let profileId: string;

  beforeAll(async () => {
    const dbs = createDbs();
    superDb = dbs.superDb;
    cleanup = dbs.cleanup;
    app = await buildApp({
      db: dbs.appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey: process.env['JWT_PUBLIC_KEY']!,
    });
  });

  beforeEach(async () => {
    const apiKey = await createUnclaimedKey(superDb);
    const email = `medication_shape_${Date.now()}_${++emailCounter}@test.com`;
    const register = await app.inject({
      method: 'POST', url: '/api/v1/auth/register', headers: { 'X-Api-Key': apiKey },
      payload: { email, password: 'password1234' },
    });
    expect(register.statusCode).toBe(201);
    const login = await app.inject({
      method: 'POST', url: '/api/v1/auth/login', headers: { 'X-Api-Key': apiKey },
      payload: { email, password: 'password1234' },
    });
    expect(login.statusCode).toBe(200);
    bearer = {
      authorization: `Bearer ${login.json<{ accessToken: string }>().accessToken}`,
      'X-Api-Key': apiKey,
      'X-Simpastil-Client-Build': '2',
    };
    const profile = await app.inject({
      method: 'POST', url: '/api/v1/profiles', headers: bearer,
      payload: { mutationId: randomUUID(), name: 'Owner' },
    });
    expect(profile.statusCode).toBe(201);
    profileId = profile.json<{ id: string }>().id;
  });

  afterEach(async () => truncateAll(superDb));

  afterAll(async () => {
    await app.close();
    await cleanup();
  });

  async function pulledPills(pillId: string): Promise<Array<Record<string, unknown>>> {
    const pull = await app.inject({
      method: 'GET', url: '/api/v1/sync/stable?contractVersion=2', headers: bearer,
    });
    expect(pull.statusCode).toBe(200);
    return pull.json<{ items: PillChange[] }>().items
      .map((item) => item.change?.payload)
      .filter((payload): payload is Record<string, unknown> => payload?.['kind'] === 'pill')
      .filter((payload) => payload['id'] === pillId);
  }

  async function create(extra: Record<string, unknown> = {}) {
    return app.inject({
      method: 'POST', url: `/api/v1/profiles/${profileId}/pills`, headers: bearer,
      payload: { mutationId: randomUUID(), name: 'Magnefar', ...extra },
    });
  }

  it('stores a shape set at creation and hands it back on the pull', async () => {
    const created = await create({ shape: 'softgel' });
    expect(created.statusCode).toBe(201);
    expect(created.json()).toMatchObject({ shape: 'softgel' });
    const pillId = created.json<{ id: string }>().id;

    const pulled = await pulledPills(pillId);
    expect(pulled[pulled.length - 1]).toMatchObject({ shape: 'softgel' });
  });

  it('reads a medicine with no shape as null and leaves the key off its change row', async () => {
    const created = await create();
    expect(created.statusCode).toBe(201);
    expect(created.json()).toMatchObject({ shape: null });
    const pulled = await pulledPills(created.json<{ id: string }>().id);
    // The previous release's strict payload schema must still read this row.
    expect(Object.keys(pulled[pulled.length - 1]!)).not.toContain('shape');
  });

  it('changes the shape on its own', async () => {
    const created = await create();
    const pillId = created.json<{ id: string }>().id;
    const changed = await app.inject({
      method: 'PATCH', url: `/api/v1/profiles/${profileId}/pills/${pillId}`, headers: bearer,
      payload: { mutationId: randomUUID(), baseRevision: '1', shape: 'diamond' },
    });
    expect(changed.statusCode).toBe(200);
    expect(changed.json()).toMatchObject({ shape: 'diamond', revision: '2' });
    const pulled = await pulledPills(pillId);
    expect(pulled[pulled.length - 1]).toMatchObject({ shape: 'diamond', revision: '2' });
  });

  it('keeps the stored shape when an update from an older app omits it', async () => {
    const created = await create({ shape: 'caplet' });
    const pillId = created.json<{ id: string }>().id;

    const renamed = await app.inject({
      method: 'PATCH', url: `/api/v1/profiles/${profileId}/pills/${pillId}`, headers: bearer,
      payload: {
        mutationId: randomUUID(),
        baseRevision: '1',
        name: 'Magnefar forte',
        dosage: null,
        notes: null,
        color: null,
        lowStockThreshold: null,
        isPrn: false,
      },
    });
    expect(renamed.statusCode).toBe(200);
    expect(renamed.json()).toMatchObject({ name: 'Magnefar forte', shape: 'caplet' });

    const pulled = await pulledPills(pillId);
    expect(pulled[pulled.length - 1]).toMatchObject({ name: 'Magnefar forte', shape: 'caplet' });
  });

  it('refuses a shape it does not publish', async () => {
    expect((await create({ shape: 'hexagon' })).statusCode).toBe(400);
    const created = await create();
    const pillId = created.json<{ id: string }>().id;
    const changed = await app.inject({
      method: 'PATCH', url: `/api/v1/profiles/${profileId}/pills/${pillId}`, headers: bearer,
      payload: { mutationId: randomUUID(), baseRevision: '1', shape: 'hexagon' },
    });
    expect(changed.statusCode).toBe(400);
  });

  it('lists the picked shape with the profile pills', async () => {
    await create({ shape: 'triangle' });
    const list = await app.inject({
      method: 'GET', url: `/api/v1/profiles/${profileId}/pills`, headers: bearer,
    });
    expect(list.statusCode).toBe(200);
    const rows = list.json<{ pills: Array<Record<string, unknown>> }>().pills;
    expect(rows[0]).toMatchObject({ shape: 'triangle' });
  });
});
