import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { openApiDocument } from '../../contracts/openapi.js';
import { BridgePrnCommandSchema } from '../../modules/medication/bridge-prn-command.schema.js';
import { MedicationCommandSchema } from '../../modules/medication/medication-command.schema.js';
import { SyncChangePayloadV2Schema } from '../../modules/sync/sync-payload.js';

const contracts = new URL('../../../../contracts/', import.meta.url);
const readContract = <T>(path: string): T => JSON.parse(readFileSync(new URL(path, contracts), 'utf8')) as T;

interface Fixture {
  validCommands: Array<{ name: string; command: unknown }>;
  invalidCommands: Array<{ name: string; command: unknown }>;
  eventChanges: Array<{ name: string; expectedName: string | null; expectedKnown: boolean; change: unknown }>;
}

describe('medication recordedBy contract', () => {
  const fixture = readContract<Fixture>('fixtures/medication-recorded-by-v1.json');

  it('accepts every valid command and round-trips recordedBy untouched', () => {
    for (const item of fixture.validCommands) {
      const parsed = MedicationCommandSchema.safeParse(item.command);
      expect(parsed.success, item.name + (parsed.success ? '' : JSON.stringify(parsed.error.issues))).toBe(true);
      if (!parsed.success) continue;
      const sent = (item.command as { recordedBy?: unknown }).recordedBy;
      // Absent stays absent: the parser adds no default that would change the fingerprint.
      expect(Object.hasOwn(parsed.data, 'recordedBy'), item.name).toBe(sent !== undefined);
      expect(parsed.data.recordedBy, item.name).toEqual(sent);
    }
  });

  it('rejects every invalid command', () => {
    for (const item of fixture.invalidCommands) {
      expect(MedicationCommandSchema.safeParse(item.command).success, item.name).toBe(false);
    }
  });

  it('does not echo a rejected name in the validation issues', () => {
    const result = MedicationCommandSchema.safeParse((fixture.invalidCommands.find((c) => c.name === 'untrimmed-name')!).command);
    expect(JSON.stringify(result.success ? [] : result.error.issues)).not.toContain('Mama');
  });

  it('reads every event change through the strict payload schema, with and without recordedBy', () => {
    for (const item of fixture.eventChanges) {
      const parsed = SyncChangePayloadV2Schema.safeParse(item.change);
      expect(parsed.success, item.name + (parsed.success ? '' : JSON.stringify(parsed.error.issues))).toBe(true);
      if (!parsed.success || parsed.data.payload.kind !== 'occurrenceEvent') continue;
      expect(parsed.data.payload.recordedBy?.name ?? null, item.name).toBe(item.expectedName);
      expect(parsed.data.payload.recordedBy !== undefined, item.name).toBe(item.expectedKnown);
    }
  });

  it('accepts recordedBy on a PRN take and undo and refuses a bad one', () => {
    const take = {
      operation: 'take', commandId: '00000000-0000-4000-8000-000000000901', eventId: '00000000-0000-4000-8000-000000000902',
      occurrenceId: '00000000-0000-4000-8000-000000000903', occurrenceKey: 'prn:v1:00000000-0000-4000-8000-000000000903',
      profileId: '00000000-0000-4000-8000-000000000002', pillId: '00000000-0000-4000-8000-000000000013',
      scheduleId: '00000000-0000-4000-8000-000000000014', scheduleRevision: '1', plannedLocalDate: '2026-10-06',
      timeZone: 'Europe/Bucharest', actualAt: null, actualTimeKnown: false, amount: { version: 1, state: 'unknown' }, note: null,
    };
    const undo = {
      operation: 'undo', commandId: '00000000-0000-4000-8000-000000000904', eventId: '00000000-0000-4000-8000-000000000905',
      occurrenceId: take.occurrenceId, occurrenceKey: take.occurrenceKey, baseVersion: '1',
      reversesEventId: take.eventId, note: null,
    };
    for (const base of [take, undo]) {
      expect(BridgePrnCommandSchema.safeParse(base).success).toBe(true);
      expect(BridgePrnCommandSchema.safeParse({ ...base, recordedBy: { version: 1, name: 'Mama' } }).success).toBe(true);
      expect(BridgePrnCommandSchema.safeParse({ ...base, recordedBy: { version: 1, name: null } }).success).toBe(true);
      expect(BridgePrnCommandSchema.safeParse({ ...base, recordedBy: { version: 2, name: 'Mama' } }).success).toBe(false);
    }
  });

  it('declares recordedBy optional in the published contract and in OpenAPI', () => {
    const schema = readContract<{
      $defs: { occurrenceEvent: { required: string[]; properties: Record<string, unknown> }; recordedBy: unknown };
    }>('sync-change-payload-v2.json');
    expect(schema.$defs.recordedBy).toBeDefined();
    expect(schema.$defs.occurrenceEvent.properties['recordedBy']).toBeDefined();
    expect(schema.$defs.occurrenceEvent.required).not.toContain('recordedBy');
    const document = JSON.stringify(openApiDocument);
    expect(document).toContain('RecordedByV1');
    expect(document).toContain('medicationRecordedBy');
  });
});
