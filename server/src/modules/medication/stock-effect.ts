import type { AdministrationAmount } from '../shared/administration-amount.js';
import { amountToStock, sameStockUnit } from '../shared/stock-quantity.js';

const UNIT = 1_000_000n;

export type StockEffectKind = 'none' | 'not_tracked' | 'applied' | 'needs_review';

export interface StockEffectInput {
  /** Whether the medicine counts stock at all. */
  tracked: boolean;
  /** pills.stock_unit; null means a plain count where a take removes one. */
  stockUnit: string | null;
  /** pills.amount_per_use, already parsed; the fallback when a take names no amount. */
  amountPerUse: AdministrationAmount | null;
  /** The amount the command carries, when it carries one. */
  commandAmount: AdministrationAmount | null;
  /** The effective action: `undo` reverses an inventory event, everything else is a transition. */
  action: 'take' | 'skip' | 'undo' | 'correct' | 'miss';
  /**
   * The reducer's whole-dose contribution of the transition: negative when the
   * dose becomes taken, positive when it stops being taken, 0 otherwise.
   */
  transition: number;
  /** An undo: the scaled delta of the inventory event being reversed, or null if it had none. */
  referencedDelta: bigint | null;
  /** Everything already linked to this occurrence's events, scaled (a dose taken is negative). */
  linkedNet: bigint;
}

export interface StockEffect {
  kind: StockEffectKind;
  /** Scaled by 10^6; 0 unless `kind` is `applied`. */
  delta: bigint;
}

/**
 * The stock side of one dose command, as a pure function.
 *
 * A plain count (no unit) keeps today's rule: the reducer's whole-dose delta.
 * Stock counted in a unit subtracts the exact amount taken. An amount that
 * cannot be applied exactly (unknown, another unit, one third) never changes
 * the count and never blocks the dose: the take is recorded and the effect is
 * `needs_review`. Negative stock is allowed; nothing here clamps.
 *
 * The Dart twin lives in flutter_app/lib/core/medication/stock_effect.dart and
 * both read contracts/fixtures/fractional-stock-v1.json.
 */
export function computeStockEffect(input: StockEffectInput): StockEffect {
  if (!input.tracked) return { kind: 'not_tracked', delta: 0n };

  if (input.stockUnit === null) {
    const delta = BigInt(input.transition) * UNIT;
    return delta === 0n ? { kind: 'none', delta: 0n } : { kind: 'applied', delta };
  }

  if (input.action === 'undo') {
    if (input.referencedDelta === null || input.referencedDelta === 0n) return { kind: 'none', delta: 0n };
    return { kind: 'applied', delta: -input.referencedDelta };
  }
  if (input.transition === 0) return { kind: 'none', delta: 0n };
  if (input.transition > 0) {
    // Leaving taken gives back exactly what this dose consumed.
    return input.linkedNet === 0n ? { kind: 'none', delta: 0n } : { kind: 'applied', delta: -input.linkedNet };
  }

  const known = input.commandAmount?.state === 'known' ? input.commandAmount : null;
  const amount = known ?? (input.amountPerUse?.state === 'known' ? input.amountPerUse : null);
  if (!amount || !sameStockUnit(amount.state === 'known' ? amount.unit : null, input.stockUnit)) {
    return { kind: 'needs_review', delta: 0n };
  }
  const scaled = amountToStock(amount);
  return scaled === null ? { kind: 'needs_review', delta: 0n } : { kind: 'applied', delta: -scaled };
}
