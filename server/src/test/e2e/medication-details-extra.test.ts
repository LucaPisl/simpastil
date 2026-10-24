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

describe('limits, expiry and contacts travel with the pill', () => {
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
    const email = `medication_extra_${Date.now()}_${++emailCounter}@test.com`;
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
      payload: { mutationId: randomUUID(), name: 'Paracetamol', ...extra },
    });
  }

  const full = {
    prnMaxPer24h: 3,
    prnMinGapMinutes: 240,
    expiresOn: '2027-03-31',
    prescriberName: 'Dr. Ana Popescu',
    prescriberPhone: '+40 721 000 000',
    pharmacyName: 'Farmacia Centrala',
    pharmacyPhone: '021.000.0000',
  };
  const unset = Object.fromEntries(Object.keys(full).map((key) => [key, null]));

  function patch(pillId: string, baseRevision: string, extra: Record<string, unknown>) {
    return app.inject({
      method: 'PATCH', url: `/api/v1/profiles/${profileId}/pills/${pillId}`, headers: bearer,
      payload: { mutationId: randomUUID(), baseRevision, ...extra },
    });
  }

  it('announces the capability', async () => {
    const response = await app.inject({ method: 'GET', url: '/api/v1/capabilities' });
    expect(response.statusCode).toBe(200);
    expect(response.json<{ contracts: Record<string, number> }>().contracts['medicationDetailsExtra']).toBe(1);
  });

  it('stores the fields set at creation and hands them back on the pull', async () => {
    const created = await create(full);
    expect(created.statusCode).toBe(201);
    expect(created.json()).toMatchObject(full);
    const pulled = await pulledPills(created.json<{ id: string }>().id);
    expect(pulled[pulled.length - 1]).toMatchObject(full);
  });

  it('reads a medicine with none set as null and leaves every key off its change row', async () => {
    const created = await create();
    expect(created.statusCode).toBe(201);
    expect(created.json()).toMatchObject(unset);
    const pulled = await pulledPills(created.json<{ id: string }>().id);
    // The previous release's strict payload schema must still read this row.
    const keys = Object.keys(pulled[pulled.length - 1]!);
    for (const key of Object.keys(full)) expect(keys).not.toContain(key);
  });

  it('stores names and numbers trimmed', async () => {
    const created = await create({ prescriberName: '  Dr. Ana  ', prescriberPhone: ' 0211234567 ' });
    expect(created.statusCode).toBe(201);
    expect(created.json()).toMatchObject({ prescriberName: 'Dr. Ana', prescriberPhone: '0211234567' });
  });

  it('keeps every stored value when an update from an older app omits them', async () => {
    const created = await create(full);
    const pillId = created.json<{ id: string }>().id;
    const renamed = await patch(pillId, '1', {
      name: 'Paracetamol forte', dosage: null, notes: null, color: null, lowStockThreshold: null, isPrn: true,
    });
    expect(renamed.statusCode).toBe(200);
    expect(renamed.json()).toMatchObject({ name: 'Paracetamol forte', ...full });
    const pulled = await pulledPills(pillId);
    expect(pulled[pulled.length - 1]).toMatchObject({ name: 'Paracetamol forte', ...full });
  });

  it('changes one field on its own and clears one with null', async () => {
    const created = await create(full);
    const pillId = created.json<{ id: string }>().id;
    const changed = await patch(pillId, '1', { prnMaxPer24h: 2 });
    expect(changed.statusCode).toBe(200);
    expect(changed.json()).toMatchObject({ ...full, prnMaxPer24h: 2, revision: '2' });
    const cleared = await patch(pillId, '2', { expiresOn: null, pharmacyPhone: null });
    expect(cleared.statusCode).toBe(200);
    expect(cleared.json()).toMatchObject({ ...full, prnMaxPer24h: 2, expiresOn: null, pharmacyPhone: null, revision: '3' });
    const pulled = (await pulledPills(pillId)).pop()!;
    expect(pulled).toMatchObject({ prnMaxPer24h: 2, pharmacyName: 'Farmacia Centrala' });
    expect(Object.keys(pulled)).not.toContain('expiresOn');
    expect(Object.keys(pulled)).not.toContain('pharmacyPhone');
  });

  it('refuses values outside the published limits', async () => {
    for (const bad of [
      { prnMaxPer24h: 0 }, { prnMaxPer24h: 49 }, { prnMinGapMinutes: 2881 }, { expiresOn: '2027-02-30' },
      { prescriberName: '' }, { prescriberPhone: 'call me' }, { pharmacyPhone: '12' },
    ]) {
      expect((await create(bad)).statusCode, JSON.stringify(bad)).toBe(400);
    }
    const created = await create();
    const pillId = created.json<{ id: string }>().id;
    expect((await patch(pillId, '1', { prnMaxPer24h: 99 })).statusCode).toBe(400);
  });

  it('never echoes the contacts in a stale-revision conflict body', async () => {
    const created = await create(full);
    const pillId = created.json<{ id: string }>().id;
    expect((await patch(pillId, '1', { prnMaxPer24h: 2 })).statusCode).toBe(200);
    const stale = await patch(pillId, '1', { prnMaxPer24h: 1 });
    expect(stale.statusCode).toBe(409);
    const body = stale.body;
    expect(body).not.toContain('Popescu');
    expect(body).not.toContain('721 000');
  });

  it('lists the fields with the profile pills', async () => {
    await create(full);
    const list = await app.inject({
      method: 'GET', url: `/api/v1/profiles/${profileId}/pills`, headers: bearer,
    });
    expect(list.statusCode).toBe(200);
    expect(list.json<{ pills: Array<Record<string, unknown>> }>().pills[0]).toMatchObject(full);
  });
});
