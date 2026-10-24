import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  calculateScheduledOccurrenceSlots,
  type ScheduledOccurrenceSource,
} from './occurrence-materializer.js';
import { SyncChangePayloadV2Schema, canonicalJson } from '../sync/sync-payload.js';

const contractsDir = join(dirname(fileURLToPath(import.meta.url)), '../../../../contracts');
const fixtures = JSON.parse(readFileSync(join(contractsDir, 'fixtures/occurrence-materializer-v3.json'), 'utf8')) as {
  cases: Array<{
    id: string;
    frequency: ScheduledOccurrenceSource['frequency'];
    frequencyDays?: number[];
    everyDays?: number;
    anchorDate?: string;
    startDate?: string;
    endDate?: string | null;
    timeZone?: string;
    hour?: number;
    minute?: number;
    from: string;
    through: string;
    expectedLocalDates: string[];
    expectedInstants?: Record<string, string>;
  }>;
  snapshotV3: Record<string, unknown>;
  syncSchedulePayload: Record<string, Record<string, unknown>>;
};

function source(overrides: Partial<ScheduledOccurrenceSource> = {}): ScheduledOccurrenceSource {
  return {
    id: '22222222-2222-4222-8222-222222222222',
    userId: '11111111-1111-4111-8111-111111111111',
    revision: 1n,
    pillId: '44444444-4444-4444-8444-444444444444',
    hour: 8,
    minute: 30,
    frequency: 'daily',
    frequencyDays: null,
    isActive: true,
    deletedAt: null,
    legacyQuarantineIssueId: null,
    timeZoneStatus: 'known',
    timeZone: 'Europe/Bucharest',
    materializeFromLocalDate: null,
    updatedAt: new Date('2026-01-01T00:00:00Z'),
    pillName: 'Example medication',
    dosage: '10mg',
    profileId: '33333333-3333-4333-8333-333333333333',
    profileName: 'Example profile',
    ...overrides,
  };
}

const userId = '11111111-1111-4111-8111-111111111111';

describe('interval and window materialization', () => {
  for (const item of fixtures.cases) {
    it(`produces the shared fixture dates for ${item.id}`, () => {
      const slots = calculateScheduledOccurrenceSlots(source({
        frequency: item.frequency,
        frequencyDays: item.frequencyDays ?? null,
        everyDays: item.everyDays ?? null,
        anchorDate: item.anchorDate ?? null,
        startDate: item.startDate ?? null,
        endDate: item.endDate ?? null,
        timeZone: item.timeZone ?? 'Europe/Bucharest',
        hour: item.hour ?? 8,
        minute: item.minute ?? 30,
      }), userId, item.from, item.through);
      expect(slots.map((slot) => slot.plannedLocalDate)).toEqual(item.expectedLocalDates);
      for (const [date, instant] of Object.entries(item.expectedInstants ?? {})) {
        expect(slots.find((slot) => slot.plannedLocalDate === date)?.plannedAt.toISOString()).toBe(instant);
      }
    });
  }

  it('keeps the V1 snapshot byte for byte for a daily, non-dated routine', () => {
    const [slot] = calculateScheduledOccurrenceSlots(source(), userId, '2026-06-01', '2026-06-01');
    expect(slot?.scheduleSnapshot).toEqual({
      version: 1,
      pillName: 'Example medication',
      dosage: '10mg',
      frequency: 'daily',
      frequencyDays: null,
      hour: 8,
      minute: 30,
      timeZone: 'Europe/Bucharest',
      profileId: '33333333-3333-4333-8333-333333333333',
      profileName: 'Example profile',
    });
    expect(Object.keys(slot!.scheduleSnapshot)).toEqual([
      'version', 'pillName', 'dosage', 'frequency', 'frequencyDays', 'hour', 'minute',
      'timeZone', 'profileId', 'profileName',
    ]);
  });

  it('writes snapshot V3 for an interval and for a dated routine, with the fixture shape', () => {
    const [interval] = calculateScheduledOccurrenceSlots(source({
      frequency: 'interval', everyDays: 3, anchorDate: '2026-03-01',
    }), userId, '2026-03-01', '2026-03-01');
    expect(interval?.scheduleSnapshot).toEqual(fixtures.snapshotV3['interval']);
    const [dated] = calculateScheduledOccurrenceSlots(source({
      startDate: '2026-06-03', endDate: '2026-06-05',
    }), userId, '2026-06-03', '2026-06-03');
    expect(dated?.scheduleSnapshot).toEqual(fixtures.snapshotV3['dailyWithWindow']);
  });

  it('does not change the occurrence key when a schedule gains a window', () => {
    const [plain] = calculateScheduledOccurrenceSlots(source(), userId, '2026-06-03', '2026-06-03');
    const [dated] = calculateScheduledOccurrenceSlots(source({ startDate: '2026-06-01' }), userId, '2026-06-03', '2026-06-03');
    expect(dated?.occurrenceKey).toBe(plain?.occurrenceKey);
  });

  it('never materializes before materializeFromLocalDate, even inside the window', () => {
    const slots = calculateScheduledOccurrenceSlots(source({
      startDate: '2026-06-01', materializeFromLocalDate: '2026-06-04',
    }), userId, '2026-06-01', '2026-06-06');
    expect(slots.map((slot) => slot.plannedLocalDate)).toEqual(['2026-06-04', '2026-06-05', '2026-06-06']);
  });
});

describe('sync payloads for the interval and window fields', () => {
  it('accepts a schedule payload with or without the four keys, and V1 or V3 occurrence snapshots', () => {
    for (const payload of Object.values(fixtures.syncSchedulePayload)) {
      const parsed = SyncChangePayloadV2Schema.safeParse({
        schemaVersion: 2, component: 'stable', entityType: 'schedule',
        entityId: payload['id'], operation: 'upsert',
        sourceIdentity: { sourceKind: 'schedule', sourceId: payload['id'], sourceRevision: '1' },
        payload,
      });
      expect(parsed.success, JSON.stringify(parsed.error?.issues)).toBe(true);
    }
    const without = fixtures.syncSchedulePayload['withoutWindowKeys']!;
    expect(Object.keys(without)).not.toContain('everyDays');
    expect(canonicalJson(without)).not.toContain('anchorDate');
  });

  it('rejects an occurrence whose snapshot version disagrees with its snapshot', () => {
    const [slot] = calculateScheduledOccurrenceSlots(source({
      frequency: 'interval', everyDays: 3, anchorDate: '2026-03-01',
    }), userId, '2026-03-01', '2026-03-01');
    const occurrence = (snapshotVersion: number) => ({
      schemaVersion: 2, component: 'medication', entityType: 'medication_occurrence',
      entityId: '55555555-5555-4555-8555-555555555555', operation: 'upsert',
      sourceIdentity: { sourceKind: 'occurrence', sourceId: '55555555-5555-4555-8555-555555555555', sourceRevision: '1' },
      payload: {
        kind: 'medicationOccurrence', id: '55555555-5555-4555-8555-555555555555',
        pillId: '44444444-4444-4444-8444-444444444444', scheduleId: '22222222-2222-4222-8222-222222222222',
        occurrenceKey: slot!.occurrenceKey, source: 'scheduled', scheduleRevision: '1',
        plannedLocalDate: slot!.plannedLocalDate, plannedLocalTime: slot!.plannedLocalTime,
        timeZone: slot!.timeZone, plannedAt: slot!.plannedAt.toISOString(), expected: true,
        snapshotVersion, scheduleSnapshot: slot!.scheduleSnapshot, provenance: 'exact',
        supersededAt: null, supersededByOccurrenceId: null, stateVersion: '0',
      },
    });
    expect(SyncChangePayloadV2Schema.safeParse(occurrence(3)).success).toBe(true);
    expect(SyncChangePayloadV2Schema.safeParse(occurrence(1)).success).toBe(false);
  });
});
