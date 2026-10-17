-- 0015 shipped a stock guard that, once the ledger is active, rejected every
-- pills write whose new current_stock was NULL. That includes the INSERT of an
-- untracked pill and of any new pill before its inventory start command (stock
-- stays NULL until then), so POST /profiles/:id/pills failed with a 500 on an
-- activated deployment. The "cannot be removed" rule now applies only when the
-- previous stock was non-null (UPDATE to NULL, or DELETE of a tracked pill).
-- A non-null stock still needs an opening inventory event and must equal the
-- ledger projection. Everything else is the 0015 definition, unchanged.

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
    SELECT pr.user_id INTO STRICT tenant_user_id
    FROM public.schedules s JOIN public.pills p ON p.id = s.pill_id
    JOIN public.profiles pr ON pr.id = p.profile_id
    WHERE s.id = CASE WHEN TG_OP = 'DELETE' THEN OLD.schedule_id ELSE NEW.schedule_id END;
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
      SELECT pr.user_id INTO STRICT tenant_user_id
      FROM public.pills p JOIN public.profiles pr ON pr.id = p.profile_id
      WHERE p.id = source_id;
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

ALTER FUNCTION public.journal_legacy_medication_write() OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.journal_legacy_medication_write() FROM PUBLIC;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.record_deployment_schema_version_0021()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  UPDATE public.deployment_manifest
  SET schema_version = 21, release_id = 'migration-0021',
      migration_completed_at = now(), updated_at = now()
  WHERE singleton_key IS TRUE;
END;
$function$;
--> statement-breakpoint

ALTER FUNCTION public.record_deployment_schema_version_0021() OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.record_deployment_schema_version_0021() FROM PUBLIC;
SELECT public.record_deployment_schema_version_0021();
--> statement-breakpoint

DROP FUNCTION public.record_deployment_schema_version_0021();
