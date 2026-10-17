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

describe('reviewed medication details travel with the pill', () => {
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
    const email = `medication_detail_${Date.now()}_${++emailCounter}@test.com`;
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

  /// The newest pill item the stable component sync hands back for `pillId`.
  /// The component sync is an append-only log ordered by server sequence, so a
  /// pill that was created and then reviewed appears twice; the review is last.
  async function pulledPill(pillId: string): Promise<Record<string, unknown>> {
    const pull = await app.inject({
      method: 'GET', url: '/api/v1/sync/stable?contractVersion=2', headers: bearer,
    });
    expect(pull.statusCode).toBe(200);
    const items = pull.json<{ items: PillChange[] }>().items;
    const pills = items
      .map((item) => item.change?.payload)
      .filter((payload): payload is Record<string, unknown> => payload?.['kind'] === 'pill')
      .filter((payload) => payload['id'] === pillId);
    expect(pills.length, 'the pill reached the stable component').toBeGreaterThan(0);
    return pills[pills.length - 1]!;
  }

  it('carries details set at creation through to the pull', async () => {
    const created = await app.inject({
      method: 'POST', url: `/api/v1/profiles/${profileId}/pills`, headers: bearer,
      payload: {
        mutationId: randomUUID(),
        name: 'Pastila ficat',
        dosage: '1 pastila',
        amountPerUse: { version: 1, state: 'known', quantity: '1', unit: 'pastila' },
        packageStrength: '500 mg',
        form: 'tablet',
        legacyDosageReviewed: true,
      },
    });
    expect(created.statusCode).toBe(201);
    const pillId = created.json<{ id: string }>().id;
    expect(created.json()).toMatchObject({
      amountPerUse: { version: 1, state: 'known', quantity: '1', unit: 'pastila' },
      packageStrength: '500 mg',
      form: 'tablet',
      legacyDosageReviewed: true,
      // The wording a person typed is evidence and is never rewritten.
      dosage: '1 pastila',
    });

    expect(await pulledPill(pillId)).toMatchObject({
      amountPerUse: { version: 1, state: 'known', quantity: '1', unit: 'pastila' },
      packageStrength: '500 mg',
      form: 'tablet',
      legacyDosageReviewed: true,
      dosage: '1 pastila',
    });
  });

  it('accepts a review that only sets the details', async () => {
    const created = await app.inject({
      method: 'POST', url: `/api/v1/profiles/${profileId}/pills`, headers: bearer,
      payload: { mutationId: randomUUID(), name: 'Pastila ficat', dosage: '1 pastila' },
    });
    expect(created.statusCode).toBe(201);
    const pillId = created.json<{ id: string }>().id;
    // A medicine nobody has reviewed yet reads as unreviewed with no amount.
    expect(created.json()).toMatchObject({ amountPerUse: null, legacyDosageReviewed: false });

    const reviewed = await app.inject({
      method: 'PATCH', url: `/api/v1/profiles/${profileId}/pills/${pillId}`, headers: bearer,
      payload: {
        mutationId: randomUUID(),
        baseRevision: '1',
        amountPerUse: { version: 1, state: 'known', quantity: '1/2', unit: 'tablet' },
        legacyDosageReviewed: true,
      },
    });
    expect(reviewed.statusCode).toBe(200);
    expect(reviewed.json()).toMatchObject({
      amountPerUse: { version: 1, state: 'known', quantity: '1/2', unit: 'tablet' },
      legacyDosageReviewed: true,
    });

    expect(await pulledPill(pillId)).toMatchObject({
      amountPerUse: { version: 1, state: 'known', quantity: '1/2', unit: 'tablet' },
      legacyDosageReviewed: true,
      dosage: '1 pastila',
      revision: '2',
    });
  });

  it('leaves the details standing when a client never mentions them', async () => {
    const created = await app.inject({
      method: 'POST', url: `/api/v1/profiles/${profileId}/pills`, headers: bearer,
      payload: {
        mutationId: randomUUID(),
        name: 'Pastila ficat',
        dosage: '1 pastila',
        amountPerUse: { version: 1, state: 'known', quantity: '1', unit: 'pastila' },
        packageStrength: '500 mg',
        form: 'tablet',
        legacyDosageReviewed: true,
      },
    });
    expect(created.statusCode).toBe(201);
    const pillId = created.json<{ id: string }>().id;

    // An app built before these fields existed sends the medicine's own fields
    // and nothing else. Absent must not read as empty, or every edit made from
    // such a build would erase a review somebody made from a newer one.
    const renamed = await app.inject({
      method: 'PATCH', url: `/api/v1/profiles/${profileId}/pills/${pillId}`, headers: bearer,
      payload: {
        mutationId: randomUUID(),
        baseRevision: '1',
        name: 'Pastila ficat forte',
        dosage: '1 pastila',
        notes: null,
        color: null,
        lowStockThreshold: null,
        isPrn: false,
      },
    });
    expect(renamed.statusCode).toBe(200);
    expect(renamed.json()).toMatchObject({
      name: 'Pastila ficat forte',
      amountPerUse: { version: 1, state: 'known', quantity: '1', unit: 'pastila' },
      packageStrength: '500 mg',
      form: 'tablet',
      legacyDosageReviewed: true,
    });

    expect(await pulledPill(pillId)).toMatchObject({
      name: 'Pastila ficat forte',
      amountPerUse: { version: 1, state: 'known', quantity: '1', unit: 'pastila' },
      packageStrength: '500 mg',
      form: 'tablet',
      legacyDosageReviewed: true,
    });
  });

  it('refuses an amount that names a quantity with no unit', async () => {
    const created = await app.inject({
      method: 'POST', url: `/api/v1/profiles/${profileId}/pills`, headers: bearer,
      payload: {
        mutationId: randomUUID(),
        name: 'Broken amount',
        amountPerUse: { version: 1, state: 'known', quantity: '1' },
      },
    });
    expect(created.statusCode).toBe(400);
  });

  it('refuses a package strength longer than the column allows', async () => {
    const created = await app.inject({
      method: 'POST', url: `/api/v1/profiles/${profileId}/pills`, headers: bearer,
      payload: {
        mutationId: randomUUID(),
        name: 'Long strength',
        packageStrength: 'x'.repeat(501),
      },
    });
    expect(created.statusCode).toBe(400);
  });
});
