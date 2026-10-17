import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import { randomUUID } from 'node:crypto';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, truncateAll, createUnclaimedKey } from '../helpers/db-helpers.js';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';

interface LogEntry {
  id: string;
  status: string;
  deletedAt: string | null;
  updatedAt: string;
  scheduledAt: string;
}
interface LogsResponse {
  logs: LogEntry[];
  nextCursor: string | null;
  serverTime: string;
}

let emailCounter = 0;

async function setupUserWithResources(
  app: FastifyInstance,
  superDb: Db,
) {
  const apiKey = await createUnclaimedKey(superDb);
  const email = `delta_${Date.now()}_${++emailCounter}@test.com`;
  const regRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/register',
    headers: { 'X-Api-Key': apiKey },
    payload: { email, password: 'password1234' },
  });
  if (regRes.statusCode !== 201) {
    throw new Error(`Register failed: ${regRes.statusCode} ${regRes.body}`);
  }
  const loginRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/login',
    headers: { 'X-Api-Key': apiKey },
    payload: { email, password: 'password1234' },
  });
  if (loginRes.statusCode !== 200) {
    throw new Error(`Login failed: ${loginRes.statusCode} ${loginRes.body}`);
  }
  const { accessToken } = loginRes.json<{ accessToken: string }>();

  const bearer = { authorization: `Bearer ${accessToken}`, 'X-Api-Key': apiKey };

  const { id: profileId } = (
    await app.inject({
      method: 'POST',
      url: '/api/v1/profiles',
      headers: bearer,
      payload: { mutationId: randomUUID(), name: 'TestProfile' },
    })
  ).json<{ id: string }>();

  const { id: pillId } = (
    await app.inject({
      method: 'POST',
      url: `/api/v1/profiles/${profileId}/pills`,
      headers: bearer,
      payload: { mutationId: randomUUID(), name: 'TestPill' },
    })
  ).json<{ id: string }>();

  const { id: scheduleId } = (
    await app.inject({
      method: 'POST',
      url: `/api/v1/pills/${pillId}/schedules`,
      headers: bearer,
      payload: {
        mutationId: randomUUID(),
        frequency: 'daily',
        hour: 8,
        minute: 0,
        timeZone: 'UTC',
      },
    })
  ).json<{ id: string }>();
  return { bearer, profileId, pillId, scheduleId, logId: randomUUID(), apiKey };
}

describe('delta sync & dose_log tombstones (M-14, M-15)', () => {
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
    });
  });

  afterAll(async () => {
    await app.close();
    await cleanup();
  });

  afterEach(async () => truncateAll(superDb));

  // Split legacy dose writes are deliberately disabled; clients must submit
  // one atomic medication command so mutation receipts and ledger effects agree.

  it('rejects legacy dose deletion and directs clients to the medication bridge', async () => {
    const { bearer, logId } = await setupUserWithResources(app, superDb);

    const delRes = await app.inject({
      method: 'DELETE',
      url: `/api/v1/logs/${logId}`,
      headers: bearer,
    });
    expect(delRes.statusCode).toBe(409);
    expect(delRes.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
  });

  it('delta reads retain a stable empty response when no legacy writes are accepted', async () => {
    const { bearer, logId, profileId } = await setupUserWithResources(app, superDb);
    const delRes = await app.inject({
      method: 'DELETE',
      url: `/api/v1/logs/${logId}`,
      headers: bearer,
    });
    expect(delRes.statusCode).toBe(409);
    const deltaRes = await app.inject({
      method: 'GET',
      url: `/api/v1/profiles/${profileId}/logs`,
      headers: bearer,
      query: { since: new Date(Date.now() - 1000).toISOString(), limit: '500' },
    });
    expect(deltaRes.statusCode).toBe(200);
    const deltaBody = deltaRes.json<LogsResponse>();
    expect(deltaBody.logs).toEqual([]);
    expect(deltaBody.serverTime).toBeTruthy();
    expect(deltaBody.nextCursor).toBeNull();
  });

  it('repeated legacy DELETE remains rejected rather than creating a split receipt', async () => {
    const { bearer, logId } = await setupUserWithResources(app, superDb);

    await app.inject({
      method: 'DELETE',
      url: `/api/v1/logs/${logId}`,
      headers: bearer,
    });
    const secondDel = await app.inject({
      method: 'DELETE',
      url: `/api/v1/logs/${logId}`,
      headers: bearer,
    });
    expect(secondDel.statusCode).toBe(409);
    expect(secondDel.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
  });

  it('rejects legacy dose PATCH requests', async () => {
    const { bearer, logId } = await setupUserWithResources(app, superDb);
    const patchRes = await app.inject({
      method: 'PATCH',
      url: `/api/v1/logs/${logId}`,
      headers: bearer,
      payload: { status: 'missed' },
    });
    expect(patchRes.statusCode).toBe(409);
    expect(patchRes.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
  });

  it('rejects legacy dose POST requests even when the client supplies an id', async () => {
    const { bearer, logId, scheduleId } = await setupUserWithResources(app, superDb);
    const repost = await app.inject({
      method: 'POST',
      url: `/api/v1/logs/${scheduleId}`,
      headers: bearer,
      payload: {
        id: logId,
        status: 'taken',
        scheduledAt: '2026-06-15T08:00:00+00:00',
        takenAt: '2026-06-15T08:05:00+00:00',
      },
    });
    expect(repost.statusCode).toBe(409);
    expect(repost.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
  });

  // Read-only legacy log pulls remain available during compatibility rollout.

  it('first sync (no since) returns a complete empty pull', async () => {
    const { bearer, profileId } = await setupUserWithResources(app, superDb);

    const res = await app.inject({
      method: 'GET',
      url: `/api/v1/profiles/${profileId}/logs`,
      headers: bearer,
    });
    const body = res.json<LogsResponse>();
    expect(body.logs).toEqual([]);
    expect(body.serverTime).toBeTruthy();
    expect(body.nextCursor).toBeNull();
  });

  it('delta pull with since returns the same response contract for an empty pull', async () => {
    const { bearer, profileId, scheduleId } = await setupUserWithResources(app, superDb);
    const watermark = new Date(Date.now() - 500).toISOString();
    const secondLog = await app.inject({
      method: 'POST',
      url: `/api/v1/logs/${scheduleId}`,
      headers: bearer,
      payload: { status: 'taken', scheduledAt: '2026-06-16T08:00:00+00:00' },
    });
    expect(secondLog.statusCode).toBe(409);
    expect(secondLog.json().error.code).toBe('MEDICATION_BRIDGE_REQUIRED');
    const deltaRes = await app.inject({
      method: 'GET',
      url: `/api/v1/profiles/${profileId}/logs`,
      headers: bearer,
      query: { since: watermark },
    });
    expect(deltaRes.statusCode).toBe(200);
    const deltaBody = deltaRes.json<LogsResponse>();
    expect(deltaBody.logs).toEqual([]);
    expect(deltaBody.serverTime).toBeTruthy();
  });

  it('empty pages do not advertise a continuation cursor', async () => {
    const { bearer, profileId } = await setupUserWithResources(app, superDb);
    const sinceEpoch = new Date('2020-01-01').toISOString();
    const page1 = await app.inject({
      method: 'GET',
      url: `/api/v1/profiles/${profileId}/logs`,
      headers: bearer,
      query: { since: sinceEpoch, limit: '2' },
    });
    expect(page1.statusCode).toBe(200);
    const p1 = page1.json<LogsResponse>();
    expect(p1.logs).toEqual([]);
    expect(p1.nextCursor).toBeNull();
  });

  it('since cannot be combined with offset', async () => {
    const { bearer, profileId } = await setupUserWithResources(app, superDb);

    const res = await app.inject({
      method: 'GET',
      url: `/api/v1/profiles/${profileId}/logs`,
      headers: bearer,
      query: { since: '2026-01-01T00:00:00Z', offset: '10' },
    });
    expect(res.statusCode).toBe(400);
  });

  it('cursor requires since', async () => {
    const { bearer, profileId } = await setupUserWithResources(app, superDb);

    const res = await app.inject({
      method: 'GET',
      url: `/api/v1/profiles/${profileId}/logs`,
      headers: bearer,
      query: { cursor: '2026-01-01T00:00:00.000Z_00000000-0000-0000-0000-000000000000' },
    });
    expect(res.statusCode).toBe(400);
  });

  it('legacy mode date filters retain the response contract', async () => {
    const { bearer, profileId } = await setupUserWithResources(app, superDb);

    const res = await app.inject({
      method: 'GET',
      url: `/api/v1/profiles/${profileId}/logs`,
      headers: bearer,
      query: { date: '2026-06-15' },
    });
    expect(res.statusCode).toBe(200);
    const body = res.json<LogsResponse>();
    expect(body.logs).toEqual([]);
    expect(body.serverTime).toBeTruthy();
  });

  it('legacy mode remains readable after a rejected split-write request', async () => {
    const { bearer, logId, profileId } = await setupUserWithResources(app, superDb);
    const deleted = await app.inject({
      method: 'DELETE',
      url: `/api/v1/logs/${logId}`,
      headers: bearer,
    });
    expect(deleted.statusCode).toBe(409);

    const res = await app.inject({
      method: 'GET',
      url: `/api/v1/profiles/${profileId}/logs`,
      headers: bearer,
    });
    expect(res.statusCode).toBe(200);
    const body = res.json<LogsResponse>();
    expect(body.logs.length).toBe(0);
  });

  it('delta sync response includes serverTime', async () => {
    const { bearer, profileId } = await setupUserWithResources(app, superDb);

    const res = await app.inject({
      method: 'GET',
      url: `/api/v1/profiles/${profileId}/logs`,
      headers: bearer,
      query: { since: '2020-01-01T00:00:00Z' },
    });
    expect(res.statusCode).toBe(200);
    const body = res.json<LogsResponse>();
    expect(body.serverTime).toBeTruthy();
    const serverDate = new Date(body.serverTime);
    expect(serverDate.getTime()).toBeGreaterThan(Date.now() - 60_000);
    expect(serverDate.getTime()).toBeLessThanOrEqual(Date.now() + 1_000);
  });
});
