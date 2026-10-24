import { Buffer } from 'node:buffer';
import { z } from 'zod';
import { LegacyEstimatedHistoryV1Schema } from './legacy-estimated-history.js';
import { AdministrationAmountSchema } from '../shared/administration-amount.js';
import { RecordedBySchema } from '../shared/recorded-by.js';
import { isCanonicalStock, isStockInRange, parseCanonicalStock } from '../shared/stock-quantity.js';

const StockQuantityWireSchema = z.string().refine(
  (value) => isCanonicalStock(value) && isStockInRange(parseCanonicalStock(value)),
  'a stock quantity must be a canonical decimal with at most six fraction digits',
);

const MAX_SIGNED_64 = 9_223_372_036_854_775_807n;
const UuidSchema = z.guid();
const PositiveDecimalSchema = z.string().refine(
  (value) => /^[1-9]\d{0,18}$/.test(value) && BigInt(value) <= MAX_SIGNED_64,
  'must be a canonical positive signed-64 decimal string',
);
const NonNegativeDecimalSchema = z.string().refine(
  (value) => /^(0|[1-9]\d{0,18})$/.test(value) && BigInt(value) <= MAX_SIGNED_64,
  'must be a canonical non-negative signed-64 decimal string',
);
const LocalDateSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).refine((value) => {
  if (value.startsWith('0000-')) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}, 'must be a valid Gregorian date (YYYY-MM-DD)');
const DateTimeSchema = z.string().datetime({ offset: true });
const IanaTimeZoneSchema = z.string().min(1).max(128).refine((value) => {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: value });
    return true;
  } catch {
    return false;
  }
}, 'must be a supported IANA timezone');
const WeekdayArraySchema = z.array(z.number().int().min(1).max(7)).max(7)
  .refine((days) => new Set(days).size === days.length);

const ScheduleIssueSnapshotSchema = z.object({
  scheduleId: UuidSchema,
  sourceScheduleRevision: PositiveDecimalSchema,
  frequency: z.enum(['daily', 'weekly', 'custom', 'prn']),
  frequencyDays: z.array(z.number().int().nullable()).max(4096).nullable(),
  isActive: z.boolean(),
  deletedAt: DateTimeSchema.nullable(),
  timeZoneStatus: z.literal('legacy_unknown'),
  timeZone: z.null(),
}).strict();

const SplitIssueSnapshotSchema = z.object({
  version: z.literal(1),
  reason: z.enum(['source_missing', 'base_changed', 'evidence_ambiguous', 'evidence_conflict']),
  legacySourceKind: z.enum(['dose_log', 'pill_stock']).nullable(),
  legacySourceId: UuidSchema.nullable(),
  sourceFingerprint: z.string().regex(/^[a-f0-9]{64}$/).nullable(),
  observedBaseRevision: PositiveDecimalSchema.nullable(),
  observedBaseStock: z.number().int().nullable(),
  targetStock: z.number().int().nullable(),
  settlement: z.object({
    version: z.literal(1),
    commandId: UuidSchema,
    resolution: z.enum(['adopt', 'apply_residual', 'keep_server_state']),
    disposition: z.enum(['adopted', 'residual_applied', 'kept_server_state']),
    issueId: UuidSchema,
  }).strict().optional(),
}).strict();

const SafeIssueSnapshotSchema = z.union([
  ScheduleIssueSnapshotSchema,
  SplitIssueSnapshotSchema,
]);

const AccountItemSchema = z.object({
  kind: z.literal('account'),
  id: UuidSchema,
  email: z.string().email().max(254),
  revision: PositiveDecimalSchema,
  createdAt: DateTimeSchema,
  updatedAt: DateTimeSchema,
}).strict();

const MigrationIssueItemSchema = z.object({
  kind: z.literal('migrationIssue'),
  id: UuidSchema,
  entityType: z.string().regex(/^[a-z][a-z0-9_]{0,31}$/),
  entityId: UuidSchema,
  issueCode: z.string().regex(/^[a-z][a-z0-9_]{0,63}$/),
  safeSnapshot: SafeIssueSnapshotSchema,
  revision: PositiveDecimalSchema,
  state: z.enum(['unresolved', 'resolved']),
  resolvedAt: DateTimeSchema.nullable(),
  createdAt: DateTimeSchema,
}).strict();

const ProfileItemSchema = z.object({
  kind: z.literal('profile'),
  id: UuidSchema,
  userId: UuidSchema,
  name: z.string().min(1).max(100),
  avatarEmoji: z.string().min(1).max(32),
  isActive: z.boolean(),
  revision: PositiveDecimalSchema,
  deletedAt: DateTimeSchema.nullable(),
  createdAt: DateTimeSchema,
  updatedAt: DateTimeSchema,
}).strict();

const PillItemSchema = z.object({
  kind: z.literal('pill'),
  id: UuidSchema,
  profileId: UuidSchema,
  name: z.string().min(1).max(100),
  dosage: z.string().max(50).nullable(),
  notes: z.string().max(500).nullable(),
  color: z.string().regex(/^#[0-9A-Fa-f]{6}$/).nullable(),
  currentStock: z.number().int().safe().nullable(),
  // Exact stock for a medicine counted in a unit; `currentStock` stays the
  // whole part. Present only when `stockUnit` is.
  stockQuantity: StockQuantityWireSchema.optional(),
  stockUnit: z.string().min(1).max(80).optional(),
  // Sent only as true: a take that could not be subtracted exactly left the
  // count alone, so it needs a recount until a count command clears it.
  stockNeedsRecount: z.boolean().optional(),
  lowStockThreshold: z.number().int().min(0).safe().nullable(),
  isPrn: z.boolean(),
  // The reviewed details are optional for life. Every stored change row is
  // re-parsed on each pull, and the rows written before migration 0025 do not
  // carry these keys, so requiring one would fail every pull of older history.
  amountPerUse: AdministrationAmountSchema.nullable().optional(),
  packageStrength: z.string().max(500).nullable().optional(),
  form: z.string().max(500).nullable().optional(),
  legacyDosageReviewed: z.boolean().optional(),
  // The silhouette picked for the medicine. Read permissively on purpose:
  // every stored change row is re-parsed on each pull, so a name added by a
  // later release must not fail the pull. The write side (pills.schema.ts and
  // the database check) accepts only the published names; readers treat any
  // other value as "no shape chosen".
  shape: z.string().min(1).max(32).nullable().optional(),
  // Limits, expiry and contacts (capability medicationDetailsExtra 1). Optional
  // for life and present only once set, so a change row written before
  // migration 0033 still parses. Contacts are personal data.
  prnMaxPer24h: z.number().int().min(1).max(48).nullable().optional(),
  prnMinGapMinutes: z.number().int().min(1).max(2880).nullable().optional(),
  expiresOn: LocalDateSchema.nullable().optional(),
  prescriberName: z.string().min(1).max(120).nullable().optional(),
  prescriberPhone: z.string().min(3).max(40).nullable().optional(),
  pharmacyName: z.string().min(1).max(120).nullable().optional(),
  pharmacyPhone: z.string().min(3).max(40).nullable().optional(),
  // The photo of the medicine (capability contracts.medicationPhoto 1): a
  // reference only, present only while a photo is set. The bytes travel on
  // GET /pills/:id/photo; a changed sha256 tells a device to fetch them.
  photo: z.object({
    sha256: z.string().regex(/^[0-9a-f]{64}$/),
    revision: PositiveDecimalSchema,
  }).strict().optional(),
  revision: PositiveDecimalSchema,
  deletedAt: DateTimeSchema.nullable(),
  createdAt: DateTimeSchema,
  updatedAt: DateTimeSchema,
}).strict();

const ScheduleItemSchema = z.object({
  kind: z.literal('schedule'),
  id: UuidSchema,
  pillId: UuidSchema,
  hour: z.number().int().min(0).max(23),
  minute: z.number().int().min(0).max(59),
  frequency: z.enum(['daily', 'weekly', 'custom', 'interval', 'prn']),
  frequencyDays: WeekdayArraySchema.nullable(),
  // Present only when the schedule is an interval or has a start or end date.
  // Optional so every payload stored before they existed still parses.
  everyDays: z.number().int().min(1).max(36500).nullable().optional(),
  anchorDate: LocalDateSchema.nullable().optional(),
  startDate: LocalDateSchema.nullable().optional(),
  endDate: LocalDateSchema.nullable().optional(),
  isActive: z.boolean(),
  revision: PositiveDecimalSchema,
  timeZoneStatus: z.enum(['known', 'legacy_unknown']),
  timeZone: IanaTimeZoneSchema.nullable(),
  deletedAt: DateTimeSchema.nullable(),
  createdAt: DateTimeSchema,
  updatedAt: DateTimeSchema,
}).strict().superRefine((schedule, ctx) => {
  if ((schedule.timeZoneStatus === 'known') !== (schedule.timeZone !== null)) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'timezone status and value disagree', path: ['timeZone'] });
  }
});

const HistoricalParentScheduleSchema = z.object({
  id: UuidSchema,
  pillId: UuidSchema,
  hour: z.number().int().min(0).max(23),
  minute: z.number().int().min(0).max(59),
  frequency: z.enum(['daily', 'weekly', 'custom', 'interval', 'prn']),
  // Preserve quarantined legacy evidence exactly. These values deliberately
  // are not constrained to valid weekdays or uniqueness.
  frequencyDays: z.array(z.number().int().min(-2147483648).max(2147483647).nullable()).max(4096).nullable(),
  revision: PositiveDecimalSchema,
  createdAt: DateTimeSchema,
  updatedAt: DateTimeSchema,
  deletedAt: DateTimeSchema.nullable(),
  disposition: z.enum(['quarantined', 'deleted']),
}).strict().superRefine((parent, ctx) => {
  if (parent.disposition === 'quarantined' && parent.deletedAt !== null) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'quarantined parent cannot be deleted', path: ['deletedAt'] });
  }
  if (parent.disposition === 'deleted' && parent.deletedAt === null) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'deleted parent requires deletedAt', path: ['deletedAt'] });
  }
});

const BridgeDoseItemSchema = z.object({
  kind: z.literal('bridgeDose'),
  id: UuidSchema,
  scheduleId: UuidSchema,
  scheduledAt: DateTimeSchema,
  takenAt: DateTimeSchema.nullable(),
  status: z.enum(['taken', 'missed', 'skipped']),
  deletedAt: DateTimeSchema.nullable(),
  sourceRevision: PositiveDecimalSchema,
  parentSchedule: HistoricalParentScheduleSchema.optional(),
  parentPill: PillItemSchema.optional(),
  parentProfile: ProfileItemSchema.optional(),
}).strict().superRefine((dose, ctx) => {
  if (dose.parentSchedule && dose.parentSchedule.id !== dose.scheduleId) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'parent schedule identity does not match bridge dose', path: ['parentSchedule', 'id'] });
  }
  if (dose.parentPill !== undefined || dose.parentProfile !== undefined) {
    if (!dose.parentSchedule || !dose.parentPill || !dose.parentProfile
        || dose.parentSchedule.pillId !== dose.parentPill.id
        || dose.parentPill.profileId !== dose.parentProfile.id) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'historical ancestor chain is incomplete or inconsistent', path: ['parentPill'] });
    }
  }
});

const BridgeStockItemSchema = z.object({
  kind: z.literal('bridgeStock'),
  pillId: UuidSchema,
  currentStock: z.number().int().safe().nullable(),
  sourceRevision: PositiveDecimalSchema,
  updatedAt: DateTimeSchema,
}).strict();

const ScheduleSnapshotV1Schema = z.object({
  version: z.literal(1),
  pillName: z.string().min(1).max(100),
  dosage: z.string().max(50).nullable(),
  frequency: z.enum(['daily', 'weekly', 'custom', 'prn']),
  frequencyDays: WeekdayArraySchema.nullable(),
  hour: z.number().int().min(0).max(23).nullable(),
  minute: z.number().int().min(0).max(59).nullable(),
  timeZone: IanaTimeZoneSchema,
  profileId: UuidSchema,
  profileName: z.string().min(1).max(100),
}).strict();

// Version 2 is the app's device-local snapshot and never reaches the server.
const ScheduleSnapshotV3Schema = z.object({
  version: z.literal(3),
  pillName: z.string().min(1).max(100),
  dosage: z.string().max(50).nullable(),
  frequency: z.enum(['daily', 'weekly', 'custom', 'interval']),
  frequencyDays: WeekdayArraySchema.nullable(),
  everyDays: z.number().int().min(1).max(36500).nullable(),
  anchorDate: LocalDateSchema.nullable(),
  startDate: LocalDateSchema.nullable(),
  endDate: LocalDateSchema.nullable(),
  hour: z.number().int().min(0).max(23).nullable(),
  minute: z.number().int().min(0).max(59).nullable(),
  timeZone: IanaTimeZoneSchema,
  profileId: UuidSchema,
  profileName: z.string().min(1).max(100),
}).strict();

const OccurrenceItemSchema = z.object({
  kind: z.literal('medicationOccurrence'),
  id: UuidSchema,
  pillId: UuidSchema.nullable(),
  scheduleId: UuidSchema.nullable(),
  occurrenceKey: z.string().min(1).max(256),
  source: z.enum(['scheduled', 'prn', 'legacy']),
  scheduleRevision: PositiveDecimalSchema.nullable(),
  plannedLocalDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  plannedLocalTime: z.string().regex(/^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d(?:\.\d{1,6})?)?$/).nullable(),
  timeZone: z.string().min(1).max(128),
  plannedAt: DateTimeSchema.nullable(),
  expected: z.boolean(),
  snapshotVersion: z.union([z.literal(1), z.literal(3)]),
  scheduleSnapshot: z.union([ScheduleSnapshotV1Schema, ScheduleSnapshotV3Schema]),
  provenance: z.enum(['exact', 'legacy_estimated']),
  supersededAt: DateTimeSchema.nullable(),
  supersededByOccurrenceId: UuidSchema.nullable(),
  stateVersion: NonNegativeDecimalSchema,
}).strict().superRefine((occurrence, ctx) => {
  if (occurrence.snapshotVersion !== occurrence.scheduleSnapshot.version) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'snapshot version disagrees with the snapshot', path: ['snapshotVersion'] });
  }
});

const OccurrenceEventItemSchema = z.object({
  kind: z.literal('occurrenceEvent'),
  id: UuidSchema,
  occurrenceId: UuidSchema,
  commandId: UuidSchema,
  action: z.enum(['take', 'skip', 'undo', 'correct', 'miss']),
  fromState: z.enum(['pending', 'taken', 'skipped', 'missed']),
  toState: z.enum(['pending', 'taken', 'skipped', 'missed']),
  reversesEventId: UuidSchema.nullable(),
  rebasesCommandId: UuidSchema.nullable(),
  actualAt: DateTimeSchema.nullable(),
  actualTimeKnown: z.boolean(),
  administrationAmount: z.union([
    z.object({ version: z.literal(1), state: z.literal('unknown') }).strict(),
    z.object({
      version: z.literal(1), state: z.literal('known'),
      quantity: z.string().min(1).max(64), unit: z.string().min(1).max(80),
    }).strict(),
  ]).nullable().default(null),
  recordedBy: RecordedBySchema.optional(),
  note: z.string().max(500).nullable(),
  origin: z.enum(['native', 'legacy_backfill', 'legacy_handoff']),
  baseVersion: NonNegativeDecimalSchema,
  resultVersion: PositiveDecimalSchema,
  serverSequence: PositiveDecimalSchema,
  recordedAt: DateTimeSchema,
}).strict().refine((event) => event.actualTimeKnown === (event.actualAt !== null), {
  message: 'actual-time evidence and its known flag disagree',
  path: ['actualTimeKnown'],
});

const InventoryEventItemSchema = z.object({
  kind: z.literal('inventoryEvent'),
  id: UuidSchema,
  pillId: UuidSchema,
  commandId: UuidSchema,
  eventKind: z.enum(['opening', 'dose', 'dose_reversal', 'refill', 'correction']),
  // A whole-number change keeps `delta`; an exact change in a unit travels as
  // `quantityDelta`. At least one is present and they agree when both are.
  delta: z.number().int().optional(),
  quantityDelta: StockQuantityWireSchema.optional(),
  occurrenceEventId: UuidSchema.nullable(),
  reversesInventoryEventId: UuidSchema.nullable(),
  provenance: z.enum(['native', 'legacy_backfill', 'legacy_handoff']),
  note: z.string().max(500).nullable(),
  serverSequence: PositiveDecimalSchema,
  recordedAt: DateTimeSchema,
}).strict().refine((event) => event.delta !== undefined || event.quantityDelta !== undefined, {
  message: 'an inventory event carries delta or quantityDelta',
  path: ['delta'],
}).refine((event) => event.delta === undefined || event.quantityDelta === undefined
  || parseCanonicalStock(event.quantityDelta) === BigInt(event.delta) * 1_000_000n, {
  message: 'delta and quantityDelta disagree',
  path: ['quantityDelta'],
}).refine((event) => {
  const zero = event.quantityDelta !== undefined ? parseCanonicalStock(event.quantityDelta) === 0n : event.delta === 0;
  return !zero || event.eventKind === 'opening';
}, {
  message: 'zero inventory delta is permitted only for an opening event',
  path: ['delta'],
});

const TombstoneItemSchema = z.object({
  kind: z.literal('tombstone'),
  entityType: z.enum([
    'account', 'migration_issue', 'profile', 'pill', 'schedule', 'bridge_dose',
    'bridge_stock', 'medication_occurrence', 'occurrence_event', 'inventory_event',
    'legacy_medication_history',
  ]),
  id: UuidSchema,
  revision: PositiveDecimalSchema,
  deletedAt: DateTimeSchema,
}).strict();

const IdentityMappingItemSchema = z.object({
  kind: z.literal('identityMapping'),
  mappingRevision: PositiveDecimalSchema,
  legacySourceKind: z.enum(['dose_log', 'pill_stock']),
  legacySourceId: UuidSchema,
  historyId: UuidSchema.nullable(),
  bridgeCommandId: UuidSchema.nullable(),
  targetEntityType: z.enum(['medication_occurrence', 'occurrence_event', 'inventory_event', 'legacy_medication_history']),
  targetEntityId: UuidSchema,
  targetRevision: PositiveDecimalSchema,
}).strict();

const SyncItemSchema = z.union([
  AccountItemSchema,
  MigrationIssueItemSchema,
  ProfileItemSchema,
  PillItemSchema,
  ScheduleItemSchema,
  BridgeDoseItemSchema,
  BridgeStockItemSchema,
  OccurrenceItemSchema,
  OccurrenceEventItemSchema,
  InventoryEventItemSchema,
  LegacyEstimatedHistoryV1Schema,
  TombstoneItemSchema,
  IdentityMappingItemSchema,
]);

const SyncComponentSchema = z.enum(['account', 'stable', 'medicationBridge', 'medication']);
const SourceKindSchema = z.enum([
  'account', 'migration_issue', 'profile', 'pill', 'schedule', 'legacy_dose_log',
  'legacy_pill_stock', 'legacy_history_entry', 'occurrence', 'occurrence_event',
  'inventory_event', 'bridge_mapping',
]);

export const SyncChangePayloadV2Schema = z.object({
  schemaVersion: z.literal(2),
  component: SyncComponentSchema,
  entityType: z.enum([
    'account', 'migration_issue', 'profile', 'pill', 'schedule', 'bridge_dose',
    'bridge_stock', 'medication_occurrence', 'occurrence_event', 'inventory_event',
    'legacy_medication_history', 'identity_mapping',
  ]),
  entityId: UuidSchema,
  operation: z.enum(['upsert', 'tombstone', 'mapping']),
  sourceIdentity: z.object({
    sourceKind: SourceKindSchema,
    sourceId: UuidSchema,
    sourceRevision: PositiveDecimalSchema,
  }).strict(),
  payload: SyncItemSchema,
}).strict().superRefine((change, ctx) => {
  const item = change.payload;
  const expectedEntityTypeByKind: Record<Exclude<typeof item.kind, 'tombstone'>, string> = {
    account: 'account',
    migrationIssue: 'migration_issue',
    profile: 'profile',
    pill: 'pill',
    schedule: 'schedule',
    bridgeDose: 'bridge_dose',
    bridgeStock: 'bridge_stock',
    medicationOccurrence: 'medication_occurrence',
    occurrenceEvent: 'occurrence_event',
    inventoryEvent: 'inventory_event',
    legacyEstimatedHistory: 'legacy_medication_history',
    identityMapping: 'identity_mapping',
  };
  const expectedEntityType = item.kind === 'tombstone'
    ? item.entityType
    : expectedEntityTypeByKind[item.kind];
  if (change.entityType !== expectedEntityType) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'entityType does not match payload kind', path: ['entityType'] });
  }

  const expectedOperation = item.kind === 'tombstone'
    ? 'tombstone'
    : item.kind === 'identityMapping' ? 'mapping' : 'upsert';
  if (change.operation !== expectedOperation) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'operation does not match payload kind', path: ['operation'] });
  }

  const tombstoneComponent = item.kind === 'tombstone'
    ? item.entityType === 'account' || item.entityType === 'migration_issue' ? 'account'
      : item.entityType === 'profile' || item.entityType === 'pill' || item.entityType === 'schedule' ? 'stable'
        : item.entityType === 'bridge_dose' || item.entityType === 'bridge_stock' ? 'medicationBridge'
          : item.entityType === 'legacy_medication_history'
            ? (change.component === 'medicationBridge' ? 'medicationBridge' : 'medication')
            : 'medication'
    : undefined;
  const expectedComponent = item.kind === 'account' || item.kind === 'migrationIssue'
    ? 'account'
    : item.kind === 'profile' || item.kind === 'pill' || item.kind === 'schedule'
      ? 'stable'
      : item.kind === 'bridgeDose' || item.kind === 'bridgeStock'
        ? 'medicationBridge'
        : item.kind === 'medicationOccurrence' || item.kind === 'occurrenceEvent'
          ? (change.component === 'medicationBridge' ? 'medicationBridge' : 'medication')
        : item.kind === 'legacyEstimatedHistory'
          ? (change.component === 'medicationBridge' || change.component === 'medication'
            ? change.component : 'medication')
          : item.kind === 'tombstone' ? tombstoneComponent : 'medication';
  if (change.component !== expectedComponent) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'component does not match payload kind', path: ['component'] });
  }

  if (item.kind === 'tombstone') {
    if (change.entityId !== item.id) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'entityId does not match tombstone', path: ['entityId'] });
    }
  } else if (item.kind === 'identityMapping') {
    if (change.entityId !== item.targetEntityId) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'entityId does not match mapping target', path: ['entityId'] });
    }
  } else {
    const itemId = item.kind === 'bridgeStock'
      ? item.pillId
      : item.kind === 'legacyEstimatedHistory' ? item.historyId : item.id;
    if (change.entityId !== itemId) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'entityId does not match payload identity', path: ['entityId'] });
    }
  }

  let expectedSourceKind: z.infer<typeof SourceKindSchema> | undefined;
  let expectedSourceId: string | undefined;
  let expectedSourceRevision: string | undefined;
  if (item.kind === 'account') {
    expectedSourceKind = 'account'; expectedSourceId = item.id; expectedSourceRevision = item.revision;
  } else if (item.kind === 'migrationIssue') {
    expectedSourceKind = 'migration_issue'; expectedSourceId = item.id; expectedSourceRevision = item.revision;
  } else if (item.kind === 'profile') {
    expectedSourceKind = 'profile'; expectedSourceId = item.id; expectedSourceRevision = item.revision;
  } else if (item.kind === 'pill') {
    expectedSourceKind = 'pill'; expectedSourceId = item.id; expectedSourceRevision = item.revision;
  } else if (item.kind === 'schedule') {
    expectedSourceKind = 'schedule'; expectedSourceId = item.id; expectedSourceRevision = item.revision;
  } else if (item.kind === 'bridgeDose') {
    expectedSourceKind = 'legacy_dose_log'; expectedSourceId = item.id; expectedSourceRevision = item.sourceRevision;
  } else if (item.kind === 'bridgeStock') {
    expectedSourceKind = 'legacy_pill_stock'; expectedSourceId = item.pillId; expectedSourceRevision = item.sourceRevision;
  } else if (item.kind === 'medicationOccurrence') {
    expectedSourceKind = 'occurrence';
    expectedSourceId = item.id;
    expectedSourceRevision = (BigInt(item.stateVersion) + 1n).toString();
  } else if (item.kind === 'occurrenceEvent') {
    expectedSourceKind = 'occurrence_event'; expectedSourceId = item.id; expectedSourceRevision = item.serverSequence;
  } else if (item.kind === 'inventoryEvent') {
    expectedSourceKind = 'inventory_event'; expectedSourceId = item.id; expectedSourceRevision = item.serverSequence;
  } else if (item.kind === 'legacyEstimatedHistory') {
    expectedSourceKind = 'legacy_history_entry';
    expectedSourceId = item.historyEntryId;
    expectedSourceRevision = item.sourceRevision;
  } else if (item.kind === 'identityMapping') {
    expectedSourceKind = 'bridge_mapping';
    expectedSourceId = item.legacySourceId;
    expectedSourceRevision = item.mappingRevision;
  } else if (item.kind === 'tombstone') {
    const sourceByEntity: Record<typeof item.entityType, z.infer<typeof SourceKindSchema>> = {
      account: 'account', migration_issue: 'migration_issue', profile: 'profile', pill: 'pill',
      schedule: 'schedule', bridge_dose: 'legacy_dose_log', bridge_stock: 'legacy_pill_stock',
      medication_occurrence: 'occurrence', occurrence_event: 'occurrence_event',
      inventory_event: 'inventory_event', legacy_medication_history: 'legacy_history_entry',
    };
    expectedSourceKind = sourceByEntity[item.entityType];
    expectedSourceId = item.id;
    expectedSourceRevision = item.revision;
  }
  if (expectedSourceKind && change.sourceIdentity.sourceKind !== expectedSourceKind) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'sourceKind does not match payload kind', path: ['sourceIdentity', 'sourceKind'] });
  }
  if (expectedSourceId && change.sourceIdentity.sourceId !== expectedSourceId) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'sourceId does not match payload identity', path: ['sourceIdentity', 'sourceId'] });
  }
  if (expectedSourceRevision && change.sourceIdentity.sourceRevision !== expectedSourceRevision) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'sourceRevision does not match payload version', path: ['sourceIdentity', 'sourceRevision'] });
  }
});

export type SyncChangePayloadV2 = z.infer<typeof SyncChangePayloadV2Schema>;

export const MAX_SYNC_CHANGE_PAYLOAD_BYTES = 32_768;

export function canonicalJson(value: unknown): string {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') {
    return JSON.stringify(value);
  }
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new TypeError('Sync payload contains a non-finite number');
    return JSON.stringify(Object.is(value, -0) ? 0 : value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (typeof value === 'object') {
    const record = value as Record<string, unknown>;
    const keys = Object.keys(record).filter((key) => record[key] !== undefined).sort();
    return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalJson(record[key])}`).join(',')}}`;
  }
  throw new TypeError('Sync payload is not JSON-compatible');
}

export function serializeSyncChangePayload(input: unknown): {
  value: SyncChangePayloadV2;
  canonicalJson: string;
} {
  const value = SyncChangePayloadV2Schema.parse(input);
  if (value.payload.kind === 'bridgeDose' && value.payload.parentSchedule !== undefined) {
    throw new TypeError('Historical bridge parent metadata is response-only');
  }
  const json = canonicalJson(value);
  if (Buffer.byteLength(json, 'utf8') > MAX_SYNC_CHANGE_PAYLOAD_BYTES) {
    throw new RangeError('Sync payload exceeds the safe payload limit');
  }
  return { value, canonicalJson: json };
}
