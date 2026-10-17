import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { ZodError } from 'zod';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';
import { migrationIssues, schedules, syncChanges } from '../../db/schema.js';
import { ComponentSyncResponseSchema } from '../../modules/sync/sync.schema.js';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, createUnclaimedKey, truncateAll } from '../helpers/db-helpers.js';

let emailCounter = 0;

describe('sequence-bounded component sync', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let cleanup: () => Promise<void>;
  let bearer: Record<string, string>;
  let userId: string;

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
    const email = `component_sync_${Date.now()}_${++emailCounter}@test.com`;
    const register = await app.inject({
      method: 'POST', url: '/api/v1/auth/register', headers: { 'X-Api-Key': apiKey },
      payload: { email, password: 'password1234' },
    });
    expect(register.statusCode).toBe(201);
    userId = register.json<{ userId: string }>().userId;
    const login = await app.inject({
      method: 'POST', url: '/api/v1/auth/login', headers: { 'X-Api-Key': apiKey },
      payload: { email, password: 'password1234' },
    });
    expect(login.statusCode).toBe(200);
    bearer = { authorization: `Bearer ${login.json<{ accessToken: string }>().accessToken}`, 'X-Api-Key': apiKey, 'X-Simpastil-Client-Build': '2' };
  });

  afterEach(async () => truncateAll(superDb));

  afterAll(async () => {
    await app.close();
    await cleanup();
  });

  it('reports a server-built page that fails its own schema as 500 SYNC_PAYLOAD_INVALID', async () => {
    const spy = vi.spyOn(ComponentSyncResponseSchema, 'safeParse').mockReturnValueOnce({
      success: false,
      error: new ZodError([{ code: 'custom', path: ['items', 0, 'change'], message: 'canary-secret-detail' }]),
    });
    try {
      const res = await app.inject({ method: 'GET', url: '/api/v1/sync/account?contractVersion=2', headers: bearer });
      expect(res.statusCode).toBe(500);
      const error = res.json().error;
      expect(error.code).toBe('SYNC_PAYLOAD_INVALID');
      expect(error.code).not.toBe('VALIDATION_ERROR');
      expect(JSON.stringify(res.json())).not.toContain('canary-secret-detail');
    } finally {
      spy.mockRestore();
    }
    const again = await app.inject({ method: 'GET', url: '/api/v1/sync/account?contractVersion=2', headers: bearer });
    expect(again.statusCode).toBe(200);
  });

  it('returns the account component and preserves the signed-inactive split', async () => {
    const account = await app.inject({ method: 'GET', url: '/api/v1/sync/account?contractVersion=2', headers: bearer });
    expect(account.statusCode).toBe(200);
    expect(account.json().items.some((item: { change?: { payload?: { kind?: string } } }) => item.change?.payload?.kind === 'account')).toBe(true);

    const inactiveV2 = await app.inject({ method: 'GET', url: '/api/v1/sync/medication?contractVersion=2', headers: bearer });
    expect(inactiveV2.statusCode).toBe(409);
    expect(inactiveV2.json().error.code).toBe('CONTRACT_NOT_ACTIVE');
    const bridge = await app.inject({ method: 'GET', url: '/api/v1/sync/medication-bridge?contractVersion=1', headers: bearer });
    expect(bridge.statusCode).toBe(200);
    expect(bridge.json()).toMatchObject({ component: 'medicationBridge', contractVersion: 1, hasMore: false });
  });

  it('preserves v1/v2 and enriches v3 with exact live and deleted ancestors', async () => {
    const profileResponse = await app.inject({
      method: 'POST', url: '/api/v1/profiles', headers: bearer,
      payload: { mutationId: randomUUID(), name: 'Historical owner' },
    });
    expect(profileResponse.statusCode).toBe(201);
    const profileId = profileResponse.json<{ id: string }>().id;
    const pillResponse = await app.inject({
      method: 'POST', url: `/api/v1/profiles/${profileId}/pills`, headers: bearer,
      payload: { mutationId: randomUUID(), name: 'Historical medicine' },
    });
    expect(pillResponse.statusCode).toBe(201);
    const pillId = pillResponse.json<{ id: string }>().id;
    const scheduleId = randomUUID();
    const issueId = randomUUID();
    const timezoneIssueId = randomUUID();
    const doseId = randomUUID();
    const deletedScheduleId = randomUUID();
    const deletedTimezoneIssueId = randomUUID();
    const deletedDoseId = randomUUID();
    const createdAt = new Date('2026-06-16T06:00:00.000Z');
    const updatedAt = new Date('2026-06-16T06:05:00.000Z');
    const quarantineSource = {
      scheduleId,
      sourceScheduleRevision: '1',
      frequency: 'weekly',
      frequencyDays: [8],
      isActive: true,
      deletedAt: null,
      timeZoneStatus: 'legacy_unknown',
      timeZone: null,
    };
    const deletedAt = new Date('2026-06-17T06:05:00.000Z');
    await superDb.transaction(async (tx) => {
      await tx.execute(sql`SELECT set_config('app.current_user_id', ${userId}, true)`);
      await tx.insert(migrationIssues).values({
        id: issueId,
        userId,
        entityType: 'schedules',
        entityId: scheduleId,
        issueCode: 'invalid_schedule_frequency_days',
        safeSnapshot: quarantineSource,
      });
      await tx.insert(migrationIssues).values({
        id: timezoneIssueId,
        userId,
        entityType: 'schedules',
        entityId: scheduleId,
        issueCode: 'schedule_timezone_review_required',
        safeSnapshot: quarantineSource,
      });
      await tx.insert(schedules).values({
        id: scheduleId,
        pillId,
        hour: 8,
        minute: 15,
        frequency: 'weekly',
        frequencyDays: [8],
        isActive: false,
        revision: 1n,
        legacyQuarantineIssueId: issueId,
        legacyQuarantineOrigin: 'migration-0013',
        legacyQuarantineSource: quarantineSource,
        timeZoneStatus: 'legacy_unknown',
        timeZone: null,
        timezoneReviewIssueId: timezoneIssueId,
        createdAt,
        updatedAt,
      });
      await tx.insert(migrationIssues).values({
        id: deletedTimezoneIssueId,
        userId,
        entityType: 'schedules',
        entityId: deletedScheduleId,
        issueCode: 'schedule_timezone_review_required',
        safeSnapshot: {
          scheduleId: deletedScheduleId,
          frequency: 'daily',
          frequencyDays: null,
          isActive: false,
          deletedAt: deletedAt.toISOString(),
          timeZoneStatus: 'legacy_unknown',
          timeZone: null,
        },
      });
      await tx.insert(schedules).values({
        id: deletedScheduleId,
        pillId,
        hour: 9,
        minute: 30,
        frequency: 'daily',
        frequencyDays: null,
        isActive: false,
        deletedAt,
        revision: 1n,
        timeZoneStatus: 'legacy_unknown',
        timeZone: null,
        timezoneReviewIssueId: deletedTimezoneIssueId,
        createdAt,
        updatedAt: deletedAt,
      });
    });
    const storedChange = {
      schemaVersion: 2,
      component: 'medicationBridge',
      entityType: 'bridge_dose',
      entityId: doseId,
      operation: 'upsert',
      sourceIdentity: { sourceKind: 'legacy_dose_log', sourceId: doseId, sourceRevision: '1' },
      payload: {
        kind: 'bridgeDose',
        id: doseId,
        scheduleId,
        scheduledAt: '2026-06-16T06:15:00.000Z',
        takenAt: '2026-06-16T06:16:00.000Z',
        status: 'taken',
        deletedAt: null,
        sourceRevision: '1',
      },
    };
    const deletedChange = {
      schemaVersion: 2,
      component: 'medicationBridge',
      entityType: 'bridge_dose',
      entityId: deletedDoseId,
      operation: 'upsert',
      sourceIdentity: { sourceKind: 'legacy_dose_log', sourceId: deletedDoseId, sourceRevision: '1' },
      payload: {
        kind: 'bridgeDose', id: deletedDoseId, scheduleId: deletedScheduleId,
        scheduledAt: '2026-06-17T06:30:00.000Z', takenAt: null, status: 'missed',
        deletedAt: null, sourceRevision: '1',
      },
    };
    await superDb.transaction(async (tx) => {
      await tx.execute(sql`SELECT set_config('app.current_user_id', ${userId}, true)`);
      await tx.insert(syncChanges).values({
        userId,
        component: 'medicationBridge',
        entityType: 'bridge_dose',
        entityId: doseId,
        operation: 'upsert',
        sourceKind: 'legacy_dose_log',
        sourceId: doseId,
        sourceRevision: 1n,
        serverSequence: 100n,
        payloadSchemaVersion: 2,
        payload: storedChange,
      });
      await tx.insert(syncChanges).values({
        userId, component: 'medicationBridge', entityType: 'bridge_dose', entityId: deletedDoseId,
        operation: 'upsert', sourceKind: 'legacy_dose_log', sourceId: deletedDoseId,
        sourceRevision: 1n, serverSequence: 101n, payloadSchemaVersion: 2, payload: deletedChange,
      });
    });

    const v1Paged = await app.inject({ method: 'GET', url: '/api/v1/sync/medication-bridge?contractVersion=1&pageSize=1', headers: bearer });
    expect(v1Paged.statusCode).toBe(200);
    const v1Cursor = v1Paged.json<{ nextCursor: string }>().nextCursor;
    const mismatchedCursor = await app.inject({
      method: 'GET',
      url: `/api/v1/sync/medication-bridge?contractVersion=2&cursor=${encodeURIComponent(v1Cursor)}`,
      headers: bearer,
    });
    expect(mismatchedCursor.statusCode).toBe(400);

    const v1 = await app.inject({ method: 'GET', url: '/api/v1/sync/medication-bridge?contractVersion=1', headers: bearer });
    expect(v1.statusCode).toBe(200);
    const v1Items = v1.json().items as Array<{ change: { entityId: string; payload: Record<string, unknown> } }>;
    expect(v1Items.find((item) => item.change.entityId === doseId)?.change).toEqual(storedChange);
    expect(v1Items.every((item) => item.change.payload['parentSchedule'] === undefined)).toBe(true);

    const v2 = await app.inject({ method: 'GET', url: '/api/v1/sync/medication-bridge?contractVersion=2', headers: bearer });
    expect(v2.statusCode).toBe(200);
    const v2Items = v2.json().items as Array<{ change: { entityId: string; payload: { parentSchedule?: unknown } } }>;
    expect(v2Items.find((item) => item.change.entityId === doseId)?.change.payload.parentSchedule).toEqual({
      id: scheduleId,
      pillId,
      hour: 8,
      minute: 15,
      frequency: 'weekly',
      frequencyDays: [8],
      revision: '1',
      createdAt: createdAt.toISOString(),
      updatedAt: updatedAt.toISOString(),
      deletedAt: null,
      disposition: 'quarantined',
    });
    expect(v2Items.find((item) => item.change.entityId === deletedDoseId)?.change.payload.parentSchedule).toEqual({
      id: deletedScheduleId,
      pillId,
      hour: 9,
      minute: 30,
      frequency: 'daily',
      frequencyDays: null,
      revision: '1',
      createdAt: createdAt.toISOString(),
      updatedAt: deletedAt.toISOString(),
      deletedAt: deletedAt.toISOString(),
      disposition: 'deleted',
    });
    for (const item of v2Items) {
      expect(item.change.payload).not.toHaveProperty('parentPill');
      expect(item.change.payload).not.toHaveProperty('parentProfile');
    }
    const readV3 = () => app.inject({ method: 'GET', url: '/api/v1/sync/medication-bridge?contractVersion=3', headers: bearer });
    const v3 = await readV3();
    expect(v3.statusCode).toBe(200);
    const live = v3.json().items.find((item: { change: { entityId: string } }) => item.change.entityId === doseId).change.payload;
    expect(live.parentPill).toMatchObject({ kind: 'pill', id: pillId, profileId, name: 'Historical medicine', revision: '1', deletedAt: null });
    expect(live.parentProfile).toMatchObject({ kind: 'profile', id: profileId, userId, name: 'Historical owner', revision: '1', deletedAt: null });
    expect(live.parentSchedule).toEqual(v2Items.find((item) => item.change.entityId === doseId)!.change.payload.parentSchedule);
    for (const [from, to] of [[2, 3], [3, 2]]) {
      const paged = await app.inject({ method: 'GET', url: `/api/v1/sync/medication-bridge?contractVersion=${from}&pageSize=1`, headers: bearer });
      const response = await app.inject({ method: 'GET', url: `/api/v1/sync/medication-bridge?contractVersion=${to}&cursor=${encodeURIComponent(paged.json().nextCursor)}`, headers: bearer });
      expect(response.statusCode).toBe(400);
    }
    const deletePill = await app.inject({ method: 'DELETE', url: `/api/v1/profiles/${profileId}/pills/${pillId}`, headers: bearer, payload: { mutationId: randomUUID(), baseRevision: '1' } });
    expect(deletePill.statusCode).toBe(204);
    const deleteProfile = await app.inject({ method: 'DELETE', url: `/api/v1/profiles/${profileId}`, headers: bearer, payload: { mutationId: randomUUID(), baseRevision: '1' } });
    expect(deleteProfile.statusCode).toBe(204);
    const deleted = await readV3();
    expect(deleted.statusCode).toBe(200);
    const archived = deleted.json().items.find((item: { change: { entityId: string } }) => item.change.entityId === deletedDoseId).change.payload;
    expect(archived.parentPill).toMatchObject({ ...live.parentPill, revision: '2', deletedAt: expect.any(String), updatedAt: expect.any(String) });
    expect(archived.parentProfile).toMatchObject({ ...live.parentProfile, revision: '2', deletedAt: expect.any(String), updatedAt: expect.any(String) });
  });

  it('refuses a bridge parent that cannot be proven inside the requesting tenant', async () => {
    const otherKey = await createUnclaimedKey(superDb);
    const otherEmail = `other_${Date.now()}@test.com`;
    const other = await app.inject({
      method: 'POST', url: '/api/v1/auth/register', headers: { 'X-Api-Key': otherKey },
      payload: { email: otherEmail, password: 'password1234' },
    });
    expect(other.statusCode).toBe(201);
    const otherUserId = other.json<{ userId: string }>().userId;
    const otherLogin = await app.inject({
      method: 'POST', url: '/api/v1/auth/login', headers: { 'X-Api-Key': otherKey },
      payload: { email: otherEmail, password: 'password1234' },
    });
    expect(otherLogin.statusCode).toBe(200);
    const otherBearer = {
      authorization: `Bearer ${otherLogin.json<{ accessToken: string }>().accessToken}`,
      'X-Api-Key': otherKey,
      'X-Simpastil-Client-Build': '2',
    };
    const profileResponse = await app.inject({
      method: 'POST', url: '/api/v1/profiles', headers: otherBearer,
      payload: { mutationId: randomUUID(), name: 'Other owner' },
    });
    expect(profileResponse.statusCode).toBe(201);
    const profileId = profileResponse.json<{ id: string }>().id;
    const pillResponse = await app.inject({
      method: 'POST', url: `/api/v1/profiles/${profileId}/pills`, headers: otherBearer,
      payload: { mutationId: randomUUID(), name: 'Other medicine' },
    });
    expect(pillResponse.statusCode).toBe(201);
    const pillId = pillResponse.json<{ id: string }>().id;
    const scheduleId = randomUUID();
    const doseId = randomUUID();
    const issueId = randomUUID();
    const timezoneIssueId = randomUUID();
    const source = {
      scheduleId, sourceScheduleRevision: '1', frequency: 'weekly', frequencyDays: [8],
      isActive: true, deletedAt: null, timeZoneStatus: 'legacy_unknown', timeZone: null,
    };
    await superDb.transaction(async (tx) => {
      await tx.execute(sql`SELECT set_config('app.current_user_id', ${otherUserId}, true)`);
      await tx.insert(migrationIssues).values({
        id: issueId, userId: otherUserId, entityType: 'schedules', entityId: scheduleId,
        issueCode: 'invalid_schedule_frequency_days', safeSnapshot: source,
      });
      await tx.insert(migrationIssues).values({
        id: timezoneIssueId, userId: otherUserId, entityType: 'schedules', entityId: scheduleId,
        issueCode: 'schedule_timezone_review_required', safeSnapshot: source,
      });
      await tx.insert(schedules).values({
        id: scheduleId, pillId, hour: 8, minute: 0, frequency: 'weekly', frequencyDays: [8],
        isActive: false, legacyQuarantineIssueId: issueId, legacyQuarantineOrigin: 'migration-0013',
        legacyQuarantineSource: source, timeZoneStatus: 'legacy_unknown', timeZone: null,
        timezoneReviewIssueId: timezoneIssueId,
      });
    });
    const change = {
      schemaVersion: 2, component: 'medicationBridge', entityType: 'bridge_dose', entityId: doseId,
      operation: 'upsert',
      sourceIdentity: { sourceKind: 'legacy_dose_log', sourceId: doseId, sourceRevision: '1' },
      payload: {
        kind: 'bridgeDose', id: doseId, scheduleId, scheduledAt: '2026-06-16T06:15:00.000Z',
        takenAt: null, status: 'missed', deletedAt: null, sourceRevision: '1',
      },
    };
    await superDb.transaction(async (tx) => {
      await tx.execute(sql`SELECT set_config('app.current_user_id', ${userId}, true)`);
      await tx.insert(syncChanges).values({
        userId, component: 'medicationBridge', entityType: 'bridge_dose', entityId: doseId,
        operation: 'upsert', sourceKind: 'legacy_dose_log', sourceId: doseId,
        sourceRevision: 1n, serverSequence: 200n, payloadSchemaVersion: 2, payload: change,
      });
    });

    for (const contractVersion of [2, 3]) {
      const response = await app.inject({
        method: 'GET', url: `/api/v1/sync/medication-bridge?contractVersion=${contractVersion}`, headers: bearer,
      });
      expect(response.statusCode).toBe(500);
      expect(response.json().error.code).toBe('INTERNAL');
      expect(response.body).not.toContain('Other owner');
      expect(response.body).not.toContain('Other medicine');
    }
  });

  it('v4 replays and replenishes exact scheduled occurrences while older bridge views stay unchanged', async () => {
    const profileResponse = await app.inject({
      method: 'POST', url: '/api/v1/profiles', headers: bearer,
      payload: { mutationId: randomUUID(), name: 'Reviewed owner' },
    });
    expect(profileResponse.statusCode).toBe(201);
    const profileId = profileResponse.json<{ id: string }>().id;
    const pillResponse = await app.inject({
      method: 'POST', url: `/api/v1/profiles/${profileId}/pills`, headers: bearer,
      payload: { mutationId: randomUUID(), name: 'Reviewed medicine' },
    });
    expect(pillResponse.statusCode).toBe(201);
    const pillId = pillResponse.json<{ id: string }>().id;
    const now = new Date();
    const dateParts = new Intl.DateTimeFormat('en-US', {
      timeZone: 'Europe/Bucharest', year: 'numeric', month: '2-digit', day: '2-digit',
    }).formatToParts(now);
    const part = (type: Intl.DateTimeFormatPartTypes) =>
      dateParts.find((value) => value.type === type)!.value;
    const localDate = `${part('year')}-${part('month')}-${part('day')}`;
    const scheduleId = randomUUID();
    const issueId = randomUUID();
    await superDb.transaction(async (tx) => {
      await tx.execute(sql`SELECT set_config('app.current_user_id', ${userId}, true)`);
      await tx.insert(migrationIssues).values({
        id: issueId, userId, entityType: 'schedules', entityId: scheduleId,
        issueCode: 'schedule_timezone_review_required',
        safeSnapshot: {
          scheduleId, sourceScheduleRevision: '1', frequency: 'daily', frequencyDays: null,
          isActive: true, deletedAt: null, timeZoneStatus: 'legacy_unknown', timeZone: null,
        },
      });
      await tx.insert(schedules).values({
        id: scheduleId, pillId, hour: 23, minute: 59, frequency: 'daily', frequencyDays: null,
        isActive: true, revision: 1n, timeZoneStatus: 'legacy_unknown', timeZone: null,
        timezoneReviewIssueId: issueId,
      });
    });
    const repairMutationId = randomUUID();
    const rejectedEdit = await app.inject({
      method: 'PATCH', url: `/api/v1/pills/${pillId}/schedules/${scheduleId}`, headers: bearer,
      payload: { mutationId: repairMutationId, baseRevision: '1', hour: 23, minute: 59,
        frequency: 'daily', frequencyDays: null, isActive: true, timeZone: 'Europe/Bucharest' },
    });
    expect(rejectedEdit.statusCode).toBe(409);
    expect(rejectedEdit.json().error.code).toBe('SCHEDULE_TIMEZONE_REVIEW_REQUIRED');
    const repairPayload = {
      mutationId: repairMutationId, baseRevision: '1', effectiveFromLocalDate: localDate,
      schedule: { hour: 23, minute: 59, frequency: 'daily', frequencyDays: null,
        isActive: true, timeZone: 'Europe/Bucharest' },
    };
    const repair = await app.inject({
      method: 'POST', url: `/api/v1/pills/${pillId}/schedules/${scheduleId}/repair`, headers: bearer,
      payload: repairPayload,
    });
    expect(repair.statusCode, `${localDate} ${repair.body}`).toBe(200);
    expect(repair.json().revision).toBe('2');
    expect(repair.json().materializeFromLocalDate).toBe(localDate);
    const replay = await app.inject({
      method: 'POST', url: `/api/v1/pills/${pillId}/schedules/${scheduleId}/repair`, headers: bearer,
      payload: repairPayload,
    });
    expect(replay.statusCode).toBe(200);
    expect(replay.json()).toEqual(repair.json());
    const changedReplay = await app.inject({
      method: 'POST', url: `/api/v1/pills/${pillId}/schedules/${scheduleId}/repair`, headers: bearer,
      payload: { ...repairPayload, schedule: { ...repairPayload.schedule, minute: 58 } },
    });
    expect(changedReplay.statusCode).toBe(409);
    expect(changedReplay.json().error.code).toBe('CONFLICT_MUTATION_REUSE');

    for (const contractVersion of [1, 2, 3]) {
      const legacy = await app.inject({
        method: 'GET',
        url: `/api/v1/sync/medication-bridge?contractVersion=${contractVersion}`,
        headers: bearer,
      });
      expect(legacy.statusCode).toBe(200);
      expect(legacy.json().items.some(
        (item: { change?: { payload?: { kind?: string } } }) =>
          item.change?.payload?.kind === 'medicationOccurrence',
      )).toBe(false);
    }

    const v4 = await app.inject({
      method: 'GET', url: '/api/v1/sync/medication-bridge?contractVersion=4', headers: bearer,
    });
    expect(v4.statusCode).toBe(200);
    const body = v4.json<{
      throughSequence: string;
      items: Array<{ change: { component: string; entityId: string; payload: Record<string, unknown> } }>;
    }>();
    const occurrences = body.items.filter((item) => item.change.payload['kind'] === 'medicationOccurrence');
    expect(occurrences.length).toBeGreaterThan(0);
    expect(occurrences.every((item) =>
      item.change.component === 'medicationBridge'
      && item.change.payload['scheduleId'] === scheduleId
      && item.change.payload['pillId'] === pillId
      && item.change.payload['source'] === 'scheduled'
      && item.change.payload['provenance'] === 'exact'
      && item.change.payload['timeZone'] === 'Europe/Bucharest'
    )).toBe(true);
    expect(occurrences.some((item) => item.change.payload['scheduleRevision'] === '2')).toBe(true);
    expect(occurrences.some((item) => item.change.payload['plannedLocalDate'] === localDate)).toBe(true);

    const update = await app.inject({
      method: 'PATCH', url: `/api/v1/pills/${pillId}/schedules/${scheduleId}`, headers: bearer,
      payload: { mutationId: randomUUID(), baseRevision: '2', minute: 58 },
    });
    expect(update.statusCode).toBe(200);
    const delta = await app.inject({
      method: 'GET',
      url: `/api/v1/sync/medication-bridge?contractVersion=4&afterSequence=${body.throughSequence}`,
      headers: bearer,
    });
    expect(delta.statusCode).toBe(200);
    const deltaBody = delta.json<{
      throughSequence: string;
      items: Array<{ change: { payload: Record<string, unknown> } }>;
    }>();
    const changedOccurrences = deltaBody.items.filter(
      (item) => item.change.payload['kind'] === 'medicationOccurrence',
    );
    expect(changedOccurrences.some((item) => item.change.payload['scheduleRevision'] === '3')).toBe(true);
    expect(changedOccurrences.some((item) => item.change.payload['supersededAt'] !== null)).toBe(true);

    const repeated = await app.inject({
      method: 'GET',
      url: `/api/v1/sync/medication-bridge?contractVersion=4&afterSequence=${deltaBody.throughSequence}`,
      headers: bearer,
    });
    expect(repeated.statusCode).toBe(200);
    expect(repeated.json().items).toEqual([]);
    expect(repeated.json().throughSequence).toBe(deltaBody.throughSequence);
  });

  it('keeps continuations inside the first-page sequence boundary', async () => {
    const profileResponse = await app.inject({
      method: 'POST', url: '/api/v1/profiles', headers: bearer,
      payload: { mutationId: randomUUID(), name: 'Component profile' },
    });
    expect(profileResponse.statusCode).toBe(201);
    const profileId = profileResponse.json<{ id: string }>().id;
    const pillResponse = await app.inject({
      method: 'POST', url: `/api/v1/profiles/${profileId}/pills`, headers: bearer,
      payload: { mutationId: randomUUID(), name: 'Boundary pill' },
    });
    expect(pillResponse.statusCode).toBe(201);
    const pillId = pillResponse.json<{ id: string }>().id;

    const first = await app.inject({
      method: 'GET', url: '/api/v1/sync/stable?contractVersion=2&pageSize=1', headers: bearer,
    });
    expect(first.statusCode).toBe(200);
    expect(first.json().hasMore).toBe(true);
    expect(first.json().items[0].serverSequence).toMatch(/^[1-9]\d*$/);
    const cursor = first.json<{ nextCursor: string }>().nextCursor;

    const update = await app.inject({
      method: 'PATCH', url: `/api/v1/profiles/${profileId}/pills/${pillId}`, headers: bearer,
      payload: { mutationId: randomUUID(), baseRevision: '1', name: 'After boundary' },
    });
    expect(update.statusCode).toBe(200);

    const continuation = await app.inject({
      method: 'GET', url: `/api/v1/sync/stable?contractVersion=2&cursor=${encodeURIComponent(cursor)}`,
      headers: bearer,
    });
    expect(continuation.statusCode).toBe(200);
    const continuationItems = continuation.json<{ items: Array<{ change: { payload: { id?: string; name?: string } } }> }>().items;
    expect(continuationItems.some((item) => item.change.payload.id === pillId && item.change.payload.name === 'After boundary')).toBe(false);

    const checkpoint = continuation.json<{ throughSequence: string }>().throughSequence;
    const resumed = await app.inject({
      method: 'GET',
      url: `/api/v1/sync/stable?contractVersion=2&afterSequence=${checkpoint}`,
      headers: bearer,
    });
    expect(resumed.statusCode).toBe(200);
    const resumedItems = resumed.json<{ items: Array<{ serverSequence: string; change: { payload: { id?: string; name?: string } } }> }>().items;
    expect(resumedItems.some((item) => item.change.payload.id === pillId && item.change.payload.name === 'After boundary')).toBe(true);
    expect(resumedItems.every((item) => BigInt(item.serverSequence) > BigInt(checkpoint))).toBe(true);
  });
});
