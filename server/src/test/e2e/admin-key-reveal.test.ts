import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, prepareBootstrapProof, truncateAll, createUnclaimedKey } from '../helpers/db-helpers.js';
import { auditLogs } from '../../db/schema.js';
import { desc, eq } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';

describe('admin key reveal', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    app = await buildApp({
      db: appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey: process.env['JWT_PUBLIC_KEY']!,
      withErrorHandler: true,
    });
  });

  afterAll(async () => {
    await app.close();
    await cleanup();
  });

  afterEach(async () => {
    await truncateAll(superDb);
  });

  async function adminSetup() {
    const proof = await prepareBootstrapProof(superDb);
    return app.inject({ method: 'POST', url: '/api/v1/admin/setup', payload: { email: 'admin@test.com', password: 'adminpassword1234', proof } });
  }

  async function adminLogin() {
    const res = await app.inject({ method: 'POST', url: '/api/v1/admin/auth/login', payload: { password: 'adminpassword1234' } });
    return res.json<{ accessToken: string }>().accessToken;
  }

  it('GET /admin/keys/:id/reveal requires authentication', async () => {
    const res = await app.inject({ method: 'GET', url: '/api/v1/admin/keys/fake-id/reveal' });
    expect(res.statusCode).toBe(401);
  });

  it('GET /admin/keys requires admin token', async () => {
    const res = await app.inject({ method: 'GET', url: '/api/v1/admin/keys' });
    expect(res.statusCode).toBe(401);
  });

  it('reveals a newly created key and returns the raw value', async () => {
    await adminSetup();
    const token = await adminLogin();

    const createRes = await app.inject({
      method: 'POST', url: '/api/v1/admin/keys',
      headers: { Authorization: `Bearer ${token}` },
      payload: { label: 'reveal-test' },
    });
    expect(createRes.statusCode).toBe(201);
    const { rawKey: createdKey, keyId } = createRes.json<{ rawKey: string; keyId: string }>();
    expect(createdKey).toHaveLength(64);
    expect(keyId).toMatch(/^[0-9a-f-]{36}$/);

    const revealRes = await app.inject({
      method: 'GET', url: `/api/v1/admin/keys/${keyId}/reveal`,
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(revealRes.statusCode).toBe(200);
    const { rawKey: revealedKey } = revealRes.json<{ rawKey: string }>();
    expect(revealedKey).toBe(createdKey);
  });

  it('writes an audit log entry on reveal', async () => {
    await adminSetup();
    const token = await adminLogin();

    const createRes = await app.inject({
      method: 'POST', url: '/api/v1/admin/keys',
      headers: { Authorization: `Bearer ${token}` },
      payload: { label: 'audit-test' },
    });
    const { keyId } = createRes.json<{ keyId: string }>();

    await app.inject({
      method: 'GET', url: `/api/v1/admin/keys/${keyId}/reveal`,
      headers: { Authorization: `Bearer ${token}` },
    });

    const logs = await superDb
      .select()
      .from(auditLogs)
      .where(eq(auditLogs.action, 'key.reveal'))
      .orderBy(desc(auditLogs.createdAt));

    expect(logs).toHaveLength(1);
    expect(logs[0]!.targetType).toBe('api_key');
    expect(logs[0]!.targetId).toBe(keyId);
    expect(logs[0]!.actor).toBe('admin');
  });

  it('returns null for legacy keys without encrypted_key', async () => {
    await adminSetup();
    const token = await adminLogin();

    // createUnclaimedKey inserts directly via DB — no encrypted_key column set
    const legacyRawKey = await createUnclaimedKey(superDb, 'legacy-key');
    // Find the key's ID
    const listRes = await app.inject({
      method: 'GET', url: '/api/v1/admin/keys',
      headers: { Authorization: `Bearer ${token}` },
    });
    const legacyKey = listRes.json<{ keys: { id: string; label: string }[] }>()
      .keys.find(k => k.label === 'legacy-key');
    expect(legacyKey).toBeTruthy();

    const revealRes = await app.inject({
      method: 'GET', url: `/api/v1/admin/keys/${legacyKey!.id}/reveal`,
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(revealRes.statusCode).toBe(200);
    expect(revealRes.json<{ rawKey: string | null }>().rawKey).toBeNull();
  });
});
