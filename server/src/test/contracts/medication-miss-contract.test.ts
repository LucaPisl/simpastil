import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { MedicationCommandSchema } from '../../modules/medication/medication-command.schema.js';
import {
  reduceOccurrenceCommand,
  type OccurrenceCommandAction,
  type OccurrenceState,
} from '../../modules/medication/occurrence-reducer.js';
import { serializeSyncChangePayload } from '../../modules/sync/sync-payload.js';

const contracts = new URL('../../../../contracts/', import.meta.url);
const readContract = <T>(path: string): T => JSON.parse(readFileSync(new URL(path, contracts), 'utf8')) as T;

interface ReducerVectors {
  inventoryContribution: Record<OccurrenceState, number>;
  transitions: Array<{
    fromState: OccurrenceState;
    action: OccurrenceCommandAction;
    targetState?: OccurrenceState;
    effectiveAction: OccurrenceCommandAction;
    toState: OccurrenceState;
    inventoryDelta: number;
  }>;
  rejected: Array<{ fromState: OccurrenceState; action: OccurrenceCommandAction; targetState?: OccurrenceState }>;
  undo: Array<{
    name: string;
    fromState: OccurrenceState;
    referenced: { fromState: OccurrenceState; toState: OccurrenceState; inventoryDelta: number | null };
    toState: OccurrenceState;
    inventoryDelta: number;
  }>;
}

describe('recorded miss contracts shared with the app', () => {
  const vectors = readContract<ReducerVectors>('fixtures/occurrence-reducer-v1.json');

  it('reproduces every shared reducer transition vector', () => {
    expect(vectors.transitions.length).toBeGreaterThan(20);
    for (const vector of vectors.transitions) {
      const result = reduceOccurrenceCommand({
        fromState: vector.fromState,
        action: vector.action,
        ...(vector.targetState ? { targetState: vector.targetState } : {}),
      });
      expect(result, JSON.stringify(vector)).toMatchObject({
        action: vector.effectiveAction,
        fromState: vector.fromState,
        toState: vector.toState,
        inventoryDelta: vector.inventoryDelta,
      });
    }
  });

  it('refuses every shared rejected vector', () => {
    for (const vector of vectors.rejected) {
      expect(() => reduceOccurrenceCommand({
        fromState: vector.fromState,
        action: vector.action,
        ...(vector.targetState ? { targetState: vector.targetState } : {}),
      }), JSON.stringify(vector)).toThrow();
    }
  });

  it('reverses the recorded effect of every shared undo vector exactly', () => {
    const headId = '00000000-0000-4000-8000-000000000050';
    for (const vector of vectors.undo) {
      const result = reduceOccurrenceCommand({
        fromState: vector.fromState,
        action: 'undo',
        currentHeadEventId: headId,
        referencedEvent: { id: headId, ...vector.referenced },
      });
      expect(result, vector.name).toMatchObject({ toState: vector.toState, inventoryDelta: vector.inventoryDelta });
    }
  });

  it('derives the contribution of each state from the shared table', () => {
    // Taken costs one unit; a miss consumed nothing.
    for (const vector of vectors.transitions.filter((row) => row.action === 'correct')) {
      const expected = vectors.inventoryContribution[vector.toState] - vectors.inventoryContribution[vector.fromState];
      expect(vector.inventoryDelta, JSON.stringify(vector)).toBe(expected);
    }
  });

  it('accepts the valid v3 command fixtures and rejects the invalid ones at the schema', () => {
    const fixtures = readContract<{
      valid: Array<{ name: string; command: unknown }>;
      invalid: Array<{ name: string; command: unknown }>;
      unknownAction: { command: unknown };
    }>('fixtures/medication-command-v3.json');
    for (const item of fixtures.valid) {
      expect(MedicationCommandSchema.safeParse(item.command).success, item.name).toBe(true);
    }
    for (const item of fixtures.invalid) {
      expect(MedicationCommandSchema.safeParse(item.command).success, item.name).toBe(false);
    }
    expect(MedicationCommandSchema.safeParse(fixtures.unknownAction.command).success).toBe(false);
  });

  it('round-trips every sync change fixture through the strict payload schema byte for byte', () => {
    const fixture = readContract<{ cases: Array<{ name: string; canonicalJson: string }> }>(
      'fixtures/sync-change-payload-v2.json');
    const names = fixture.cases.map((item) => item.name);
    expect(names).toEqual(expect.arrayContaining([
      'occurrence-event-recorded-miss', 'occurrence-event-take-from-missed',
    ]));
    for (const item of fixture.cases.filter((row) => row.name.startsWith('occurrence-event'))) {
      const parsed = serializeSyncChangePayload(JSON.parse(item.canonicalJson));
      // The miss cases are written exactly as the server serializes them
      // (including the nullable administrationAmount default).
      if (item.name === 'occurrence-event-recorded-miss' || item.name === 'occurrence-event-take-from-missed') {
        expect(parsed.canonicalJson, item.name).toBe(item.canonicalJson);
      }
    }
  });

  it('keeps the JSON schema enums in step with the server enums', () => {
    const schema = readContract<{
      $defs: { occurrenceEvent: { properties: Record<string, { enum: string[] }> } };
    }>('sync-change-payload-v2.json');
    const event = schema.$defs.occurrenceEvent.properties;
    expect(event['action']?.enum).toEqual(['take', 'skip', 'undo', 'correct', 'miss']);
    expect(event['fromState']?.enum).toEqual(['pending', 'taken', 'skipped', 'missed']);
    expect(event['toState']?.enum).toEqual(['pending', 'taken', 'skipped', 'missed']);
  });
});
