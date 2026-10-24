import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import type { AdministrationAmount } from '../../modules/shared/administration-amount.js';
import {
  amountToStock,
  canonicalStockUnit,
  formatStock,
  isCanonicalStock,
  isCountableUnit,
  isStockInRange,
  parseCanonicalStock,
  sameStockUnit,
} from '../../modules/shared/stock-quantity.js';
import { computeStockEffect } from '../../modules/medication/stock-effect.js';
import { InventoryCommandSchema, MedicationCommandSchema } from '../../modules/medication/medication-command.schema.js';
import { serializeSyncChangePayload } from '../../modules/sync/sync-payload.js';

const url = new URL('../../../../contracts/fixtures/fractional-stock-v1.json', import.meta.url);

interface Vector {
  name: string;
  tracked: boolean;
  stockUnit: string | null;
  amountPerUse: AdministrationAmount | null;
  commandAmount: AdministrationAmount | null;
  action: 'take' | 'skip' | 'undo' | 'correct' | 'miss';
  transition: number;
  referencedDelta: string | null;
  linkedNet: string;
  expect: { kind: string; delta: string };
}

const fixture = JSON.parse(readFileSync(url, 'utf8')) as {
  canonicalQuantities: { valid: string[]; invalid: string[] };
  amounts: Array<{ amount: AdministrationAmount; scaled: string | null }>;
  countableUnits: { yes: string[]; no: string[] };
  unitSpellings: { same: string[][]; different: string[][]; canonical: Record<string, string> };
  effects: Vector[];
};

const dec = (text: string | null): bigint | null => (text === null ? null : parseCanonicalStock(text));

describe('fractional stock vectors shared with the app', () => {
  it('accepts exactly the canonical spellings', () => {
    for (const text of fixture.canonicalQuantities.valid) {
      expect(isCanonicalStock(text) && isStockInRange(parseCanonicalStock(text)), text).toBe(true);
      expect(formatStock(parseCanonicalStock(text)), text).toBe(text);
    }
    for (const text of fixture.canonicalQuantities.invalid) {
      expect(isCanonicalStock(text) && isStockInRange(parseCanonicalStock(text)), text).toBe(false);
    }
  });

  it('turns amounts into exact quantities, or null when they do not terminate', () => {
    for (const row of fixture.amounts) {
      const scaled = amountToStock(row.amount);
      expect(scaled === null ? null : formatStock(scaled), JSON.stringify(row.amount)).toBe(row.scaled);
    }
  });

  it('knows which units are countable', () => {
    for (const unit of fixture.countableUnits.yes) expect(isCountableUnit(unit), unit).toBe(true);
    for (const unit of fixture.countableUnits.no) expect(isCountableUnit(unit), unit).toBe(false);
  });

  it('compares and canonicalises unit spellings like the app', () => {
    for (const [a, b] of fixture.unitSpellings.same) {
      expect(sameStockUnit(a, b), `${a} = ${b}`).toBe(true);
      expect(sameStockUnit(b, a), `${b} = ${a}`).toBe(true);
    }
    for (const [a, b] of fixture.unitSpellings.different) expect(sameStockUnit(a, b), `${a} != ${b}`).toBe(false);
    for (const [from, to] of Object.entries(fixture.unitSpellings.canonical)) expect(canonicalStockUnit(from), from).toBe(to);
    expect(sameStockUnit(null, 'tablet')).toBe(false);
  });

  it('reproduces every stock effect vector', () => {
    expect(fixture.effects.length).toBeGreaterThan(15);
    for (const vector of fixture.effects) {
      const effect = computeStockEffect({
        tracked: vector.tracked,
        stockUnit: vector.stockUnit,
        amountPerUse: vector.amountPerUse,
        commandAmount: vector.commandAmount,
        action: vector.action,
        transition: vector.transition,
        referencedDelta: dec(vector.referencedDelta),
        linkedNet: dec(vector.linkedNet)!,
      });
      expect({ kind: effect.kind, delta: formatStock(effect.delta) }, vector.name).toEqual(vector.expect);
    }
  });
});

describe('fractional stock wire schemas', () => {
  const ids = {
    commandId: '11111111-1111-4111-8111-111111111111',
    pillId: '22222222-2222-4222-8222-222222222222',
  };

  it('accepts an exact quantity with its unit and rejects a bare fraction', () => {
    const base = { action: 'start', ...ids, baseRevision: '1', note: null };
    expect(InventoryCommandSchema.safeParse({ ...base, initialQuantity: '10.5', stockUnit: 'tablet' }).success).toBe(true);
    expect(InventoryCommandSchema.safeParse({ ...base, initialQuantity: '10.5' }).success).toBe(false);
    expect(InventoryCommandSchema.safeParse({ ...base, initialQuantity: '10', initialStock: 10 }).success).toBe(false);
    expect(InventoryCommandSchema.safeParse({ ...base, initialQuantity: '10.50', stockUnit: 'tablet' }).success).toBe(false);
    expect(InventoryCommandSchema.safeParse({ ...base, initialStock: 10 }).success).toBe(true);
  });

  it('allows an amount only on take and correct', () => {
    const amount = { version: 1, state: 'known', quantity: '1/2', unit: 'tablet' };
    const base = {
      commandId: ids.commandId,
      occurrenceId: ids.pillId,
      occurrenceKey: 'k',
      baseVersion: '0',
      actualAt: null,
      actualTimeKnown: false,
      note: null,
      administrationAmount: amount,
    };
    expect(MedicationCommandSchema.safeParse({ ...base, action: 'take' }).success).toBe(true);
    expect(MedicationCommandSchema.safeParse({ ...base, action: 'skip' }).success).toBe(false);
  });

  it('parses an exact inventory event, with and without the integer delta', () => {
    const event = {
      kind: 'inventoryEvent',
      id: ids.commandId,
      pillId: ids.pillId,
      commandId: ids.commandId,
      eventKind: 'dose',
      occurrenceEventId: null,
      reversesInventoryEventId: null,
      provenance: 'native',
      note: null,
      serverSequence: '7',
      recordedAt: '2026-10-22T10:00:00.000Z',
    };
    const wrap = (payload: object) => ({
      schemaVersion: 2, component: 'medication', entityType: 'inventory_event', entityId: ids.commandId,
      operation: 'upsert', sourceIdentity: { sourceKind: 'inventory_event', sourceId: ids.commandId, sourceRevision: '7' }, payload,
    });
    expect(() => serializeSyncChangePayload(wrap({ ...event, quantityDelta: '-0.5' }) as never)).not.toThrow();
    expect(() => serializeSyncChangePayload(wrap({ ...event, delta: -1 }) as never)).not.toThrow();
    expect(() => serializeSyncChangePayload(wrap({ ...event, delta: -1, quantityDelta: '-1' }) as never)).not.toThrow();
    expect(() => serializeSyncChangePayload(wrap({ ...event, delta: -1, quantityDelta: '-0.5' }) as never)).toThrow();
    expect(() => serializeSyncChangePayload(wrap(event) as never)).toThrow();
    expect(() => serializeSyncChangePayload(wrap({ ...event, quantityDelta: '0' }) as never)).toThrow();
  });
});
