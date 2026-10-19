import { z } from 'zod';

const UuidSchema = z.guid();
const PositiveRevisionSchema = z.string().refine(
  (value) => /^[1-9]\d{0,18}$/.test(value) && BigInt(value) <= 9_223_372_036_854_775_807n,
  'revision must be a canonical positive signed-64 decimal string',
);

export const SplitCheckpointSchema = z.object({
  version: z.literal(1),
  reason: z.enum(['source_missing', 'base_changed', 'evidence_ambiguous', 'evidence_conflict']),
  legacySourceKind: z.enum(['dose_log', 'pill_stock']).nullable(),
  legacySourceId: UuidSchema.nullable(),
  sourceFingerprint: z.string().regex(/^[a-f0-9]{64}$/).nullable(),
  observedBaseRevision: PositiveRevisionSchema.nullable(),
  observedBaseStock: z.number().int().nullable(),
  targetStock: z.number().int().nullable(),
}).strict();

const RecordSplitCheckpointSchema = z.object({
  operation: z.literal('record'),
  issueId: UuidSchema,
  commandId: UuidSchema,
  commandBundleId: UuidSchema,
  transactionCorrelationId: UuidSchema,
  checkpoint: SplitCheckpointSchema,
}).strict();

const ResolveSplitCheckpointSchema = z.object({
  operation: z.literal('resolve'),
  issueId: UuidSchema,
  commandId: UuidSchema,
  commandBundleId: UuidSchema,
  transactionCorrelationId: UuidSchema,
  baseIssueRevision: PositiveRevisionSchema,
  resolution: z.enum(['adopt', 'apply_residual', 'keep_server_state']),
}).strict();

export const LegacySplitReconciliationSchema = z.discriminatedUnion('operation', [
  RecordSplitCheckpointSchema,
  ResolveSplitCheckpointSchema,
]);

export type LegacySplitReconciliation = z.infer<typeof LegacySplitReconciliationSchema>;
