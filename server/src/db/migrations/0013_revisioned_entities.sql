-- Migration 0013 — revisioned stable records, repair issues, and schedule invariants.
-- Existing schedule intent is preserved exactly; no weekday or timezone is inferred.

CREATE OR REPLACE FUNCTION public.schedule_frequency_days_valid(
  p_frequency text,
  p_frequency_days integer[]
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $function$
  SELECT CASE
    WHEN p_frequency IN ('daily', 'prn') THEN p_frequency_days IS NULL
    WHEN p_frequency = 'weekly' THEN
      p_frequency_days IS NOT NULL
      AND array_ndims(p_frequency_days) = 1
      AND cardinality(p_frequency_days) = 1
      AND EXISTS (
        SELECT 1
        FROM unnest(p_frequency_days) AS weekday(value)
        WHERE weekday.value IS NOT NULL AND weekday.value BETWEEN 1 AND 7
      )
    WHEN p_frequency = 'custom' THEN
      p_frequency_days IS NOT NULL
      AND array_ndims(p_frequency_days) = 1
      AND cardinality(p_frequency_days) > 0
      AND (
        SELECT count(*) = cardinality(p_frequency_days)
          AND count(*) = count(DISTINCT weekday.value)
          AND min(weekday.value) >= 1
          AND max(weekday.value) <= 7
        FROM unnest(p_frequency_days) AS weekday(value)
      )
    ELSE false
  END;
$function$;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.schedule_legacy_source_snapshot(
  p_schedule_id uuid,
  p_revision bigint,
  p_frequency text,
  p_frequency_days integer[],
  p_is_active boolean,
  p_deleted_at timestamp with time zone
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $function$
  SELECT jsonb_build_object(
    'scheduleId', p_schedule_id::text,
    'sourceScheduleRevision', p_revision::text,
    'frequency', p_frequency,
    'frequencyDays', to_jsonb(p_frequency_days),
    'isActive', p_is_active,
    'deletedAt', p_deleted_at,
    'timeZoneStatus', 'legacy_unknown',
    'timeZone', NULL::text
  );
$function$;
--> statement-breakpoint

CREATE TABLE "entity_mutation_receipts" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL,
  "mutation_id" uuid NOT NULL,
  "entity_type" text NOT NULL,
  "entity_id" uuid NOT NULL,
  "operation" text NOT NULL,
  "base_revision" bigint,
  "result_revision" bigint NOT NULL,
  "input_fingerprint" text NOT NULL,
  "result_metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "entity_mutation_receipts_user_mutation_key" UNIQUE("user_id", "mutation_id"),
  CONSTRAINT "entity_mutation_receipts_entity_type_check"
    CHECK ("entity_type" IN ('profiles', 'pills', 'schedules')),
  CONSTRAINT "entity_mutation_receipts_operation_check"
    CHECK ("operation" IN ('create', 'update', 'delete')),
  CONSTRAINT "entity_mutation_receipts_revision_check" CHECK (
    "result_revision" > 0 AND (
      ("operation" = 'create' AND "base_revision" IS NULL AND "result_revision" = 1)
      OR ("operation" IN ('update', 'delete') AND "base_revision" > 0
        AND "result_revision" = "base_revision" + 1)
    )
  ),
  CONSTRAINT "entity_mutation_receipts_fingerprint_check"
    CHECK ("input_fingerprint" ~ '^[a-f0-9]{64}$'),
  CONSTRAINT "entity_mutation_receipts_result_metadata_check" CHECK (
    jsonb_typeof("result_metadata") = 'object'
    AND octet_length("result_metadata"::text) <= 8192
  )
);
--> statement-breakpoint

CREATE TABLE "migration_issues" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL,
  "entity_type" text NOT NULL,
  "entity_id" uuid NOT NULL,
  "issue_code" text NOT NULL,
  "safe_snapshot" jsonb NOT NULL,
  "revision" bigint DEFAULT 1 NOT NULL,
  "state" text DEFAULT 'unresolved' NOT NULL,
  "resolved_by" uuid,
  "resolved_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "migration_issues_user_entity_code_key"
    UNIQUE("user_id", "entity_type", "entity_id", "issue_code"),
  CONSTRAINT "migration_issues_revision_check" CHECK ("revision" > 0),
  CONSTRAINT "migration_issues_code_check" CHECK (
    "entity_type" ~ '^[a-z][a-z0-9_]{0,31}$'
    AND "issue_code" ~ '^[a-z][a-z0-9_]{0,63}$'
  ),
  CONSTRAINT "migration_issues_snapshot_check" CHECK (
    jsonb_typeof("safe_snapshot") = 'object'
    AND octet_length("safe_snapshot"::text) <= 16384
  ),
  CONSTRAINT "migration_issues_resolution_check" CHECK (
    ("state" = 'unresolved' AND "revision" = 1
      AND "resolved_by" IS NULL AND "resolved_at" IS NULL)
    OR ("state" = 'resolved' AND "revision" = 2
      AND "resolved_by" = "user_id" AND "resolved_at" IS NOT NULL)
  )
);
--> statement-breakpoint

ALTER TABLE "pills" ADD COLUMN "revision" bigint DEFAULT 1 NOT NULL;
--> statement-breakpoint
ALTER TABLE "pills" ADD COLUMN "last_mutation_id" uuid;
--> statement-breakpoint
ALTER TABLE "profiles" ADD COLUMN "revision" bigint DEFAULT 1 NOT NULL;
--> statement-breakpoint
ALTER TABLE "profiles" ADD COLUMN "last_mutation_id" uuid;
--> statement-breakpoint
ALTER TABLE "schedules" ADD COLUMN "revision" bigint DEFAULT 1 NOT NULL;
--> statement-breakpoint
ALTER TABLE "schedules" ADD COLUMN "last_mutation_id" uuid;
--> statement-breakpoint
ALTER TABLE "schedules" ADD COLUMN "legacy_quarantine_issue_id" uuid;
--> statement-breakpoint
ALTER TABLE "schedules" ADD COLUMN "legacy_quarantine_origin" text;
--> statement-breakpoint
ALTER TABLE "schedules" ADD COLUMN "legacy_quarantine_source" jsonb;
--> statement-breakpoint
ALTER TABLE "schedules" ADD COLUMN "timezone_review_issue_id" uuid;
--> statement-breakpoint
ALTER TABLE "schedules" ADD COLUMN "time_zone_status" text DEFAULT 'known' NOT NULL;
--> statement-breakpoint
ALTER TABLE "schedules" ADD COLUMN "time_zone" text;
--> statement-breakpoint

ALTER TABLE "entity_mutation_receipts"
  ADD CONSTRAINT "entity_mutation_receipts_user_id_users_id_fk"
  FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "migration_issues"
  ADD CONSTRAINT "migration_issues_user_id_users_id_fk"
  FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "schedules"
  ADD CONSTRAINT "schedules_legacy_quarantine_issue_id_migration_issues_id_fk"
  FOREIGN KEY ("legacy_quarantine_issue_id") REFERENCES "public"."migration_issues"("id")
  ON DELETE no action ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "schedules"
  ADD CONSTRAINT "schedules_timezone_review_issue_id_migration_issues_id_fk"
  FOREIGN KEY ("timezone_review_issue_id") REFERENCES "public"."migration_issues"("id")
  ON DELETE no action ON UPDATE no action;
--> statement-breakpoint

CREATE INDEX "entity_mutation_receipts_user_entity_idx"
  ON "entity_mutation_receipts" USING btree ("user_id", "entity_type", "entity_id");
--> statement-breakpoint
CREATE INDEX "migration_issues_user_state_created_idx"
  ON "migration_issues" USING btree ("user_id", "state", "created_at");
--> statement-breakpoint
CREATE INDEX "migration_issues_user_entity_idx"
  ON "migration_issues" USING btree ("user_id", "entity_type", "entity_id");
--> statement-breakpoint
CREATE INDEX "schedules_legacy_quarantine_issue_idx"
  ON "schedules" USING btree ("legacy_quarantine_issue_id");
--> statement-breakpoint
CREATE INDEX "schedules_timezone_review_issue_idx"
  ON "schedules" USING btree ("timezone_review_issue_id");
--> statement-breakpoint

DO $migration$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.schedules AS schedule
    WHERE octet_length(public.schedule_legacy_source_snapshot(
      schedule.id,
      schedule.revision,
      schedule.frequency,
      schedule.frequency_days,
      schedule.is_active,
      schedule.deleted_at
    )::text) > 16384
  ) THEN
    RAISE EXCEPTION
      '0013 cannot preserve a schedule snapshot larger than migration_issues safe_snapshot limit';
  END IF;
END;
$migration$;
--> statement-breakpoint

INSERT INTO public.migration_issues (
  user_id, entity_type, entity_id, issue_code, safe_snapshot
)
SELECT
  profile.user_id,
  'schedules',
  schedule.id,
  'schedule_timezone_review_required',
  public.schedule_legacy_source_snapshot(
    schedule.id,
    schedule.revision,
    schedule.frequency,
    schedule.frequency_days,
    schedule.is_active,
    schedule.deleted_at
  )
FROM public.schedules AS schedule
JOIN public.pills AS pill ON pill.id = schedule.pill_id
JOIN public.profiles AS profile ON profile.id = pill.profile_id
ON CONFLICT (user_id, entity_type, entity_id, issue_code) DO NOTHING;
--> statement-breakpoint

UPDATE public.schedules AS schedule
SET time_zone_status = 'legacy_unknown',
    time_zone = NULL,
    timezone_review_issue_id = issue.id
FROM public.pills AS pill,
     public.profiles AS profile,
     public.migration_issues AS issue
WHERE pill.id = schedule.pill_id
  AND profile.id = pill.profile_id
  AND issue.user_id = profile.user_id
  AND issue.entity_type = 'schedules'
  AND issue.entity_id = schedule.id
  AND issue.issue_code = 'schedule_timezone_review_required'
  AND issue.state = 'unresolved'
  AND issue.revision = 1
  AND schedule.timezone_review_issue_id IS NULL;
--> statement-breakpoint

UPDATE public.schedules
SET frequency_days = NULL
WHERE frequency IN ('daily', 'prn')
  AND frequency_days IS NOT NULL;
--> statement-breakpoint

INSERT INTO public.migration_issues (
  user_id, entity_type, entity_id, issue_code, safe_snapshot
)
SELECT
  profile.user_id,
  'schedules',
  schedule.id,
  'invalid_schedule_frequency_days',
  public.schedule_legacy_source_snapshot(
    schedule.id,
    schedule.revision,
    schedule.frequency,
    schedule.frequency_days,
    schedule.is_active,
    schedule.deleted_at
  )
FROM public.schedules AS schedule
JOIN public.pills AS pill ON pill.id = schedule.pill_id
JOIN public.profiles AS profile ON profile.id = pill.profile_id
WHERE NOT public.schedule_frequency_days_valid(
  schedule.frequency, schedule.frequency_days
)
ON CONFLICT (user_id, entity_type, entity_id, issue_code) DO NOTHING;
--> statement-breakpoint

UPDATE public.schedules AS schedule
SET legacy_quarantine_issue_id = issue.id,
    legacy_quarantine_origin = 'migration-0013',
    legacy_quarantine_source = issue.safe_snapshot,
    is_active = false
FROM public.pills AS pill,
     public.profiles AS profile,
     public.migration_issues AS issue
WHERE pill.id = schedule.pill_id
  AND profile.id = pill.profile_id
  AND issue.user_id = profile.user_id
  AND issue.entity_type = 'schedules'
  AND issue.entity_id = schedule.id
  AND issue.issue_code = 'invalid_schedule_frequency_days'
  AND issue.state = 'unresolved'
  AND issue.revision = 1
  AND schedule.legacy_quarantine_issue_id IS NULL;
--> statement-breakpoint

DO $migration$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.schedules AS schedule
    WHERE NOT public.schedule_frequency_days_valid(
      schedule.frequency, schedule.frequency_days
    )
      AND (
        schedule.legacy_quarantine_issue_id IS NULL
        OR schedule.legacy_quarantine_origin IS DISTINCT FROM 'migration-0013'
        OR schedule.legacy_quarantine_source IS NULL
        OR schedule.is_active
      )
  ) THEN
    RAISE EXCEPTION '0013 found an invalid schedule without complete migration quarantine';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.schedules AS schedule
    WHERE schedule.time_zone_status <> 'legacy_unknown'
       OR schedule.time_zone IS NOT NULL
       OR schedule.timezone_review_issue_id IS NULL
  ) THEN
    RAISE EXCEPTION '0013 failed to preserve timezone uncertainty for every legacy schedule';
  END IF;
END;
$migration$;
--> statement-breakpoint

ALTER TABLE "pills"
  ADD CONSTRAINT "pills_revision_check" CHECK ("revision" > 0);
--> statement-breakpoint
ALTER TABLE "profiles"
  ADD CONSTRAINT "profiles_revision_check" CHECK ("revision" > 0);
--> statement-breakpoint
ALTER TABLE "schedules"
  ADD CONSTRAINT "schedules_revision_check" CHECK ("revision" > 0);
--> statement-breakpoint
ALTER TABLE "schedules"
  ADD CONSTRAINT "schedules_timezone_status_check" CHECK (
    ("time_zone_status" = 'known' AND "time_zone" IS NOT NULL)
    OR ("time_zone_status" = 'legacy_unknown' AND "time_zone" IS NULL)
  );
--> statement-breakpoint
ALTER TABLE "schedules"
  ADD CONSTRAINT "schedules_legacy_quarantine_shape_check" CHECK (
    ("legacy_quarantine_issue_id" IS NULL
      AND "legacy_quarantine_origin" IS NULL
      AND "legacy_quarantine_source" IS NULL)
    OR ("legacy_quarantine_issue_id" IS NOT NULL
      AND "legacy_quarantine_origin" = 'migration-0013'
      AND "legacy_quarantine_source" IS NOT NULL
      AND jsonb_typeof("legacy_quarantine_source") = 'object'
      AND octet_length("legacy_quarantine_source"::text) <= 16384)
  );
--> statement-breakpoint
ALTER TABLE "schedules"
  DROP CONSTRAINT IF EXISTS "schedules_frequency_days_check";
--> statement-breakpoint
ALTER TABLE "schedules"
  ADD CONSTRAINT "schedules_frequency_days_check"
  CHECK (
    public.schedule_frequency_days_valid("frequency", "frequency_days")
    OR ("legacy_quarantine_issue_id" IS NOT NULL
      AND "legacy_quarantine_origin" = 'migration-0013'
      AND "legacy_quarantine_source" IS NOT NULL
      AND jsonb_typeof("legacy_quarantine_source") = 'object'
      AND octet_length("legacy_quarantine_source"::text) <= 16384
      AND "is_active" = false)
  ) NOT VALID;
--> statement-breakpoint

DO $migration$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.schedules AS schedule
    WHERE NOT public.schedule_frequency_days_valid(
      schedule.frequency, schedule.frequency_days
    )
      AND (
        schedule.legacy_quarantine_issue_id IS NULL
        OR schedule.legacy_quarantine_origin IS DISTINCT FROM 'migration-0013'
        OR schedule.legacy_quarantine_source IS NULL
        OR schedule.is_active
      )
  ) THEN
    RAISE EXCEPTION '0013 validation found an invalid, unquarantined schedule';
  END IF;
END;
$migration$;
--> statement-breakpoint
ALTER TABLE "schedules" VALIDATE CONSTRAINT "schedules_frequency_days_check";
--> statement-breakpoint

ALTER TABLE public.migration_issues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.migration_issues FORCE ROW LEVEL SECURITY;
ALTER TABLE public.entity_mutation_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.entity_mutation_receipts FORCE ROW LEVEL SECURITY;
--> statement-breakpoint

CREATE POLICY migration_issues_tenant_read ON public.migration_issues
  FOR SELECT TO app_user
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
--> statement-breakpoint
CREATE POLICY migration_issues_definer_access ON public.migration_issues
  FOR ALL TO deployment_authority_owner
  USING (true) WITH CHECK (true);
--> statement-breakpoint
CREATE POLICY entity_mutation_receipts_tenant_select ON public.entity_mutation_receipts
  FOR SELECT TO app_user
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
--> statement-breakpoint
CREATE POLICY entity_mutation_receipts_tenant_insert ON public.entity_mutation_receipts
  FOR INSERT TO app_user
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
--> statement-breakpoint
CREATE POLICY schedules_definer_access ON public.schedules
  FOR ALL TO deployment_authority_owner
  USING (true) WITH CHECK (true);
--> statement-breakpoint

REVOKE ALL ON public.migration_issues FROM PUBLIC, app_user, outbox_user;
GRANT SELECT ON public.migration_issues TO app_user;
GRANT SELECT, INSERT, UPDATE ON public.migration_issues TO deployment_authority_owner;
REVOKE ALL ON public.entity_mutation_receipts FROM PUBLIC, app_user, outbox_user;
GRANT SELECT, INSERT ON public.entity_mutation_receipts TO app_user;
GRANT SELECT, UPDATE ON public.schedules TO deployment_authority_owner;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.guard_migration_issue_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $function$
DECLARE
  caller_is_superuser boolean;
BEGIN
  SELECT COALESCE((
    SELECT role.rolsuper
    FROM pg_catalog.pg_roles AS role
    WHERE role.rolname = current_user
  ), false) INTO caller_is_superuser;

  IF TG_OP = 'INSERT' THEN
    IF current_user <> 'deployment_authority_owner' AND NOT caller_is_superuser THEN
      RAISE EXCEPTION 'migration issues may only be created by a guarded system operation'
        USING ERRCODE = '42501';
    END IF;
    IF NEW.revision <> 1 OR NEW.state <> 'unresolved'
       OR NEW.resolved_by IS NOT NULL OR NEW.resolved_at IS NOT NULL THEN
      RAISE EXCEPTION 'migration issues must begin unresolved at revision 1'
        USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    IF current_user <> 'deployment_authority_owner' AND NOT caller_is_superuser THEN
      RAISE EXCEPTION 'migration issue resolution requires the guarded owner operation'
        USING ERRCODE = '42501';
    END IF;
    IF ROW(NEW.id, NEW.user_id, NEW.entity_type, NEW.entity_id, NEW.issue_code,
           NEW.safe_snapshot, NEW.created_at)
       IS DISTINCT FROM
       ROW(OLD.id, OLD.user_id, OLD.entity_type, OLD.entity_id, OLD.issue_code,
           OLD.safe_snapshot, OLD.created_at) THEN
      RAISE EXCEPTION 'migration issue identity and source snapshot are immutable'
        USING ERRCODE = '23514';
    END IF;
    IF OLD.state <> 'unresolved' OR OLD.revision <> 1
       OR NEW.state <> 'resolved' OR NEW.revision <> 2
       OR NEW.resolved_by IS DISTINCT FROM NEW.user_id
       OR NEW.resolved_at IS NULL THEN
      RAISE EXCEPTION 'migration issues allow only unresolved revision 1 to resolved revision 2'
        USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    IF caller_is_superuser OR pg_trigger_depth() > 1 THEN
      RETURN OLD;
    END IF;
    RAISE EXCEPTION 'migration issues cannot be deleted independently'
      USING ERRCODE = '42501';
  END IF;
  RETURN NULL;
END;
$function$;
--> statement-breakpoint

CREATE TRIGGER migration_issues_guard_mutation
  BEFORE INSERT OR UPDATE OR DELETE ON public.migration_issues
  FOR EACH ROW EXECUTE FUNCTION public.guard_migration_issue_mutation();
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.prevent_entity_mutation_receipt_rewrite()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'entity mutation receipts are immutable'
    USING ERRCODE = '42501';
END;
$function$;
--> statement-breakpoint

CREATE TRIGGER entity_mutation_receipts_immutable
  BEFORE UPDATE OR DELETE ON public.entity_mutation_receipts
  FOR EACH ROW EXECUTE FUNCTION public.prevent_entity_mutation_receipt_rewrite();
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.guard_stable_entity_revision()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.revision <> 1 THEN
      RAISE EXCEPTION 'new stable entities must begin at revision 1'
        USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;
  IF TG_OP <> 'UPDATE' THEN
    RETURN NEW;
  END IF;
  IF NEW.revision < OLD.revision OR NEW.revision > OLD.revision + 1 THEN
    RAISE EXCEPTION 'stable entity revision cannot regress or skip'
      USING ERRCODE = '23514';
  END IF;
  IF NEW.revision = OLD.revision
     AND NEW.last_mutation_id IS DISTINCT FROM OLD.last_mutation_id THEN
    RAISE EXCEPTION 'last mutation id can change only with a revision increment'
      USING ERRCODE = '23514';
  END IF;
  IF NEW.revision = OLD.revision + 1
     AND (NEW.last_mutation_id IS NULL
       OR NEW.last_mutation_id IS NOT DISTINCT FROM OLD.last_mutation_id) THEN
    RAISE EXCEPTION 'revision increments require a new mutation id'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$function$;
--> statement-breakpoint

CREATE TRIGGER profiles_revision_guard
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.guard_stable_entity_revision();
--> statement-breakpoint
CREATE TRIGGER pills_revision_guard
  BEFORE INSERT OR UPDATE ON public.pills
  FOR EACH ROW EXECUTE FUNCTION public.guard_stable_entity_revision();
--> statement-breakpoint
CREATE TRIGGER schedules_revision_guard
  BEFORE INSERT OR UPDATE ON public.schedules
  FOR EACH ROW EXECUTE FUNCTION public.guard_stable_entity_revision();
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.guard_schedule_provenance()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $function$
DECLARE
  caller_is_superuser boolean;
  tenant_user_id uuid;
  linked_snapshot jsonb;
BEGIN
  SELECT COALESCE((
    SELECT role.rolsuper
    FROM pg_catalog.pg_roles AS role
    WHERE role.rolname = current_user
  ), false) INTO caller_is_superuser;

  IF TG_OP = 'DELETE' THEN
    IF (OLD.legacy_quarantine_issue_id IS NOT NULL
        OR OLD.time_zone_status = 'legacy_unknown')
       AND NOT caller_is_superuser
       AND pg_trigger_depth() = 1 THEN
      RAISE EXCEPTION 'a schedule with unresolved migration history cannot be deleted'
        USING ERRCODE = '23514';
    END IF;
    RETURN OLD;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF (NEW.legacy_quarantine_issue_id IS NOT NULL
        OR NEW.legacy_quarantine_origin IS NOT NULL
        OR NEW.legacy_quarantine_source IS NOT NULL
        OR NEW.timezone_review_issue_id IS NOT NULL
        OR NEW.time_zone_status <> 'known')
       AND NOT caller_is_superuser THEN
      RAISE EXCEPTION 'only migration 0013 may admit legacy schedule markers'
        USING ERRCODE = '42501';
    END IF;
  ELSE
    IF (OLD.legacy_quarantine_issue_id IS NOT NULL
        OR OLD.time_zone_status = 'legacy_unknown')
       AND current_user <> 'deployment_authority_owner'
       AND NOT caller_is_superuser THEN
      RAISE EXCEPTION 'legacy schedule history requires guarded owner repair'
        USING ERRCODE = '23514';
    END IF;

    IF OLD.legacy_quarantine_issue_id IS NULL
       AND NEW.legacy_quarantine_issue_id IS NOT NULL
       AND NOT caller_is_superuser THEN
      RAISE EXCEPTION 'runtime roles cannot create schedule quarantine markers'
        USING ERRCODE = '42501';
    END IF;
    IF OLD.legacy_quarantine_issue_id IS NOT NULL
       AND NEW.legacy_quarantine_issue_id IS DISTINCT FROM OLD.legacy_quarantine_issue_id
       AND NEW.legacy_quarantine_issue_id IS NOT NULL THEN
      RAISE EXCEPTION 'schedule quarantine issue identity is immutable'
        USING ERRCODE = '23514';
    END IF;
    IF OLD.legacy_quarantine_issue_id IS NOT NULL
       AND NEW.legacy_quarantine_issue_id IS NULL
       AND current_user <> 'deployment_authority_owner'
       AND NOT caller_is_superuser THEN
      RAISE EXCEPTION 'only guarded owner repair may clear schedule quarantine'
        USING ERRCODE = '42501';
    END IF;

    IF OLD.legacy_quarantine_source IS DISTINCT FROM NEW.legacy_quarantine_source
       AND NOT caller_is_superuser
       AND NOT (current_user = 'deployment_authority_owner'
         AND NEW.legacy_quarantine_issue_id IS NULL
         AND NEW.legacy_quarantine_source IS NULL) THEN
      RAISE EXCEPTION 'schedule quarantine source is immutable'
        USING ERRCODE = '23514';
    END IF;
    IF OLD.legacy_quarantine_origin IS DISTINCT FROM NEW.legacy_quarantine_origin
       AND NOT caller_is_superuser
       AND NOT (current_user = 'deployment_authority_owner'
         AND NEW.legacy_quarantine_issue_id IS NULL
         AND NEW.legacy_quarantine_origin IS NULL) THEN
      RAISE EXCEPTION 'schedule quarantine origin is immutable'
        USING ERRCODE = '23514';
    END IF;

    IF OLD.timezone_review_issue_id IS NULL
       AND NEW.timezone_review_issue_id IS NOT NULL
       AND NOT caller_is_superuser THEN
      RAISE EXCEPTION 'runtime roles cannot create timezone-review markers'
        USING ERRCODE = '42501';
    END IF;
    IF OLD.timezone_review_issue_id IS NOT NULL
       AND NEW.timezone_review_issue_id IS DISTINCT FROM OLD.timezone_review_issue_id
       AND NEW.timezone_review_issue_id IS NOT NULL THEN
      RAISE EXCEPTION 'timezone-review issue identity is immutable'
        USING ERRCODE = '23514';
    END IF;
    IF OLD.timezone_review_issue_id IS NOT NULL
       AND NEW.timezone_review_issue_id IS NULL
       AND current_user <> 'deployment_authority_owner'
       AND NOT caller_is_superuser THEN
      RAISE EXCEPTION 'only guarded owner repair may clear timezone-review markers'
        USING ERRCODE = '42501';
    END IF;

    IF OLD.time_zone_status = 'legacy_unknown'
       AND current_user = 'deployment_authority_owner'
       AND OLD.legacy_quarantine_issue_id IS NOT NULL
       AND NEW.legacy_quarantine_issue_id IS NOT NULL
       AND ROW(NEW.pill_id, NEW.hour, NEW.minute, NEW.frequency, NEW.frequency_days,
               NEW.is_active, NEW.deleted_at)
         IS DISTINCT FROM
           ROW(OLD.pill_id, OLD.hour, OLD.minute, OLD.frequency, OLD.frequency_days,
               OLD.is_active, OLD.deleted_at) THEN
      RAISE EXCEPTION 'timezone repair cannot partially rewrite a quarantined schedule'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.time_zone_status = 'legacy_unknown' AND NOT caller_is_superuser THEN
    RAISE EXCEPTION 'runtime operations must not create or retain unknown timezone state'
      USING ERRCODE = '42501';
  END IF;
  IF NEW.time_zone_status = 'known' AND (
    NEW.time_zone IS NULL
    OR NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_timezone_names AS zone
      WHERE zone.name = NEW.time_zone
    )
  ) THEN
    RAISE EXCEPTION 'known schedules require a valid IANA timezone'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.legacy_quarantine_issue_id IS NOT NULL THEN
    IF NEW.is_active
       OR NEW.legacy_quarantine_origin IS DISTINCT FROM 'migration-0013'
       OR NEW.legacy_quarantine_source IS NULL
       OR jsonb_typeof(NEW.legacy_quarantine_source) <> 'object'
       OR octet_length(NEW.legacy_quarantine_source::text) > 16384 THEN
      RAISE EXCEPTION 'schedule quarantine marker is incomplete or active'
        USING ERRCODE = '23514';
    END IF;

    SELECT profile.user_id INTO tenant_user_id
    FROM public.pills AS pill
    JOIN public.profiles AS profile ON profile.id = pill.profile_id
    WHERE pill.id = NEW.pill_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'schedule tenant could not be resolved for quarantine validation'
        USING ERRCODE = '23503';
    END IF;

    SELECT issue.safe_snapshot INTO linked_snapshot
    FROM public.migration_issues AS issue
    WHERE issue.id = NEW.legacy_quarantine_issue_id
      AND issue.user_id = tenant_user_id
      AND issue.entity_type = 'schedules'
      AND issue.entity_id = NEW.id
      AND issue.issue_code = 'invalid_schedule_frequency_days'
      AND issue.state = 'unresolved'
      AND issue.revision = 1;
    IF NOT FOUND OR linked_snapshot IS DISTINCT FROM NEW.legacy_quarantine_source THEN
      RAISE EXCEPTION 'schedule quarantine must link its immutable unresolved source issue'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.timezone_review_issue_id IS NOT NULL THEN
    SELECT profile.user_id INTO tenant_user_id
    FROM public.pills AS pill
    JOIN public.profiles AS profile ON profile.id = pill.profile_id
    WHERE pill.id = NEW.pill_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'schedule tenant could not be resolved for timezone-review validation'
        USING ERRCODE = '23503';
    END IF;

    PERFORM 1
    FROM public.migration_issues AS issue
    WHERE issue.id = NEW.timezone_review_issue_id
      AND issue.user_id = tenant_user_id
      AND issue.entity_type = 'schedules'
      AND issue.entity_id = NEW.id
      AND issue.issue_code = 'schedule_timezone_review_required'
      AND issue.state = 'unresolved'
      AND issue.revision = 1
      AND issue.safe_snapshot ->> 'scheduleId' = NEW.id::text;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'unknown timezone must link its unresolved tenant issue'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;
--> statement-breakpoint

CREATE TRIGGER schedules_provenance_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.schedules
  FOR EACH ROW EXECUTE FUNCTION public.guard_schedule_provenance();
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.guard_unresolved_schedule_parent_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $function$
DECLARE
  caller_is_superuser boolean;
  unresolved_child boolean;
BEGIN
  SELECT COALESCE((
    SELECT role.rolsuper
    FROM pg_catalog.pg_roles AS role
    WHERE role.rolname = current_user
  ), false) INTO caller_is_superuser;

  IF caller_is_superuser OR pg_trigger_depth() > 1 THEN
    RETURN OLD;
  END IF;

  IF TG_TABLE_NAME = 'pills' THEN
    SELECT EXISTS (
      SELECT 1 FROM public.schedules AS schedule
      WHERE schedule.pill_id = OLD.id
        AND (schedule.legacy_quarantine_issue_id IS NOT NULL
          OR schedule.time_zone_status = 'legacy_unknown')
    ) INTO unresolved_child;
  ELSIF TG_TABLE_NAME = 'profiles' THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.pills AS pill
      JOIN public.schedules AS schedule ON schedule.pill_id = pill.id
      WHERE pill.profile_id = OLD.id
        AND (schedule.legacy_quarantine_issue_id IS NOT NULL
          OR schedule.time_zone_status = 'legacy_unknown')
    ) INTO unresolved_child;
  ELSE
    RETURN OLD;
  END IF;

  IF unresolved_child THEN
    RAISE EXCEPTION 'a parent with unresolved legacy schedules cannot be deleted'
      USING ERRCODE = '23514';
  END IF;
  RETURN OLD;
END;
$function$;
--> statement-breakpoint

CREATE TRIGGER profiles_unresolved_schedule_delete_guard
  BEFORE DELETE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.guard_unresolved_schedule_parent_delete();
--> statement-breakpoint
CREATE TRIGGER pills_unresolved_schedule_delete_guard
  BEFORE DELETE ON public.pills
  FOR EACH ROW EXECUTE FUNCTION public.guard_unresolved_schedule_parent_delete();
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.validate_schedule_issue_pairings()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $function$
DECLARE
  current_schedule public.schedules%ROWTYPE;
  current_issue public.migration_issues%ROWTYPE;
  tenant_user_id uuid;
BEGIN
  IF TG_TABLE_NAME = 'schedules' THEN
    SELECT * INTO current_schedule
    FROM public.schedules
    WHERE id = NEW.id;
    IF NOT FOUND THEN
      RETURN NULL;
    END IF;

    SELECT profile.user_id INTO tenant_user_id
    FROM public.pills AS pill
    JOIN public.profiles AS profile ON profile.id = pill.profile_id
    WHERE pill.id = current_schedule.pill_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'schedule tenant is missing at migration-issue validation'
        USING ERRCODE = '23503';
    END IF;

    IF current_schedule.legacy_quarantine_issue_id IS NOT NULL THEN
      PERFORM 1
      FROM public.migration_issues AS issue
      WHERE issue.id = current_schedule.legacy_quarantine_issue_id
        AND issue.user_id = tenant_user_id
        AND issue.entity_type = 'schedules'
        AND issue.entity_id = current_schedule.id
        AND issue.issue_code = 'invalid_schedule_frequency_days'
        AND issue.state = 'unresolved'
        AND issue.revision = 1
        AND issue.safe_snapshot = current_schedule.legacy_quarantine_source;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'schedule quarantine must remain linked to its unresolved source issue'
          USING ERRCODE = '23514';
      END IF;
    END IF;

    IF current_schedule.time_zone_status = 'legacy_unknown' THEN
      PERFORM 1
      FROM public.migration_issues AS issue
      WHERE issue.id = current_schedule.timezone_review_issue_id
        AND issue.user_id = tenant_user_id
        AND issue.entity_type = 'schedules'
        AND issue.entity_id = current_schedule.id
        AND issue.issue_code = 'schedule_timezone_review_required'
        AND issue.state = 'unresolved'
        AND issue.revision = 1;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown timezone must retain its unresolved review issue'
          USING ERRCODE = '23514';
      END IF;
    ELSIF current_schedule.timezone_review_issue_id IS NOT NULL THEN
      RAISE EXCEPTION 'known timezone cannot retain an unresolved review marker'
        USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
  END IF;

  SELECT * INTO current_issue
  FROM public.migration_issues
  WHERE id = NEW.id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF current_issue.state = 'resolved'
     AND current_issue.entity_type = 'schedules'
     AND current_issue.issue_code = 'invalid_schedule_frequency_days'
     AND EXISTS (
       SELECT 1 FROM public.schedules AS schedule
       WHERE schedule.legacy_quarantine_issue_id = current_issue.id
     ) THEN
    RAISE EXCEPTION 'resolved frequency issue still has a quarantined schedule'
      USING ERRCODE = '23514';
  END IF;
  IF current_issue.state = 'resolved'
     AND current_issue.entity_type = 'schedules'
     AND current_issue.issue_code = 'schedule_timezone_review_required'
     AND EXISTS (
       SELECT 1 FROM public.schedules AS schedule
       WHERE schedule.timezone_review_issue_id = current_issue.id
     ) THEN
    RAISE EXCEPTION 'resolved timezone issue still has a schedule marker'
      USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END;
$function$;
--> statement-breakpoint

CREATE CONSTRAINT TRIGGER schedules_issue_pairing_deferred
  AFTER INSERT OR UPDATE ON public.schedules
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.validate_schedule_issue_pairings();
--> statement-breakpoint
CREATE CONSTRAINT TRIGGER migration_issues_schedule_pairing_deferred
  AFTER INSERT OR UPDATE ON public.migration_issues
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.validate_schedule_issue_pairings();
--> statement-breakpoint
