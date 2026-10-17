-- Deleting a user (DELETE /admin/users/:id) cascades into profiles, pills,
-- schedules and dose_logs. The 0015 handoff triggers fire for those cascaded
-- deletes, and by then the users row is already gone, so
-- next_sync_server_sequence() inserted into sync_stream_counters for a missing
-- user and failed sync_stream_counters_user_id_users_id_fk (HTTP 500). The
-- journal exists to capture a live tenant's legacy writes for the ledger
-- handoff; a tenant that no longer exists has nothing to hand off, and its
-- counters and journal rows go away with it through ON DELETE CASCADE.
--
-- These triggers now return early, only for a DELETE whose tenant user row no
-- longer exists. Every other path (including a profile or pill removed while
-- its user remains) behaves exactly as before. The owner role gets a
-- column-level SELECT on users.id to make that existence check.
--
-- A user who still has an unresolved schedule review or quarantine hit a second
-- failure on the same delete: ON DELETE CASCADE removes the user's
-- migration_issues before the schedules that reference them, and the NO ACTION
-- foreign keys from schedules were checked immediately. They are now deferred to
-- commit, when the whole cascade has finished; a schedule that really still
-- points at a missing issue is still rejected there.

GRANT SELECT (id) ON public.users TO deployment_authority_owner;
--> statement-breakpoint

ALTER TABLE public.schedules
  ALTER CONSTRAINT schedules_legacy_quarantine_issue_id_migration_issues_id_fk DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE public.schedules
  ALTER CONSTRAINT schedules_timezone_review_issue_id_migration_issues_id_fk DEFERRABLE INITIALLY DEFERRED;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.lock_legacy_medication_authority()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  activated boolean;
  tenant_user_id uuid := NULLIF(current_setting('app.current_user_id', true), '')::uuid;
BEGIN
  SELECT ledger_activated INTO STRICT activated
  FROM public.deployment_manifest WHERE singleton_key IS TRUE FOR SHARE;
  IF tenant_user_id IS NOT NULL AND TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::uuid) THEN
    RETURN NULL;
  END IF;
  IF tenant_user_id IS NULL THEN
    RAISE EXCEPTION 'legacy medication write lacks tenant context' USING ERRCODE = '42501';
  END IF;
  IF TG_TABLE_NAME = 'dose_logs' AND activated THEN
    RAISE EXCEPTION 'legacy dose writes are disabled after ledger activation' USING ERRCODE = '55000';
  END IF;
  -- Prime the tenant sequence lock before this statement takes source-row locks.
  PERFORM public.next_sync_server_sequence(tenant_user_id);
  RETURN NULL;
END;
$function$;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.journal_legacy_medication_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  tenant_user_id uuid;
  source_id uuid;
  source_kind text;
  effect_kind text;
  before_value jsonb;
  after_value jsonb;
  bundle_id uuid;
  correlation_id uuid;
  command_id uuid;
  command_fingerprint text;
  source_revision bigint;
  sequence_value bigint;
  ordinal_value integer;
  activated boolean;
  balance bigint;
  inventory_event_count bigint;
  payload jsonb;
  tombstone_at timestamptz;
  configured_bundle text := NULLIF(current_setting('app.medication_command_bundle_id', true), '');
  configured_correlation text := NULLIF(current_setting('app.transaction_correlation_id', true), '');
  configured_command text := NULLIF(current_setting('app.medication_command_id', true), '');
  configured_fingerprint text := NULLIF(current_setting('app.medication_command_fingerprint', true), '');
BEGIN
  IF TG_TABLE_NAME = 'dose_logs' THEN
    source_kind := 'dose_log';
    effect_kind := 'dose';
    source_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END;
    SELECT pr.user_id INTO tenant_user_id
    FROM public.schedules s JOIN public.pills p ON p.id = s.pill_id
    JOIN public.profiles pr ON pr.id = p.profile_id
    WHERE s.id = CASE WHEN TG_OP = 'DELETE' THEN OLD.schedule_id ELSE NEW.schedule_id END;
    IF tenant_user_id IS NULL THEN
      IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::uuid) THEN RETURN OLD; END IF;
      RAISE EXCEPTION 'legacy medication write has no owning tenant' USING ERRCODE = 'P0002';
    END IF;
    IF TG_OP <> 'INSERT' THEN
      before_value := jsonb_build_object('id', OLD.id, 'scheduleId', OLD.schedule_id,
        'scheduledAt', public.simpastil_utc_iso(OLD.scheduled_at), 'takenAt', public.simpastil_utc_iso(OLD.taken_at),
        'status', OLD.status, 'deletedAt', public.simpastil_utc_iso(OLD.deleted_at));
    END IF;
    IF TG_OP <> 'DELETE' THEN
      after_value := jsonb_build_object('id', NEW.id, 'scheduleId', NEW.schedule_id,
        'scheduledAt', public.simpastil_utc_iso(NEW.scheduled_at), 'takenAt', public.simpastil_utc_iso(NEW.taken_at),
        'status', NEW.status, 'deletedAt', public.simpastil_utc_iso(NEW.deleted_at));
    END IF;
  ELSE
    source_kind := 'pill_stock';
    effect_kind := 'inventory';
    source_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END;
    IF TG_OP = 'INSERT' THEN
      SELECT pr.user_id INTO STRICT tenant_user_id
      FROM public.profiles pr
      WHERE pr.id = NEW.profile_id;
    ELSE
      SELECT pr.user_id INTO tenant_user_id
      FROM public.pills p JOIN public.profiles pr ON pr.id = p.profile_id
      WHERE p.id = source_id;
    END IF;
    IF tenant_user_id IS NULL THEN
      IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::uuid) THEN RETURN OLD; END IF;
      RAISE EXCEPTION 'legacy medication write has no owning tenant' USING ERRCODE = 'P0002';
    END IF;
    IF TG_OP = 'UPDATE' THEN
      IF NEW.current_stock IS NOT DISTINCT FROM OLD.current_stock THEN RETURN NEW; END IF;
    END IF;
    IF TG_OP <> 'INSERT' THEN
      before_value := jsonb_build_object('pillId', OLD.id, 'currentStock', OLD.current_stock,
        'updatedAt', public.simpastil_utc_iso(OLD.updated_at));
    END IF;
    IF TG_OP <> 'DELETE' THEN
      after_value := jsonb_build_object('pillId', NEW.id, 'currentStock', NEW.current_stock,
        'updatedAt', public.simpastil_utc_iso(NEW.updated_at));
    END IF;
    SELECT ledger_activated INTO STRICT activated FROM public.deployment_manifest WHERE singleton_key IS TRUE;
    IF activated THEN
      IF TG_OP = 'DELETE' THEN
        IF OLD.current_stock IS NOT NULL THEN
          RAISE EXCEPTION 'tracked stock cannot be removed after ledger activation' USING ERRCODE = '23514';
        END IF;
        RETURN OLD;
      END IF;
      IF NEW.current_stock IS NULL THEN
        IF TG_OP = 'UPDATE' AND OLD.current_stock IS NOT NULL THEN
          RAISE EXCEPTION 'tracked stock cannot be removed after ledger activation' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      SELECT COALESCE(sum(event.delta), 0)::bigint, count(*) INTO balance, inventory_event_count
      FROM public.inventory_events event WHERE event.user_id = tenant_user_id AND event.pill_id = source_id;
      IF inventory_event_count = 0 THEN
        RAISE EXCEPTION 'tracked stock requires an opening inventory event' USING ERRCODE = '23514';
      END IF;
      IF NEW.current_stock::bigint IS DISTINCT FROM balance THEN
        RAISE EXCEPTION 'pill stock must equal its medication inventory ledger projection' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END IF;
  END IF;

  IF tenant_user_id IS DISTINCT FROM NULLIF(current_setting('app.current_user_id', true), '')::uuid THEN
    RAISE EXCEPTION 'legacy journal tenant does not match transaction context' USING ERRCODE = '42501';
  END IF;
  IF configured_bundle ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN
    bundle_id := configured_bundle::uuid;
  ELSE
    bundle_id := public.simpastil_deterministic_uuid('medication-handoff-tx|' || txid_current()::text);
    PERFORM set_config('app.medication_command_bundle_id', bundle_id::text, true);
  END IF;
  IF configured_correlation ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN
    correlation_id := configured_correlation::uuid;
  ELSE
    correlation_id := bundle_id;
    PERFORM set_config('app.transaction_correlation_id', correlation_id::text, true);
  END IF;
  IF configured_command ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN
    command_id := configured_command::uuid;
  END IF;
  IF configured_fingerprint ~ '^[a-f0-9]{64}$' THEN command_fingerprint := configured_fingerprint; END IF;

  SELECT GREATEST(
    COALESCE((SELECT max(j.source_revision) FROM public.medication_handoff_journal j
      WHERE j.user_id = tenant_user_id AND j.legacy_source_kind = source_kind AND j.legacy_source_id = source_id), 0),
    COALESCE((SELECT max(h.source_revision) FROM public.legacy_medication_history h
      WHERE h.user_id = tenant_user_id AND h.legacy_source_kind = source_kind AND h.legacy_source_id = source_id), 0)
  ) + 1 INTO source_revision;
  SELECT COALESCE(max(j.subeffect_ordinal), 0) + 1 INTO ordinal_value
  FROM public.medication_handoff_journal j
  WHERE j.user_id = tenant_user_id AND j.command_bundle_id = bundle_id;
  sequence_value := public.next_sync_server_sequence(tenant_user_id);

  INSERT INTO public.medication_handoff_journal (
    user_id, journal_sequence, command_bundle_id, transaction_correlation_id,
    command_id, command_fingerprint, subeffect_ordinal, subeffect_kind,
    legacy_source_kind, legacy_source_id, source_revision, before_evidence, after_evidence
  ) VALUES (
    tenant_user_id, sequence_value, bundle_id, correlation_id, command_id,
    command_fingerprint, ordinal_value, effect_kind, source_kind, source_id,
    source_revision, before_value, after_value
  );

  IF source_kind = 'dose_log' THEN
    IF TG_OP = 'DELETE' THEN
      tombstone_at := now();
      payload := jsonb_build_object('kind', 'tombstone', 'entityType', 'bridge_dose',
        'id', source_id, 'revision', source_revision::text,
        'deletedAt', public.simpastil_utc_iso(tombstone_at));
      PERFORM public.simpastil_seed_sync_change(tenant_user_id, 'medicationBridge', 'bridge_dose',
        source_id, 'tombstone', 'legacy_dose_log', source_id, source_revision, payload);
    ELSIF NEW.deleted_at IS NOT NULL THEN
      tombstone_at := NEW.deleted_at;
      payload := jsonb_build_object('kind', 'tombstone', 'entityType', 'bridge_dose',
        'id', source_id, 'revision', source_revision::text,
        'deletedAt', public.simpastil_utc_iso(tombstone_at));
      PERFORM public.simpastil_seed_sync_change(tenant_user_id, 'medicationBridge', 'bridge_dose',
        source_id, 'tombstone', 'legacy_dose_log', source_id, source_revision, payload);
    ELSE
      payload := jsonb_build_object('kind', 'bridgeDose', 'id', source_id,
        'scheduleId', NEW.schedule_id, 'scheduledAt', public.simpastil_utc_iso(NEW.scheduled_at),
        'takenAt', public.simpastil_utc_iso(NEW.taken_at), 'status', NEW.status,
        'deletedAt', NULL, 'sourceRevision', source_revision::text);
      PERFORM public.simpastil_seed_sync_change(tenant_user_id, 'medicationBridge', 'bridge_dose',
        source_id, 'upsert', 'legacy_dose_log', source_id, source_revision, payload);
    END IF;
  ELSE
    IF TG_OP = 'DELETE' THEN
      payload := jsonb_build_object('kind', 'tombstone', 'entityType', 'bridge_stock',
        'id', source_id, 'revision', source_revision::text, 'deletedAt', public.simpastil_utc_iso(now()));
      PERFORM public.simpastil_seed_sync_change(tenant_user_id, 'medicationBridge', 'bridge_stock',
        source_id, 'tombstone', 'legacy_pill_stock', source_id, source_revision, payload);
    ELSE
      payload := jsonb_build_object('kind', 'bridgeStock', 'pillId', source_id,
        'currentStock', NEW.current_stock, 'sourceRevision', source_revision::text,
        'updatedAt', public.simpastil_utc_iso(NEW.updated_at));
      PERFORM public.simpastil_seed_sync_change(tenant_user_id, 'medicationBridge', 'bridge_stock',
        source_id, 'upsert', 'legacy_pill_stock', source_id, source_revision, payload);
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$function$;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.reject_legacy_dose_mutation_after_activation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  activated boolean;
BEGIN
  SELECT ledger_activated INTO STRICT activated
  FROM public.deployment_manifest WHERE singleton_key IS TRUE FOR SHARE;
  IF TG_OP = 'DELETE' AND activated
     AND NULLIF(current_setting('app.current_user_id', true), '') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::uuid) THEN
    RETURN OLD;
  END IF;
  IF activated THEN
    RAISE EXCEPTION 'legacy dose writes are disabled after ledger activation' USING ERRCODE = '55000';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$function$;
--> statement-breakpoint

ALTER FUNCTION public.lock_legacy_medication_authority() OWNER TO deployment_authority_owner;
ALTER FUNCTION public.journal_legacy_medication_write() OWNER TO deployment_authority_owner;
ALTER FUNCTION public.reject_legacy_dose_mutation_after_activation() OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.lock_legacy_medication_authority() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.journal_legacy_medication_write() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_legacy_dose_mutation_after_activation() FROM PUBLIC;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.record_deployment_schema_version_0022()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  UPDATE public.deployment_manifest
  SET schema_version = 22, release_id = 'migration-0022',
      migration_completed_at = now(), updated_at = now()
  WHERE singleton_key IS TRUE;
END;
$function$;
--> statement-breakpoint

ALTER FUNCTION public.record_deployment_schema_version_0022() OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.record_deployment_schema_version_0022() FROM PUBLIC;
SELECT public.record_deployment_schema_version_0022();
--> statement-breakpoint
