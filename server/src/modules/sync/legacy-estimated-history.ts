import { z } from 'zod';

const MAX_SIGNED_64 = 9_223_372_036_854_775_807n;
const MIN_SIGNED_64 = -9_223_372_036_854_775_808n;
const PositiveRevisionSchema = z.string().refine(
  (value) => /^[1-9]\d{0,18}$/.test(value) && BigInt(value) <= MAX_SIGNED_64,
  'revision must be a canonical positive signed-64 decimal string',
);
const SignedDeltaSchema = z.string().refine(
  (value) => /^-?(0|[1-9]\d{0,18})$/.test(value)
    && value !== '-0'
    && BigInt(value) >= MIN_SIGNED_64
    && BigInt(value) <= MAX_SIGNED_64,
  'inventory delta must be a canonical signed-64 decimal string',
);

function isValidLocalDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value) || value.startsWith('0000-')) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

const LocalDateEvidenceSchema = z.string().refine(isValidLocalDate, 'must be a valid stored local date');
const LocalTimeEvidenceSchema = z.string().regex(
  /^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d(?:\.\d{1,6})?)?$/,
  'must be a valid stored local time',
);

export const LegacyEstimatedHistoryV1Schema = z.object({
  kind: z.literal('legacyEstimatedHistory'),
  version: z.literal(1),
  historyId: z.guid(),
  historyEntryId: z.guid(),
  sourceRevision: PositiveRevisionSchema,
  operation: z.enum(['upsert', 'tombstone']),
  legacySourceKind: z.enum(['dose_log', 'pill_stock']),
  legacySourceId: z.guid(),
  pillId: z.guid().nullable(),
  scheduleId: z.guid().nullable(),
  localDateEvidence: LocalDateEvidenceSchema.nullable(),
  localTimeEvidence: LocalTimeEvidenceSchema.nullable(),
  storedUtc: z.string().datetime({ offset: true }).nullable(),
  timeZoneStatus: z.literal('legacy_unknown'),
  provenance: z.literal('legacy_estimated'),
  state: z.enum(['taken', 'missed', 'skipped']).nullable(),
  historicalInventoryDeltaEvidence: SignedDeltaSchema.nullable(),
  inventoryDeltaProvenance: z.enum(['explicit_source', 'linked_command', 'unknown']),
  migrationInventoryEffect: z.literal('none'),
  inventoryDisposition: z.enum(['evidence_only', 'effect_unknown']),
  sourceFingerprint: z.string().regex(/^[a-f0-9]{64}$/),
  entityRevision: PositiveRevisionSchema,
}).strict().superRefine((history, ctx) => {
  const hasDeltaEvidence = history.historicalInventoryDeltaEvidence !== null;
  if (hasDeltaEvidence !== (history.inventoryDeltaProvenance !== 'unknown')) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: 'delta evidence and its provenance must either both be present or both be unknown',
      path: ['inventoryDeltaProvenance'],
    });
  }
  if (hasDeltaEvidence !== (history.inventoryDisposition === 'evidence_only')) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: 'inventory disposition must distinguish preserved evidence from an unknown effect',
      path: ['inventoryDisposition'],
    });
  }
});

export type LegacyEstimatedHistoryV1 = z.infer<typeof LegacyEstimatedHistoryV1Schema>;

export const MAX_LEGACY_HISTORY_BYTES = 8192;

function canonicalJson(value: unknown): string {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') {
    return JSON.stringify(value);
  }
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new TypeError('Legacy history contains a non-finite number');
    return JSON.stringify(Object.is(value, -0) ? 0 : value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (typeof value === 'object') {
    const record = value as Record<string, unknown>;
    const keys = Object.keys(record).filter((key) => record[key] !== undefined).sort();
    return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalJson(record[key])}`).join(',')}}`;
  }
  throw new TypeError('Legacy history is not JSON-compatible');
}

export function serializeLegacyEstimatedHistory(input: unknown): {
  value: LegacyEstimatedHistoryV1;
  canonicalJson: string;
} {
  const value = LegacyEstimatedHistoryV1Schema.parse(input);
  const json = canonicalJson(value);
  if (Buffer.byteLength(json, 'utf8') > MAX_LEGACY_HISTORY_BYTES) {
    throw new RangeError('Legacy history exceeds the safe payload limit');
  }
  return { value, canonicalJson: json };
}
