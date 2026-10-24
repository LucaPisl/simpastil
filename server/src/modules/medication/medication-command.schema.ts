import { z } from 'zod';
import { AdministrationAmountSchema } from '../shared/administration-amount.js';
import { RecordedBySchema } from '../shared/recorded-by.js';
import { isCanonicalStock, isStockInRange, parseCanonicalStock } from '../shared/stock-quantity.js';
import { CORRECTABLE_TARGET_STATES } from './occurrence-reducer.js';

const UuidSchema = z.guid();
const NonNegativeRevisionSchema = z.string().refine(
  (value) => /^(0|[1-9]\d{0,18})$/.test(value) && BigInt(value) <= 9_223_372_036_854_775_807n,
  'baseVersion must be a canonical non-negative signed-64 decimal string',
);

export const MedicationCommandSchema = z.object({
  commandId: UuidSchema,
  occurrenceId: UuidSchema,
  occurrenceKey: z.string().min(1).max(256),
  baseVersion: NonNegativeRevisionSchema,
  action: z.enum(['take', 'skip', 'undo', 'correct', 'miss']),
  targetState: z.enum(CORRECTABLE_TARGET_STATES).optional(),
  reversesEventId: UuidSchema.optional(),
  rebasesCommandId: UuidSchema.nullable().default(null),
  actualAt: z.string().datetime({ offset: true }).nullable().default(null),
  actualTimeKnown: z.boolean(),
  note: z.string().max(500).nullable().default(null),
  // How much was taken, so stock counted in a unit loses exactly that. Optional
  // and absent from every request an older build sends.
  administrationAmount: AdministrationAmountSchema.optional(),
  // Who recorded it (capability medicationRecordedBy). Absent means unknown.
  recordedBy: RecordedBySchema.optional(),
}).strict().superRefine((command, ctx) => {
  if (command.recordedBy !== undefined && command.action === 'miss') {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'miss forbids recordedBy', path: ['recordedBy'] });
  }
  if (command.administrationAmount !== undefined && command.action !== 'take' && command.action !== 'correct') {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'administrationAmount is valid only for take and correct', path: ['administrationAmount'] });
  }
  if (command.actualTimeKnown !== (command.actualAt !== null)) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'actualTimeKnown must match actualAt', path: ['actualTimeKnown'] });
  }
  if (command.action === 'correct' && !command.targetState) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'correct requires targetState', path: ['targetState'] });
  }
  if (command.action !== 'correct' && command.targetState !== undefined) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'targetState is valid only for correct', path: ['targetState'] });
  }
  if (command.action === 'miss') {
    // A miss is written by the app on the person's behalf: it has no actual
    // time, no note and nothing to rebase.
    if (command.actualAt !== null) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'miss forbids actualAt', path: ['actualAt'] });
    }
    if (command.note !== null) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'miss forbids note', path: ['note'] });
    }
    if (command.rebasesCommandId !== null) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'miss forbids rebasesCommandId', path: ['rebasesCommandId'] });
    }
  }
  if ((command.action === 'undo') !== (command.reversesEventId !== undefined)) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'undo requires reversesEventId and other actions forbid it', path: ['reversesEventId'] });
  }
});

export type MedicationCommand = z.infer<typeof MedicationCommandSchema>;

const PositiveRevisionSchema = z.string().refine(
  (value) => /^[1-9]\d{0,18}$/.test(value) && BigInt(value) <= 9_223_372_036_854_775_807n,
  'baseRevision must be a canonical positive signed-64 decimal string',
);
const StockIntegerSchema = z.number().int().min(-2_147_483_648).max(2_147_483_647);
// An exact quantity in its one canonical spelling (see stock-quantity.ts).
const StockQuantitySchema = z.string().refine(
  (value) => isCanonicalStock(value) && isStockInRange(parseCanonicalStock(value)),
  'a stock quantity must be a canonical decimal with at most six fraction digits',
);
const StockUnitSchema = z.string().min(1).max(80).refine((value) => value === value.trim(), 'stockUnit must be trimmed');

export const InventoryCommandSchema = z.discriminatedUnion('action', [
  z.object({
    action: z.literal('start'),
    commandId: UuidSchema,
    pillId: UuidSchema,
    baseRevision: PositiveRevisionSchema,
    initialStock: StockIntegerSchema.optional(),
    initialQuantity: StockQuantitySchema.optional(),
    stockUnit: StockUnitSchema.optional(),
    note: z.string().max(500).nullable().default(null),
  }).strict(),
  z.object({
    action: z.literal('refill'),
    commandId: UuidSchema,
    pillId: UuidSchema,
    baseRevision: PositiveRevisionSchema,
    amount: z.number().int().min(1).max(2_147_483_647).optional(),
    refillQuantity: StockQuantitySchema.optional(),
    note: z.string().max(500).nullable().default(null),
  }).strict(),
  z.object({
    action: z.literal('correct'),
    commandId: UuidSchema,
    pillId: UuidSchema,
    baseRevision: PositiveRevisionSchema,
    targetStock: StockIntegerSchema.optional(),
    targetQuantity: StockQuantitySchema.optional(),
    stockUnit: StockUnitSchema.optional(),
    note: z.string().max(500).nullable().default(null),
  }).strict(),
]).superRefine((command, ctx) => {
  const [integerField, quantityField] = command.action === 'start'
    ? (['initialStock', 'initialQuantity'] as const)
    : command.action === 'refill'
      ? (['amount', 'refillQuantity'] as const)
      : (['targetStock', 'targetQuantity'] as const);
  const record = command as Record<string, unknown>;
  const integer = record[integerField];
  const quantity = record[quantityField];
  if ((integer === undefined) === (quantity === undefined)) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: `send exactly one of ${integerField} and ${quantityField}`, path: [quantityField] });
    return;
  }
  if (command.action === 'refill') {
    if (command.refillQuantity !== undefined && parseCanonicalStock(command.refillQuantity) <= 0n) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'a refill must add a positive quantity', path: ['refillQuantity'] });
    }
    return;
  }
  // A fraction is only meaningful in a unit, and a unit only with a quantity.
  const fractional = typeof quantity === 'string' && !/^-?\d+$/.test(quantity);
  if (fractional && command.stockUnit === undefined) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'a fractional quantity needs stockUnit', path: ['stockUnit'] });
  }
  if (command.stockUnit !== undefined && quantity === undefined) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'stockUnit goes with a quantity field', path: ['stockUnit'] });
  }
});

export type InventoryCommand = z.infer<typeof InventoryCommandSchema>;
