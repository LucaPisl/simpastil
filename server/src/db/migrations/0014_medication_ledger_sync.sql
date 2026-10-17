CREATE TABLE "inventory_events" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"pill_id" uuid NOT NULL,
	"command_id" uuid NOT NULL,
	"kind" text NOT NULL,
	"delta" integer NOT NULL,
	"occurrence_event_id" uuid,
	"reverses_inventory_event_id" uuid,
	"provenance" text NOT NULL,
	"note" text,
	"server_sequence" bigint NOT NULL,
	"recorded_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "inventory_events_user_sequence_key" UNIQUE("user_id","server_sequence"),
	CONSTRAINT "inventory_events_kind_check" CHECK ("inventory_events"."kind" IN ('opening', 'dose', 'dose_reversal', 'refill', 'correction')),
	CONSTRAINT "inventory_events_delta_check" CHECK ("inventory_events"."delta" <> 0 OR "inventory_events"."kind" = 'opening'),
	CONSTRAINT "inventory_events_provenance_check" CHECK ("inventory_events"."provenance" IN ('native', 'legacy_backfill', 'legacy_handoff')),
	CONSTRAINT "inventory_events_sequence_check" CHECK ("inventory_events"."server_sequence" > 0),
	CONSTRAINT "inventory_events_note_check" CHECK ("inventory_events"."note" IS NULL OR length("inventory_events"."note") <= 500)
);
--> statement-breakpoint
CREATE TABLE "legacy_medication_history" (
	"history_entry_id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"history_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"source_revision" bigint NOT NULL,
	"operation" text NOT NULL,
	"legacy_source_kind" text NOT NULL,
	"legacy_source_id" uuid NOT NULL,
	"pill_id" uuid,
	"schedule_id" uuid,
	"local_date_evidence" date,
	"local_time_evidence" time(6),
	"stored_utc" timestamp with time zone,
	"time_zone_status" text DEFAULT 'legacy_unknown' NOT NULL,
	"provenance" text DEFAULT 'legacy_estimated' NOT NULL,
	"state" text,
	"historical_inventory_delta_evidence" bigint,
	"inventory_delta_provenance" text NOT NULL,
	"migration_inventory_effect" text DEFAULT 'none' NOT NULL,
	"inventory_disposition" text NOT NULL,
	"source_fingerprint" text NOT NULL,
	"entity_revision" bigint NOT NULL,
	"source_snapshot" jsonb NOT NULL,
	"coverage_state" text DEFAULT 'pending' NOT NULL,
	"sync_change_id" uuid,
	"mapped_entity_type" text,
	"mapped_entity_id" uuid,
	"mapped_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "legacy_medication_history_user_entry_key" UNIQUE("user_id","history_entry_id"),
	CONSTRAINT "legacy_medication_history_user_source_revision_key" UNIQUE("user_id","legacy_source_kind","legacy_source_id","source_revision"),
	CONSTRAINT "legacy_medication_history_user_history_revision_key" UNIQUE("user_id","history_id","source_revision"),
	CONSTRAINT "legacy_medication_history_operation_check" CHECK ("legacy_medication_history"."operation" IN ('upsert', 'tombstone')),
	CONSTRAINT "legacy_medication_history_source_check" CHECK ("legacy_medication_history"."legacy_source_kind" IN ('dose_log', 'pill_stock')),
	CONSTRAINT "legacy_medication_history_revision_check" CHECK ("legacy_medication_history"."source_revision" > 0 AND "legacy_medication_history"."entity_revision" > 0),
	CONSTRAINT "legacy_medication_history_source_shape_check" CHECK (
    ("legacy_medication_history"."legacy_source_kind" = 'dose_log' AND "legacy_medication_history"."state" IN ('taken', 'missed', 'skipped'))
    OR ("legacy_medication_history"."legacy_source_kind" = 'pill_stock' AND "legacy_medication_history"."state" IS NULL AND "legacy_medication_history"."schedule_id" IS NULL)
  ),
	CONSTRAINT "legacy_medication_history_timezone_check" CHECK ("legacy_medication_history"."time_zone_status" = 'legacy_unknown'),
	CONSTRAINT "legacy_medication_history_provenance_check" CHECK ("legacy_medication_history"."provenance" = 'legacy_estimated'),
	CONSTRAINT "legacy_medication_history_inventory_effect_check" CHECK ("legacy_medication_history"."migration_inventory_effect" = 'none'),
	CONSTRAINT "legacy_medication_history_inventory_evidence_check" CHECK (
    ("legacy_medication_history"."historical_inventory_delta_evidence" IS NULL AND "legacy_medication_history"."inventory_delta_provenance" = 'unknown' AND "legacy_medication_history"."inventory_disposition" = 'effect_unknown')
    OR ("legacy_medication_history"."historical_inventory_delta_evidence" IS NOT NULL AND "legacy_medication_history"."inventory_delta_provenance" IN ('explicit_source', 'linked_command') AND "legacy_medication_history"."inventory_disposition" = 'evidence_only')
  ),
	CONSTRAINT "legacy_medication_history_fingerprint_check" CHECK ("legacy_medication_history"."source_fingerprint" ~ '^[a-f0-9]{64}$'),
	CONSTRAINT "legacy_medication_history_snapshot_check" CHECK (jsonb_typeof("legacy_medication_history"."source_snapshot") = 'object' AND octet_length("legacy_medication_history"."source_snapshot"::text) <= 16384),
	CONSTRAINT "legacy_medication_history_coverage_check" CHECK (
    "legacy_medication_history"."coverage_state" IN ('pending', 'covered', 'blocked')
    AND ("legacy_medication_history"."coverage_state" <> 'covered' OR
      ("legacy_medication_history"."sync_change_id" IS NOT NULL AND "legacy_medication_history"."mapped_entity_type" = 'legacy_medication_history'
        AND "legacy_medication_history"."mapped_entity_id" = "legacy_medication_history"."history_id" AND "legacy_medication_history"."mapped_at" IS NOT NULL))
  )
);
--> statement-breakpoint
CREATE TABLE "medication_command_receipts" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"command_id" uuid NOT NULL,
	"input_fingerprint" text NOT NULL,
	"origin" text NOT NULL,
	"result_metadata" jsonb NOT NULL,
	"preactivation_receipt_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "medication_command_receipts_user_command_key" UNIQUE("user_id","command_id"),
	CONSTRAINT "medication_command_receipts_preactivation_receipt_key" UNIQUE("preactivation_receipt_id"),
	CONSTRAINT "medication_command_receipts_fingerprint_check" CHECK ("medication_command_receipts"."input_fingerprint" ~ '^[a-f0-9]{64}$'),
	CONSTRAINT "medication_command_receipts_origin_check" CHECK ("medication_command_receipts"."origin" IN ('native', 'legacy_handoff')),
	CONSTRAINT "medication_command_receipts_result_check" CHECK (jsonb_typeof("medication_command_receipts"."result_metadata") = 'object' AND octet_length("medication_command_receipts"."result_metadata"::text) <= 8192)
);
--> statement-breakpoint
CREATE TABLE "medication_handoff_journal" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"journal_sequence" bigint NOT NULL,
	"command_bundle_id" uuid NOT NULL,
	"transaction_correlation_id" uuid NOT NULL,
	"command_id" uuid,
	"command_fingerprint" text,
	"subeffect_ordinal" integer NOT NULL,
	"subeffect_kind" text NOT NULL,
	"legacy_source_kind" text NOT NULL,
	"legacy_source_id" uuid NOT NULL,
	"source_revision" bigint NOT NULL,
	"before_evidence" jsonb,
	"after_evidence" jsonb,
	"coverage_state" text DEFAULT 'pending' NOT NULL,
	"history_entry_id" uuid,
	"mapped_occurrence_id" uuid,
	"mapped_occurrence_event_id" uuid,
	"mapped_inventory_event_id" uuid,
	"mapped_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "medication_handoff_journal_user_sequence_key" UNIQUE("user_id","journal_sequence"),
	CONSTRAINT "medication_handoff_journal_bundle_ordinal_key" UNIQUE("user_id","command_bundle_id","subeffect_ordinal"),
	CONSTRAINT "medication_handoff_journal_source_revision_key" UNIQUE("user_id","legacy_source_kind","legacy_source_id","source_revision"),
	CONSTRAINT "medication_handoff_journal_sequence_check" CHECK ("medication_handoff_journal"."journal_sequence" > 0 AND "medication_handoff_journal"."source_revision" > 0 AND "medication_handoff_journal"."subeffect_ordinal" > 0),
	CONSTRAINT "medication_handoff_journal_source_kind_check" CHECK ("medication_handoff_journal"."legacy_source_kind" IN ('dose_log', 'pill_stock')),
	CONSTRAINT "medication_handoff_journal_subeffect_check" CHECK ("medication_handoff_journal"."subeffect_kind" IN ('dose', 'inventory')),
	CONSTRAINT "medication_handoff_journal_fingerprint_check" CHECK ("medication_handoff_journal"."command_fingerprint" IS NULL OR "medication_handoff_journal"."command_fingerprint" ~ '^[a-f0-9]{64}$'),
	CONSTRAINT "medication_handoff_journal_evidence_check" CHECK (
    ("medication_handoff_journal"."before_evidence" IS NULL OR (jsonb_typeof("medication_handoff_journal"."before_evidence") = 'object' AND octet_length("medication_handoff_journal"."before_evidence"::text) <= 8192))
    AND ("medication_handoff_journal"."after_evidence" IS NULL OR (jsonb_typeof("medication_handoff_journal"."after_evidence") = 'object' AND octet_length("medication_handoff_journal"."after_evidence"::text) <= 8192))
    AND ("medication_handoff_journal"."before_evidence" IS NOT NULL OR "medication_handoff_journal"."after_evidence" IS NOT NULL)
  ),
	CONSTRAINT "medication_handoff_journal_coverage_check" CHECK (
    "medication_handoff_journal"."coverage_state" IN ('pending', 'covered', 'blocked')
    AND ("medication_handoff_journal"."coverage_state" <> 'covered' OR
      ("medication_handoff_journal"."mapped_at" IS NOT NULL AND
        ("medication_handoff_journal"."history_entry_id" IS NOT NULL OR "medication_handoff_journal"."mapped_occurrence_id" IS NOT NULL
          OR "medication_handoff_journal"."mapped_occurrence_event_id" IS NOT NULL OR "medication_handoff_journal"."mapped_inventory_event_id" IS NOT NULL)))
  )
);
--> statement-breakpoint
CREATE TABLE "medication_occurrences" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"pill_id" uuid,
	"schedule_id" uuid,
	"occurrence_key" text NOT NULL,
	"source" text NOT NULL,
	"schedule_revision" bigint,
	"planned_local_date" date NOT NULL,
	"planned_local_time" time(6),
	"time_zone" text NOT NULL,
	"planned_at" timestamp with time zone,
	"expected" boolean NOT NULL,
	"snapshot_version" integer DEFAULT 1 NOT NULL,
	"schedule_snapshot" jsonb NOT NULL,
	"provenance" text NOT NULL,
	"superseded_at" timestamp with time zone,
	"superseded_by_occurrence_id" uuid,
	"state_version" bigint DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "medication_occurrences_user_key" UNIQUE("user_id","occurrence_key"),
	CONSTRAINT "medication_occurrences_key_check" CHECK (length("medication_occurrences"."occurrence_key") BETWEEN 1 AND 256),
	CONSTRAINT "medication_occurrences_source_check" CHECK ("medication_occurrences"."source" IN ('scheduled', 'prn', 'legacy')),
	CONSTRAINT "medication_occurrences_revision_check" CHECK ("medication_occurrences"."schedule_revision" IS NULL OR "medication_occurrences"."schedule_revision" > 0),
	CONSTRAINT "medication_occurrences_source_shape_check" CHECK (
    ("medication_occurrences"."source" = 'scheduled' AND "medication_occurrences"."schedule_id" IS NOT NULL
      AND "medication_occurrences"."schedule_revision" IS NOT NULL AND "medication_occurrences"."planned_local_time" IS NOT NULL
      AND "medication_occurrences"."planned_at" IS NOT NULL AND "medication_occurrences"."expected" = true)
    OR ("medication_occurrences"."source" = 'prn' AND "medication_occurrences"."expected" = false)
    OR ("medication_occurrences"."source" = 'legacy' AND "medication_occurrences"."expected" = false)
  ),
	CONSTRAINT "medication_occurrences_local_time_check" CHECK ("medication_occurrences"."planned_local_time" IS NOT NULL OR "medication_occurrences"."source" = 'prn'),
	CONSTRAINT "medication_occurrences_timezone_check" CHECK (length("medication_occurrences"."time_zone") BETWEEN 1 AND 128),
	CONSTRAINT "medication_occurrences_snapshot_check" CHECK (
    jsonb_typeof("medication_occurrences"."schedule_snapshot") = 'object'
    AND "medication_occurrences"."schedule_snapshot"->>'version' = '1'
    AND octet_length("medication_occurrences"."schedule_snapshot"::text) <= 16384
  ),
	CONSTRAINT "medication_occurrences_provenance_check" CHECK ("medication_occurrences"."provenance" IN ('exact', 'legacy_estimated')),
	CONSTRAINT "medication_occurrences_supersession_check" CHECK (
    ("medication_occurrences"."superseded_at" IS NULL AND "medication_occurrences"."superseded_by_occurrence_id" IS NULL)
    OR ("medication_occurrences"."superseded_at" IS NOT NULL AND "medication_occurrences"."superseded_by_occurrence_id" IS NOT NULL
      AND "medication_occurrences"."superseded_by_occurrence_id" <> "medication_occurrences"."id")
  ),
	CONSTRAINT "medication_occurrences_state_version_check" CHECK ("medication_occurrences"."state_version" >= 0)
);
--> statement-breakpoint
CREATE TABLE "occurrence_events" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"occurrence_id" uuid NOT NULL,
	"command_id" uuid NOT NULL,
	"action" text NOT NULL,
	"from_state" text NOT NULL,
	"to_state" text NOT NULL,
	"reverses_event_id" uuid,
	"rebases_command_id" uuid,
	"actual_at" timestamp with time zone,
	"actual_time_known" boolean NOT NULL,
	"note" text,
	"origin" text NOT NULL,
	"base_version" bigint NOT NULL,
	"result_version" bigint NOT NULL,
	"server_sequence" bigint NOT NULL,
	"recorded_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "occurrence_events_user_command_key" UNIQUE("user_id","command_id"),
	CONSTRAINT "occurrence_events_user_sequence_key" UNIQUE("user_id","server_sequence"),
	CONSTRAINT "occurrence_events_action_check" CHECK ("occurrence_events"."action" IN ('take', 'skip', 'undo', 'correct')),
	CONSTRAINT "occurrence_events_from_state_check" CHECK ("occurrence_events"."from_state" IN ('pending', 'taken', 'skipped')),
	CONSTRAINT "occurrence_events_to_state_check" CHECK ("occurrence_events"."to_state" IN ('pending', 'taken', 'skipped')),
	CONSTRAINT "occurrence_events_origin_check" CHECK ("occurrence_events"."origin" IN ('native', 'legacy_backfill', 'legacy_handoff')),
	CONSTRAINT "occurrence_events_version_check" CHECK (
    "occurrence_events"."base_version" >= 0 AND "occurrence_events"."result_version" = "occurrence_events"."base_version" + 1
    AND "occurrence_events"."server_sequence" > 0
  ),
	CONSTRAINT "occurrence_events_actual_time_check" CHECK ("occurrence_events"."actual_time_known" = ("occurrence_events"."actual_at" IS NOT NULL)),
	CONSTRAINT "occurrence_events_note_check" CHECK ("occurrence_events"."note" IS NULL OR length("occurrence_events"."note") <= 500)
);
--> statement-breakpoint
CREATE TABLE "preactivation_medication_receipts" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"command_id" uuid NOT NULL,
	"command_bundle_id" uuid NOT NULL,
	"transaction_correlation_id" uuid NOT NULL,
	"origin" text NOT NULL,
	"input_fingerprint" text NOT NULL,
	"source_fingerprint" text,
	"intent_metadata" jsonb NOT NULL,
	"planned_at" timestamp with time zone,
	"planned_local_date" date,
	"date_only" boolean DEFAULT false NOT NULL,
	"inventory_delta" integer,
	"observed_base_stock" integer,
	"observed_base_revision" bigint,
	"target_stock" integer,
	"adopted_legacy_source_ids" uuid[] DEFAULT '{}'::uuid[] NOT NULL,
	"backfill_reference_ids" uuid[] DEFAULT '{}'::uuid[] NOT NULL,
	"reconciliation_disposition" text DEFAULT 'pending' NOT NULL,
	"expected_subeffect_count" integer DEFAULT 0 NOT NULL,
	"observed_subeffect_count" integer DEFAULT 0 NOT NULL,
	"complete" boolean DEFAULT false NOT NULL,
	"result_metadata" jsonb,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"completed_at" timestamp with time zone,
	CONSTRAINT "preactivation_medication_receipts_user_command_key" UNIQUE("user_id","command_id"),
	CONSTRAINT "preactivation_medication_receipts_origin_check" CHECK ("preactivation_medication_receipts"."origin" IN ('bridge', 'legacy_split_reconciliation')),
	CONSTRAINT "preactivation_medication_receipts_input_fingerprint_check" CHECK ("preactivation_medication_receipts"."input_fingerprint" ~ '^[a-f0-9]{64}$'),
	CONSTRAINT "preactivation_medication_receipts_source_fingerprint_check" CHECK ("preactivation_medication_receipts"."source_fingerprint" IS NULL OR "preactivation_medication_receipts"."source_fingerprint" ~ '^[a-f0-9]{64}$'),
	CONSTRAINT "preactivation_medication_receipts_intent_check" CHECK (jsonb_typeof("preactivation_medication_receipts"."intent_metadata") = 'object' AND octet_length("preactivation_medication_receipts"."intent_metadata"::text) <= 16384),
	CONSTRAINT "preactivation_medication_receipts_result_check" CHECK ("preactivation_medication_receipts"."result_metadata" IS NULL OR (jsonb_typeof("preactivation_medication_receipts"."result_metadata") = 'object' AND octet_length("preactivation_medication_receipts"."result_metadata"::text) <= 8192)),
	CONSTRAINT "preactivation_medication_receipts_count_check" CHECK (
    "preactivation_medication_receipts"."expected_subeffect_count" >= 0 AND "preactivation_medication_receipts"."observed_subeffect_count" >= 0
    AND "preactivation_medication_receipts"."observed_subeffect_count" <= "preactivation_medication_receipts"."expected_subeffect_count"
    AND cardinality("preactivation_medication_receipts"."adopted_legacy_source_ids") <= 128
    AND cardinality("preactivation_medication_receipts"."backfill_reference_ids") <= 128
  ),
	CONSTRAINT "preactivation_medication_receipts_completion_check" CHECK (
    ("preactivation_medication_receipts"."complete" = false AND "preactivation_medication_receipts"."completed_at" IS NULL AND "preactivation_medication_receipts"."result_metadata" IS NULL)
    OR ("preactivation_medication_receipts"."complete" = true AND "preactivation_medication_receipts"."completed_at" IS NOT NULL
      AND "preactivation_medication_receipts"."result_metadata" IS NOT NULL
      AND "preactivation_medication_receipts"."observed_subeffect_count" = "preactivation_medication_receipts"."expected_subeffect_count"
      AND "preactivation_medication_receipts"."reconciliation_disposition" IN ('applied', 'adopted', 'residual_applied', 'kept_server_state'))
  ),
	CONSTRAINT "preactivation_medication_receipts_disposition_check" CHECK ("preactivation_medication_receipts"."reconciliation_disposition" IN ('pending', 'applied', 'adopted', 'residual_applied', 'kept_server_state')),
	CONSTRAINT "preactivation_medication_receipts_base_revision_check" CHECK ("preactivation_medication_receipts"."observed_base_revision" IS NULL OR "preactivation_medication_receipts"."observed_base_revision" > 0),
	CONSTRAINT "preactivation_medication_receipts_date_only_check" CHECK ("preactivation_medication_receipts"."date_only" = false OR "preactivation_medication_receipts"."planned_at" IS NULL),
	CONSTRAINT "preactivation_medication_receipts_target_check" CHECK (
    "preactivation_medication_receipts"."target_stock" IS NULL
    OR ("preactivation_medication_receipts"."observed_base_stock" IS NOT NULL AND "preactivation_medication_receipts"."inventory_delta" IS NOT NULL
      AND "preactivation_medication_receipts"."target_stock"::bigint = "preactivation_medication_receipts"."observed_base_stock"::bigint + "preactivation_medication_receipts"."inventory_delta"::bigint)
  )
);
--> statement-breakpoint
CREATE TABLE "sync_changes" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"component" text NOT NULL,
	"entity_type" text NOT NULL,
	"entity_id" uuid NOT NULL,
	"operation" text NOT NULL,
	"source_kind" text NOT NULL,
	"source_id" uuid NOT NULL,
	"source_revision" bigint NOT NULL,
	"server_sequence" bigint NOT NULL,
	"payload_schema_version" integer NOT NULL,
	"payload" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "sync_changes_user_sequence_key" UNIQUE("user_id","server_sequence"),
	CONSTRAINT "sync_changes_user_source_revision_key" UNIQUE("user_id","source_kind","source_id","source_revision"),
	CONSTRAINT "sync_changes_component_check" CHECK ("sync_changes"."component" IN ('account', 'stable', 'medicationBridge', 'medication')),
	CONSTRAINT "sync_changes_entity_type_check" CHECK ("sync_changes"."entity_type" IN ('account', 'migration_issue', 'profile', 'pill', 'schedule', 'bridge_dose', 'bridge_stock', 'medication_occurrence', 'occurrence_event', 'inventory_event', 'legacy_medication_history', 'identity_mapping')),
	CONSTRAINT "sync_changes_operation_check" CHECK ("sync_changes"."operation" IN ('upsert', 'tombstone', 'mapping')),
	CONSTRAINT "sync_changes_source_kind_check" CHECK ("sync_changes"."source_kind" IN ('account', 'migration_issue', 'profile', 'pill', 'schedule', 'legacy_dose_log', 'legacy_pill_stock', 'legacy_history_entry', 'occurrence', 'occurrence_event', 'inventory_event', 'bridge_mapping')),
	CONSTRAINT "sync_changes_revision_sequence_check" CHECK ("sync_changes"."source_revision" > 0 AND "sync_changes"."server_sequence" > 0),
	CONSTRAINT "sync_changes_payload_version_check" CHECK ("sync_changes"."payload_schema_version" > 0),
	CONSTRAINT "sync_changes_payload_check" CHECK (jsonb_typeof("sync_changes"."payload") = 'object' AND octet_length("sync_changes"."payload"::text) <= 32768)
);
--> statement-breakpoint
CREATE TABLE "sync_stream_counters" (
	"user_id" uuid PRIMARY KEY NOT NULL,
	"last_sequence" bigint DEFAULT 0 NOT NULL,
	CONSTRAINT "sync_stream_counters_sequence_check" CHECK ("sync_stream_counters"."last_sequence" >= 0)
);
--> statement-breakpoint
ALTER TABLE "inventory_events" ADD CONSTRAINT "inventory_events_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "inventory_events" ADD CONSTRAINT "inventory_events_pill_id_pills_id_fk" FOREIGN KEY ("pill_id") REFERENCES "public"."pills"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "inventory_events" ADD CONSTRAINT "inventory_events_occurrence_event_id_occurrence_events_id_fk" FOREIGN KEY ("occurrence_event_id") REFERENCES "public"."occurrence_events"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "inventory_events" ADD CONSTRAINT "inventory_events_reverses_inventory_event_id_inventory_events_id_fk" FOREIGN KEY ("reverses_inventory_event_id") REFERENCES "public"."inventory_events"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "legacy_medication_history" ADD CONSTRAINT "legacy_medication_history_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "legacy_medication_history" ADD CONSTRAINT "legacy_medication_history_pill_id_pills_id_fk" FOREIGN KEY ("pill_id") REFERENCES "public"."pills"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "legacy_medication_history" ADD CONSTRAINT "legacy_medication_history_schedule_id_schedules_id_fk" FOREIGN KEY ("schedule_id") REFERENCES "public"."schedules"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "legacy_medication_history" ADD CONSTRAINT "legacy_medication_history_sync_change_id_sync_changes_id_fk" FOREIGN KEY ("sync_change_id") REFERENCES "public"."sync_changes"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "medication_command_receipts" ADD CONSTRAINT "medication_command_receipts_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "medication_command_receipts" ADD CONSTRAINT "medication_command_receipts_preactivation_receipt_id_preactivation_medication_receipts_id_fk" FOREIGN KEY ("preactivation_receipt_id") REFERENCES "public"."preactivation_medication_receipts"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "medication_handoff_journal" ADD CONSTRAINT "medication_handoff_journal_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "medication_handoff_journal" ADD CONSTRAINT "medication_handoff_journal_history_entry_id_legacy_medication_history_history_entry_id_fk" FOREIGN KEY ("history_entry_id") REFERENCES "public"."legacy_medication_history"("history_entry_id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "medication_handoff_journal" ADD CONSTRAINT "medication_handoff_journal_mapped_occurrence_id_medication_occurrences_id_fk" FOREIGN KEY ("mapped_occurrence_id") REFERENCES "public"."medication_occurrences"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "medication_handoff_journal" ADD CONSTRAINT "medication_handoff_journal_mapped_occurrence_event_id_occurrence_events_id_fk" FOREIGN KEY ("mapped_occurrence_event_id") REFERENCES "public"."occurrence_events"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "medication_handoff_journal" ADD CONSTRAINT "medication_handoff_journal_mapped_inventory_event_id_inventory_events_id_fk" FOREIGN KEY ("mapped_inventory_event_id") REFERENCES "public"."inventory_events"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "medication_occurrences" ADD CONSTRAINT "medication_occurrences_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "medication_occurrences" ADD CONSTRAINT "medication_occurrences_pill_id_pills_id_fk" FOREIGN KEY ("pill_id") REFERENCES "public"."pills"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "medication_occurrences" ADD CONSTRAINT "medication_occurrences_schedule_id_schedules_id_fk" FOREIGN KEY ("schedule_id") REFERENCES "public"."schedules"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "medication_occurrences" ADD CONSTRAINT "medication_occurrences_superseded_by_occurrence_id_medication_occurrences_id_fk" FOREIGN KEY ("superseded_by_occurrence_id") REFERENCES "public"."medication_occurrences"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "occurrence_events" ADD CONSTRAINT "occurrence_events_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "occurrence_events" ADD CONSTRAINT "occurrence_events_occurrence_id_medication_occurrences_id_fk" FOREIGN KEY ("occurrence_id") REFERENCES "public"."medication_occurrences"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "occurrence_events" ADD CONSTRAINT "occurrence_events_reverses_event_id_occurrence_events_id_fk" FOREIGN KEY ("reverses_event_id") REFERENCES "public"."occurrence_events"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "preactivation_medication_receipts" ADD CONSTRAINT "preactivation_medication_receipts_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "sync_changes" ADD CONSTRAINT "sync_changes_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "sync_stream_counters" ADD CONSTRAINT "sync_stream_counters_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "inventory_events_user_pill_sequence_idx" ON "inventory_events" USING btree ("user_id","pill_id","server_sequence");--> statement-breakpoint
CREATE INDEX "inventory_events_occurrence_event_idx" ON "inventory_events" USING btree ("user_id","occurrence_event_id");--> statement-breakpoint
CREATE INDEX "legacy_medication_history_user_coverage_idx" ON "legacy_medication_history" USING btree ("user_id","coverage_state","created_at");--> statement-breakpoint
CREATE INDEX "medication_command_receipts_user_created_idx" ON "medication_command_receipts" USING btree ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "medication_handoff_journal_user_coverage_idx" ON "medication_handoff_journal" USING btree ("user_id","coverage_state","journal_sequence");--> statement-breakpoint
CREATE INDEX "medication_occurrences_user_date_idx" ON "medication_occurrences" USING btree ("user_id","planned_local_date","id");--> statement-breakpoint
CREATE INDEX "medication_occurrences_pill_date_idx" ON "medication_occurrences" USING btree ("user_id","pill_id","planned_local_date");--> statement-breakpoint
CREATE INDEX "occurrence_events_user_occurrence_sequence_idx" ON "occurrence_events" USING btree ("user_id","occurrence_id","server_sequence");--> statement-breakpoint
CREATE INDEX "preactivation_medication_receipts_bundle_idx" ON "preactivation_medication_receipts" USING btree ("user_id","command_bundle_id");--> statement-breakpoint
CREATE INDEX "sync_changes_user_component_sequence_idx" ON "sync_changes" USING btree ("user_id","component","server_sequence");--> statement-breakpoint
CREATE INDEX "sync_changes_user_entity_sequence_idx" ON "sync_changes" USING btree ("user_id","entity_type","entity_id","server_sequence");
-- Task 11 immutable ledger security follows.
-- Tenant isolation is mandatory even when the migration/definer roles own a
-- relation. The application never receives direct access to the stream counter.
ALTER TABLE public.medication_occurrences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medication_occurrences FORCE ROW LEVEL SECURITY;
ALTER TABLE public.occurrence_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.occurrence_events FORCE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_events FORCE ROW LEVEL SECURITY;
ALTER TABLE public.preactivation_medication_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.preactivation_medication_receipts FORCE ROW LEVEL SECURITY;
ALTER TABLE public.medication_command_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medication_command_receipts FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sync_stream_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sync_stream_counters FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sync_changes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sync_changes FORCE ROW LEVEL SECURITY;
ALTER TABLE public.legacy_medication_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.legacy_medication_history FORCE ROW LEVEL SECURITY;
ALTER TABLE public.medication_handoff_journal ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medication_handoff_journal FORCE ROW LEVEL SECURITY;
--> statement-breakpoint

CREATE POLICY medication_occurrences_app_tenant ON public.medication_occurrences
  FOR ALL TO app_user
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
CREATE POLICY medication_occurrences_authority_access ON public.medication_occurrences
  FOR ALL TO deployment_authority_owner USING (true) WITH CHECK (true);
CREATE POLICY occurrence_events_app_tenant ON public.occurrence_events
  FOR ALL TO app_user
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
CREATE POLICY occurrence_events_authority_access ON public.occurrence_events
  FOR ALL TO deployment_authority_owner USING (true) WITH CHECK (true);
CREATE POLICY inventory_events_app_tenant ON public.inventory_events
  FOR ALL TO app_user
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
CREATE POLICY inventory_events_authority_access ON public.inventory_events
  FOR ALL TO deployment_authority_owner USING (true) WITH CHECK (true);
CREATE POLICY preactivation_receipts_app_tenant ON public.preactivation_medication_receipts
  FOR ALL TO app_user
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
CREATE POLICY preactivation_receipts_authority_access ON public.preactivation_medication_receipts
  FOR ALL TO deployment_authority_owner USING (true) WITH CHECK (true);
CREATE POLICY medication_command_receipts_app_tenant ON public.medication_command_receipts
  FOR ALL TO app_user
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
CREATE POLICY medication_command_receipts_authority_access ON public.medication_command_receipts
  FOR ALL TO deployment_authority_owner USING (true) WITH CHECK (true);
CREATE POLICY sync_stream_counters_authority_access ON public.sync_stream_counters
  FOR ALL TO deployment_authority_owner USING (true) WITH CHECK (true);
CREATE POLICY sync_changes_app_tenant ON public.sync_changes
  FOR ALL TO app_user
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
CREATE POLICY sync_changes_authority_access ON public.sync_changes
  FOR ALL TO deployment_authority_owner USING (true) WITH CHECK (true);
CREATE POLICY legacy_history_app_tenant ON public.legacy_medication_history
  FOR ALL TO app_user
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
CREATE POLICY legacy_history_authority_access ON public.legacy_medication_history
  FOR ALL TO deployment_authority_owner USING (true) WITH CHECK (true);
CREATE POLICY handoff_journal_app_tenant ON public.medication_handoff_journal
  FOR ALL TO app_user
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
CREATE POLICY handoff_journal_authority_access ON public.medication_handoff_journal
  FOR ALL TO deployment_authority_owner USING (true) WITH CHECK (true);
--> statement-breakpoint

REVOKE ALL ON TABLE public.medication_occurrences, public.occurrence_events,
  public.inventory_events, public.preactivation_medication_receipts,
  public.medication_command_receipts, public.sync_stream_counters,
  public.sync_changes, public.legacy_medication_history,
  public.medication_handoff_journal
  FROM PUBLIC, app_user, outbox_user, deployment_authority_owner;
GRANT SELECT, INSERT ON public.medication_occurrences TO app_user;
GRANT UPDATE (state_version, superseded_at, superseded_by_occurrence_id)
  ON public.medication_occurrences TO app_user;
GRANT SELECT, INSERT ON public.occurrence_events, public.inventory_events,
  public.medication_command_receipts, public.sync_changes,
  public.legacy_medication_history, public.medication_handoff_journal TO app_user;
GRANT SELECT, INSERT, UPDATE (observed_subeffect_count, adopted_legacy_source_ids,
  backfill_reference_ids, reconciliation_disposition, complete, result_metadata,
  completed_at) ON public.preactivation_medication_receipts TO app_user;
GRANT SELECT, INSERT ON public.medication_occurrences, public.occurrence_events,
  public.inventory_events, public.preactivation_medication_receipts,
  public.medication_command_receipts, public.sync_changes,
  public.legacy_medication_history, public.medication_handoff_journal
  TO deployment_authority_owner;
GRANT UPDATE (state_version, superseded_at, superseded_by_occurrence_id)
  ON public.medication_occurrences TO deployment_authority_owner;
GRANT UPDATE (coverage_state, sync_change_id, mapped_entity_type, mapped_entity_id, mapped_at)
  ON public.legacy_medication_history TO deployment_authority_owner;
GRANT UPDATE (coverage_state, history_entry_id, mapped_occurrence_id,
  mapped_occurrence_event_id, mapped_inventory_event_id, mapped_at)
  ON public.medication_handoff_journal TO deployment_authority_owner;
GRANT SELECT, INSERT, UPDATE ON public.sync_stream_counters TO deployment_authority_owner;
GRANT SELECT ON public.profiles, public.pills, public.schedules TO deployment_authority_owner;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.next_sync_server_sequence(p_user_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  next_value bigint;
BEGIN
  IF p_user_id IS NULL OR p_user_id IS DISTINCT FROM
     NULLIF(current_setting('app.current_user_id', true), '')::uuid THEN
    RAISE EXCEPTION 'sync sequence tenant does not match transaction context'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.sync_stream_counters (user_id, last_sequence)
  VALUES (p_user_id, 1)
  ON CONFLICT (user_id) DO UPDATE
    SET last_sequence = public.sync_stream_counters.last_sequence + 1
  RETURNING last_sequence INTO next_value;

  RETURN next_value;
END;
$function$;
ALTER FUNCTION public.next_sync_server_sequence(uuid) OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.next_sync_server_sequence(uuid) FROM PUBLIC, outbox_user;
GRANT EXECUTE ON FUNCTION public.next_sync_server_sequence(uuid) TO app_user;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.prevent_ledger_event_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $function$
DECLARE
  caller_is_superuser boolean;
BEGIN
  SELECT COALESCE((
    SELECT role.rolsuper FROM pg_catalog.pg_roles AS role
    WHERE role.rolname = current_user
  ), false) INTO caller_is_superuser;

  IF caller_is_superuser THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;
  IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION '% rows are append-only', TG_TABLE_NAME
    USING ERRCODE = '42501';
END;
$function$;
CREATE TRIGGER occurrence_events_immutable
  BEFORE UPDATE OR DELETE ON public.occurrence_events
  FOR EACH ROW EXECUTE FUNCTION public.prevent_ledger_event_mutation();
CREATE TRIGGER inventory_events_immutable
  BEFORE UPDATE OR DELETE ON public.inventory_events
  FOR EACH ROW EXECUTE FUNCTION public.prevent_ledger_event_mutation();
CREATE TRIGGER medication_command_receipts_immutable
  BEFORE UPDATE OR DELETE ON public.medication_command_receipts
  FOR EACH ROW EXECUTE FUNCTION public.prevent_ledger_event_mutation();
CREATE TRIGGER sync_changes_immutable
  BEFORE UPDATE OR DELETE ON public.sync_changes
  FOR EACH ROW EXECUTE FUNCTION public.prevent_ledger_event_mutation();
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.guard_medication_occurrence_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $function$
DECLARE
  caller_is_superuser boolean;
BEGIN
  SELECT COALESCE((
    SELECT role.rolsuper FROM pg_catalog.pg_roles AS role
    WHERE role.rolname = current_user
  ), false) INTO caller_is_superuser;

  IF TG_OP = 'DELETE' THEN
    IF caller_is_superuser OR pg_trigger_depth() > 1 THEN RETURN OLD; END IF;
    RAISE EXCEPTION 'medication occurrences cannot be deleted independently'
      USING ERRCODE = '42501';
  ELSIF TG_OP = 'INSERT' THEN
    IF NEW.state_version <> 0 OR NEW.superseded_at IS NOT NULL
       OR NEW.superseded_by_occurrence_id IS NOT NULL THEN
      RAISE EXCEPTION 'medication occurrences must begin at state version zero and unsuperseded'
        USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  IF caller_is_superuser THEN RETURN NEW; END IF;
  IF current_user NOT IN ('app_user', 'deployment_authority_owner') THEN
    RAISE EXCEPTION 'medication occurrence update is not authorized'
      USING ERRCODE = '42501';
  END IF;
  IF (to_jsonb(NEW) - ARRAY['state_version', 'superseded_at', 'superseded_by_occurrence_id'])
     IS DISTINCT FROM
     (to_jsonb(OLD) - ARRAY['state_version', 'superseded_at', 'superseded_by_occurrence_id']) THEN
    RAISE EXCEPTION 'medication occurrence identity and snapshot are immutable'
      USING ERRCODE = '23514';
  END IF;
  IF NEW.state_version < OLD.state_version OR NEW.state_version > OLD.state_version + 1 THEN
    RAISE EXCEPTION 'medication occurrence state version must be monotonic and advance by at most one'
      USING ERRCODE = '23514';
  END IF;
  IF OLD.superseded_at IS NOT NULL AND
     (NEW.superseded_at IS DISTINCT FROM OLD.superseded_at OR
      NEW.superseded_by_occurrence_id IS DISTINCT FROM OLD.superseded_by_occurrence_id) THEN
    RAISE EXCEPTION 'medication occurrence supersession is terminal'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$function$;
CREATE TRIGGER medication_occurrences_guard_mutation
  BEFORE INSERT OR UPDATE OR DELETE ON public.medication_occurrences
  FOR EACH ROW EXECUTE FUNCTION public.guard_medication_occurrence_mutation();
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.guard_preactivation_receipt_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $function$
DECLARE
  caller_is_superuser boolean;
BEGIN
  SELECT COALESCE((
    SELECT role.rolsuper FROM pg_catalog.pg_roles AS role
    WHERE role.rolname = current_user
  ), false) INTO caller_is_superuser;

  IF TG_OP = 'DELETE' THEN
    IF caller_is_superuser OR pg_trigger_depth() > 1 THEN RETURN OLD; END IF;
    RAISE EXCEPTION 'preactivation medication receipts cannot be deleted independently'
      USING ERRCODE = '42501';
  ELSIF TG_OP = 'INSERT' THEN
    IF NEW.complete OR NEW.completed_at IS NOT NULL OR NEW.result_metadata IS NOT NULL THEN
      RAISE EXCEPTION 'preactivation receipts must begin incomplete'
        USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  IF caller_is_superuser THEN RETURN NEW; END IF;
  IF current_user NOT IN ('app_user', 'deployment_authority_owner') THEN
    RAISE EXCEPTION 'preactivation receipt completion is not authorized'
      USING ERRCODE = '42501';
  END IF;
  IF OLD.complete OR NOT NEW.complete OR NEW.completed_at IS NULL
     OR NEW.result_metadata IS NULL THEN
    RAISE EXCEPTION 'preactivation receipt permits one incomplete-to-complete transition'
      USING ERRCODE = '23514';
  END IF;
  IF (to_jsonb(NEW) - ARRAY['observed_subeffect_count', 'adopted_legacy_source_ids',
       'backfill_reference_ids', 'reconciliation_disposition', 'complete',
       'result_metadata', 'completed_at'])
     IS DISTINCT FROM
     (to_jsonb(OLD) - ARRAY['observed_subeffect_count', 'adopted_legacy_source_ids',
       'backfill_reference_ids', 'reconciliation_disposition', 'complete',
       'result_metadata', 'completed_at']) THEN
    RAISE EXCEPTION 'preactivation receipt authority fields are immutable'
      USING ERRCODE = '23514';
  END IF;
  IF NEW.observed_subeffect_count < OLD.observed_subeffect_count
     OR NOT (OLD.adopted_legacy_source_ids <@ NEW.adopted_legacy_source_ids)
     OR NOT (OLD.backfill_reference_ids <@ NEW.backfill_reference_ids) THEN
    RAISE EXCEPTION 'preactivation receipt evidence cannot be removed'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$function$;
CREATE TRIGGER preactivation_receipts_guard_mutation
  BEFORE INSERT OR UPDATE OR DELETE ON public.preactivation_medication_receipts
  FOR EACH ROW EXECUTE FUNCTION public.guard_preactivation_receipt_mutation();
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.guard_sync_change_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $function$
DECLARE
  expected_kind text;
  payload_kind text;
  expected_entity_id text;
  expected_source_revision text;
BEGIN
  IF NEW.user_id IS DISTINCT FROM
     NULLIF(current_setting('app.current_user_id', true), '')::uuid THEN
    RAISE EXCEPTION 'sync change tenant does not match transaction context'
      USING ERRCODE = '42501';
  END IF;
  IF NEW.payload_schema_version <> 2
     OR NEW.payload->>'schemaVersion' <> '2'
     OR NEW.payload->>'component' IS DISTINCT FROM NEW.component
     OR NEW.payload->>'entityType' IS DISTINCT FROM NEW.entity_type
     OR NEW.payload->>'entityId' IS DISTINCT FROM NEW.entity_id::text
     OR NEW.payload->>'operation' IS DISTINCT FROM NEW.operation
     OR NEW.payload#>>'{sourceIdentity,sourceKind}' IS DISTINCT FROM NEW.source_kind
     OR NEW.payload#>>'{sourceIdentity,sourceId}' IS DISTINCT FROM NEW.source_id::text
     OR NEW.payload#>>'{sourceIdentity,sourceRevision}' IS DISTINCT FROM NEW.source_revision::text
     OR jsonb_typeof(NEW.payload->'payload') IS DISTINCT FROM 'object'
     OR jsonb_typeof(NEW.payload->'sourceIdentity') IS DISTINCT FROM 'object'
     OR octet_length(NEW.payload::text) > 32768 THEN
    RAISE EXCEPTION 'sync change envelope does not match its indexed identity'
      USING ERRCODE = '23514';
  END IF;

  expected_kind := CASE NEW.entity_type
    WHEN 'account' THEN 'account'
    WHEN 'migration_issue' THEN 'migrationIssue'
    WHEN 'profile' THEN 'profile'
    WHEN 'pill' THEN 'pill'
    WHEN 'schedule' THEN 'schedule'
    WHEN 'bridge_dose' THEN 'bridgeDose'
    WHEN 'bridge_stock' THEN 'bridgeStock'
    WHEN 'medication_occurrence' THEN 'medicationOccurrence'
    WHEN 'occurrence_event' THEN 'occurrenceEvent'
    WHEN 'inventory_event' THEN 'inventoryEvent'
    WHEN 'legacy_medication_history' THEN 'legacyEstimatedHistory'
    WHEN 'identity_mapping' THEN 'identityMapping'
  END;
  payload_kind := NEW.payload#>>'{payload,kind}';
  expected_entity_id := COALESCE(
    NEW.payload#>>'{payload,id}',
    NEW.payload#>>'{payload,historyId}',
    NEW.payload#>>'{payload,targetEntityId}',
    CASE WHEN NEW.entity_type = 'bridge_stock' AND NEW.operation = 'upsert'
      THEN NEW.payload#>>'{payload,pillId}' END
  );
  IF expected_entity_id IS DISTINCT FROM NEW.entity_id::text THEN
    RAISE EXCEPTION 'sync payload entity identity does not match its envelope'
      USING ERRCODE = '23514';
  END IF;
  IF NEW.operation = 'tombstone' THEN
    IF payload_kind IS DISTINCT FROM 'tombstone'
       OR NEW.payload#>>'{payload,entityType}' IS DISTINCT FROM NEW.entity_type THEN
      RAISE EXCEPTION 'sync tombstone payload type does not match its envelope'
        USING ERRCODE = '23514';
    END IF;
  ELSIF payload_kind IS DISTINCT FROM expected_kind THEN
    RAISE EXCEPTION 'sync payload kind does not match its entity type'
      USING ERRCODE = '23514';
  END IF;

  expected_source_revision := CASE
    WHEN NEW.operation = 'tombstone' THEN NEW.payload#>>'{payload,revision}'
    WHEN NEW.source_kind IN ('account', 'migration_issue', 'profile', 'pill', 'schedule')
      THEN NEW.payload#>>'{payload,revision}'
    WHEN NEW.source_kind IN ('legacy_dose_log', 'legacy_pill_stock')
      THEN NEW.payload#>>'{payload,sourceRevision}'
    WHEN NEW.source_kind = 'occurrence'
      THEN ((NEW.payload#>>'{payload,stateVersion}')::numeric + 1)::text
    WHEN NEW.source_kind IN ('occurrence_event', 'inventory_event')
      THEN NEW.payload#>>'{payload,serverSequence}'
    WHEN NEW.source_kind = 'legacy_history_entry'
      THEN NEW.payload#>>'{payload,sourceRevision}'
    WHEN NEW.source_kind = 'bridge_mapping'
      THEN NEW.payload#>>'{payload,mappingRevision}'
  END;
  IF expected_source_revision IS DISTINCT FROM NEW.source_revision::text THEN
    RAISE EXCEPTION 'sync payload source revision does not match its stable source tuple'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.operation = 'mapping'
     AND (NEW.entity_type <> 'identity_mapping' OR NEW.component <> 'medication') THEN
    RAISE EXCEPTION 'sync mapping operation has an invalid entity or component'
      USING ERRCODE = '23514';
  END IF;
  IF NEW.entity_type = 'identity_mapping' AND NEW.operation <> 'mapping' THEN
    RAISE EXCEPTION 'identity mapping rows require the mapping operation'
      USING ERRCODE = '23514';
  END IF;
  IF NEW.component = 'account'
     AND (NEW.payload->'payload') ?| ARRAY['password', 'passwordHash', 'totpSecret',
       'recoveryCodes', 'refreshToken', 'accessToken', 'secret'] THEN
    RAISE EXCEPTION 'account sync payload contains a secret field'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$function$;
CREATE TRIGGER sync_changes_guard_insert
  BEFORE INSERT ON public.sync_changes
  FOR EACH ROW EXECUTE FUNCTION public.guard_sync_change_insert();
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.guard_medication_tenant_references()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $function$
DECLARE
  parent_pill_id uuid;
  current_user_id uuid := NULLIF(current_setting('app.current_user_id', true), '')::uuid;
BEGIN
  IF NEW.user_id IS DISTINCT FROM current_user_id THEN
    RAISE EXCEPTION 'medication ledger tenant does not match transaction context'
      USING ERRCODE = '42501';
  END IF;

  IF TG_TABLE_NAME = 'medication_occurrences' THEN
    IF NEW.pill_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.pills AS p
      JOIN public.profiles AS pr ON pr.id = p.profile_id
      WHERE p.id = NEW.pill_id AND pr.user_id = NEW.user_id
    ) THEN
      RAISE EXCEPTION 'occurrence pill does not belong to its tenant'
        USING ERRCODE = '23503';
    END IF;
    IF NEW.schedule_id IS NOT NULL THEN
      SELECT s.pill_id INTO parent_pill_id
      FROM public.schedules AS s
      JOIN public.pills AS p ON p.id = s.pill_id
      JOIN public.profiles AS pr ON pr.id = p.profile_id
      WHERE s.id = NEW.schedule_id AND pr.user_id = NEW.user_id;
      IF NOT FOUND OR parent_pill_id IS DISTINCT FROM NEW.pill_id THEN
        RAISE EXCEPTION 'occurrence schedule and pill must belong to the same tenant and match'
          USING ERRCODE = '23503';
      END IF;
    END IF;
  ELSIF TG_TABLE_NAME = 'occurrence_events' THEN
    IF NOT EXISTS (SELECT 1 FROM public.medication_occurrences o
      WHERE o.id = NEW.occurrence_id AND o.user_id = NEW.user_id) THEN
      RAISE EXCEPTION 'occurrence event parent belongs to another tenant'
        USING ERRCODE = '23503';
    END IF;
  ELSIF TG_TABLE_NAME = 'inventory_events' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.pills p JOIN public.profiles pr ON pr.id = p.profile_id
      WHERE p.id = NEW.pill_id AND pr.user_id = NEW.user_id
    ) THEN
      RAISE EXCEPTION 'inventory event pill belongs to another tenant'
        USING ERRCODE = '23503';
    END IF;
    IF NEW.occurrence_event_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.occurrence_events e
      JOIN public.medication_occurrences o ON o.id = e.occurrence_id
      WHERE e.id = NEW.occurrence_event_id AND e.user_id = NEW.user_id
        AND o.user_id = NEW.user_id AND o.pill_id = NEW.pill_id
    ) THEN
      RAISE EXCEPTION 'inventory event occurrence evidence does not match its tenant and pill'
        USING ERRCODE = '23503';
    END IF;
  ELSIF TG_TABLE_NAME = 'medication_command_receipts' THEN
    IF NEW.preactivation_receipt_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.preactivation_medication_receipts r
      WHERE r.id = NEW.preactivation_receipt_id AND r.user_id = NEW.user_id
        AND r.command_id = NEW.command_id
    ) THEN
      RAISE EXCEPTION 'permanent command receipt does not match its preactivation receipt'
        USING ERRCODE = '23503';
    END IF;
  ELSIF TG_TABLE_NAME = 'preactivation_medication_receipts' THEN
    NULL;
  ELSIF TG_TABLE_NAME = 'legacy_medication_history' THEN
    IF NEW.pill_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.pills p JOIN public.profiles pr ON pr.id = p.profile_id
      WHERE p.id = NEW.pill_id AND pr.user_id = NEW.user_id
    ) THEN
      RAISE EXCEPTION 'legacy history pill belongs to another tenant'
        USING ERRCODE = '23503';
    END IF;
    IF NEW.schedule_id IS NOT NULL THEN
      SELECT s.pill_id INTO parent_pill_id
      FROM public.schedules s JOIN public.pills p ON p.id = s.pill_id
      JOIN public.profiles pr ON pr.id = p.profile_id
      WHERE s.id = NEW.schedule_id AND pr.user_id = NEW.user_id;
      IF NOT FOUND OR parent_pill_id IS DISTINCT FROM NEW.pill_id THEN
        RAISE EXCEPTION 'legacy history schedule and pill must belong to the same tenant'
          USING ERRCODE = '23503';
      END IF;
    END IF;
    IF NEW.legacy_source_kind = 'pill_stock'
       AND (NEW.pill_id IS NULL OR NEW.legacy_source_id IS DISTINCT FROM NEW.pill_id) THEN
      RAISE EXCEPTION 'legacy stock evidence must identify its source pill'
        USING ERRCODE = '23514';
    END IF;
    IF NEW.sync_change_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.sync_changes c
      WHERE c.id = NEW.sync_change_id AND c.user_id = NEW.user_id
        AND c.entity_type = 'legacy_medication_history'
        -- The stream upserts an immutable history entry; its payload preserves
        -- whether the historical source itself was an upsert or a tombstone.
        AND c.entity_id = NEW.history_id AND c.operation = 'upsert'
        AND c.payload#>>'{payload,operation}' = NEW.operation
        AND c.source_kind = 'legacy_history_entry'
        AND c.source_id = NEW.history_entry_id
        AND c.source_revision = NEW.source_revision
    ) THEN
      RAISE EXCEPTION 'legacy history sync reference does not match its immutable source identity'
        USING ERRCODE = '23503';
    END IF;
    IF NEW.coverage_state = 'covered' AND NEW.sync_change_id IS NULL THEN
      RAISE EXCEPTION 'covered legacy history requires its matching immutable sync change'
        USING ERRCODE = '23503';
    END IF;
  ELSIF TG_TABLE_NAME = 'medication_handoff_journal' THEN
    IF NEW.history_entry_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.legacy_medication_history h
      WHERE h.history_entry_id = NEW.history_entry_id AND h.user_id = NEW.user_id
        AND h.legacy_source_kind = NEW.legacy_source_kind
        AND h.legacy_source_id = NEW.legacy_source_id
        AND h.source_revision = NEW.source_revision
    ) THEN
      RAISE EXCEPTION 'handoff history mapping does not match its source identity'
        USING ERRCODE = '23503';
    END IF;
    IF NEW.mapped_occurrence_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.medication_occurrences o
      WHERE o.id = NEW.mapped_occurrence_id AND o.user_id = NEW.user_id
    ) THEN
      RAISE EXCEPTION 'handoff occurrence mapping belongs to another tenant'
        USING ERRCODE = '23503';
    END IF;
    IF NEW.mapped_occurrence_event_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.occurrence_events e
      WHERE e.id = NEW.mapped_occurrence_event_id AND e.user_id = NEW.user_id
    ) THEN
      RAISE EXCEPTION 'handoff event mapping belongs to another tenant'
        USING ERRCODE = '23503';
    END IF;
    IF NEW.mapped_inventory_event_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.inventory_events i
      WHERE i.id = NEW.mapped_inventory_event_id AND i.user_id = NEW.user_id
    ) THEN
      RAISE EXCEPTION 'handoff inventory mapping belongs to another tenant'
        USING ERRCODE = '23503';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;
--> statement-breakpoint
CREATE TRIGGER medication_occurrences_tenant_references
  BEFORE INSERT OR UPDATE ON public.medication_occurrences
  FOR EACH ROW EXECUTE FUNCTION public.guard_medication_tenant_references();
CREATE TRIGGER occurrence_events_tenant_references
  BEFORE INSERT OR UPDATE ON public.occurrence_events
  FOR EACH ROW EXECUTE FUNCTION public.guard_medication_tenant_references();
CREATE TRIGGER inventory_events_tenant_references
  BEFORE INSERT OR UPDATE ON public.inventory_events
  FOR EACH ROW EXECUTE FUNCTION public.guard_medication_tenant_references();
CREATE TRIGGER preactivation_receipts_tenant_references
  BEFORE INSERT OR UPDATE ON public.preactivation_medication_receipts
  FOR EACH ROW EXECUTE FUNCTION public.guard_medication_tenant_references();
CREATE TRIGGER medication_command_receipts_tenant_references
  BEFORE INSERT OR UPDATE ON public.medication_command_receipts
  FOR EACH ROW EXECUTE FUNCTION public.guard_medication_tenant_references();
CREATE TRIGGER sync_changes_tenant_references
  BEFORE INSERT OR UPDATE ON public.sync_changes
  FOR EACH ROW EXECUTE FUNCTION public.guard_medication_tenant_references();
CREATE TRIGGER legacy_history_tenant_references
  BEFORE INSERT OR UPDATE ON public.legacy_medication_history
  FOR EACH ROW EXECUTE FUNCTION public.guard_medication_tenant_references();
CREATE TRIGGER handoff_journal_tenant_references
  BEFORE INSERT OR UPDATE ON public.medication_handoff_journal
  FOR EACH ROW EXECUTE FUNCTION public.guard_medication_tenant_references();
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.guard_legacy_history_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $function$
DECLARE
  caller_is_superuser boolean;
BEGIN
  SELECT COALESCE((
    SELECT role.rolsuper FROM pg_catalog.pg_roles AS role
    WHERE role.rolname = current_user
  ), false) INTO caller_is_superuser;
  IF TG_OP = 'DELETE' THEN
    IF caller_is_superuser OR pg_trigger_depth() > 1 THEN RETURN OLD; END IF;
    RAISE EXCEPTION 'legacy medication history cannot be deleted independently'
      USING ERRCODE = '42501';
  ELSIF TG_OP = 'INSERT' THEN
    IF NEW.coverage_state <> 'pending' AND current_user <> 'deployment_authority_owner'
       AND NOT caller_is_superuser THEN
      RAISE EXCEPTION 'legacy history coverage is controlled by the authority owner'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF caller_is_superuser THEN RETURN NEW; END IF;
  IF current_user <> 'deployment_authority_owner' THEN
    RAISE EXCEPTION 'legacy history mapping is controlled by the authority owner'
      USING ERRCODE = '42501';
  END IF;
  IF (to_jsonb(NEW) - ARRAY['coverage_state', 'sync_change_id', 'mapped_entity_type',
       'mapped_entity_id', 'mapped_at'])
     IS DISTINCT FROM
     (to_jsonb(OLD) - ARRAY['coverage_state', 'sync_change_id', 'mapped_entity_type',
       'mapped_entity_id', 'mapped_at']) THEN
    RAISE EXCEPTION 'legacy history source evidence is immutable'
      USING ERRCODE = '23514';
  END IF;
  IF (CASE OLD.coverage_state WHEN 'pending' THEN 0 WHEN 'blocked' THEN 1 WHEN 'covered' THEN 2 END)
     > (CASE NEW.coverage_state WHEN 'pending' THEN 0 WHEN 'blocked' THEN 1 WHEN 'covered' THEN 2 END) THEN
    RAISE EXCEPTION 'legacy history coverage cannot move backwards'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$function$;
CREATE TRIGGER legacy_history_guard_mutation
  BEFORE INSERT OR UPDATE OR DELETE ON public.legacy_medication_history
  FOR EACH ROW EXECUTE FUNCTION public.guard_legacy_history_mutation();
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.guard_handoff_journal_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $function$
DECLARE
  caller_is_superuser boolean;
BEGIN
  SELECT COALESCE((
    SELECT role.rolsuper FROM pg_catalog.pg_roles AS role
    WHERE role.rolname = current_user
  ), false) INTO caller_is_superuser;
  IF TG_OP = 'DELETE' THEN
    IF caller_is_superuser OR pg_trigger_depth() > 1 THEN RETURN OLD; END IF;
    RAISE EXCEPTION 'medication handoff journal cannot be deleted independently'
      USING ERRCODE = '42501';
  ELSIF TG_OP = 'INSERT' THEN
    IF NEW.coverage_state <> 'pending' AND current_user <> 'deployment_authority_owner'
       AND NOT caller_is_superuser THEN
      RAISE EXCEPTION 'handoff journal coverage is controlled by the authority owner'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF caller_is_superuser THEN RETURN NEW; END IF;
  IF current_user <> 'deployment_authority_owner' THEN
    RAISE EXCEPTION 'handoff journal mapping is controlled by the authority owner'
      USING ERRCODE = '42501';
  END IF;
  IF (to_jsonb(NEW) - ARRAY['coverage_state', 'history_entry_id', 'mapped_occurrence_id',
       'mapped_occurrence_event_id', 'mapped_inventory_event_id', 'mapped_at'])
     IS DISTINCT FROM
     (to_jsonb(OLD) - ARRAY['coverage_state', 'history_entry_id', 'mapped_occurrence_id',
       'mapped_occurrence_event_id', 'mapped_inventory_event_id', 'mapped_at']) THEN
    RAISE EXCEPTION 'handoff journal evidence is immutable'
      USING ERRCODE = '23514';
  END IF;
  IF (CASE OLD.coverage_state WHEN 'pending' THEN 0 WHEN 'blocked' THEN 1 WHEN 'covered' THEN 2 END)
     > (CASE NEW.coverage_state WHEN 'pending' THEN 0 WHEN 'blocked' THEN 1 WHEN 'covered' THEN 2 END) THEN
    RAISE EXCEPTION 'handoff journal coverage cannot move backwards'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$function$;
CREATE TRIGGER handoff_journal_guard_mutation
  BEFORE INSERT OR UPDATE OR DELETE ON public.medication_handoff_journal
  FOR EACH ROW EXECUTE FUNCTION public.guard_handoff_journal_mutation();
--> statement-breakpoint

REVOKE ALL ON FUNCTION public.prevent_ledger_event_mutation() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.guard_medication_occurrence_mutation() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.guard_preactivation_receipt_mutation() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.guard_sync_change_insert() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.guard_medication_tenant_references() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.guard_legacy_history_mutation() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.guard_handoff_journal_mutation() FROM PUBLIC;
