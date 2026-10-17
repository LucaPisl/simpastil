import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, truncateAll, createUnclaimedKey } from '../helpers/db-helpers.js';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';
import { sql as drizzleSql } from 'drizzle-orm';
import { randomUUID } from 'node:crypto';

describe('RLS cross-user isolation', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    app = await buildApp({
      db: appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey:  process.env['JWT_PUBLIC_KEY']!,
    });
  });

  afterAll(async () => {
    await app.close();
    await cleanup();
  });

  afterEach(async () => truncateAll(superDb));

  // ── helpers ──────────────────────────────────────────────────────────────

  async function registerAndLogin(email: string) {
    const key = await createUnclaimedKey(superDb);
    await app.inject({
      method: 'POST', url: '/api/v1/auth/register',
      headers: { 'X-Api-Key': key },
      payload: { email, password: 'securepass123' },
    });
    const res = await app.inject({
      method: 'POST', url: '/api/v1/auth/login',
      headers: { 'X-Api-Key': key },
      payload: { email, password: 'securepass123' },
    });
    return { ...res.json<{ accessToken: string; refreshToken: string }>(), apiKey: key };
  }

  function auth(token: string, apiKey: string) {
    return {
      authorization: `Bearer ${token}`,
      'X-Api-Key': apiKey,
      'x-simpastil-client-build': '2',
    };
  }

  // ── test ─────────────────────────────────────────────────────────────────

  it('user B cannot access user A\'s resources and legacy writes stay bridge-blocked', async () => {
    const { accessToken: tokenA, apiKey: keyA } = await registerAndLogin('a@example.com');
    const { accessToken: tokenB, apiKey: keyB } = await registerAndLogin('b@example.com');

    // User A creates the full data chain.
    const profileResponse = await app.inject({
      method: 'POST', url: '/api/v1/profiles',
      headers: auth(tokenA, keyA),
      payload: { mutationId: randomUUID(), name: 'Alice', avatarEmoji: '💊' },
    });
    expect(profileResponse.statusCode, profileResponse.body).toBe(201);
    const profileId = profileResponse.json<{ id: string }>().id;

    const pillResponse = await app.inject({
      method: 'POST', url: `/api/v1/profiles/${profileId}/pills`,
      headers: auth(tokenA, keyA),
      payload: { mutationId: randomUUID(), name: 'Aspirin', dosage: '100mg' },
    });
    expect(pillResponse.statusCode, pillResponse.body).toBe(201);
    const pillId = pillResponse.json<{ id: string }>().id;

    const scheduleResponse = await app.inject({
      method: 'POST', url: `/api/v1/pills/${pillId}/schedules`,
      headers: auth(tokenA, keyA),
      payload: {
        mutationId: randomUUID(),
        frequency: 'daily',
        hour: 8,
        minute: 0,
        timeZone: 'UTC',
      },
    });
    expect(scheduleResponse.statusCode, scheduleResponse.body).toBe(201);
    const scheduleId = scheduleResponse.json<{ id: string }>().id;

    const splitDoseWrite = await app.inject({
      method: 'POST', url: `/api/v1/logs/${scheduleId}`,
      headers: auth(tokenA, keyA),
      payload: { status: 'taken', scheduledAt: '2026-03-23T08:00:00+00:00' },
    });
    expect(splitDoseWrite.statusCode).toBe(409);
    expect(splitDoseWrite.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');

    // User B attempts to access / mutate each of User A's resources.
    const cases: Array<{
      method: string;
      url: string;
      payload?: unknown;
      expectedStatus?: number;
    }> = [
      { method: 'GET',    url: `/api/v1/profiles/${profileId}/pills` },
      { method: 'GET',    url: `/api/v1/pills/${pillId}/schedules` },
      { method: 'GET',    url: `/api/v1/profiles/${profileId}/logs` },
      {
        method: 'DELETE',
        url: `/api/v1/profiles/${profileId}`,
        payload: { mutationId: randomUUID(), baseRevision: '1' },
      },
      { method: 'POST',   url: `/api/v1/profiles/${profileId}/pills`,
        payload: { mutationId: randomUUID(), name: 'Evil' } },
      { method: 'POST',   url: `/api/v1/pills/${pillId}/schedules`,
        payload: {
          mutationId: randomUUID(),
          frequency: 'daily',
          hour: 9,
          minute: 0,
          timeZone: 'UTC',
        } },
      { method: 'POST',   url: `/api/v1/logs/${scheduleId}`,
        payload: { status: 'taken', scheduledAt: '2026-03-23T09:00:00+00:00' },
        expectedStatus: 409 },
    ];

    for (const c of cases) {
      const res = await app.inject({
        method: c.method as 'GET' | 'POST' | 'DELETE',
        url: c.url,
        headers: auth(tokenB, keyB),
        payload: c.payload,
      });
      const expectedStatus = c.expectedStatus ?? 404;
      expect(
        res.statusCode,
        `${c.method} ${c.url} should be ${expectedStatus}, got ${res.statusCode}`,
      ).toBe(expectedStatus);
      if (expectedStatus === 409) {
        expect(res.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
      }
    }
  });

  it('allows bounded outbox enqueue but denies API reads, claims, and authority mutation', async () => {
    await expect(appDb.execute(
      drizzleSql`INSERT INTO outbox_messages (
        message_type, recipient_ref, encrypted_delivery_payload, state,
        attempt_count, next_attempt_at, expires_at
      ) VALUES ('password_reset', 'rls-test-recipient', 'sealed', 'queued', 0,
        now(), now() + interval '30 minutes')`,
    )).resolves.toBeDefined();

    await expect(appDb.execute(
      drizzleSql`SELECT encrypted_delivery_payload FROM outbox_messages`,
    )).rejects.toThrow();
    await expect(appDb.execute(
      drizzleSql`UPDATE outbox_messages SET state = 'sending'`,
    )).rejects.toThrow();
    await expect(appDb.execute(
      drizzleSql`UPDATE deployment_manifest SET enforced_minimum_client_build = 2`,
    )).rejects.toThrow();
    await expect(appDb.execute(
      drizzleSql`INSERT INTO deployment_authority_events (
        old_contract_version, new_contract_version,
        event_type, old_ledger_activated, new_ledger_activated,
        old_enforced_minimum_client_build, new_enforced_minimum_client_build,
        change_reference
      ) VALUES (1, 1, 'minimum_client_build', false, false, 1, 2, 'rls-forbidden')`,
    )).rejects.toThrow();
  });
});
