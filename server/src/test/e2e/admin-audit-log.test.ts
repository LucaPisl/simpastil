import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, prepareBootstrapProof, truncateAll } from '../helpers/db-helpers.js';
import { auditLogs } from '../../db/schema.js';
import type { Db } from '../../db/client.js';

const ADMIN_PASSWORD = 'adminpassword1234';

interface Page { logs: Array<{ action: string; createdAt: string; ipAddress: string | null }>; hasMore: boolean }

describe('admin audit log listing', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    const keys = { privateKey: process.env['JWT_PRIVATE_KEY']!, publicKey: process.env['JWT_PUBLIC_KEY']! };
    app = await buildApp({ db: appDb, ...keys, ttlSeconds: 600 });
  });

  afterAll(async () => {
    await app.close();
    await cleanup();
  });
  afterEach(async () => { await truncateAll(superDb); });

  async function token(): Promise<string> {
    const proof = await prepareBootstrapProof(superDb);
    await app.inject({
      method: 'POST', url: '/api/v1/admin/setup',
      payload: { email: 'admin@test.com', password: ADMIN_PASSWORD, proof },
    });
    const res = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/login', payload: { password: ADMIN_PASSWORD },
    });
    return res.json().accessToken as string;
  }

  /** Replace everything the sign-in wrote with a known history, one entry a day. */
  async function seed(): Promise<void> {
    await superDb.delete(auditLogs);
    const day = (n: number) => new Date(Date.UTC(2026, 9, n, 12, 0, 0));
    await superDb.insert(auditLogs).values([
      { actor: 'admin', action: 'key.create', targetType: 'api_key', targetId: 'k1', createdAt: day(1), metadata: { label: 'Kitchen' } },
      { actor: 'admin', action: 'key.revoke', targetType: 'api_key', targetId: 'k1', createdAt: day(2) },
      { actor: 'admin', action: 'key.create', targetType: 'api_key', targetId: 'k2', createdAt: day(3) },
      { actor: 'admin', action: 'user.delete', targetType: 'user', targetId: 'u1', createdAt: day(4) },
      { actor: 'admin', action: 'admin.login', targetType: 'admin', targetId: null, createdAt: day(5), ipAddress: '203.0.113.9' },
    ]);
  }

  const list = async (accessToken: string, query: string): Promise<Page> => {
    const res = await app.inject({
      method: 'GET', url: `/api/v1/admin/audit-logs?${query}`, headers: { authorization: `Bearer ${accessToken}` },
    });
    expect(res.statusCode).toBe(200);
    expect(res.headers['cache-control']).toBe('no-store');
    return res.json<Page>();
  };

  it('pages newest first and says whether another page follows', async () => {
    const t = await token();
    await seed();

    const first = await list(t, 'limit=2');
    expect(first.logs.map((l) => l.action)).toEqual(['admin.login', 'user.delete']);
    expect(first.hasMore).toBe(true);

    const second = await list(t, 'limit=2&offset=2');
    expect(second.logs.map((l) => l.action)).toEqual(['key.create', 'key.revoke']);
    expect(second.hasMore).toBe(true);

    const last = await list(t, 'limit=2&offset=4');
    expect(last.logs.map((l) => l.action)).toEqual(['key.create']);
    expect(last.hasMore).toBe(false);

    const exact = await list(t, 'limit=5');
    expect(exact.logs).toHaveLength(5);
    expect(exact.hasMore).toBe(false);
  });

  it('filters by action and by time range, together', async () => {
    const t = await token();
    await seed();

    expect((await list(t, 'action=key.create')).logs).toHaveLength(2);
    // `from` is inclusive, `to` is exclusive.
    const range = await list(t, `from=${encodeURIComponent('2026-10-02T12:00:00.000Z')}&to=${encodeURIComponent('2026-10-04T12:00:00.000Z')}`);
    expect(range.logs.map((l) => l.action)).toEqual(['key.create', 'key.revoke']);
    const both = await list(t, `action=key.create&from=${encodeURIComponent('2026-10-02T00:00:00Z')}`);
    expect(both.logs).toHaveLength(1);
    expect((await list(t, 'action=nothing.like.this')).logs).toEqual([]);
  });

  it('rejects a malformed date or an out-of-range page', async () => {
    const t = await token();
    for (const query of ['from=yesterday', 'to=2026-10-01', 'limit=0', 'limit=201', 'offset=-1']) {
      const res = await app.inject({
        method: 'GET', url: `/api/v1/admin/audit-logs?${query}`, headers: { authorization: `Bearer ${t}` },
      });
      expect(res.statusCode, query).toBe(400);
    }
  });
});
