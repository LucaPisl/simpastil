import { describe, expect, it } from 'vitest';
import { reduceOccurrenceCommand } from './occurrence-reducer.js';

describe('occurrence command reducer', () => {
  it.each([
    ['pending', 'take', 'take', 'taken', -1],
    ['pending', 'skip', 'skip', 'skipped', 0],
    ['taken', 'take', 'correct', 'taken', 0],
    ['taken', 'skip', 'correct', 'skipped', 1],
    ['skipped', 'take', 'correct', 'taken', -1],
    ['skipped', 'skip', 'correct', 'skipped', 0],
    ['pending', 'miss', 'miss', 'missed', 0],
    // A late take or a skip on a recorded miss is a correction of that record.
    ['missed', 'take', 'correct', 'taken', -1],
    ['missed', 'skip', 'correct', 'skipped', 0],
  ] as const)('%s + %s -> %s / %s / %i', (fromState, action, effectiveAction, toState, inventoryDelta) => {
    expect(reduceOccurrenceCommand({ fromState, action })).toMatchObject({
      action: effectiveAction,
      fromState,
      toState,
      inventoryDelta,
      reversesEventId: null,
    });
  });

  it('undoes only the current head and applies the exact inverse inventory effect', () => {
    expect(reduceOccurrenceCommand({
      fromState: 'taken',
      action: 'undo',
      currentHeadEventId: '00000000-0000-4000-8000-000000000010',
      referencedEvent: {
        id: '00000000-0000-4000-8000-000000000010',
        fromState: 'pending',
        toState: 'taken',
        inventoryDelta: -1,
      },
    })).toMatchObject({
      action: 'undo',
      fromState: 'taken',
      toState: 'pending',
      inventoryDelta: 1,
      reversesEventId: '00000000-0000-4000-8000-000000000010',
    });
  });

  it('keeps same-state corrections auditable without inventing a stock delta', () => {
    expect(reduceOccurrenceCommand({
      fromState: 'skipped',
      action: 'correct',
      targetState: 'skipped',
    })).toMatchObject({ action: 'correct', toState: 'skipped', inventoryDelta: 0 });
  });

  it('rejects undo when its referenced event is no longer the occurrence head', () => {
    expect(() => reduceOccurrenceCommand({
      fromState: 'taken',
      action: 'undo',
      currentHeadEventId: '00000000-0000-4000-8000-000000000011',
      referencedEvent: {
        id: '00000000-0000-4000-8000-000000000010',
        fromState: 'pending',
        toState: 'taken',
        inventoryDelta: -1,
      },
    })).toThrow(/current occurrence head/);
  });

  describe('recorded miss', () => {
    const headId = '00000000-0000-4000-8000-000000000020';

    it.each(['taken', 'skipped', 'missed'] as const)('refuses to miss a dose that is already %s', (fromState) => {
      expect(() => reduceOccurrenceCommand({ fromState, action: 'miss' })).toThrow(/pending/);
    });

    it('never lets a correction target the missed state', () => {
      for (const fromState of ['pending', 'taken', 'skipped', 'missed'] as const) {
        expect(() => reduceOccurrenceCommand({ fromState, action: 'correct', targetState: 'missed' }))
          .toThrow(/missed/);
      }
    });

    it('undoes a miss back to pending without touching stock', () => {
      expect(reduceOccurrenceCommand({
        fromState: 'missed',
        action: 'undo',
        currentHeadEventId: headId,
        referencedEvent: { id: headId, fromState: 'pending', toState: 'missed', inventoryDelta: 0 },
      })).toMatchObject({ action: 'undo', fromState: 'missed', toState: 'pending', inventoryDelta: 0, reversesEventId: headId });
    });

    it('undoes a late take back to missed and returns its unit to stock', () => {
      const late = reduceOccurrenceCommand({ fromState: 'missed', action: 'take' });
      expect(late).toMatchObject({ action: 'correct', toState: 'taken', inventoryDelta: -1 });
      expect(reduceOccurrenceCommand({
        fromState: 'taken',
        action: 'undo',
        currentHeadEventId: headId,
        referencedEvent: { id: headId, fromState: 'missed', toState: 'taken', inventoryDelta: late.inventoryDelta },
      })).toMatchObject({ toState: 'missed', inventoryDelta: 1 });
    });

    it('undoes a skip of a missed dose back to missed without a stock effect', () => {
      const skip = reduceOccurrenceCommand({ fromState: 'missed', action: 'skip' });
      expect(reduceOccurrenceCommand({
        fromState: 'skipped',
        action: 'undo',
        currentHeadEventId: headId,
        referencedEvent: { id: headId, fromState: 'missed', toState: 'skipped', inventoryDelta: skip.inventoryDelta },
      })).toMatchObject({ toState: 'missed', inventoryDelta: 0 });
    });

    it('keeps stock balanced across a miss, a late take and the full undo chain', () => {
      let state: 'pending' | 'taken' | 'skipped' | 'missed' = 'pending';
      let stock = 10;
      const apply = (r: ReturnType<typeof reduceOccurrenceCommand>) => {
        expect(r.fromState).toBe(state);
        state = r.toState;
        stock += r.inventoryDelta;
      };
      apply(reduceOccurrenceCommand({ fromState: state, action: 'miss' }));
      expect([state, stock]).toEqual(['missed', 10]);
      apply(reduceOccurrenceCommand({ fromState: state, action: 'take' }));
      expect([state, stock]).toEqual(['taken', 9]);
      apply(reduceOccurrenceCommand({
        fromState: state, action: 'undo', currentHeadEventId: headId,
        referencedEvent: { id: headId, fromState: 'missed', toState: 'taken', inventoryDelta: -1 },
      }));
      expect([state, stock]).toEqual(['missed', 10]);
      apply(reduceOccurrenceCommand({
        fromState: state, action: 'undo', currentHeadEventId: headId,
        referencedEvent: { id: headId, fromState: 'pending', toState: 'missed', inventoryDelta: 0 },
      }));
      expect([state, stock]).toEqual(['pending', 10]);
    });
  });
});
