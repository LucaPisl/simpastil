import { describe, expect, it } from 'vitest';
import { serializeSyncChangePayload, SyncChangePayloadV2Schema } from '../../modules/sync/sync-payload.js';
import { ComponentSyncResponseSchema } from '../../modules/sync/sync.schema.js';

const dose = {
  schemaVersion: 2,
  component: 'medicationBridge',
  entityType: 'bridge_dose',
  entityId: '10000000-0000-4000-8000-000000000001',
  operation: 'upsert',
  sourceIdentity: {
    sourceKind: 'legacy_dose_log',
    sourceId: '10000000-0000-4000-8000-000000000001',
    sourceRevision: '1',
  },
  payload: {
    kind: 'bridgeDose',
    id: '10000000-0000-4000-8000-000000000001',
    scheduleId: '20000000-0000-4000-8000-000000000002',
    scheduledAt: '2026-06-16T06:15:00.000Z',
    takenAt: null,
    status: 'missed',
    deletedAt: null,
    sourceRevision: '1',
  },
} as const;

const parent = {
  id: dose.payload.scheduleId,
  pillId: '30000000-0000-4000-8000-000000000003',
  hour: 8,
  minute: 15,
  frequency: 'weekly',
  frequencyDays: [8, 8],
  revision: '1',
  createdAt: '2026-06-16T06:00:00.000Z',
  updatedAt: '2026-06-16T06:05:00.000Z',
  deletedAt: null,
  disposition: 'quarantined',
} as const;

const profile = {
  kind: 'profile', id: '40000000-0000-4000-8000-000000000004',
  userId: '50000000-0000-4000-8000-000000000005', name: 'Fictional owner',
  avatarEmoji: '🙂', isActive: false, revision: '2',
  deletedAt: '2026-06-17T06:00:00.000Z',
  createdAt: parent.createdAt, updatedAt: '2026-06-17T06:00:00.000Z',
} as const;
const pill = {
  kind: 'pill', id: parent.pillId, profileId: profile.id,
  name: 'Fictional historical medicine', dosage: 'Legacy text', notes: null,
  color: null, currentStock: -1, lowStockThreshold: 0, isPrn: false,
  revision: '2', deletedAt: profile.deletedAt,
  createdAt: parent.createdAt, updatedAt: profile.updatedAt,
} as const;
const ancestors = { parentSchedule: parent, parentProfile: profile, parentPill: pill };
const response = (contractVersion: number, metadata: Record<string, unknown>) => ({
  component: 'medicationBridge', contractVersion,
  afterSequence: '0', throughSequence: '1', nextCursor: null, hasMore: false,
  items: [{ serverSequence: '1', change: { ...dose, payload: { ...dose.payload, ...metadata } } }],
});

describe('bridge parent contract', () => {
  it('v3 preserves complete deleted ancestors and keeps them response-only', () => {
    const parsed = ComponentSyncResponseSchema.parse(response(3, ancestors));
    expect(parsed.items[0]!.change.payload).toMatchObject(ancestors);
    expect(() => serializeSyncChangePayload(parsed.items[0]!.change)).toThrow('response-only');
    expect(() => ComponentSyncResponseSchema.parse(response(3, {}))).not.toThrow();
  });

  it('v3 ancestry is all-or-none, exact-chain and unavailable in v1/v2', () => {
    for (const metadata of [
      { parentSchedule: parent },
      { parentSchedule: parent, parentPill: pill },
      { parentProfile: profile, parentPill: pill },
      { ...ancestors, parentPill: { ...pill, profileId: parent.id } },
      { ...ancestors, parentPill: { ...pill, id: profile.id } },
    ]) expect(() => ComponentSyncResponseSchema.parse(response(3, metadata))).toThrow();
    for (const version of [1, 2]) {
      expect(() => ComponentSyncResponseSchema.parse(response(version, ancestors))).toThrow();
    }
  });
  it('preserves bounded invalid weekday evidence without requiring the optional parent', () => {
    expect(SyncChangePayloadV2Schema.parse(dose).payload).not.toHaveProperty('parentSchedule');
    const parsed = SyncChangePayloadV2Schema.parse({
      ...dose,
      payload: { ...dose.payload, parentSchedule: parent },
    });
    expect(parsed.payload).toMatchObject({ parentSchedule: { frequencyDays: [8, 8] } });
    expect(() => serializeSyncChangePayload(parsed)).toThrow('response-only');
  });

  it('rejects null, mismatched, and disposition-inconsistent parents', () => {
    expect(() => SyncChangePayloadV2Schema.parse({
      ...dose,
      payload: { ...dose.payload, parentSchedule: null },
    })).toThrow();
    expect(() => SyncChangePayloadV2Schema.parse({
      ...dose,
      payload: { ...dose.payload, parentSchedule: { ...parent, id: '40000000-0000-4000-8000-000000000004' } },
    })).toThrow();
    expect(() => SyncChangePayloadV2Schema.parse({
      ...dose,
      payload: { ...dose.payload, parentSchedule: { ...parent, disposition: 'deleted' } },
    })).toThrow();
  });
});
