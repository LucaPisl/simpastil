import {
  type AnyPgColumn,
  bigint,
  boolean,
  check,
  date,
  index,
  integer,
  jsonb,
  pgTable,
  text,
  time,
  timestamp,
  unique,
  uniqueIndex,
  uuid,
} from 'drizzle-orm/pg-core';
import { relations, sql } from 'drizzle-orm';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const uuidPk = () =>
  uuid('id')
    .primaryKey()
    .default(sql`gen_random_uuid()`);

const timestamps = {
  createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true, mode: 'date' })
    .notNull()
    .default(sql`now()`),
};

// ---------------------------------------------------------------------------
// users
// RLS policy: id = current_setting('app.current_user_id')::UUID
// ---------------------------------------------------------------------------

export const users = pgTable('users', {
  id: uuidPk(),
  email: text('email').notNull().unique(),
  passwordHash: text('password_hash').notNull(),
  sessionVersion: bigint('session_version', { mode: 'bigint' })
    .notNull()
    .default(sql`1`),
  totpSecret: text('totp_secret'),
  totpEnabled: boolean('totp_enabled').notNull().default(false),
  totpBackupCodes: text('totp_backup_codes').array(),
  totpLastUsedStep: bigint('totp_last_used_step', { mode: 'number' }),
  ...timestamps,
}, (table) => [
  check('users_session_version_check', sql`${table.sessionVersion} > 0`),
]);

// ---------------------------------------------------------------------------
// migration_issues — tenant-owned, revisioned review state for preserved data
// ---------------------------------------------------------------------------

export const migrationIssues = pgTable(
  'migration_issues',
  {
    id: uuidPk(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    entityType: text('entity_type').notNull(),
    entityId: uuid('entity_id').notNull(),
    issueCode: text('issue_code').notNull(),
    safeSnapshot: jsonb('safe_snapshot').notNull(),
    revision: bigint('revision', { mode: 'bigint' }).notNull().default(sql`1`),
    state: text('state').notNull().default('unresolved'),
    resolvedBy: uuid('resolved_by'),
    resolvedAt: timestamp('resolved_at', { withTimezone: true, mode: 'date' }),
    createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' })
      .notNull()
      .default(sql`now()`),
  },
  (table) => [
    unique('migration_issues_user_entity_code_key').on(
      table.userId,
      table.entityType,
      table.entityId,
      table.issueCode,
    ),
    index('migration_issues_user_state_created_idx').on(table.userId, table.state, table.createdAt),
    index('migration_issues_user_entity_idx').on(table.userId, table.entityType, table.entityId),
    check('migration_issues_revision_check', sql`${table.revision} > 0`),
    check(
      'migration_issues_code_check',
      sql`${table.entityType} ~ '^[a-z][a-z0-9_]{0,31}$'
        AND ${table.issueCode} ~ '^[a-z][a-z0-9_]{0,63}$'`,
    ),
    check(
      'migration_issues_snapshot_check',
      sql`jsonb_typeof(${table.safeSnapshot}) = 'object'
        AND octet_length(${table.safeSnapshot}::text) <= 16384`,
    ),
    check(
      'migration_issues_resolution_check',
      sql`(${table.state} = 'unresolved' AND ${table.revision} = 1
          AND ${table.resolvedBy} IS NULL AND ${table.resolvedAt} IS NULL)
        OR (${table.state} = 'resolved' AND ${table.revision} = 2
          AND ${table.resolvedBy} = ${table.userId} AND ${table.resolvedAt} IS NOT NULL)`,
    ),
  ],
);

// ---------------------------------------------------------------------------
// entity_mutation_receipts — permanent tenant-scoped retry authority
// ---------------------------------------------------------------------------

export const entityMutationReceipts = pgTable(
  'entity_mutation_receipts',
  {
    id: uuidPk(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    mutationId: uuid('mutation_id').notNull(),
    entityType: text('entity_type').notNull(),
    entityId: uuid('entity_id').notNull(),
    operation: text('operation').notNull(),
    baseRevision: bigint('base_revision', { mode: 'bigint' }),
    resultRevision: bigint('result_revision', { mode: 'bigint' }).notNull(),
    inputFingerprint: text('input_fingerprint').notNull(),
    resultMetadata: jsonb('result_metadata').notNull().default(sql`'{}'::jsonb`),
    createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' })
      .notNull()
      .default(sql`now()`),
  },
  (table) => [
    unique('entity_mutation_receipts_user_mutation_key').on(table.userId, table.mutationId),
    index('entity_mutation_receipts_user_entity_idx').on(table.userId, table.entityType, table.entityId),
    check(
      'entity_mutation_receipts_entity_type_check',
      sql`${table.entityType} IN ('profiles', 'pills', 'schedules')`,
    ),
    check(
      'entity_mutation_receipts_operation_check',
      sql`${table.operation} IN ('create', 'update', 'delete')`,
    ),
    check(
      'entity_mutation_receipts_revision_check',
      sql`${table.resultRevision} > 0 AND (
        (${table.operation} = 'create' AND ${table.baseRevision} IS NULL AND ${table.resultRevision} = 1)
        OR (${table.operation} IN ('update', 'delete') AND ${table.baseRevision} > 0
          AND ${table.resultRevision} = ${table.baseRevision} + 1)
      )`,
    ),
    check(
      'entity_mutation_receipts_fingerprint_check',
      sql`${table.inputFingerprint} ~ '^[a-f0-9]{64}$'`,
    ),
    check(
      'entity_mutation_receipts_result_metadata_check',
      sql`jsonb_typeof(${table.resultMetadata}) = 'object'
        AND octet_length(${table.resultMetadata}::text) <= 8192`,
    ),
  ],
);

// ---------------------------------------------------------------------------
// refresh_tokens
// RLS policy: user_id = current_setting('app.current_user_id')::UUID
// ---------------------------------------------------------------------------

export const refreshTokens = pgTable(
  'refresh_tokens',
  {
    id: uuidPk(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    // SHA-256 of the raw opaque token, stored as hex.
    // Never store the raw token — hash-on-lookup prevents token DB leaks.
    tokenHash: text('token_hash').notNull(),
    // Groups tokens into a "family" for reuse-detection invalidation.
    // When a revoked token is replayed, the entire family is invalidated.
    familyId: uuid('family_id').notNull(),
    expiresAt: timestamp('expires_at', {
      withTimezone: true,
      mode: 'date',
    }).notNull(),
    revoked: boolean('revoked').notNull().default(false),
    // Proof for exact recovery only; raw successor material remains client-side.
    successorTokenHash: text('successor_token_hash'),
    rotatedAt: timestamp('rotated_at', { withTimezone: true, mode: 'date' }),
    deviceName: text('device_name'),
    createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' })
      .notNull()
      .default(sql`now()`),
  },
  (table) => [
    uniqueIndex('refresh_tokens_token_hash_idx').on(table.tokenHash),
    index('refresh_tokens_user_revoked_idx').on(table.userId, table.revoked),
    index('refresh_tokens_family_idx').on(table.familyId),
  ],
);

// ---------------------------------------------------------------------------
// profiles
// RLS policy: user_id = current_setting('app.current_user_id')::UUID
// ---------------------------------------------------------------------------

export const profiles = pgTable('profiles', {
  id: uuidPk(),
  userId: uuid('user_id')
    .notNull()
    .references(() => users.id, { onDelete: 'cascade' }),
  name: text('name').notNull(),
  avatarEmoji: text('avatar_emoji').notNull().default('👤'),
  isActive: boolean('is_active').notNull().default(true),
  deletedAt: timestamp('deleted_at', { withTimezone: true, mode: 'date' }),
  // Stable API writes advance by exactly one and pair the increment with a new mutation ID.
  revision: bigint('revision', { mode: 'bigint' }).notNull().default(sql`1`),
  lastMutationId: uuid('last_mutation_id'),
  ...timestamps,
}, (table) => [
  check('profiles_revision_check', sql`${table.revision} > 0`),
]);

// ---------------------------------------------------------------------------
// pills
// RLS policy: profile_id IN (SELECT id FROM profiles WHERE user_id = ...)
// ---------------------------------------------------------------------------

export const pills = pgTable('pills', {
  id: uuidPk(),
  profileId: uuid('profile_id')
    .notNull()
    .references(() => profiles.id, { onDelete: 'cascade' }),
  name: text('name').notNull(),
  dosage: text('dosage'),   // nullable — e.g. "10mg"
  notes: text('notes'),     // nullable
  color: text('color'),     // nullable — hex e.g. "#FF5733"
  currentStock: integer('current_stock'),       // nullable — NULL = not tracking
  lowStockThreshold: integer('low_stock_threshold'), // nullable — NULL = no alert
  isPrn: boolean('is_prn').notNull().default(false),
  // The reviewed details. `dosage` above stays the original free text a person
  // typed; these carry what that text was reviewed into, so every device shows
  // the same amount instead of each one keeping its own.
  amountPerUse: jsonb('amount_per_use'),             // nullable — same shape as occurrence_events.administration_amount
  packageStrength: text('package_strength'),         // nullable — e.g. "500 mg tablets"
  form: text('form'),                                // nullable — e.g. "tablet"
  // Whether a person has dealt with the original `dosage` wording. The wording
  // itself is never rewritten, so only this flag can retire the reminder.
  legacyDosageReviewed: boolean('legacy_dosage_reviewed').notNull().default(false),
  deletedAt: timestamp('deleted_at', { withTimezone: true, mode: 'date' }),
  // Stable API writes advance by exactly one and pair the increment with a new mutation ID.
  revision: bigint('revision', { mode: 'bigint' }).notNull().default(sql`1`),
  lastMutationId: uuid('last_mutation_id'),
  ...timestamps,
}, (table) => [
  check('pills_revision_check', sql`${table.revision} > 0`),
  check('pills_package_strength_check', sql`${table.packageStrength} IS NULL OR length(${table.packageStrength}) <= 500`),
  check('pills_form_check', sql`${table.form} IS NULL OR length(${table.form}) <= 500`),
  // Mirrors occurrence_events_amount_check: the same amount shape, rejected in
  // the database too so no route can write one the clients cannot read.
  check('pills_amount_per_use_check', sql`
    ${table.amountPerUse} IS NULL OR COALESCE((
      jsonb_typeof(${table.amountPerUse}) = 'object'
      AND ${table.amountPerUse}->'version' = '1'::jsonb
      AND octet_length(${table.amountPerUse}::text) <= 512
      AND (
        ${table.amountPerUse} = '{"version": 1, "state": "unknown"}'::jsonb
        OR (
          ${table.amountPerUse}->>'state' = 'known'
          AND (${table.amountPerUse} - ARRAY['version', 'state', 'quantity', 'unit']) = '{}'::jsonb
          AND jsonb_typeof(${table.amountPerUse}->'quantity') = 'string'
          AND length(${table.amountPerUse}->>'quantity') BETWEEN 1 AND 64
          AND jsonb_typeof(${table.amountPerUse}->'unit') = 'string'
          AND length(${table.amountPerUse}->>'unit') BETWEEN 1 AND 80
        )
      )
    ), FALSE)
  `),
]);

// ---------------------------------------------------------------------------
// schedules
// RLS policy: via pills → profiles → users chain
// ---------------------------------------------------------------------------

export const schedules = pgTable(
  'schedules',
  {
    id: uuidPk(),
    pillId: uuid('pill_id')
      .notNull()
      .references(() => pills.id, { onDelete: 'cascade' }),
    hour: integer('hour').notNull(),
    minute: integer('minute').notNull(),
    // 'daily' | 'weekly' | 'custom' — enforced by CHECK constraint below
    frequency: text('frequency').notNull(),
    // ISO weekdays: 1=Mon … 7=Sun.
    // Required for 'weekly' (exactly one) and 'custom' (one or more).
    // Must be NULL for 'daily' and 'prn'.
    frequencyDays: integer('frequency_days').array(),
    isActive: boolean('is_active').notNull().default(true),
    deletedAt: timestamp('deleted_at', { withTimezone: true, mode: 'date' }),
    // The migration quarantine is immutable source evidence; only a guarded repair clears it.
    // Unknown legacy zones are never inferred from the server's timezone.
    // Stable API writes advance by exactly one and pair the increment with a new mutation ID.
    revision: bigint('revision', { mode: 'bigint' }).notNull().default(sql`1`),
    lastMutationId: uuid('last_mutation_id'),
    legacyQuarantineIssueId: uuid('legacy_quarantine_issue_id')
      .references(() => migrationIssues.id, { onDelete: 'no action' }),
    legacyQuarantineOrigin: text('legacy_quarantine_origin'),
    legacyQuarantineSource: jsonb('legacy_quarantine_source'),
    timezoneReviewIssueId: uuid('timezone_review_issue_id')
      .references(() => migrationIssues.id, { onDelete: 'no action' }),
    timeZoneStatus: text('time_zone_status').notNull().default('known'),
    timeZone: text('time_zone'),
    materializeFromLocalDate: date('materialize_from_local_date', { mode: 'string' }),
    ...timestamps,
  },
  (table) => [
    index('schedules_legacy_quarantine_issue_idx').on(table.legacyQuarantineIssueId),
    index('schedules_timezone_review_issue_idx').on(table.timezoneReviewIssueId),
    check('schedules_hour_check', sql`${table.hour} BETWEEN 0 AND 23`),
    check('schedules_minute_check', sql`${table.minute} BETWEEN 0 AND 59`),
    check('schedules_revision_check', sql`${table.revision} > 0`),
    check(
      'schedules_timezone_status_check',
      sql`(${table.timeZoneStatus} = 'known' AND ${table.timeZone} IS NOT NULL)
        OR (${table.timeZoneStatus} = 'legacy_unknown' AND ${table.timeZone} IS NULL)`,
    ),
    check(
      'schedules_legacy_quarantine_shape_check',
      sql`(${table.legacyQuarantineIssueId} IS NULL
          AND ${table.legacyQuarantineOrigin} IS NULL
          AND ${table.legacyQuarantineSource} IS NULL)
        OR (${table.legacyQuarantineIssueId} IS NOT NULL
          AND ${table.legacyQuarantineOrigin} = 'migration-0013'
          AND ${table.legacyQuarantineSource} IS NOT NULL
          AND jsonb_typeof(${table.legacyQuarantineSource}) = 'object'
          AND octet_length(${table.legacyQuarantineSource}::text) <= 16384)`,
    ),
    check(
      'schedules_frequency_check',
      sql`${table.frequency} IN ('daily', 'weekly', 'custom', 'prn')`,
    ),
    check(
      'schedules_frequency_days_check',
      sql`public.schedule_frequency_days_valid(${table.frequency}, ${table.frequencyDays})
        OR (${table.legacyQuarantineIssueId} IS NOT NULL
          AND ${table.legacyQuarantineOrigin} = 'migration-0013'
          AND ${table.legacyQuarantineSource} IS NOT NULL
          AND jsonb_typeof(${table.legacyQuarantineSource}) = 'object'
          AND octet_length(${table.legacyQuarantineSource}::text) <= 16384
          AND ${table.isActive} = false)`,
    ),
  ],
);

// ---------------------------------------------------------------------------
// dose_logs
// RLS policy: via schedules → pills → profiles → users chain
// ---------------------------------------------------------------------------

export const doseLogs = pgTable(
  'dose_logs',
  {
    id: uuidPk(),
    scheduleId: uuid('schedule_id')
      .notNull()
      .references(() => schedules.id, { onDelete: 'cascade' }),
    scheduledAt: timestamp('scheduled_at', {
      withTimezone: true,
      mode: 'date',
    }).notNull(),
    // NULL means the dose window is still open (not yet taken or missed)
    takenAt: timestamp('taken_at', { withTimezone: true, mode: 'date' }),
    // 'taken' | 'missed' | 'skipped' — enforced by CHECK constraint
    status: text('status').notNull(),
    note: text('note'),
    deletedAt: timestamp('deleted_at', { withTimezone: true, mode: 'date' }),
    createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' })
      .notNull()
      .default(sql`now()`),
    updatedAt: timestamp('updated_at', { withTimezone: true, mode: 'date' })
      .notNull()
      .default(sql`now()`),
  },
  (table) => [
    check(
      'dose_logs_status_check',
      sql`${table.status} IN ('taken', 'missed', 'skipped')`,
    ),
    index('idx_dose_logs_updated_at_id').on(table.updatedAt, table.id),
  ],
);

// ---------------------------------------------------------------------------
// medication_occurrences — immutable expected/actionable occurrence identity
// ---------------------------------------------------------------------------

export const medicationOccurrences = pgTable('medication_occurrences', {
  id: uuidPk(),
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  pillId: uuid('pill_id').references(() => pills.id, { onDelete: 'set null' }),
  scheduleId: uuid('schedule_id').references(() => schedules.id, { onDelete: 'set null' }),
  occurrenceKey: text('occurrence_key').notNull(),
  source: text('source').notNull(),
  scheduleRevision: bigint('schedule_revision', { mode: 'bigint' }),
  plannedLocalDate: date('planned_local_date', { mode: 'string' }).notNull(),
  plannedLocalTime: time('planned_local_time', { precision: 6 }),
  timeZone: text('time_zone').notNull(),
  plannedAt: timestamp('planned_at', { withTimezone: true, mode: 'date' }),
  expected: boolean('expected').notNull(),
  snapshotVersion: integer('snapshot_version').notNull().default(1),
  scheduleSnapshot: jsonb('schedule_snapshot').notNull(),
  provenance: text('provenance').notNull(),
  supersededAt: timestamp('superseded_at', { withTimezone: true, mode: 'date' }),
  supersededByOccurrenceId: uuid('superseded_by_occurrence_id')
    .references((): AnyPgColumn => medicationOccurrences.id, { onDelete: 'set null' }),
  stateVersion: bigint('state_version', { mode: 'bigint' }).notNull().default(sql`0`),
  createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
}, (table) => [
  unique('medication_occurrences_user_key').on(table.userId, table.occurrenceKey),
  index('medication_occurrences_user_date_idx').on(table.userId, table.plannedLocalDate, table.id),
  index('medication_occurrences_pill_date_idx').on(table.userId, table.pillId, table.plannedLocalDate),
  check('medication_occurrences_key_check', sql`length(${table.occurrenceKey}) BETWEEN 1 AND 256`),
  check('medication_occurrences_source_check', sql`${table.source} IN ('scheduled', 'prn', 'legacy')`),
  check('medication_occurrences_revision_check', sql`${table.scheduleRevision} IS NULL OR ${table.scheduleRevision} > 0`),
  check('medication_occurrences_source_shape_check', sql`
    (${table.source} = 'scheduled' AND ${table.scheduleId} IS NOT NULL
      AND ${table.scheduleRevision} IS NOT NULL AND ${table.plannedLocalTime} IS NOT NULL
      AND ${table.plannedAt} IS NOT NULL AND ${table.expected} = true)
    OR (${table.source} = 'prn' AND ${table.expected} = false)
    OR (${table.source} = 'legacy' AND ${table.expected} = false)
  `),
  check('medication_occurrences_local_time_check', sql`${table.plannedLocalTime} IS NOT NULL OR ${table.source} = 'prn'`),
  check('medication_occurrences_timezone_check', sql`length(${table.timeZone}) BETWEEN 1 AND 128`),
  check('medication_occurrences_snapshot_check', sql`
    jsonb_typeof(${table.scheduleSnapshot}) = 'object'
    AND ${table.scheduleSnapshot}->>'version' = '1'
    AND octet_length(${table.scheduleSnapshot}::text) <= 16384
  `),
  check('medication_occurrences_provenance_check', sql`${table.provenance} IN ('exact', 'legacy_estimated')`),
  check('medication_occurrences_supersession_check', sql`
    (${table.supersededAt} IS NULL AND ${table.supersededByOccurrenceId} IS NULL)
    OR (${table.supersededAt} IS NOT NULL
      AND (${table.supersededByOccurrenceId} IS NULL
        OR ${table.supersededByOccurrenceId} <> ${table.id}))
  `),
  check('medication_occurrences_state_version_check', sql`${table.stateVersion} >= 0`),
]);

// ---------------------------------------------------------------------------
// occurrence_events — append-only user actions and reducer evidence
// ---------------------------------------------------------------------------

export const occurrenceEvents = pgTable('occurrence_events', {
  id: uuidPk(),
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  occurrenceId: uuid('occurrence_id').notNull()
    .references(() => medicationOccurrences.id, { onDelete: 'restrict' }),
  commandId: uuid('command_id').notNull(),
  action: text('action').notNull(),
  fromState: text('from_state').notNull(),
  toState: text('to_state').notNull(),
  reversesEventId: uuid('reverses_event_id')
    .references((): AnyPgColumn => occurrenceEvents.id, { onDelete: 'restrict' }),
  rebasesCommandId: uuid('rebases_command_id'),
  actualAt: timestamp('actual_at', { withTimezone: true, mode: 'date' }),
  actualTimeKnown: boolean('actual_time_known').notNull(),
  administrationAmount: jsonb('administration_amount'),
  note: text('note'),
  origin: text('origin').notNull(),
  baseVersion: bigint('base_version', { mode: 'bigint' }).notNull(),
  resultVersion: bigint('result_version', { mode: 'bigint' }).notNull(),
  serverSequence: bigint('server_sequence', { mode: 'bigint' }).notNull(),
  recordedAt: timestamp('recorded_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
}, (table) => [
  unique('occurrence_events_user_command_key').on(table.userId, table.commandId),
  unique('occurrence_events_user_sequence_key').on(table.userId, table.serverSequence),
  index('occurrence_events_user_occurrence_sequence_idx').on(table.userId, table.occurrenceId, table.serverSequence),
  check('occurrence_events_action_check', sql`${table.action} IN ('take', 'skip', 'undo', 'correct', 'miss')`),
  check('occurrence_events_from_state_check', sql`${table.fromState} IN ('pending', 'taken', 'skipped', 'missed')`),
  check('occurrence_events_to_state_check', sql`${table.toState} IN ('pending', 'taken', 'skipped', 'missed')`),
  check('occurrence_events_origin_check', sql`${table.origin} IN ('native', 'legacy_backfill', 'legacy_handoff')`),
  check('occurrence_events_version_check', sql`
    ${table.baseVersion} >= 0 AND ${table.resultVersion} = ${table.baseVersion} + 1
    AND ${table.serverSequence} > 0
  `),
  check('occurrence_events_actual_time_check', sql`${table.actualTimeKnown} = (${table.actualAt} IS NOT NULL)`),
  check('occurrence_events_amount_check', sql`
    ${table.administrationAmount} IS NULL OR COALESCE((
      jsonb_typeof(${table.administrationAmount}) = 'object'
      AND ${table.administrationAmount}->'version' = '1'::jsonb
      AND octet_length(${table.administrationAmount}::text) <= 512
      AND (
        ${table.administrationAmount} = '{"version": 1, "state": "unknown"}'::jsonb
        OR (
          ${table.administrationAmount}->>'state' = 'known'
          AND (${table.administrationAmount} - ARRAY['version', 'state', 'quantity', 'unit']) = '{}'::jsonb
          AND jsonb_typeof(${table.administrationAmount}->'quantity') = 'string'
          AND length(${table.administrationAmount}->>'quantity') BETWEEN 1 AND 64
          AND jsonb_typeof(${table.administrationAmount}->'unit') = 'string'
          AND length(${table.administrationAmount}->>'unit') BETWEEN 1 AND 80
        )
      )
    ), FALSE)
  `),
  check('occurrence_events_note_check', sql`${table.note} IS NULL OR length(${table.note}) <= 500`),
]);

// ---------------------------------------------------------------------------
// inventory_events — append-only signed inventory deltas
// ---------------------------------------------------------------------------

export const inventoryEvents = pgTable('inventory_events', {
  id: uuidPk(),
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  pillId: uuid('pill_id').notNull().references(() => pills.id, { onDelete: 'restrict' }),
  commandId: uuid('command_id').notNull(),
  kind: text('kind').notNull(),
  delta: integer('delta').notNull(),
  occurrenceEventId: uuid('occurrence_event_id')
    .references(() => occurrenceEvents.id, { onDelete: 'restrict' }),
  reversesInventoryEventId: uuid('reverses_inventory_event_id')
    .references((): AnyPgColumn => inventoryEvents.id, { onDelete: 'restrict' }),
  provenance: text('provenance').notNull(),
  note: text('note'),
  serverSequence: bigint('server_sequence', { mode: 'bigint' }).notNull(),
  recordedAt: timestamp('recorded_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
}, (table) => [
  unique('inventory_events_user_sequence_key').on(table.userId, table.serverSequence),
  index('inventory_events_user_pill_sequence_idx').on(table.userId, table.pillId, table.serverSequence),
  index('inventory_events_occurrence_event_idx').on(table.userId, table.occurrenceEventId),
  check('inventory_events_kind_check', sql`${table.kind} IN ('opening', 'dose', 'dose_reversal', 'refill', 'correction')`),
  check('inventory_events_delta_check', sql`${table.delta} <> 0 OR ${table.kind} = 'opening'`),
  check('inventory_events_provenance_check', sql`${table.provenance} IN ('native', 'legacy_backfill', 'legacy_handoff')`),
  check('inventory_events_sequence_check', sql`${table.serverSequence} > 0`),
  check('inventory_events_note_check', sql`${table.note} IS NULL OR length(${table.note}) <= 500`),
]);

// ---------------------------------------------------------------------------
// preactivation_medication_receipts — inactive bridge retry authority
// ---------------------------------------------------------------------------

export const preactivationMedicationReceipts = pgTable('preactivation_medication_receipts', {
  id: uuidPk(),
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  commandId: uuid('command_id').notNull(),
  commandBundleId: uuid('command_bundle_id').notNull(),
  transactionCorrelationId: uuid('transaction_correlation_id').notNull(),
  origin: text('origin').notNull(),
  inputFingerprint: text('input_fingerprint').notNull(),
  sourceFingerprint: text('source_fingerprint'),
  intentMetadata: jsonb('intent_metadata').notNull(),
  plannedAt: timestamp('planned_at', { withTimezone: true, mode: 'date' }),
  plannedLocalDate: date('planned_local_date', { mode: 'string' }),
  dateOnly: boolean('date_only').notNull().default(false),
  inventoryDelta: integer('inventory_delta'),
  observedBaseStock: integer('observed_base_stock'),
  observedBaseRevision: bigint('observed_base_revision', { mode: 'bigint' }),
  targetStock: integer('target_stock'),
  adoptedLegacySourceIds: uuid('adopted_legacy_source_ids').array().notNull().default(sql`'{}'::uuid[]`),
  backfillReferenceIds: uuid('backfill_reference_ids').array().notNull().default(sql`'{}'::uuid[]`),
  reconciliationDisposition: text('reconciliation_disposition').notNull().default('pending'),
  expectedSubeffectCount: integer('expected_subeffect_count').notNull().default(0),
  observedSubeffectCount: integer('observed_subeffect_count').notNull().default(0),
  complete: boolean('complete').notNull().default(false),
  resultMetadata: jsonb('result_metadata'),
  createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
  completedAt: timestamp('completed_at', { withTimezone: true, mode: 'date' }),
}, (table) => [
  unique('preactivation_medication_receipts_user_command_key').on(table.userId, table.commandId),
  index('preactivation_medication_receipts_bundle_idx').on(table.userId, table.commandBundleId),
  check('preactivation_medication_receipts_origin_check', sql`${table.origin} IN ('bridge', 'legacy_split_reconciliation')`),
  check('preactivation_medication_receipts_input_fingerprint_check', sql`${table.inputFingerprint} ~ '^[a-f0-9]{64}$'`),
  check('preactivation_medication_receipts_source_fingerprint_check', sql`${table.sourceFingerprint} IS NULL OR ${table.sourceFingerprint} ~ '^[a-f0-9]{64}$'`),
  check('preactivation_medication_receipts_intent_check', sql`jsonb_typeof(${table.intentMetadata}) = 'object' AND octet_length(${table.intentMetadata}::text) <= 16384`),
  check('preactivation_medication_receipts_result_check', sql`${table.resultMetadata} IS NULL OR (jsonb_typeof(${table.resultMetadata}) = 'object' AND octet_length(${table.resultMetadata}::text) <= 8192)`),
  check('preactivation_medication_receipts_count_check', sql`
    ${table.expectedSubeffectCount} >= 0 AND ${table.observedSubeffectCount} >= 0
    AND ${table.observedSubeffectCount} <= ${table.expectedSubeffectCount}
    AND cardinality(${table.adoptedLegacySourceIds}) <= 128
    AND cardinality(${table.backfillReferenceIds}) <= 128
  `),
  check('preactivation_medication_receipts_completion_check', sql`
    (${table.complete} = false AND ${table.completedAt} IS NULL AND ${table.resultMetadata} IS NULL)
    OR (${table.complete} = true AND ${table.completedAt} IS NOT NULL
      AND ${table.resultMetadata} IS NOT NULL
      AND ${table.observedSubeffectCount} = ${table.expectedSubeffectCount}
      AND ${table.reconciliationDisposition} IN ('applied', 'adopted', 'residual_applied', 'kept_server_state'))
  `),
  check('preactivation_medication_receipts_disposition_check', sql`${table.reconciliationDisposition} IN ('pending', 'applied', 'adopted', 'residual_applied', 'kept_server_state')`),
  check('preactivation_medication_receipts_base_revision_check', sql`${table.observedBaseRevision} IS NULL OR ${table.observedBaseRevision} > 0`),
  check('preactivation_medication_receipts_date_only_check', sql`${table.dateOnly} = false OR ${table.plannedAt} IS NULL`),
  check('preactivation_medication_receipts_target_check', sql`
    ${table.targetStock} IS NULL
    OR (${table.observedBaseStock} IS NOT NULL AND ${table.inventoryDelta} IS NOT NULL
      AND ${table.targetStock}::bigint = ${table.observedBaseStock}::bigint + ${table.inventoryDelta}::bigint)
  `),
]);

// ---------------------------------------------------------------------------
// medication_command_receipts — permanent command retry authority
// ---------------------------------------------------------------------------

export const medicationCommandReceipts = pgTable('medication_command_receipts', {
  id: uuidPk(),
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  commandId: uuid('command_id').notNull(),
  inputFingerprint: text('input_fingerprint').notNull(),
  origin: text('origin').notNull(),
  resultMetadata: jsonb('result_metadata').notNull(),
  preactivationReceiptId: uuid('preactivation_receipt_id')
    .references(() => preactivationMedicationReceipts.id, { onDelete: 'restrict' }),
  createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
}, (table) => [
  unique('medication_command_receipts_user_command_key').on(table.userId, table.commandId),
  unique('medication_command_receipts_preactivation_receipt_key').on(table.preactivationReceiptId),
  index('medication_command_receipts_user_created_idx').on(table.userId, table.createdAt),
  check('medication_command_receipts_fingerprint_check', sql`${table.inputFingerprint} ~ '^[a-f0-9]{64}$'`),
  check('medication_command_receipts_origin_check', sql`${table.origin} IN ('native', 'legacy_handoff')`),
  check('medication_command_receipts_result_check', sql`jsonb_typeof(${table.resultMetadata}) = 'object' AND octet_length(${table.resultMetadata}::text) <= 8192`),
]);

// ---------------------------------------------------------------------------
// sync_stream_counters and sync_changes — ordered immutable publications
// ---------------------------------------------------------------------------

export const syncStreamCounters = pgTable('sync_stream_counters', {
  userId: uuid('user_id').primaryKey().references(() => users.id, { onDelete: 'cascade' }),
  lastSequence: bigint('last_sequence', { mode: 'bigint' }).notNull().default(sql`0`),
}, (table) => [
  check('sync_stream_counters_sequence_check', sql`${table.lastSequence} >= 0`),
]);

export const syncChanges = pgTable('sync_changes', {
  id: uuidPk(),
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  component: text('component').notNull(),
  entityType: text('entity_type').notNull(),
  entityId: uuid('entity_id').notNull(),
  operation: text('operation').notNull(),
  sourceKind: text('source_kind').notNull(),
  sourceId: uuid('source_id').notNull(),
  sourceRevision: bigint('source_revision', { mode: 'bigint' }).notNull(),
  serverSequence: bigint('server_sequence', { mode: 'bigint' }).notNull(),
  payloadSchemaVersion: integer('payload_schema_version').notNull(),
  payload: jsonb('payload').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
}, (table) => [
  unique('sync_changes_user_sequence_key').on(table.userId, table.serverSequence),
  unique('sync_changes_user_source_revision_key').on(table.userId, table.sourceKind, table.sourceId, table.sourceRevision),
  index('sync_changes_user_component_sequence_idx').on(table.userId, table.component, table.serverSequence),
  index('sync_changes_user_entity_sequence_idx').on(table.userId, table.entityType, table.entityId, table.serverSequence),
  check('sync_changes_component_check', sql`${table.component} IN ('account', 'stable', 'medicationBridge', 'medication')`),
  check('sync_changes_entity_type_check', sql`${table.entityType} IN ('account', 'migration_issue', 'profile', 'pill', 'schedule', 'bridge_dose', 'bridge_stock', 'medication_occurrence', 'occurrence_event', 'inventory_event', 'legacy_medication_history', 'identity_mapping')`),
  check('sync_changes_operation_check', sql`${table.operation} IN ('upsert', 'tombstone', 'mapping')`),
  check('sync_changes_source_kind_check', sql`${table.sourceKind} IN ('account', 'migration_issue', 'profile', 'pill', 'schedule', 'legacy_dose_log', 'legacy_pill_stock', 'legacy_history_entry', 'occurrence', 'occurrence_event', 'inventory_event', 'bridge_mapping')`),
  check('sync_changes_revision_sequence_check', sql`${table.sourceRevision} > 0 AND ${table.serverSequence} > 0`),
  check('sync_changes_payload_version_check', sql`${table.payloadSchemaVersion} > 0`),
  check('sync_changes_payload_check', sql`jsonb_typeof(${table.payload}) = 'object' AND octet_length(${table.payload}::text) <= 32768`),
]);

// ---------------------------------------------------------------------------
// legacy_medication_history — immutable evidence, never a ledger effect
// ---------------------------------------------------------------------------

export const legacyMedicationHistory = pgTable('legacy_medication_history', {
  historyEntryId: uuid('history_entry_id').primaryKey().default(sql`gen_random_uuid()`),
  historyId: uuid('history_id').notNull(),
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  sourceRevision: bigint('source_revision', { mode: 'bigint' }).notNull(),
  operation: text('operation').notNull(),
  legacySourceKind: text('legacy_source_kind').notNull(),
  legacySourceId: uuid('legacy_source_id').notNull(),
  pillId: uuid('pill_id').references(() => pills.id, { onDelete: 'set null' }),
  scheduleId: uuid('schedule_id').references(() => schedules.id, { onDelete: 'set null' }),
  localDateEvidence: date('local_date_evidence', { mode: 'string' }),
  localTimeEvidence: time('local_time_evidence', { precision: 6 }),
  storedUtc: timestamp('stored_utc', { withTimezone: true, mode: 'date' }),
  timeZoneStatus: text('time_zone_status').notNull().default('legacy_unknown'),
  provenance: text('provenance').notNull().default('legacy_estimated'),
  state: text('state'),
  historicalInventoryDeltaEvidence: bigint('historical_inventory_delta_evidence', { mode: 'bigint' }),
  inventoryDeltaProvenance: text('inventory_delta_provenance').notNull(),
  migrationInventoryEffect: text('migration_inventory_effect').notNull().default('none'),
  inventoryDisposition: text('inventory_disposition').notNull(),
  sourceFingerprint: text('source_fingerprint').notNull(),
  entityRevision: bigint('entity_revision', { mode: 'bigint' }).notNull(),
  sourceSnapshot: jsonb('source_snapshot').notNull(),
  coverageState: text('coverage_state').notNull().default('pending'),
  syncChangeId: uuid('sync_change_id').references(() => syncChanges.id, { onDelete: 'restrict' }),
  mappedEntityType: text('mapped_entity_type'),
  mappedEntityId: uuid('mapped_entity_id'),
  mappedAt: timestamp('mapped_at', { withTimezone: true, mode: 'date' }),
  createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
}, (table) => [
  unique('legacy_medication_history_user_entry_key').on(table.userId, table.historyEntryId),
  unique('legacy_medication_history_user_source_revision_key').on(table.userId, table.legacySourceKind, table.legacySourceId, table.sourceRevision),
  unique('legacy_medication_history_user_history_revision_key').on(table.userId, table.historyId, table.sourceRevision),
  index('legacy_medication_history_user_coverage_idx').on(table.userId, table.coverageState, table.createdAt),
  check('legacy_medication_history_operation_check', sql`${table.operation} IN ('upsert', 'tombstone')`),
  check('legacy_medication_history_source_check', sql`${table.legacySourceKind} IN ('dose_log', 'pill_stock')`),
  check('legacy_medication_history_revision_check', sql`${table.sourceRevision} > 0 AND ${table.entityRevision} > 0`),
  check('legacy_medication_history_source_shape_check', sql`
    (${table.legacySourceKind} = 'dose_log' AND ${table.state} IN ('taken', 'missed', 'skipped'))
    OR (${table.legacySourceKind} = 'pill_stock' AND ${table.state} IS NULL AND ${table.scheduleId} IS NULL)
  `),
  check('legacy_medication_history_timezone_check', sql`${table.timeZoneStatus} = 'legacy_unknown'`),
  check('legacy_medication_history_provenance_check', sql`${table.provenance} = 'legacy_estimated'`),
  check('legacy_medication_history_inventory_effect_check', sql`${table.migrationInventoryEffect} = 'none'`),
  check('legacy_medication_history_inventory_evidence_check', sql`
    (${table.historicalInventoryDeltaEvidence} IS NULL AND ${table.inventoryDeltaProvenance} = 'unknown' AND ${table.inventoryDisposition} = 'effect_unknown')
    OR (${table.historicalInventoryDeltaEvidence} IS NOT NULL AND ${table.inventoryDeltaProvenance} IN ('explicit_source', 'linked_command') AND ${table.inventoryDisposition} = 'evidence_only')
  `),
  check('legacy_medication_history_fingerprint_check', sql`${table.sourceFingerprint} ~ '^[a-f0-9]{64}$'`),
  check('legacy_medication_history_snapshot_check', sql`jsonb_typeof(${table.sourceSnapshot}) = 'object' AND octet_length(${table.sourceSnapshot}::text) <= 16384`),
  check('legacy_medication_history_coverage_check', sql`
    ${table.coverageState} IN ('pending', 'covered', 'blocked')
    AND (${table.coverageState} <> 'covered' OR
      (${table.syncChangeId} IS NOT NULL AND ${table.mappedEntityType} = 'legacy_medication_history'
        AND ${table.mappedEntityId} = ${table.historyId} AND ${table.mappedAt} IS NOT NULL))
  `),
]);

// ---------------------------------------------------------------------------
// medication_handoff_journal — append-only compatibility-write evidence
// ---------------------------------------------------------------------------

export const medicationHandoffJournal = pgTable('medication_handoff_journal', {
  id: uuidPk(),
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  journalSequence: bigint('journal_sequence', { mode: 'bigint' }).notNull(),
  commandBundleId: uuid('command_bundle_id').notNull(),
  transactionCorrelationId: uuid('transaction_correlation_id').notNull(),
  commandId: uuid('command_id'),
  commandFingerprint: text('command_fingerprint'),
  subeffectOrdinal: integer('subeffect_ordinal').notNull(),
  subeffectKind: text('subeffect_kind').notNull(),
  legacySourceKind: text('legacy_source_kind').notNull(),
  legacySourceId: uuid('legacy_source_id').notNull(),
  sourceRevision: bigint('source_revision', { mode: 'bigint' }).notNull(),
  beforeEvidence: jsonb('before_evidence'),
  afterEvidence: jsonb('after_evidence'),
  coverageState: text('coverage_state').notNull().default('pending'),
  historyEntryId: uuid('history_entry_id').references(() => legacyMedicationHistory.historyEntryId, { onDelete: 'restrict' }),
  mappedOccurrenceId: uuid('mapped_occurrence_id').references(() => medicationOccurrences.id, { onDelete: 'restrict' }),
  mappedOccurrenceEventId: uuid('mapped_occurrence_event_id').references(() => occurrenceEvents.id, { onDelete: 'restrict' }),
  mappedInventoryEventId: uuid('mapped_inventory_event_id').references(() => inventoryEvents.id, { onDelete: 'restrict' }),
  mappedAt: timestamp('mapped_at', { withTimezone: true, mode: 'date' }),
  createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
}, (table) => [
  unique('medication_handoff_journal_user_sequence_key').on(table.userId, table.journalSequence),
  unique('medication_handoff_journal_bundle_ordinal_key').on(table.userId, table.commandBundleId, table.subeffectOrdinal),
  unique('medication_handoff_journal_source_revision_key').on(table.userId, table.legacySourceKind, table.legacySourceId, table.sourceRevision),
  index('medication_handoff_journal_user_coverage_idx').on(table.userId, table.coverageState, table.journalSequence),
  check('medication_handoff_journal_sequence_check', sql`${table.journalSequence} > 0 AND ${table.sourceRevision} > 0 AND ${table.subeffectOrdinal} > 0`),
  check('medication_handoff_journal_source_kind_check', sql`${table.legacySourceKind} IN ('dose_log', 'pill_stock')`),
  check('medication_handoff_journal_subeffect_check', sql`${table.subeffectKind} IN ('dose', 'inventory')`),
  check('medication_handoff_journal_fingerprint_check', sql`${table.commandFingerprint} IS NULL OR ${table.commandFingerprint} ~ '^[a-f0-9]{64}$'`),
  check('medication_handoff_journal_evidence_check', sql`
    (${table.beforeEvidence} IS NULL OR (jsonb_typeof(${table.beforeEvidence}) = 'object' AND octet_length(${table.beforeEvidence}::text) <= 8192))
    AND (${table.afterEvidence} IS NULL OR (jsonb_typeof(${table.afterEvidence}) = 'object' AND octet_length(${table.afterEvidence}::text) <= 8192))
    AND (${table.beforeEvidence} IS NOT NULL OR ${table.afterEvidence} IS NOT NULL)
  `),
  check('medication_handoff_journal_coverage_check', sql`
    ${table.coverageState} IN ('pending', 'covered', 'blocked')
    AND (${table.coverageState} <> 'covered' OR
      (${table.mappedAt} IS NOT NULL AND
        (${table.historyEntryId} IS NOT NULL OR ${table.mappedOccurrenceId} IS NOT NULL
          OR ${table.mappedOccurrenceEventId} IS NOT NULL OR ${table.mappedInventoryEventId} IS NOT NULL)))
  `),
]);

// The counter is incremented through next_sync_server_sequence(), a bounded
// SECURITY DEFINER function added by migration 0014; its row lock is held to commit.

// ---------------------------------------------------------------------------
// password_reset_tokens
// ---------------------------------------------------------------------------

export const passwordResetTokens = pgTable('password_reset_tokens', {
  id: uuidPk(),
  userId: uuid('user_id')
    .notNull()
    .references(() => users.id, { onDelete: 'cascade' }),
  // SHA-256 of the raw opaque token, stored as hex.
  // The raw token is only ever sent to the user's email — never persisted.
  tokenHash: text('token_hash').notNull(),
  expiresAt: timestamp('expires_at', { withTimezone: true, mode: 'date' }).notNull(),
  used: boolean('used').notNull().default(false),
  createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' })
    .notNull()
    .default(sql`now()`),
});

// ---------------------------------------------------------------------------
// api_keys
// No RLS — apiKeyGuard looks up keys before user context is established.
// ---------------------------------------------------------------------------

export const apiKeys = pgTable(
  'api_keys',
  {
    id:          uuidPk(),
    userId:      uuid('user_id').references(() => users.id, { onDelete: 'cascade' }),
    keyHash:     text('key_hash').notNull(),
    encryptedKey: text('encrypted_key'),
    label:       text('label').notNull(),
    revokedAt:   timestamp('revoked_at', { withTimezone: true, mode: 'date' }),
    lastUsedAt:  timestamp('last_used_at', { withTimezone: true, mode: 'date' }),
    createdAt:   timestamp('created_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
  },
  (table) => [
    index('api_keys_key_hash_idx').on(table.keyHash),
    index('api_keys_user_id_idx').on(table.userId),
  ],
);

// ---------------------------------------------------------------------------
// admin_config — single-row table for first-run wizard
// ---------------------------------------------------------------------------

export const adminConfig = pgTable('admin_config', {
  id:           uuidPk(),
  email:        text('email').notNull(),
  passwordHash: text('password_hash').notNull(),
  sessionVersion: bigint('session_version', { mode: 'bigint' })
    .notNull()
    .default(sql`1`),
  totpSecret:   text('totp_secret'),
  totpEnabled:  boolean('totp_enabled').notNull().default(false),
  totpBackupCodes: text('totp_backup_codes').array(),
  totpLastUsedStep: bigint('totp_last_used_step', { mode: 'number' }),
  createdAt:    timestamp('created_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
}, (table) => [
  check('admin_config_session_version_check', sql`${table.sessionVersion} > 0`),
]);

// ---------------------------------------------------------------------------
// server_settings — single-row operator settings (password reset policy).
// Seeded by migration 0026; the API may only SELECT and UPDATE the row.
// ---------------------------------------------------------------------------

export const serverSettings = pgTable('server_settings', {
  singletonKey: boolean('singleton_key').primaryKey().default(sql`true`),
  // NULL means automatic: email when SMTP is configured, manual otherwise.
  passwordResetMode: text('password_reset_mode'),
  resetLinkLifetimeMinutes: integer('reset_link_lifetime_minutes').notNull().default(60),
  updatedAt: timestamp('updated_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
}, (table) => [
  check('server_settings_singleton_check', sql`${table.singletonKey} IS TRUE`),
  check('server_settings_reset_mode_check', sql`${table.passwordResetMode} IS NULL OR ${table.passwordResetMode} IN ('email', 'manual')`),
  check('server_settings_reset_lifetime_check', sql`${table.resetLinkLifetimeMinutes} BETWEEN 5 AND 1440`),
]);

// ---------------------------------------------------------------------------
// admin_refresh_tokens — separate from user refresh_tokens
// ---------------------------------------------------------------------------

export const adminRefreshTokens = pgTable(
  'admin_refresh_tokens',
  {
    id:        uuidPk(),
    tokenHash: text('token_hash').notNull(),
    familyId:  uuid('family_id').notNull(),
    expiresAt: timestamp('expires_at', { withTimezone: true, mode: 'date' }).notNull(),
    revoked:   boolean('revoked').notNull().default(false),
    createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
  },
  (table) => [
    index('admin_refresh_tokens_hash_idx').on(table.tokenHash),
    index('admin_refresh_tokens_family_idx').on(table.familyId),
  ],
);

// ---------------------------------------------------------------------------
// audit_logs — admin action audit trail
// No RLS — admin-only reads, writes via service layer.
// ---------------------------------------------------------------------------

export const auditLogs = pgTable(
  'audit_logs',
  {
    id:         uuidPk(),
    actor:      text('actor').notNull(),
    action:     text('action').notNull(),
    targetType: text('target_type').notNull(),
    targetId:   text('target_id'),
    metadata:   jsonb('metadata'),
    ipAddress:  text('ip_address'),
    createdAt:  timestamp('created_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
  },
  (table) => [
    index('audit_logs_action_idx').on(table.action),
    index('audit_logs_created_at_idx').on(table.createdAt),
  ],
);

// ---------------------------------------------------------------------------
// backup_codes — atomic single-use 2FA backup codes (H-2)
// RLS policy: user_id = current_setting('app.current_user_id')::UUID
// ---------------------------------------------------------------------------

export const backupCodes = pgTable(
  'backup_codes',
  {
    id: uuidPk(),
    userId: uuid('user_id').references(() => users.id, { onDelete: 'cascade' }),
    codeHash: text('code_hash').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' })
      .notNull()
      .default(sql`now()`),
  },
  (table) => [
    index('backup_codes_user_id_idx').on(table.userId),
  ],
);

// ---------------------------------------------------------------------------
// admin_bootstrap_state — single-use first-run bootstrap proof
// The token hash is the only persisted token material. The operator rotates
// the row and displays the plaintext proof once; existing configured admins
// are migrated as already consumed.
// ---------------------------------------------------------------------------

export const adminBootstrapState = pgTable(
  'admin_bootstrap_state',
  {
    id: uuidPk(),
    singletonKey: boolean('singleton_key').notNull().default(true),
    tokenHash: text('token_hash').notNull().unique(),
    generation: bigint('generation', { mode: 'bigint' }).notNull().default(sql`1`),
    createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
    expiresAt: timestamp('expires_at', { withTimezone: true, mode: 'date' }).notNull(),
    consumedAt: timestamp('consumed_at', { withTimezone: true, mode: 'date' }),
  },
  (table) => [
    unique('admin_bootstrap_state_singleton_key').on(table.singletonKey),
    index('admin_bootstrap_state_expires_at_idx').on(table.expiresAt),
    check('admin_bootstrap_state_singleton_check', sql`${table.singletonKey} IS TRUE`),
    check('admin_bootstrap_state_generation_check', sql`${table.generation} > 0`),
  ],
);

// ---------------------------------------------------------------------------
// invitation_tokens — hash-only invitation proofs tied to a generated key
// ---------------------------------------------------------------------------

export const invitationTokens = pgTable(
  'invitation_tokens',
  {
    id: uuidPk(),
    tokenHash: text('token_hash').notNull().unique(),
    recipientEmail: text('recipient_email').notNull(),
    apiKeyId: uuid('api_key_id')
      .notNull()
      .references(() => apiKeys.id, { onDelete: 'restrict' }),
    expiresAt: timestamp('expires_at', { withTimezone: true, mode: 'date' }).notNull(),
    consumedAt: timestamp('consumed_at', { withTimezone: true, mode: 'date' }),
    revokedAt: timestamp('revoked_at', { withTimezone: true, mode: 'date' }),
    ...timestamps,
  },
  (table) => [
    index('invitation_tokens_api_key_id_idx').on(table.apiKeyId),
    index('invitation_tokens_expires_at_idx').on(table.expiresAt),
  ],
);

// ---------------------------------------------------------------------------
// outbox_messages — envelope ciphertext and bounded delivery state
// ---------------------------------------------------------------------------

export const outboxMessages = pgTable(
  'outbox_messages',
  {
    id: uuidPk(),
    messageType: text('message_type').notNull(),
    recipientRef: text('recipient_ref').notNull(),
    encryptedDeliveryPayload: text('encrypted_delivery_payload'),
    state: text('state').notNull().default('queued'),
    attemptCount: integer('attempt_count').notNull().default(0),
    nextAttemptAt: timestamp('next_attempt_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
    safeErrorCategory: text('safe_error_category'),
    correlationId: text('correlation_id'),
    leaseExpiresAt: timestamp('lease_expires_at', { withTimezone: true, mode: 'date' }),
    sentAt: timestamp('sent_at', { withTimezone: true, mode: 'date' }),
    expiresAt: timestamp('expires_at', { withTimezone: true, mode: 'date' }).notNull(),
    ...timestamps,
  },
  (table) => [
    index('outbox_messages_claim_idx').on(table.state, table.nextAttemptAt),
    index('outbox_messages_expires_at_idx').on(table.expiresAt),
    check(
      'outbox_messages_state_check',
      sql`${table.state} IN ('queued', 'sending', 'retrying', 'sent', 'failedPermanent')`,
    ),
    check('outbox_messages_attempt_count_check', sql`${table.attemptCount} >= 0`),
    check(
      'outbox_messages_payload_state_check',
      sql`(${table.state} IN ('queued', 'sending', 'retrying') AND ${table.encryptedDeliveryPayload} IS NOT NULL)
        OR (${table.state} IN ('sent', 'failedPermanent'))`,
    ),
  ],
);

// ---------------------------------------------------------------------------
// deployment_manifest — single-row release and live authority state
// ---------------------------------------------------------------------------

export const deploymentManifest = pgTable(
  'deployment_manifest',
  {
    id: uuidPk(),
    singletonKey: boolean('singleton_key').notNull().default(true),
    schemaVersion: integer('schema_version').notNull().default(12),
    contractVersion: bigint('contract_version', { mode: 'bigint' }).notNull().default(sql`1`),
    ledgerActivated: boolean('ledger_activated').notNull().default(false),
    enforcedMinimumClientBuild: integer('enforced_minimum_client_build').notNull().default(1),
    targetMinimumClientBuild: integer('target_minimum_client_build').notNull().default(2),
    releaseId: text('release_id').notNull().default('migration-0012'),
    serverImageDigest: text('server_image_digest').notNull().default('unknown'),
    migrationCompletedAt: timestamp('migration_completed_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
    // Oldest bundled migration count an image may have and still run on this
    // database. Expand-only migrations leave it; breaking ones raise it.
    compatibleFromMigrationCount: integer('compatible_from_migration_count').notNull().default(25),
    ...timestamps,
  },
  (table) => [
    unique('deployment_manifest_singleton_key').on(table.singletonKey),
    check('deployment_manifest_compatible_from_check', sql`${table.compatibleFromMigrationCount} > 0`),
    check('deployment_manifest_singleton_check', sql`${table.singletonKey} IS TRUE`),
    check('deployment_manifest_schema_version_check', sql`${table.schemaVersion} > 0`),
    check('deployment_manifest_contract_version_check', sql`${table.contractVersion} > 0`),
    check('deployment_manifest_enforced_build_check', sql`${table.enforcedMinimumClientBuild} > 0`),
    check('deployment_manifest_target_build_check', sql`${table.targetMinimumClientBuild} = 2`),
  ],
);

// ---------------------------------------------------------------------------
// deployment_authority_events — append-only privileged transition audit
// ---------------------------------------------------------------------------

export const deploymentAuthorityEvents = pgTable(
  'deployment_authority_events',
  {
    id: uuidPk(),
    eventType: text('event_type').notNull(),
    oldContractVersion: bigint('old_contract_version', { mode: 'bigint' }).notNull(),
    newContractVersion: bigint('new_contract_version', { mode: 'bigint' }).notNull(),
    oldLedgerActivated: boolean('old_ledger_activated').notNull(),
    newLedgerActivated: boolean('new_ledger_activated').notNull(),
    oldEnforcedMinimumClientBuild: integer('old_enforced_minimum_client_build').notNull(),
    newEnforcedMinimumClientBuild: integer('new_enforced_minimum_client_build').notNull(),
    changeReference: text('change_reference').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' }).notNull().default(sql`now()`),
  },
  (table) => [
    index('deployment_authority_events_created_at_idx').on(table.createdAt),
    check(
      'deployment_authority_events_type_check',
      sql`${table.eventType} IN ('ledger_activation', 'minimum_client_build')`,
    ),
    check(
      'deployment_authority_events_contract_version_check',
      sql`${table.oldContractVersion} > 0 AND ${table.newContractVersion} >= ${table.oldContractVersion}`,
    ),
    check(
      'deployment_authority_events_build_check',
      sql`${table.oldEnforcedMinimumClientBuild} > 0 AND ${table.newEnforcedMinimumClientBuild} > 0`,
    ),
    check(
      'deployment_authority_events_transition_check',
      sql`(
        ${table.eventType} = 'ledger_activation'
        AND ${table.oldLedgerActivated} IS FALSE
        AND ${table.newLedgerActivated} IS TRUE
        AND ${table.oldEnforcedMinimumClientBuild} = ${table.newEnforcedMinimumClientBuild}
      ) OR (
        ${table.eventType} = 'minimum_client_build'
        AND ${table.oldLedgerActivated} = ${table.newLedgerActivated}
        AND ${table.oldContractVersion} = ${table.newContractVersion}
      )`,
    ),
    check('deployment_authority_events_reference_check', sql`length(${table.changeReference}) BETWEEN 1 AND 256`),
  ],
);

// ---------------------------------------------------------------------------
// Relations (for Drizzle's relational query API)
// ---------------------------------------------------------------------------

export const usersRelations = relations(users, ({ many }) => ({
  refreshTokens: many(refreshTokens),
  profiles: many(profiles),
  passwordResetTokens: many(passwordResetTokens),
  apiKeys: many(apiKeys),
  migrationIssues: many(migrationIssues),
  entityMutationReceipts: many(entityMutationReceipts),
}));

export const migrationIssuesRelations = relations(migrationIssues, ({ one }) => ({
  user: one(users, { fields: [migrationIssues.userId], references: [users.id] }),
}));

export const entityMutationReceiptsRelations = relations(entityMutationReceipts, ({ one }) => ({
  user: one(users, {
    fields: [entityMutationReceipts.userId],
    references: [users.id],
  }),
}));

export const refreshTokensRelations = relations(refreshTokens, ({ one }) => ({
  user: one(users, { fields: [refreshTokens.userId], references: [users.id] }),
}));

export const passwordResetTokensRelations = relations(passwordResetTokens, ({ one }) => ({
  user: one(users, { fields: [passwordResetTokens.userId], references: [users.id] }),
}));

export const profilesRelations = relations(profiles, ({ one, many }) => ({
  user: one(users, { fields: [profiles.userId], references: [users.id] }),
  pills: many(pills),
}));

export const pillsRelations = relations(pills, ({ one, many }) => ({
  profile: one(profiles, {
    fields: [pills.profileId],
    references: [profiles.id],
  }),
  schedules: many(schedules),
}));

export const schedulesRelations = relations(schedules, ({ one, many }) => ({
  pill: one(pills, { fields: [schedules.pillId], references: [pills.id] }),
  doseLogs: many(doseLogs),
}));

export const doseLogsRelations = relations(doseLogs, ({ one }) => ({
  schedule: one(schedules, {
    fields: [doseLogs.scheduleId],
    references: [schedules.id],
  }),
}));

export const apiKeysRelations = relations(apiKeys, ({ one }) => ({
  user: one(users, { fields: [apiKeys.userId], references: [users.id] }),
}));

export const invitationTokensRelations = relations(invitationTokens, ({ one }) => ({
  apiKey: one(apiKeys, { fields: [invitationTokens.apiKeyId], references: [apiKeys.id] }),
}));

// ---------------------------------------------------------------------------
// Exported TypeScript types inferred from the schema
// ---------------------------------------------------------------------------

export type User = typeof users.$inferSelect;
export type NewUser = typeof users.$inferInsert;

export type RefreshToken = typeof refreshTokens.$inferSelect;
export type NewRefreshToken = typeof refreshTokens.$inferInsert;

export type AdminBootstrapState = typeof adminBootstrapState.$inferSelect;
export type NewAdminBootstrapState = typeof adminBootstrapState.$inferInsert;

export type InvitationToken = typeof invitationTokens.$inferSelect;
export type NewInvitationToken = typeof invitationTokens.$inferInsert;

export type OutboxMessage = typeof outboxMessages.$inferSelect;
export type NewOutboxMessage = typeof outboxMessages.$inferInsert;

export type DeploymentManifest = typeof deploymentManifest.$inferSelect;
export type NewDeploymentManifest = typeof deploymentManifest.$inferInsert;

export type DeploymentAuthorityEvent = typeof deploymentAuthorityEvents.$inferSelect;
export type NewDeploymentAuthorityEvent = typeof deploymentAuthorityEvents.$inferInsert;

export type Profile = typeof profiles.$inferSelect;
export type NewProfile = typeof profiles.$inferInsert;

export type Pill = typeof pills.$inferSelect;
export type NewPill = typeof pills.$inferInsert;

export type Schedule = typeof schedules.$inferSelect;
export type NewSchedule = typeof schedules.$inferInsert;

export type DoseLog = typeof doseLogs.$inferSelect;
export type NewDoseLog = typeof doseLogs.$inferInsert;

export type PasswordResetToken = typeof passwordResetTokens.$inferSelect;
export type NewPasswordResetToken = typeof passwordResetTokens.$inferInsert;

export type ApiKey = typeof apiKeys.$inferSelect;
export type NewApiKey = typeof apiKeys.$inferInsert;
export type AdminConfig = typeof adminConfig.$inferSelect;
export type NewAdminConfig = typeof adminConfig.$inferInsert;
export type AdminRefreshToken = typeof adminRefreshTokens.$inferSelect;
export type NewAdminRefreshToken = typeof adminRefreshTokens.$inferInsert;
export type AuditLog = typeof auditLogs.$inferSelect;
export type NewAuditLog = typeof auditLogs.$inferInsert;
export type BackupCode = typeof backupCodes.$inferSelect;
export type NewBackupCode = typeof backupCodes.$inferInsert;
