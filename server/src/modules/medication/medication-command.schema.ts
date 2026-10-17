import { z } from 'zod';
import { CORRECTABLE_TARGET_STATES } from './occurrence-reducer.js';

const UuidSchema = z.string().uuid();
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
}).strict().superRefine((command, ctx) => {
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

export const InventoryCommandSchema = z.discriminatedUnion('action', [
  z.object({
    action: z.literal('start'),
    commandId: UuidSchema,
    pillId: UuidSchema,
    baseRevision: PositiveRevisionSchema,
    initialStock: StockIntegerSchema,
    note: z.string().max(500).nullable().default(null),
  }).strict(),
  z.object({
    action: z.literal('refill'),
    commandId: UuidSchema,
    pillId: UuidSchema,
    baseRevision: PositiveRevisionSchema,
    amount: z.number().int().min(1).max(2_147_483_647),
    note: z.string().max(500).nullable().default(null),
  }).strict(),
  z.object({
    action: z.literal('correct'),
    commandId: UuidSchema,
    pillId: UuidSchema,
    baseRevision: PositiveRevisionSchema,
    targetStock: StockIntegerSchema,
    note: z.string().max(500).nullable().default(null),
  }).strict(),
]);

export type InventoryCommand = z.infer<typeof InventoryCommandSchema>;
