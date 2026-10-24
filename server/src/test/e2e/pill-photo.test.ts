import { createHash, randomUUID } from 'node:crypto';
import { request as httpRequest } from 'node:http';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { sql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, createUnclaimedKey, truncateAll } from '../helpers/db-helpers.js';
import { makeJpeg } from '../helpers/jpeg-fixture.js';

interface PillChange {
  change?: { payload?: Record<string, unknown> };
}

interface Account {
  headers: Record<string, string>;
  profileId: string;
  userId: string;
}

let emailCounter = 0;
const sha256 = (bytes: Buffer) => createHash('sha256').update(bytes).digest('hex');

describe('the photo of a medication', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;
  let me: Account;

  beforeAll(async () => {
    const dbs = createDbs();
    superDb = dbs.superDb;
    appDb = dbs.appDb;
    cleanup = dbs.cleanup;
    app = await buildApp({
      db: dbs.appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey: process.env['JWT_PUBLIC_KEY']!,
    });
  });

  async function register(): Promise<Account> {
    const apiKey = await createUnclaimedKey(superDb);
    const email = `pill_photo_${Date.now()}_${++emailCounter}@test.com`;
    const registered = await app.inject({
      method: 'POST', url: '/api/v1/auth/register', headers: { 'X-Api-Key': apiKey },
      payload: { email, password: 'password1234' },
    });
    expect(registered.statusCode).toBe(201);
    const login = await app.inject({
      method: 'POST', url: '/api/v1/auth/login', headers: { 'X-Api-Key': apiKey },
      payload: { email, password: 'password1234' },
    });
    expect(login.statusCode).toBe(200);
    const headers = {
      authorization: `Bearer ${login.json<{ accessToken: string }>().accessToken}`,
      'X-Api-Key': apiKey,
      'X-Simpastil-Client-Build': '2',
    };
    const profile = await app.inject({
      method: 'POST', url: '/api/v1/profiles', headers,
      payload: { mutationId: randomUUID(), name: 'Owner' },
    });
    expect(profile.statusCode).toBe(201);
    const [user] = await superDb.execute<{ id: string }>(sql`SELECT id FROM users WHERE email = ${email}`);
    return { headers, profileId: profile.json<{ id: string }>().id, userId: user!.id };
  }

  beforeEach(async () => {
    me = await register();
  });

  afterEach(async () => truncateAll(superDb));

  afterAll(async () => {
    await app.close();
    await cleanup();
  });

  async function createPill(account: Account = me, extra: Record<string, unknown> = {}) {
    const response = await app.inject({
      method: 'POST', url: `/api/v1/profiles/${account.profileId}/pills`, headers: account.headers,
      payload: { mutationId: randomUUID(), name: 'Paracetamol', ...extra },
    });
    expect(response.statusCode).toBe(201);
    return response.json<{ id: string; revision: string }>();
  }

  const put = (pillId: string, body: Buffer | string, account: Account = me, contentType = 'image/jpeg') => app.inject({
    method: 'PUT', url: `/api/v1/pills/${pillId}/photo`,
    headers: { ...account.headers, 'content-type': contentType }, payload: body,
  });
  const get = (pillId: string, account: Account = me) => app.inject({
    method: 'GET', url: `/api/v1/pills/${pillId}/photo`, headers: account.headers,
  });
  const remove = (pillId: string, account: Account = me) => app.inject({
    method: 'DELETE', url: `/api/v1/pills/${pillId}/photo`, headers: account.headers,
  });

  async function pulledPills(pillId: string, account: Account = me): Promise<Array<Record<string, unknown>>> {
    const pull = await app.inject({ method: 'GET', url: '/api/v1/sync/stable?contractVersion=2', headers: account.headers });
    expect(pull.statusCode).toBe(200);
    return pull.json<{ items: PillChange[] }>().items
      .map((item) => item.change?.payload)
      .filter((payload): payload is Record<string, unknown> => payload?.['kind'] === 'pill' && payload['id'] === pillId);
  }

  // Hard deletes need the tenant context the legacy medication guard asks for.
  const hardDelete = (userId: string, statement: ReturnType<typeof sql>) => superDb.transaction(async (tx) => {
    await tx.execute(sql`SELECT set_config('app.current_user_id', ${userId}, true)`);
    await tx.execute(statement);
  });

  const count = async (table: string) => {
    const [row] = await superDb.execute<{ n: number }>(sql`SELECT count(*)::int AS n FROM ${sql.raw(table)}`);
    return row!.n;
  };

  it('announces the capability', async () => {
    const response = await app.inject({ method: 'GET', url: '/api/v1/capabilities' });
    expect(response.json<{ contracts: Record<string, number> }>().contracts['medicationPhoto']).toBe(1);
  });

  it('stores a photo, names it on the pill and returns the same bytes', async () => {
    const pill = await createPill();
    const photo = makeJpeg({ width: 1200, height: 900 });
    const stored = await put(pill.id, photo);
    expect(stored.statusCode).toBe(200);
    expect(stored.json()).toEqual({
      pillId: pill.id, sha256: sha256(photo), revision: '1', width: 1200, height: 900, pillRevision: '2',
    });
    const read = await get(pill.id);
    expect(read.statusCode).toBe(200);
    expect(read.headers['content-type']).toBe('image/jpeg');
    expect(read.headers['etag']).toBe(`"${sha256(photo)}"`);
    expect(read.rawPayload.equals(photo)).toBe(true);

    const pulled = await pulledPills(pill.id);
    const last = pulled[pulled.length - 1]!;
    expect(last['photo']).toEqual({ sha256: sha256(photo), revision: '1' });
    expect(last['revision']).toBe('2');
    // The bytes never travel in the sync stream.
    expect(JSON.stringify(last)).not.toContain(photo.toString('base64').slice(0, 40));
  });

  it('leaves the photo key off a pill that has none', async () => {
    const pill = await createPill();
    const pulled = await pulledPills(pill.id);
    expect(Object.keys(pulled[pulled.length - 1]!)).not.toContain('photo');
  });

  it('keeps the reference on later edits of the pill and drops it with the photo', async () => {
    const pill = await createPill();
    const photo = makeJpeg({ width: 400, height: 300 });
    await put(pill.id, photo);
    const edited = await app.inject({
      method: 'PATCH', url: `/api/v1/profiles/${me.profileId}/pills/${pill.id}`, headers: me.headers,
      payload: { mutationId: randomUUID(), baseRevision: '2', name: 'Ibuprofen' },
    });
    expect(edited.statusCode).toBe(200);
    let pulled = await pulledPills(pill.id);
    expect(pulled[pulled.length - 1]).toMatchObject({ name: 'Ibuprofen', revision: '3', photo: { sha256: sha256(photo), revision: '1' } });

    expect((await remove(pill.id)).statusCode).toBe(204);
    expect((await get(pill.id)).statusCode).toBe(404);
    pulled = await pulledPills(pill.id);
    const last = pulled[pulled.length - 1]!;
    expect(last['revision']).toBe('4');
    expect(Object.keys(last)).not.toContain('photo');
  });

  it('counts a replacement as a new photo revision and the same bytes as nothing', async () => {
    const pill = await createPill();
    const first = makeJpeg({ width: 400, height: 300, filler: 1 });
    const second = makeJpeg({ width: 400, height: 300, filler: 2 });
    await put(pill.id, first);
    const again = await put(pill.id, first);
    expect(again.json()).toMatchObject({ revision: '1', pillRevision: '2' });
    const replaced = await put(pill.id, second);
    expect(replaced.json()).toMatchObject({ sha256: sha256(second), revision: '2', pillRevision: '3' });
    expect((await get(pill.id)).rawPayload.equals(second)).toBe(true);
    expect(await count('pill_photos')).toBe(1);
  });

  it('removing nothing is a no-op', async () => {
    const pill = await createPill();
    expect((await remove(pill.id)).statusCode).toBe(204);
    const pulled = await pulledPills(pill.id);
    expect(pulled).toHaveLength(1);
  });

  it('makes a stale edit of the pill conflict after a photo change', async () => {
    const pill = await createPill();
    await put(pill.id, makeJpeg({ width: 100, height: 100 }));
    const stale = await app.inject({
      method: 'PATCH', url: `/api/v1/profiles/${me.profileId}/pills/${pill.id}`, headers: me.headers,
      payload: { mutationId: randomUUID(), baseRevision: '1', name: 'Late' },
    });
    expect(stale.statusCode).toBe(409);
  });

  describe('refuses', () => {
    it('a photo that carries Exif or XMP', async () => {
      const pill = await createPill();
      const exif = makeJpeg({ width: 400, height: 300, app1: Buffer.from('Exif\0\0GPSLatitude', 'latin1') });
      const xmp = makeJpeg({ width: 400, height: 300, app1: Buffer.from('http://ns.adobe.com/xap/1.0/\0<x:xmpmeta/>', 'latin1') });
      for (const body of [exif, xmp]) {
        const response = await put(pill.id, body);
        expect(response.statusCode).toBe(422);
        expect(response.json()).toMatchObject({ error: { code: 'VALIDATION_ERROR' } });
      }
      expect(await count('pill_photos')).toBe(0);
    });

    it('a photo larger than 1600 px on a side', async () => {
      const pill = await createPill();
      expect((await put(pill.id, makeJpeg({ width: 1601, height: 100 }))).statusCode).toBe(422);
      expect((await put(pill.id, makeJpeg({ width: 100, height: 4000 }))).statusCode).toBe(422);
      expect((await put(pill.id, makeJpeg({ width: 1600, height: 1600 }))).statusCode).toBe(200);
    });

    it('a photo over 512 KiB, before and after the route limit', async () => {
      const pill = await createPill();
      const justOver = makeJpeg({ width: 800, height: 600, size: 524289 });
      expect((await put(pill.id, justOver)).statusCode).toBe(413);
      const huge = makeJpeg({ width: 800, height: 600, size: 700000 });
      expect((await put(pill.id, huge)).statusCode).toBe(413);
      expect((await put(pill.id, makeJpeg({ width: 800, height: 600, size: 524288 }))).statusCode).toBe(200);
    });

    it('bytes that are not a JPEG, a cut-off JPEG and another content type', async () => {
      const pill = await createPill();
      expect((await put(pill.id, Buffer.from('GIF89a not a jpeg at all'))).statusCode).toBe(422);
      expect((await put(pill.id, Buffer.alloc(0))).statusCode).toBeGreaterThanOrEqual(400);
      const whole = makeJpeg({ width: 100, height: 100 });
      expect((await put(pill.id, whole.subarray(0, whole.length - 2))).statusCode).toBe(422);
      expect((await put(pill.id, whole, me, 'image/png')).statusCode).toBe(415);
      expect(await count('pill_photos')).toBe(0);
    });
  });

  describe('belongs to its owner', () => {
    it('answers 404 to another account on every verb and leaves the photo alone', async () => {
      const pill = await createPill();
      const photo = makeJpeg({ width: 100, height: 100 });
      await put(pill.id, photo);
      const other = await register();
      expect((await get(pill.id, other)).statusCode).toBe(404);
      expect((await put(pill.id, makeJpeg({ width: 50, height: 50 }), other)).statusCode).toBe(404);
      expect((await remove(pill.id, other)).statusCode).toBe(404);
      expect((await get(pill.id)).rawPayload.equals(photo)).toBe(true);
    });

    it('needs a signed-in account', async () => {
      const pill = await createPill();
      const response = await app.inject({ method: 'GET', url: `/api/v1/pills/${pill.id}/photo` });
      expect(response.statusCode).toBeGreaterThanOrEqual(401);
    });

    it('is invisible to another tenant under row level security', async () => {
      const pill = await createPill();
      await put(pill.id, makeJpeg({ width: 100, height: 100 }));
      const other = await register();
      const seen = await appDb.transaction(async (tx) => {
        await tx.execute(sql`SELECT set_config('app.current_user_id', ${other.userId}, true)`);
        return tx.execute<{ n: number }>(sql`SELECT count(*)::int AS n FROM pill_photos`);
      });
      expect(seen[0]!.n).toBe(0);
      await expect(appDb.transaction(async (tx) => {
        await tx.execute(sql`SELECT set_config('app.current_user_id', ${other.userId}, true)`);
        await tx.execute(sql`INSERT INTO pill_photos (pill_id, user_id, bytes, width, height, sha256)
          VALUES (${pill.id}, ${other.userId}, '\\xffd8'::bytea, 1, 1, ${'a'.repeat(64)})`);
      })).rejects.toThrow();
    });
  });

  describe('goes with what it belongs to', () => {
    it('is deleted with the medication', async () => {
      const pill = await createPill();
      await put(pill.id, makeJpeg({ width: 100, height: 100 }));
      const deleted = await app.inject({
        method: 'DELETE', url: `/api/v1/profiles/${me.profileId}/pills/${pill.id}`, headers: me.headers,
        payload: { mutationId: randomUUID(), baseRevision: '2' },
      });
      expect(deleted.statusCode).toBe(204);
      expect(await count('pill_photos')).toBe(0);
      expect((await get(pill.id)).statusCode).toBe(404);
    });

    it('cascades when the pill row goes', async () => {
      const pill = await createPill();
      await put(pill.id, makeJpeg({ width: 100, height: 100 }));
      await hardDelete(me.userId, sql`DELETE FROM pills WHERE id = ${pill.id}`);
      expect(await count('pill_photos')).toBe(0);
    });

    it('cascades when the account goes and leaves other accounts alone', async () => {
      const pill = await createPill();
      await put(pill.id, makeJpeg({ width: 100, height: 100 }));
      const other = await register();
      const otherPill = await createPill(other);
      await put(otherPill.id, makeJpeg({ width: 120, height: 90 }), other);
      await hardDelete(me.userId, sql`DELETE FROM users WHERE id = ${me.userId}`);
      expect(await count('pill_photos')).toBe(1);
      expect((await get(otherPill.id, other)).statusCode).toBe(200);
    });
  });

  describe('in the account export', () => {
    it('is written as base64 under the photos key, a few rows to a page', async () => {
      const pill = await createPill();
      const photo = makeJpeg({ width: 640, height: 480, size: 3000 });
      await put(pill.id, photo);
      const second = await createPill();
      const photo2 = makeJpeg({ width: 320, height: 240, size: 5000 });
      await put(second.id, photo2);
      const exported = await app.inject({ method: 'GET', url: '/api/v1/account/export', headers: me.headers });
      expect(exported.statusCode).toBe(200);
      const file = JSON.parse(exported.body) as { tables: { pillPhotos: Array<Record<string, unknown>> } };
      const rows = file.tables.pillPhotos;
      expect(rows).toHaveLength(2);
      const mine = rows.find((row) => row['pillId'] === pill.id)!;
      expect(mine['bytesBase64']).toBe(photo.toString('base64'));
      expect(mine['sha256']).toBe(sha256(photo));
      expect(Object.keys(mine)).not.toContain('bytes');
      expect(rows.find((row) => row['pillId'] === second.id)!['bytesBase64']).toBe(photo2.toString('base64'));
    });
  });

  describe('upload limit', () => {
    it('allows a few uploads per account, then answers 429, and counts only signed-in callers', async () => {
      const limited = await buildApp({
        db: appDb,
        privateKey: process.env['JWT_PRIVATE_KEY']!,
        publicKey: process.env['JWT_PUBLIC_KEY']!,
        rateLimitMax: 2,
        rateLimitTimeWindow: '1 minute',
      });
      try {
        const pill = await createPill();
        const send = (headers: Record<string, string>) => limited.inject({
          method: 'PUT', url: `/api/v1/pills/${pill.id}/photo`,
          headers: { ...headers, 'content-type': 'image/jpeg' }, payload: makeJpeg({ width: 100, height: 100 }),
        });
        // Unauthenticated attempts are refused before they spend the budget.
        for (let i = 0; i < 4; i += 1) {
          expect((await send({ 'X-Api-Key': me.headers['X-Api-Key']! })).statusCode).toBe(401);
        }
        expect((await send(me.headers)).statusCode).toBe(200);
        expect((await send(me.headers)).statusCode).toBe(200);
        const refused = await send(me.headers);
        expect(refused.statusCode).toBe(429);
        expect(refused.json().code).toBe('RATE_LIMIT_EXCEEDED');
        // Another account has its own budget.
        const other = await register();
        const otherPill = await createPill(other);
        const ok = await limited.inject({
          method: 'PUT', url: `/api/v1/pills/${otherPill.id}/photo`,
          headers: { ...other.headers, 'content-type': 'image/jpeg' }, payload: makeJpeg({ width: 100, height: 100 }),
        });
        expect(ok.statusCode).toBe(200);
      } finally {
        await limited.close();
      }
    });
  });

  /**
   * Announces a 500 KB body but never sends a byte of it, so the status can
   * only have come from the headers: nothing was buffered.
   */
  function statusFromHeadersOnly(address: string, pillId: string, headers: Record<string, string>): Promise<number> {
    const { port } = new URL(address);
    return new Promise<number>((resolve, reject) => {
      const request = httpRequest({
        host: '127.0.0.1', port: Number(port), method: 'PUT', path: `/api/v1/pills/${pillId}/photo`,
        headers: { 'content-type': 'image/jpeg', 'content-length': '500000', ...headers },
      }, (response) => { response.resume(); resolve(response.statusCode ?? 0); request.destroy(); });
      request.on('error', (error) => { if ((error as NodeJS.ErrnoException).code !== 'ECONNRESET') reject(error); });
      request.flushHeaders();
      setTimeout(() => reject(new Error('no answer before the body was sent')), 5000).unref();
    });
  }

  it('refuses an over-budget upload before reading its body', async () => {
    const limited = await buildApp({
      db: appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey: process.env['JWT_PUBLIC_KEY']!,
      rateLimitMax: 1,
      rateLimitTimeWindow: '1 minute',
    });
    try {
      const pill = await createPill();
      const first = await limited.inject({
        method: 'PUT', url: `/api/v1/pills/${pill.id}/photo`,
        headers: { ...me.headers, 'content-type': 'image/jpeg' }, payload: makeJpeg({ width: 100, height: 100 }),
      });
      expect(first.statusCode).toBe(200);
      const address = await limited.listen({ port: 0, host: '127.0.0.1' });
      expect(await statusFromHeadersOnly(address, pill.id, me.headers)).toBe(429);
    } finally {
      await limited.close();
    }
  });

  it('refuses an upload from a build that is too old before reading its body', async () => {
    const pill = await createPill();
    await superDb.execute(sql`UPDATE users SET minimum_client_build = 99 WHERE id = ${me.userId}::uuid`);
    const address = await app.listen({ port: 0, host: '127.0.0.1' });
    try {
      expect(await statusFromHeadersOnly(address, pill.id, me.headers)).toBe(426);
    } finally {
      await app.close();
      app = await buildApp({
        db: appDb,
        privateKey: process.env['JWT_PRIVATE_KEY']!,
        publicKey: process.env['JWT_PUBLIC_KEY']!,
      });
    }
  });

  it('refuses an unauthenticated upload before reading its body', async () => {
    const pill = await createPill();
    const address = await app.listen({ port: 0, host: '127.0.0.1' });
    const { port } = new URL(address);
    try {
      // Announce 500 KB but never send a byte of it: the answer must come from
      // the headers alone, so nothing was buffered for a caller with no account.
      const status = await new Promise<number>((resolve, reject) => {
        const request = httpRequest({
          host: '127.0.0.1', port: Number(port), method: 'PUT', path: `/api/v1/pills/${pill.id}/photo`,
          headers: { 'content-type': 'image/jpeg', 'content-length': '500000', 'X-Api-Key': me.headers['X-Api-Key']! },
        }, (response) => { response.resume(); resolve(response.statusCode ?? 0); request.destroy(); });
        request.on('error', (error) => { if ((error as NodeJS.ErrnoException).code !== 'ECONNRESET') reject(error); });
        request.flushHeaders();
        setTimeout(() => reject(new Error('no answer before the body was sent')), 5000).unref();
      });
      expect(status).toBe(401);
    } finally {
      await app.close();
      app = await buildApp({
        db: appDb,
        privateKey: process.env['JWT_PRIVATE_KEY']!,
        publicKey: process.env['JWT_PUBLIC_KEY']!,
      });
    }
  });
});
