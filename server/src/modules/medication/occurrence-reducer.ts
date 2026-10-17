export const OCCURRENCE_STATES = ['pending', 'taken', 'skipped', 'missed'] as const;
export type OccurrenceState = (typeof OCCURRENCE_STATES)[number];

/**
 * States a correction may target. `missed` is reachable only through the
 * `miss` action, so a taken dose can never be turned into a miss (which would
 * credit its stock back without an Undo).
 */
export const CORRECTABLE_TARGET_STATES = ['pending', 'taken', 'skipped'] as const;

export type OccurrenceCommandAction = 'take' | 'skip' | 'undo' | 'correct' | 'miss';

export interface ReferencedOccurrenceEvent {
  id: string;
  fromState: OccurrenceState;
  toState: OccurrenceState;
  /** Null means the original command had no tracked inventory effect. */
  inventoryDelta: number | null;
}

export interface ReduceOccurrenceCommandInput {
  fromState: OccurrenceState;
  action: OccurrenceCommandAction;
  targetState?: OccurrenceState;
  currentHeadEventId?: string | null;
  referencedEvent?: ReferencedOccurrenceEvent;
}

export interface OccurrenceReduction {
  action: OccurrenceCommandAction;
  fromState: OccurrenceState;
  toState: OccurrenceState;
  inventoryDelta: number;
  reversesEventId: string | null;
}

const inventoryContribution: Record<OccurrenceState, number> = {
  pending: 0,
  taken: -1,
  skipped: 0,
  // A recorded miss consumed nothing; Taken (late) later costs one unit.
  missed: 0,
};

function transitionDelta(from: OccurrenceState, to: OccurrenceState): number {
  return inventoryContribution[to] - inventoryContribution[from];
}

/**
 * Pure, deterministic medication-state reducer shared by active and bridge
 * commands. It never clamps stock; callers apply the returned signed delta.
 *
 * `miss` moves pending to missed with no stock effect and is never coerced:
 * from any other state it throws, because a miss must not overwrite what a
 * person (or another device) already recorded. A later take or skip on a
 * missed dose becomes a `correct`, like any take or skip on a recorded dose.
 */
export function reduceOccurrenceCommand(input: ReduceOccurrenceCommandInput): OccurrenceReduction {
  const { fromState } = input;

  if (input.action === 'undo') {
    const referenced = input.referencedEvent;
    if (!referenced || !input.currentHeadEventId || referenced.id !== input.currentHeadEventId) {
      throw new Error('undo is allowed only for the current occurrence head');
    }
    if (referenced.toState !== fromState) {
      throw new Error('referenced event state does not match the current occurrence head');
    }
    if (referenced.inventoryDelta !== null && !Number.isSafeInteger(referenced.inventoryDelta)) {
      throw new TypeError('referenced inventory delta must be a safe integer or null');
    }
    return {
      action: 'undo',
      fromState,
      toState: referenced.fromState,
      // `0 - x` rather than `-x` so a zero delta reverses to 0, never -0.
      inventoryDelta: referenced.inventoryDelta === null ? 0 : 0 - referenced.inventoryDelta,
      reversesEventId: referenced.id,
    };
  }

  if (input.action === 'miss') {
    if (fromState !== 'pending') {
      throw new Error('miss is allowed only from the pending state');
    }
    return {
      action: 'miss',
      fromState,
      toState: 'missed',
      inventoryDelta: 0,
      reversesEventId: null,
    };
  }

  if (input.action === 'correct') {
    if (!input.targetState) throw new TypeError('correct requires a target state');
    if (input.targetState === 'missed') throw new TypeError('correct cannot target the missed state');
    return {
      action: 'correct',
      fromState,
      toState: input.targetState,
      inventoryDelta: transitionDelta(fromState, input.targetState),
      reversesEventId: null,
    };
  }

  const toState: OccurrenceState = input.action === 'take' ? 'taken' : 'skipped';
  const effectiveAction = fromState === 'pending' ? input.action : 'correct';
  return {
    action: effectiveAction,
    fromState,
    toState,
    inventoryDelta: transitionDelta(fromState, toState),
    reversesEventId: null,
  };
}
