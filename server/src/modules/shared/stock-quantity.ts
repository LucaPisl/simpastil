import { AdministrationAmountSchema, type AdministrationAmount } from './administration-amount.js';

/**
 * Exact stock arithmetic. A stock quantity or a stock delta is a decimal with at
 * most six fraction digits, held here as a BigInt scaled by 10^6 so no step ever
 * goes through a floating-point number. The shared vectors in
 * contracts/fixtures/fractional-stock-v1.json pin the same rules for the app.
 */

export const STOCK_SCALE_DIGITS = 6;
const SCALE = 1_000_000n;

/** pills.current_stock and inventory_events.delta are numeric(20,6): 14 integer digits. */
const LIMIT = 100_000_000_000_000n * SCALE;

/**
 * The one wire spelling of a stock quantity: no plus sign, no trailing zeros,
 * no negative zero, so whole values read exactly like today's integers.
 */
export const CANONICAL_STOCK_RE = /^-?(0|[1-9]\d{0,13})(\.\d{0,5}[1-9])?$/;

/** The first app build that reads exact stock quantities and stock units. */
export const FRACTIONAL_STOCK_MIN_CLIENT_BUILD = 8;

export function isCanonicalStock(text: string): boolean {
  return CANONICAL_STOCK_RE.test(text) && text !== '-0';
}

/** Parses the canonical wire spelling, throwing a TypeError for anything else. */
export function parseCanonicalStock(text: string): bigint {
  if (!isCanonicalStock(text)) throw new TypeError(`not a canonical stock quantity: ${text}`);
  return parseDecimal(text);
}

function parseDecimal(text: string): bigint {
  const negative = text.startsWith('-');
  const body = negative ? text.slice(1) : text;
  const [whole = '0', fraction = ''] = body.split('.');
  const scaled = BigInt(whole) * SCALE + BigInt(fraction.padEnd(STOCK_SCALE_DIGITS, '0'));
  return negative ? -scaled : scaled;
}

/** Parses what PostgreSQL prints for a numeric(20,6) value, such as `12.500000`. */
export function parseDbStock(text: string): bigint {
  if (!/^-?\d+(\.\d{1,6})?$/.test(text)) throw new TypeError(`not a stock numeric: ${text}`);
  return parseDecimal(text);
}

export function parseDbStockOrNull(text: string | null): bigint | null {
  return text === null ? null : parseDbStock(text);
}

/** The canonical spelling, also accepted by PostgreSQL as a numeric literal. */
export function formatStock(value: bigint): string {
  if (value === 0n) return '0';
  const negative = value < 0n;
  const magnitude = negative ? -value : value;
  const whole = (magnitude / SCALE).toString();
  const fraction = (magnitude % SCALE).toString().padStart(STOCK_SCALE_DIGITS, '0').replace(/0+$/, '');
  return `${negative ? '-' : ''}${whole}${fraction === '' ? '' : `.${fraction}`}`;
}

export function formatDbStock(text: string | null): string | null {
  return text === null ? null : formatStock(parseDbStock(text));
}

export function isStockInRange(value: bigint): boolean {
  return value > -LIMIT && value < LIMIT;
}

export function isWholeStock(value: bigint): boolean {
  return value % SCALE === 0n;
}

/** Rounds toward negative infinity: the whole count older readers see. */
export function floorStock(value: bigint): number {
  let whole = value / SCALE;
  if (value % SCALE !== 0n && value < 0n) whole -= 1n;
  return Number(whole);
}

/** The integer older readers see for a stored numeric, or null when untracked. */
export function legacyStockInteger(text: string | null): number | null {
  return text === null ? null : floorStock(parseDbStock(text));
}

export function stockFromInteger(value: number): bigint {
  if (!Number.isSafeInteger(value)) throw new TypeError('stock integer must be safe');
  return BigInt(value) * SCALE;
}

/**
 * The exact quantity of an administration amount ("1/2", "0.5", "1,5", "2"),
 * or null when it is unknown, unreadable, or not representable to six decimals
 * (one third). Never rounded: a value that does not terminate means the stock
 * effect needs a person's review.
 */
export function amountToStock(amount: AdministrationAmount | null | undefined): bigint | null {
  if (!amount || amount.state !== 'known') return null;
  const text = amount.quantity.trim();
  let numerator: bigint;
  let denominator: bigint;
  const fraction = /^(\d+)\s*\/\s*(\d+)$/.exec(text);
  const decimal = /^(\d+)(?:[.,](\d+))?$/.exec(text);
  if (fraction) {
    numerator = BigInt(fraction[1]!);
    denominator = BigInt(fraction[2]!);
  } else if (decimal) {
    const digits = decimal[2] ?? '';
    numerator = BigInt(`${decimal[1]}${digits}`);
    denominator = 10n ** BigInt(digits.length);
  } else {
    return null;
  }
  if (numerator <= 0n || denominator <= 0n) return null;
  const scaled = numerator * SCALE;
  if (scaled % denominator !== 0n) return null;
  const value = scaled / denominator;
  return value > 0n && isStockInRange(value) ? value : null;
}

/** Reads a stored amount (pills.amount_per_use or an event's amount), or null if malformed. */
export function readAdministrationAmount(value: unknown): AdministrationAmount | null {
  const parsed = AdministrationAmountSchema.safeParse(value);
  return parsed.success ? parsed.data : null;
}

const COUNTABLE_UNIT_CANONICAL = new Map<string, string>([
  ['tablet', 'tablet'], ['tablets', 'tablet'], ['tab', 'tablet'], ['tabs', 'tablet'],
  ['capsule', 'capsule'], ['capsules', 'capsule'], ['cap', 'capsule'], ['caps', 'capsule'],
  ['capsula', 'capsule'], ['capsulă', 'capsule'],
  ['comprimat', 'comprimat'], ['comprimate', 'comprimat'],
  ['pastila', 'pastilă'], ['pastilă', 'pastilă'], ['pastile', 'pastilă'],
]);

function countableKey(unit: string | null | undefined): string | null {
  if (unit == null) return null;
  return COUNTABLE_UNIT_CANONICAL.get(unit.trim().toLowerCase().replace(/\.$/, '')) ?? null;
}

/**
 * The one spelling a countable unit is stored in (`tablets`, `Tab.` and
 * `tablet` all become `tablet`), so the same unit never exists in two forms.
 * Any other unit is only trimmed. The Dart twin is `canonicalStockUnit`.
 */
export function canonicalStockUnit(unit: string): string {
  return countableKey(unit) ?? unit.trim();
}

/** Whether two units name the same thing: countable units ignore number and case. */
export function sameStockUnit(a: string | null | undefined, b: string | null | undefined): boolean {
  if (a == null || b == null) return false;
  const ka = countableKey(a);
  const kb = countableKey(b);
  if (ka !== null || kb !== null) return ka === kb;
  return a.trim() === b.trim();
}

/**
 * Units that count whole things a person can split: only stock counted in one
 * of these adopts the amount's unit by itself. Anything else (ml, drops, mg)
 * keeps a plain count until a person confirms the unit.
 */
export function isCountableUnit(unit: string | null | undefined): boolean {
  return countableKey(unit) !== null;
}

/**
 * How an inventory event's delta travels. `delta` stays the whole integer older
 * readers know and is left out when the value is not whole; `quantityDelta` is
 * the exact canonical string, sent when the medicine counts stock in a unit or
 * the value is not whole. A plain-count history keeps its exact old shape.
 */
export function inventoryDeltaWire(delta: string, unitStock: boolean): { delta?: number; quantityDelta?: string } {
  const value = parseDbStock(delta);
  const whole = isWholeStock(value);
  return {
    ...(whole ? { delta: floorStock(value) } : {}),
    ...(!whole || unitStock ? { quantityDelta: formatStock(value) } : {}),
  };
}
