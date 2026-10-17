import { randomUUID } from 'node:crypto';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { sql } from 'drizzle-orm';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, createUnclaimedKey, truncateAll } from '../helpers/db-helpers.js';

type Kind = 'profiles' | 'pills' | 'schedules';
type Headers = Record<string, string>;

interface Created {
  id: string;
  revision: string;
  body: Record<string, unknown>;
  url: string;
}

let emailCounter = 0;

describe('stable entity idempotency and conflict outcomes', () => {
  let app: FastifyInstance;
  let cleanup: () => Promise<void>;
  let superDb: Awaited<ReturnType<typeof createDbs>>['superDb'];
  let headers: Headers;
  let otherHeaders: Headers;

  async function registerUser(): Promise<Headers> {
    const apiKey = await createUnclaimedKey(superDb);
    const email = `entity_idem_${Date.now()}_${++emailCounter}@test.com`;
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
    return {
      authorization: `Bearer ${login.json<{ accessToken: string }>().accessToken}`,
      'X-Api-Key': apiKey,
      'X-Simpastil-Client-Build': '2',
    };
  }

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
    headers = await registerUser();
    otherHeaders = await registerUser();
  });

  afterEach(async () => truncateAll(superDb));

  afterAll(async () => {
    await app.close();
    await cleanup();
  });

  async function createProfile(h: Headers, id: string = randomUUID(), mutationId: string = randomUUID()) {
    const body = { mutationId, id, name: 'Idem Profile' };
    const res = await app.inject({ method: 'POST', url: '/api/v1/profiles', headers: h, payload: body });
    return { res, body };
  }

  async function createPill(h: Headers, profileId: string, id: string = randomUUID(), mutationId: string = randomUUID()) {
    const body = { mutationId, id, name: 'Idem Pill' };
    const res = await app.inject({ method: 'POST', url: `/api/v1/profiles/${profileId}/pills`, headers: h, payload: body });
    return { res, body };
  }

  async function createSchedule(h: Headers, pillId: string, id: string = randomUUID(), mutationId: string = randomUUID()) {
    const body = {
      mutationId, id, hour: 8, minute: 30, frequency: 'daily', timeZone: 'Europe/Bucharest',
    };
    const res = await app.inject({ method: 'POST', url: `/api/v1/pills/${pillId}/schedules`, headers: h, payload: body });
    return { res, body };
  }

  /** Builds a parent chain and creates one entity of the requested kind. */
  async function make(kind: Kind, h: Headers = headers, id: string = randomUUID(), mutationId: string = randomUUID()) {
    const profile = kind === 'profiles' ? undefined : await createProfile(h);
    if (profile) expect(profile.res.statusCode).toBe(201);
    const profileId = profile?.body.id;
    const pill = kind === 'schedules' ? await createPill(h, profileId as string) : undefined;
    if (pill) expect(pill.res.statusCode).toBe(201);
    const created = kind === 'profiles'
      ? await createProfile(h, id, mutationId)
      : kind === 'pills'
        ? await createPill(h, profileId as string, id, mutationId)
        : await createSchedule(h, pill!.body.id, id, mutationId);
    const url = kind === 'profiles'
      ? '/api/v1/profiles'
      : kind === 'pills'
        ? `/api/v1/profiles/${profileId}/pills`
        : `/api/v1/pills/${pill!.body.id}/schedules`;
    return { created, url, parent: { profileId, pillId: pill?.body.id } };
  }

  function patchBody(kind: Kind, baseRevision: string, mutationId: string = randomUUID()) {
    return kind === 'schedules'
      ? { mutationId, baseRevision, hour: 9 }
      : { mutationId, baseRevision, name: 'Renamed' };
  }

  const kinds: Kind[] = ['profiles', 'pills', 'schedules'];

  describe.each(kinds)('%s', (kind) => {
    async function setup(): Promise<Created & { parent: { profileId: unknown; pillId: unknown } }> {
      const { created, url, parent } = await make(kind);
      expect(created.res.statusCode).toBe(201);
      const entity = created.res.json<{ id: string; revision: string }>();
      return { id: entity.id, revision: entity.revision, body: created.body, url, parent };
    }

    it('replays an identical create byte-for-byte', async () => {
      const { body, url } = await setup();
      const first = await app.inject({ method: 'POST', url, headers, payload: body });
      expect(first.statusCode).toBe(201);
      const second = await app.inject({ method: 'POST', url, headers, payload: body });
      expect(second.statusCode).toBe(201);
      expect(second.json()).toEqual(first.json());
    });

    it('rejects a reused mutationId carrying different input', async () => {
      const { body, url } = await setup();
      const changed = kind === 'schedules' ? { ...body, hour: 10 } : { ...body, name: 'Different' };
      const res = await app.inject({ method: 'POST', url, headers, payload: changed });
      expect(res.statusCode).toBe(409);
      expect(res.json().error.code).toBe('CONFLICT_MUTATION_REUSE');
    });

    it('rejects a mutationId reused for a different operation', async () => {
      const { id, revision, body, url } = await setup();
      const res = await app.inject({
        method: 'PATCH', url: `${url}/${id}`, headers,
        payload: patchBody(kind, revision, body.mutationId as string),
      });
      expect(res.statusCode).toBe(409);
      expect(res.json().error.code).toBe('CONFLICT_MUTATION_REUSE');
    });

    it('replays an identical update and rejects a reused update id with different input', async () => {
      const { id, revision, url } = await setup();
      const payload = patchBody(kind, revision);
      const first = await app.inject({ method: 'PATCH', url: `${url}/${id}`, headers, payload });
      expect(first.statusCode).toBe(200);
      const replay = await app.inject({ method: 'PATCH', url: `${url}/${id}`, headers, payload });
      expect(replay.statusCode).toBe(200);
      expect(replay.json()).toEqual(first.json());
      expect(replay.json().revision).toBe('2');

      const reuse = await app.inject({
        method: 'PATCH', url: `${url}/${id}`, headers,
        payload: { ...payload, ...(kind === 'schedules' ? { hour: 11 } : { name: 'Other' }) },
      });
      expect(reuse.statusCode).toBe(409);
      expect(reuse.json().error.code).toBe('CONFLICT_MUTATION_REUSE');
    });

    it('answers a stale revision with the current entity', async () => {
      const { id, revision, url } = await setup();
      const first = await app.inject({
        method: 'PATCH', url: `${url}/${id}`, headers, payload: patchBody(kind, revision),
      });
      expect(first.statusCode).toBe(200);
      const stale = await app.inject({
        method: 'PATCH', url: `${url}/${id}`, headers, payload: patchBody(kind, revision),
      });
      expect(stale.statusCode).toBe(409);
      const error = stale.json().error;
      expect(error.code).toBe('CONFLICT_REVISION');
      expect(error.details.currentRevision).toBe('2');
      expect(error.details.currentEntity).toMatchObject({ entityType: kind, id, revision: '2', deletedAt: null });
    });

    it('creating an existing id returns 409 CONFLICT_DUPLICATE with the current entity', async () => {
      const { id, revision, url, body } = await setup();
      const res = await app.inject({
        method: 'POST', url, headers, payload: { ...body, mutationId: randomUUID() },
      });
      expect(res.statusCode).toBe(409);
      const error = res.json().error;
      expect(error.code).toBe('CONFLICT_DUPLICATE');
      expect(error.details.existingId).toBe(id);
      expect(error.details.currentEntity).toMatchObject({ entityType: kind, id, revision, deletedAt: null });
    });

    it('creating over a soft-deleted id reports the tombstone without reviving it', async () => {
      const { id, revision, url, body } = await setup();
      const del = await app.inject({
        method: 'DELETE', url: `${url}/${id}`, headers,
        payload: { mutationId: randomUUID(), baseRevision: revision },
      });
      expect(del.statusCode).toBe(204);
      const res = await app.inject({
        method: 'POST', url, headers, payload: { ...body, mutationId: randomUUID() },
      });
      expect(res.statusCode).toBe(409);
      const error = res.json().error;
      expect(error.code).toBe('CONFLICT_DUPLICATE');
      expect(error.details.existingId).toBe(id);
      expect(error.details.currentEntity.id).toBe(id);
      expect(error.details.currentEntity.deletedAt).toEqual(expect.any(String));
    });

    it('does not disclose another tenant row on duplicate id', async () => {
      const { created, url } = await make(kind, otherHeaders);
      expect(created.res.statusCode).toBe(201);
      const foreignId = created.res.json<{ id: string }>().id;
      const mine = await make(kind, headers, foreignId);
      expect(mine.created.res.statusCode).toBe(409);
      const error = mine.created.res.json().error;
      expect(error.code).toBe('CONFLICT_DUPLICATE');
      expect(error.details.currentEntity).toBeUndefined();
      expect(error.details.existingId).toBeUndefined();
      expect(url).toBeTruthy();
    });

    it('delete is idempotent: twice with different mutation ids, and exact replay', async () => {
      const { id, revision, url } = await setup();
      const firstPayload = { mutationId: randomUUID(), baseRevision: revision };
      const first = await app.inject({ method: 'DELETE', url: `${url}/${id}`, headers, payload: firstPayload });
      expect(first.statusCode).toBe(204);

      const secondPayload = { mutationId: randomUUID(), baseRevision: revision };
      const second = await app.inject({ method: 'DELETE', url: `${url}/${id}`, headers, payload: secondPayload });
      expect(second.statusCode).toBe(204);

      const staleRevision = { mutationId: randomUUID(), baseRevision: '99' };
      const third = await app.inject({ method: 'DELETE', url: `${url}/${id}`, headers, payload: staleRevision });
      expect(third.statusCode).toBe(204);

      const replayFirst = await app.inject({ method: 'DELETE', url: `${url}/${id}`, headers, payload: firstPayload });
      expect(replayFirst.statusCode).toBe(204);
      const replaySecond = await app.inject({ method: 'DELETE', url: `${url}/${id}`, headers, payload: secondPayload });
      expect(replaySecond.statusCode).toBe(204);
    });

    it('records a receipt for the idempotent delete so the id cannot be reused for other input', async () => {
      const { id, revision, url, body } = await setup();
      const del = await app.inject({
        method: 'DELETE', url: `${url}/${id}`, headers,
        payload: { mutationId: randomUUID(), baseRevision: revision },
      });
      expect(del.statusCode).toBe(204);
      const secondId = randomUUID();
      const second = await app.inject({
        method: 'DELETE', url: `${url}/${id}`, headers,
        payload: { mutationId: secondId, baseRevision: revision },
      });
      expect(second.statusCode).toBe(204);
      const reuse = await app.inject({
        method: 'POST', url, headers, payload: { ...body, mutationId: secondId },
      });
      expect(reuse.statusCode).toBe(409);
      expect(reuse.json().error.code).toBe('CONFLICT_MUTATION_REUSE');
    });

    it('delete does not add a second tombstone to the sync stream', async () => {
      if (kind === 'schedules') return;
      const { id, revision, url } = await setup();
      for (let i = 0; i < 3; i++) {
        const res = await app.inject({
          method: 'DELETE', url: `${url}/${id}`, headers,
          payload: { mutationId: randomUUID(), baseRevision: revision },
        });
        expect(res.statusCode).toBe(204);
      }
      const pull = await app.inject({ method: 'GET', url: '/api/v1/sync/stable?contractVersion=2', headers });
      expect(pull.statusCode).toBe(200);
      const tombstones = pull.json<{ items: { change: { operation: string; entityId: string } }[] }>()
        .items.filter((item) => item.change.operation === 'tombstone' && item.change.entityId === id);
      expect(tombstones).toHaveLength(1);
    });

    it('idempotent delete of a pre-0013 tombstone (revision 1) is 204 with a valid receipt', async () => {
      const { id, revision, url } = await setup();
      expect(revision).toBe('1');
      // Old migrations soft-deleted rows without bumping the revision.
      await superDb.execute(sql`UPDATE ${sql.raw(kind)} SET deleted_at = now() WHERE id = ${id}`);
      const mutationId = randomUUID();
      const payload = { mutationId, baseRevision: revision };
      const res = await app.inject({ method: 'DELETE', url: `${url}/${id}`, headers, payload });
      expect(res.statusCode).toBe(204);
      const receipts = await superDb.execute<{ base_revision: string; result_revision: string }>(sql`
        SELECT base_revision, result_revision FROM entity_mutation_receipts WHERE mutation_id = ${mutationId}
      `);
      expect(receipts).toHaveLength(1);
      expect(String(receipts[0]!.base_revision)).toBe('1');
      expect(String(receipts[0]!.result_revision)).toBe('2');
      // The same mutation id replays from the receipt.
      const replay = await app.inject({ method: 'DELETE', url: `${url}/${id}`, headers, payload });
      expect(replay.statusCode).toBe(204);
    });

    it('update after delete stays 404 and reports the tombstone', async () => {
      const { id, revision, url } = await setup();
      const del = await app.inject({
        method: 'DELETE', url: `${url}/${id}`, headers,
        payload: { mutationId: randomUUID(), baseRevision: revision },
      });
      expect(del.statusCode).toBe(204);
      const res = await app.inject({
        method: 'PATCH', url: `${url}/${id}`, headers,
        payload: patchBody(kind, '2'),
      });
      expect(res.statusCode).toBe(404);
      const error = res.json().error;
      expect(error.code).toBe('RESOURCE_NOT_FOUND');
      expect(error.details.currentEntity).toMatchObject({ entityType: kind, id });
      expect(error.details.currentEntity.deletedAt).toEqual(expect.any(String));
    });

    it('delete of an unknown id is still 404', async () => {
      const { url } = await setup();
      const res = await app.inject({
        method: 'DELETE', url: `${url}/${randomUUID()}`, headers,
        payload: { mutationId: randomUUID(), baseRevision: '1' },
      });
      expect(res.statusCode).toBe(404);
    });

    it('delete of another tenant row is 404, not an idempotent success', async () => {
      const { created, url } = await make(kind, otherHeaders);
      const foreign = created.res.json<{ id: string; revision: string }>();
      const res = await app.inject({
        method: 'DELETE', url: `${url}/${foreign.id}`, headers,
        payload: { mutationId: randomUUID(), baseRevision: foreign.revision },
      });
      expect(res.statusCode).toBe(404);
    });

    it('delete with a stale revision on a live row is still a revision conflict', async () => {
      const { id, revision, url } = await setup();
      const bump = await app.inject({
        method: 'PATCH', url: `${url}/${id}`, headers, payload: patchBody(kind, revision),
      });
      expect(bump.statusCode).toBe(200);
      const res = await app.inject({
        method: 'DELETE', url: `${url}/${id}`, headers,
        payload: { mutationId: randomUUID(), baseRevision: revision },
      });
      expect(res.statusCode).toBe(409);
      expect(res.json().error.code).toBe('CONFLICT_REVISION');
    });
  });
});
