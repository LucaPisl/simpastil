import { z } from 'zod';

const UuidSchema = z.string().uuid();
const PositiveRevisionSchema = z.string().refine(
  (value) => /^[1-9]\d{0,18}$/.test(value) && BigInt(value) <= 9_223_372_036_854_775_807n,
  'revision must be a canonical positive signed-64 decimal string',
);

export const BridgeMedicationCommandSchema = z.object({
  commandId: UuidSchema,
  commandBundleId: UuidSchema,
  transactionCorrelationId: UuidSchema,
  pillId: UuidSchema,
  scheduleId: UuidSchema,
  legacyDoseId: UuidSchema,
  allowCreate: z.boolean().default(false),
  scheduledAt: z.string().datetime({ offset: true }),
  status: z.enum(['taken', 'missed', 'skipped', 'pending']),
  takenAt: z.string().datetime({ offset: true }).nullable().default(null),
  note: z.string().max(500).nullable().optional(),
  observedBaseDoseFingerprint: z.string().regex(/^[a-f0-9]{64}$/).nullable().default(null),
  observedBaseStock: z.number().int().nullable().default(null),
  observedBasePillRevision: PositiveRevisionSchema.nullable().default(null),
}).strict().superRefine((command, ctx) => {
  if (command.status !== 'taken' && command.takenAt !== null) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'takenAt is valid only for taken status', path: ['takenAt'] });
  }
  if (command.observedBaseStock !== null && command.observedBasePillRevision === null) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'observed stock requires its pill revision', path: ['observedBasePillRevision'] });
  }
});

export type BridgeMedicationCommand = z.infer<typeof BridgeMedicationCommandSchema>;
