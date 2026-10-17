import { z } from 'zod';
import { ComponentNameSchema } from './component-cursor.js';
import { SyncChangePayloadV2Schema } from './sync-payload.js';

const NonNegativeSequenceSchema = z.string().refine(
  (value) => /^(0|[1-9]\d{0,18})$/.test(value) && BigInt(value) <= 9_223_372_036_854_775_807n,
  'sequence must be a canonical non-negative signed-64 decimal string',
);

export const ComponentSyncParamsSchema = z.object({
  component: z.enum(['account', 'stable', 'medication-bridge', 'medication']),
}).strict();

export const ComponentSyncQuerySchema = z.object({
  contractVersion: z.coerce.number().int().positive().max(5),
  cursor: z.string().min(1).max(4096).optional(),
  afterSequence: NonNegativeSequenceSchema.optional(),
  pageSize: z.coerce.number().int().min(1).max(200).optional(),
}).strict().refine(
  (query) => !(query.cursor !== undefined && query.afterSequence !== undefined),
  'cursor and afterSequence cannot be combined',
);

export const ComponentSyncResponseSchema = z.object({
  component: ComponentNameSchema,
  contractVersion: z.union([z.literal(1), z.literal(2), z.literal(3), z.literal(4), z.literal(5)]),
  afterSequence: NonNegativeSequenceSchema,
  throughSequence: NonNegativeSequenceSchema,
  items: z.array(z.object({
    serverSequence: NonNegativeSequenceSchema,
    change: SyncChangePayloadV2Schema,
  }).strict()),
  nextCursor: z.string().nullable(),
  hasMore: z.boolean(),
}).strict().superRefine((response, ctx) => {
  if (response.contractVersion >= 3 && response.component !== 'medicationBridge') {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'ancestor contract is only available for medication bridge', path: ['contractVersion'] });
  }
  for (const [index, item] of response.items.entries()) {
    const dose = item.change.payload;
    if (dose.kind === 'medicationOccurrence') {
      const activeMedication = response.component === 'medication'
        && response.contractVersion === 2
        && item.change.component === 'medication';
      const inactiveBridge = response.component === 'medicationBridge'
        && response.contractVersion >= 4
        && item.change.component === 'medicationBridge';
      if (!activeMedication && !inactiveBridge) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'bridge occurrence does not match negotiated contract', path: ['items', index] });
      }
      continue;
    }
    if (dose.kind === 'occurrenceEvent') {
      const activeMedication = response.component === 'medication'
        && response.contractVersion === 2
        && item.change.component === 'medication';
      const inactivePrnBridge = response.component === 'medicationBridge'
        && response.contractVersion === 5
        && item.change.component === 'medicationBridge';
      if (!activeMedication && !inactivePrnBridge) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'bridge occurrence event does not match negotiated contract', path: ['items', index] });
      }
      continue;
    }
    if (dose.kind !== 'bridgeDose') continue;
    const hasAncestors = dose.parentPill !== undefined || dose.parentProfile !== undefined;
    if (response.contractVersion >= 3
        ? Boolean(dose.parentSchedule) !== Boolean(dose.parentPill && dose.parentProfile)
        : hasAncestors || (response.contractVersion === 1 && dose.parentSchedule !== undefined)) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'historical metadata does not match negotiated contract', path: ['items', index] });
    }
  }
});

export type ComponentSyncParams = z.infer<typeof ComponentSyncParamsSchema>;
export type ComponentSyncQuery = z.infer<typeof ComponentSyncQuerySchema>;
export type ComponentSyncResponse = z.infer<typeof ComponentSyncResponseSchema>;
