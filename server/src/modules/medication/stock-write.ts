import { and, eq, sql } from 'drizzle-orm';
import type { TenantTransaction } from '../../db/tenant-transaction.js';
import { inventoryEvents, pills } from '../../db/schema.js';
import { ConflictError, ErrorCode, ResourceError } from '../shared/errors.js';
import { raiseUserMinimumClientBuild } from '../schedules/schedule-windows.js';
import type { AdministrationAmount } from '../shared/administration-amount.js';
import {
  FRACTIONAL_STOCK_MIN_CLIENT_BUILD,
  canonicalStockUnit,
  floorStock,
  formatDbStock,
  formatStock,
  isCountableUnit,
  isStockInRange,
  legacyStockInteger,
  parseDbStock,
  sameStockUnit,
} from '../shared/stock-quantity.js';
import type { StockEffect } from './stock-effect.js';

export type PillRow = typeof pills.$inferSelect;
export type InventoryEventRow = typeof inventoryEvents.$inferSelect;

/**
 * The unit a plain whole-count stock adopts by itself when a build that sends
 * amounts records a dose: stock counted without a unit, on a medicine whose
 * reviewed amount per use is in tablets or capsules, and a dose that names that
 * same unit. Anything else keeps its plain count until a person confirms a unit.
 * Returns null when nothing is adopted.
 */
export function stockUnitToAdopt(
  pill: Pick<PillRow, 'currentStock' | 'stockUnit' | 'amountPerUse'>,
  commandAmount: AdministrationAmount | null,
  amountPerUse: AdministrationAmount | null,
): string | null {
  if (pill.currentStock === null || pill.stockUnit !== null) return null;
  if (commandAmount?.state !== 'known' || amountPerUse?.state !== 'known') return null;
  if (!isCountableUnit(amountPerUse.unit) || !sameStockUnit(commandAmount.unit, amountPerUse.unit)) return null;
  // A plain count can only be adopted while it is a whole number.
  if (!/^-?\d+(\.0+)?$/.test(pill.currentStock)) return null;
  return canonicalStockUnit(amountPerUse.unit);
}

/**
 * Whether a dose that could not be subtracted is still counted for this
 * medication: a taken occurrence with no net stock effect, recorded since the
 * last count (a start or a count, which settles every earlier dose). A count
 * is the latest of its ledger event and the pill's `stock_counted_at`, which
 * also covers a count that confirmed the same number and wrote no event. Reads the
 * state after the caller's occurrence event, so it must run after that insert.
 */
async function hasUnreviewedDose(
  tx: TenantTransaction,
  userId: string,
  profileId: string,
  pillId: string,
): Promise<boolean> {
  const rows = await tx.execute<{ found: number }>(sql`
    SELECT 1 AS found
    FROM public.medication_occurrences o
    JOIN LATERAL (
      SELECT e.to_state, e.recorded_at FROM public.occurrence_events e
      WHERE e.user_id = ${userId}::uuid AND e.occurrence_id = o.id
      ORDER BY e.server_sequence DESC LIMIT 1
    ) head ON true
    WHERE o.user_id = ${userId}::uuid AND o.pill_id = ${pillId}::uuid
      AND EXISTS (
        SELECT 1 FROM public.pills own
        WHERE own.id = o.pill_id AND own.profile_id = ${profileId}::uuid
      )
      AND head.to_state = 'taken'
      AND COALESCE((
        SELECT sum(i.delta) FROM public.inventory_events i
        JOIN public.occurrence_events oe ON oe.id = i.occurrence_event_id
        WHERE i.user_id = ${userId}::uuid AND oe.occurrence_id = o.id
      ), 0) = 0
      AND head.recorded_at > GREATEST(
        COALESCE((
          SELECT max(c.recorded_at) FROM public.inventory_events c
          WHERE c.user_id = ${userId}::uuid AND c.pill_id = ${pillId}::uuid
            AND c.occurrence_event_id IS NULL AND c.kind IN ('opening', 'correction')
        ), '-infinity'::timestamptz),
        COALESCE((
          SELECT p.stock_counted_at FROM public.pills p
          WHERE p.id = ${pillId}::uuid AND p.profile_id = ${profileId}::uuid
        ), '-infinity'::timestamptz)
      )
    LIMIT 1
  `);
  return rows.length > 0;
}

export interface RecordedStock {
  inventoryEvent: InventoryEventRow | undefined;
  pill: PillRow;
  tracked: boolean;
  /** True when this write is the one that gave the medicine its stock unit. */
  adoptedUnit: boolean;
}

/**
 * Writes the stock side of one dose command: the append-only inventory event,
 * the pill's new count (compared and swapped against the count that was read),
 * and the unit adoption. The first write that gives a medicine a unit raises
 * the account's minimum client build, because older builds cannot read it.
 * A `needs_review` or `none` effect writes no event and never blocks the dose.
 */
export async function recordStockEffect(
  tx: TenantTransaction,
  userId: string,
  pill: PillRow,
  input: {
    effect: StockEffect;
    adoptUnit: string | null;
    kind: 'dose' | 'dose_reversal' | 'correction';
    /**
     * An undo or a correction: the mark that a dose could not be subtracted
     * goes when no such dose is left, so the count is right again.
     */
    mayClearRecount?: boolean;
    commandId: string;
    occurrenceEventId: string;
    reversesInventoryEventId: string | null;
    note: string | null;
    recordedAt: Date;
    allocateSequence: () => Promise<bigint>;
  },
): Promise<RecordedStock> {
  const tracked = pill.currentStock !== null;
  if (!tracked) return { inventoryEvent: undefined, pill, tracked, adoptedUnit: false };

  let inventoryEvent: InventoryEventRow | undefined;
  let nextStock = pill.currentStock!;
  if (input.effect.kind === 'applied' && input.effect.delta !== 0n) {
    const next = parseDbStock(pill.currentStock!) + input.effect.delta;
    if (!isStockInRange(next)) {
      throw new ResourceError('Inventory result is outside the supported range', 409, ErrorCode.CONFLICT_REVISION);
    }
    nextStock = formatStock(next);
    const [inserted] = await tx.insert(inventoryEvents).values({
      userId,
      pillId: pill.id,
      commandId: input.commandId,
      kind: input.kind,
      delta: formatStock(input.effect.delta),
      occurrenceEventId: input.occurrenceEventId,
      reversesInventoryEventId: input.reversesInventoryEventId,
      provenance: 'native',
      note: input.note,
      serverSequence: await input.allocateSequence(),
      recordedAt: input.recordedAt,
    }).returning();
    if (!inserted) throw new Error('Inventory event insert returned no row');
    inventoryEvent = inserted;
  }

  const adopt = input.adoptUnit !== null && pill.stockUnit === null;
  // A dose that cannot be subtracted exactly leaves the count alone and marks
  // it for a recount, on the pill (the caller syncs the new revision), so
  // every device sees it.
  const flagRecount = input.effect.kind === 'needs_review' && !pill.stockNeedsRecount;
  const clearRecount = input.mayClearRecount === true && pill.stockNeedsRecount && !flagRecount
    && !(await hasUnreviewedDose(tx, userId, pill.profileId, pill.id));
  if (!inventoryEvent && !adopt && !flagRecount && !clearRecount) return { inventoryEvent, pill, tracked, adoptedUnit: false };

  const [updatedPill] = await tx.update(pills).set({
    ...(inventoryEvent ? { currentStock: nextStock } : {}),
    ...(adopt ? { stockUnit: input.adoptUnit } : {}),
    ...(flagRecount ? { stockNeedsRecount: true } : {}),
    ...(clearRecount ? { stockNeedsRecount: false } : {}),
    revision: sql`${pills.revision} + 1`,
    lastMutationId: input.commandId,
    updatedAt: input.recordedAt,
  }).where(and(
    eq(pills.id, pill.id),
    eq(pills.profileId, pill.profileId),
    eq(pills.currentStock, pill.currentStock!),
  )).returning();
  if (!updatedPill) {
    throw new ConflictError('Inventory changed while applying the command', undefined, ErrorCode.CONFLICT_STALE_UPDATE);
  }
  if (adopt) await raiseUserMinimumClientBuild(tx, userId, FRACTIONAL_STOCK_MIN_CLIENT_BUILD);
  return { inventoryEvent, pill: updatedPill, tracked, adoptedUnit: adopt };
}

/**
 * The stock part of a command receipt. A plain-count medicine keeps the exact
 * receipt older builds read; a medicine counted in a unit adds the exact
 * quantities and what happened to the stock.
 */
export function stockReceiptFields(
  recorded: RecordedStock,
  effect: StockEffect,
): Record<string, unknown> {
  const { pill, inventoryEvent, tracked } = recorded;
  const delta = inventoryEvent ? parseDbStock(inventoryEvent.delta) : 0n;
  const fields: Record<string, unknown> = {
    inventoryEventId: inventoryEvent?.id ?? null,
    inventoryDelta: tracked ? floorStock(delta) : null,
    currentStock: legacyStockInteger(pill.currentStock),
  };
  if (pill.stockUnit !== null) {
    fields['stockUnit'] = pill.stockUnit;
    fields['currentStockQuantity'] = formatDbStock(pill.currentStock);
    fields['inventoryQuantityDelta'] = tracked ? formatStock(delta) : null;
    fields['stockEffect'] = effect.kind;
  }
  return fields;
}
