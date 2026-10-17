ALTER TABLE "medication_occurrences" DROP CONSTRAINT "medication_occurrences_supersession_check";--> statement-breakpoint
ALTER TABLE "schedules" ADD COLUMN "materialize_from_local_date" date;--> statement-breakpoint
ALTER TABLE "medication_occurrences" ADD CONSTRAINT "medication_occurrences_supersession_check" CHECK (
    ("medication_occurrences"."superseded_at" IS NULL AND "medication_occurrences"."superseded_by_occurrence_id" IS NULL)
    OR ("medication_occurrences"."superseded_at" IS NOT NULL
      AND ("medication_occurrences"."superseded_by_occurrence_id" IS NULL
        OR "medication_occurrences"."superseded_by_occurrence_id" <> "medication_occurrences"."id"))
  );
--> statement-breakpoint

CREATE EXTENSION IF NOT EXISTS pgcrypto;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.simpastil_canonical_jsonb(p_value jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $function$
DECLARE
  result text;
BEGIN
  CASE jsonb_typeof(p_value)
    WHEN 'object' THEN
      SELECT '{' || COALESCE(string_agg(to_json(entry.key)::text || ':' || public.simpastil_canonical_jsonb(entry.value), ',' ORDER BY entry.key COLLATE "C"), '') || '}'
        INTO result FROM jsonb_each(p_value) AS entry;
      RETURN result;
    WHEN 'array' THEN
      SELECT '[' || COALESCE(string_agg(public.simpastil_canonical_jsonb(entry.value), ',' ORDER BY entry.ordinality), '') || ']'
        INTO result FROM jsonb_array_elements(p_value) WITH ORDINALITY AS entry(value, ordinality);
      RETURN result;
    ELSE
      RETURN p_value::text;
  END CASE;
END;
$function$;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.simpastil_deterministic_uuid(p_name text)
RETURNS uuid
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $function$
DECLARE
  bytes bytea := decode(md5(p_name), 'hex');
  value text;
BEGIN
  bytes := set_byte(bytes, 6, (get_byte(bytes, 6) & 15) | 80);
  bytes := set_byte(bytes, 8, (get_byte(bytes, 8) & 63) | 128);
  value := encode(bytes, 'hex');
  RETURN (substr(value, 1, 8) || '-' || substr(value, 9, 4) || '-' || substr(value, 13, 4)
    || '-' || substr(value, 17, 4) || '-' || substr(value, 21, 12))::uuid;
END;
$function$;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.simpastil_utc_iso(p_value timestamptz)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog
AS $function$
  SELECT CASE WHEN p_value IS NULL THEN NULL
    ELSE to_char(p_value AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') END
$function$;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.simpastil_seed_sync_change(
  p_user_id uuid,
  p_component text,
  p_entity_type text,
  p_entity_id uuid,
  p_operation text,
  p_source_kind text,
  p_source_id uuid,
  p_source_revision bigint,
  p_payload jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  sequence_value bigint;
  envelope jsonb;
BEGIN
  IF p_user_id IS DISTINCT FROM NULLIF(current_setting('app.current_user_id', true), '')::uuid THEN
    RAISE EXCEPTION 'seed sync tenant does not match transaction context' USING ERRCODE = '42501';
  END IF;
  sequence_value := public.next_sync_server_sequence(p_user_id);
  envelope := jsonb_build_object(
    'schemaVersion', 2,
    'component', p_component,
    'entityType', p_entity_type,
    'entityId', p_entity_id,
    'operation', p_operation,
    'sourceIdentity', jsonb_build_object(
      'sourceKind', p_source_kind,
      'sourceId', p_source_id,
      'sourceRevision', p_source_revision::text
    ),
    'payload', p_payload
  );
  INSERT INTO public.sync_changes (
    user_id, component, entity_type, entity_id, operation, source_kind,
    source_id, source_revision, server_sequence, payload_schema_version, payload
  ) VALUES (
    p_user_id, p_component, p_entity_type, p_entity_id, p_operation, p_source_kind,
    p_source_id, p_source_revision, sequence_value, 2, envelope
  );
  RETURN sequence_value;
END;
$function$;
--> statement-breakpoint

ALTER FUNCTION public.simpastil_seed_sync_change(uuid, text, text, uuid, text, text, uuid, bigint, jsonb)
  OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.simpastil_seed_sync_change(uuid, text, text, uuid, text, text, uuid, bigint, jsonb)
  FROM PUBLIC, app_user, outbox_user;
--> statement-breakpoint

DO $backfill$
DECLARE
  user_row record;
  item_row record;
  v_history_id uuid;
  v_entry_id uuid;
  identity_prefix text;
  source_snapshot jsonb;
  source_fingerprint text;
  sync_sequence bigint;
  event_sequence bigint;
  event_id uuid;
  payload jsonb;
BEGIN
  FOR user_row IN SELECT id, email, created_at, updated_at FROM public.users ORDER BY id LOOP
    PERFORM set_config('app.current_user_id', user_row.id::text, true);

    PERFORM public.simpastil_seed_sync_change(
      user_row.id, 'account', 'account', user_row.id, 'upsert', 'account', user_row.id, 1,
      jsonb_build_object('kind', 'account', 'id', user_row.id, 'email', user_row.email,
        'revision', '1', 'createdAt', public.simpastil_utc_iso(user_row.created_at),
        'updatedAt', public.simpastil_utc_iso(user_row.updated_at))
    );

    FOR item_row IN SELECT * FROM public.migration_issues WHERE user_id = user_row.id ORDER BY id LOOP
      PERFORM public.simpastil_seed_sync_change(
        item_row.user_id, 'account', 'migration_issue', item_row.id, 'upsert',
        'migration_issue', item_row.id, item_row.revision,
        jsonb_build_object('kind', 'migrationIssue', 'id', item_row.id,
          'entityType', item_row.entity_type, 'entityId', item_row.entity_id,
          'issueCode', item_row.issue_code, 'safeSnapshot', item_row.safe_snapshot,
          'revision', item_row.revision::text, 'state', item_row.state,
          'resolvedAt', public.simpastil_utc_iso(item_row.resolved_at),
          'createdAt', public.simpastil_utc_iso(item_row.created_at))
      );
    END LOOP;

    FOR item_row IN SELECT * FROM public.profiles WHERE user_id = user_row.id ORDER BY id LOOP
      IF item_row.deleted_at IS NULL THEN
        payload := jsonb_build_object('kind', 'profile', 'id', item_row.id, 'userId', item_row.user_id,
          'name', item_row.name, 'avatarEmoji', item_row.avatar_emoji, 'isActive', item_row.is_active,
          'revision', item_row.revision::text, 'deletedAt', NULL,
          'createdAt', public.simpastil_utc_iso(item_row.created_at),
          'updatedAt', public.simpastil_utc_iso(item_row.updated_at));
        PERFORM public.simpastil_seed_sync_change(item_row.user_id, 'stable', 'profile', item_row.id,
          'upsert', 'profile', item_row.id, item_row.revision, payload);
      ELSE
        payload := jsonb_build_object('kind', 'tombstone', 'entityType', 'profile', 'id', item_row.id,
          'revision', item_row.revision::text, 'deletedAt', public.simpastil_utc_iso(item_row.deleted_at));
        PERFORM public.simpastil_seed_sync_change(item_row.user_id, 'stable', 'profile', item_row.id,
          'tombstone', 'profile', item_row.id, item_row.revision, payload);
      END IF;
    END LOOP;

    FOR item_row IN SELECT p.* FROM public.pills p JOIN public.profiles pr ON pr.id = p.profile_id
      WHERE pr.user_id = user_row.id ORDER BY p.id LOOP
      IF item_row.deleted_at IS NULL THEN
        payload := jsonb_build_object('kind', 'pill', 'id', item_row.id, 'profileId', item_row.profile_id,
          'name', item_row.name, 'dosage', item_row.dosage, 'notes', item_row.notes, 'color', item_row.color,
          'currentStock', item_row.current_stock, 'lowStockThreshold', item_row.low_stock_threshold,
          'isPrn', item_row.is_prn, 'revision', item_row.revision::text, 'deletedAt', NULL,
          'createdAt', public.simpastil_utc_iso(item_row.created_at),
          'updatedAt', public.simpastil_utc_iso(item_row.updated_at));
        PERFORM public.simpastil_seed_sync_change(user_row.id, 'stable', 'pill', item_row.id,
          'upsert', 'pill', item_row.id, item_row.revision, payload);
      ELSE
        payload := jsonb_build_object('kind', 'tombstone', 'entityType', 'pill', 'id', item_row.id,
          'revision', item_row.revision::text, 'deletedAt', public.simpastil_utc_iso(item_row.deleted_at));
        PERFORM public.simpastil_seed_sync_change(user_row.id, 'stable', 'pill', item_row.id,
          'tombstone', 'pill', item_row.id, item_row.revision, payload);
      END IF;
    END LOOP;

    FOR item_row IN SELECT s.* FROM public.schedules s JOIN public.pills p ON p.id = s.pill_id
      JOIN public.profiles pr ON pr.id = p.profile_id
      WHERE pr.user_id = user_row.id ORDER BY s.id LOOP
      IF public.schedule_frequency_days_valid(item_row.frequency, item_row.frequency_days) THEN
        IF item_row.deleted_at IS NULL THEN
          payload := jsonb_build_object('kind', 'schedule', 'id', item_row.id, 'pillId', item_row.pill_id,
            'hour', item_row.hour, 'minute', item_row.minute, 'frequency', item_row.frequency,
            'frequencyDays', item_row.frequency_days, 'isActive', item_row.is_active,
            'revision', item_row.revision::text, 'timeZoneStatus', item_row.time_zone_status,
            'timeZone', item_row.time_zone, 'deletedAt', NULL,
            'createdAt', public.simpastil_utc_iso(item_row.created_at),
            'updatedAt', public.simpastil_utc_iso(item_row.updated_at));
          PERFORM public.simpastil_seed_sync_change(user_row.id, 'stable', 'schedule', item_row.id,
            'upsert', 'schedule', item_row.id, item_row.revision, payload);
        ELSE
          payload := jsonb_build_object('kind', 'tombstone', 'entityType', 'schedule', 'id', item_row.id,
            'revision', item_row.revision::text, 'deletedAt', public.simpastil_utc_iso(item_row.deleted_at));
          PERFORM public.simpastil_seed_sync_change(user_row.id, 'stable', 'schedule', item_row.id,
            'tombstone', 'schedule', item_row.id, item_row.revision, payload);
        END IF;
      END IF;
    END LOOP;

    FOR item_row IN SELECT d.*, s.pill_id FROM public.dose_logs d
      JOIN public.schedules s ON s.id = d.schedule_id
      JOIN public.pills p ON p.id = s.pill_id
      JOIN public.profiles pr ON pr.id = p.profile_id
      WHERE pr.user_id = user_row.id ORDER BY d.id LOOP
      identity_prefix := 'legacy-history-v1|' || lower(user_row.id::text) || '|dose_log|' || lower(item_row.id::text);
      v_history_id := public.simpastil_deterministic_uuid(identity_prefix || '|history');
      v_entry_id := public.simpastil_deterministic_uuid(identity_prefix || '|entry|1');
      source_snapshot := jsonb_build_object(
        'deletedAt', public.simpastil_utc_iso(item_row.deleted_at), 'id', item_row.id,
        'scheduleId', item_row.schedule_id, 'scheduledAt', public.simpastil_utc_iso(item_row.scheduled_at),
        'status', item_row.status, 'takenAt', public.simpastil_utc_iso(item_row.taken_at)
      );
      source_fingerprint := encode(digest(convert_to(public.simpastil_canonical_jsonb(source_snapshot), 'UTF8'), 'sha256'), 'hex');
      INSERT INTO public.legacy_medication_history (
        history_entry_id, history_id, user_id, source_revision, operation,
        legacy_source_kind, legacy_source_id, pill_id, schedule_id, local_date_evidence,
        local_time_evidence, stored_utc, time_zone_status, provenance, state,
        historical_inventory_delta_evidence, inventory_delta_provenance,
        migration_inventory_effect, inventory_disposition, source_fingerprint,
        entity_revision, source_snapshot, coverage_state
      ) VALUES (
        v_entry_id, v_history_id, user_row.id, 1,
        CASE WHEN item_row.deleted_at IS NULL THEN 'upsert' ELSE 'tombstone' END,
        'dose_log', item_row.id, item_row.pill_id, item_row.schedule_id, NULL, NULL,
        COALESCE(item_row.taken_at, item_row.scheduled_at), 'legacy_unknown', 'legacy_estimated',
        item_row.status, NULL, 'unknown', 'none', 'effect_unknown', source_fingerprint,
        1, source_snapshot, 'pending'
      ) ON CONFLICT (user_id, legacy_source_kind, legacy_source_id, source_revision) DO NOTHING;
      payload := jsonb_build_object('kind', 'legacyEstimatedHistory', 'version', 1,
        'historyId', v_history_id, 'historyEntryId', v_entry_id, 'sourceRevision', '1',
        'operation', CASE WHEN item_row.deleted_at IS NULL THEN 'upsert' ELSE 'tombstone' END,
        'legacySourceKind', 'dose_log', 'legacySourceId', item_row.id,
        'pillId', item_row.pill_id, 'scheduleId', item_row.schedule_id,
        'localDateEvidence', NULL, 'localTimeEvidence', NULL,
        'storedUtc', public.simpastil_utc_iso(COALESCE(item_row.taken_at, item_row.scheduled_at)),
        'timeZoneStatus', 'legacy_unknown', 'provenance', 'legacy_estimated', 'state', item_row.status,
        'historicalInventoryDeltaEvidence', NULL, 'inventoryDeltaProvenance', 'unknown',
        'migrationInventoryEffect', 'none', 'inventoryDisposition', 'effect_unknown',
        'sourceFingerprint', source_fingerprint, 'entityRevision', '1');
      sync_sequence := public.simpastil_seed_sync_change(user_row.id, 'medicationBridge',
        'legacy_medication_history', v_history_id, 'upsert', 'legacy_history_entry', v_entry_id, 1, payload);
      UPDATE public.legacy_medication_history SET coverage_state = 'covered',
        sync_change_id = (SELECT id FROM public.sync_changes WHERE user_id = user_row.id AND server_sequence = sync_sequence),
        mapped_entity_type = 'legacy_medication_history', mapped_entity_id = v_history_id, mapped_at = now()
      WHERE public.legacy_medication_history.user_id = user_row.id
        AND public.legacy_medication_history.history_entry_id = v_entry_id;

      IF item_row.deleted_at IS NULL THEN
        payload := jsonb_build_object('kind', 'bridgeDose', 'id', item_row.id,
          'scheduleId', item_row.schedule_id, 'scheduledAt', public.simpastil_utc_iso(item_row.scheduled_at),
          'takenAt', public.simpastil_utc_iso(item_row.taken_at), 'status', item_row.status,
          'deletedAt', NULL, 'sourceRevision', '1');
        PERFORM public.simpastil_seed_sync_change(user_row.id, 'medicationBridge', 'bridge_dose', item_row.id,
          'upsert', 'legacy_dose_log', item_row.id, 1, payload);
      ELSE
        payload := jsonb_build_object('kind', 'tombstone', 'entityType', 'bridge_dose', 'id', item_row.id,
          'revision', '1', 'deletedAt', public.simpastil_utc_iso(item_row.deleted_at));
        PERFORM public.simpastil_seed_sync_change(user_row.id, 'medicationBridge', 'bridge_dose', item_row.id,
          'tombstone', 'legacy_dose_log', item_row.id, 1, payload);
      END IF;
    END LOOP;

    FOR item_row IN SELECT p.* FROM public.pills p JOIN public.profiles pr ON pr.id = p.profile_id
      WHERE pr.user_id = user_row.id ORDER BY p.id LOOP
      identity_prefix := 'legacy-history-v1|' || lower(user_row.id::text) || '|pill_stock|' || lower(item_row.id::text);
      v_history_id := public.simpastil_deterministic_uuid(identity_prefix || '|history');
      v_entry_id := public.simpastil_deterministic_uuid(identity_prefix || '|entry|1');
      source_snapshot := jsonb_build_object('currentStock', item_row.current_stock,
        'pillId', item_row.id, 'updatedAt', public.simpastil_utc_iso(item_row.updated_at));
      source_fingerprint := encode(digest(convert_to(public.simpastil_canonical_jsonb(source_snapshot), 'UTF8'), 'sha256'), 'hex');
      INSERT INTO public.legacy_medication_history (
        history_entry_id, history_id, user_id, source_revision, operation,
        legacy_source_kind, legacy_source_id, pill_id, schedule_id, local_date_evidence,
        local_time_evidence, stored_utc, time_zone_status, provenance, state,
        historical_inventory_delta_evidence, inventory_delta_provenance,
        migration_inventory_effect, inventory_disposition, source_fingerprint,
        entity_revision, source_snapshot, coverage_state
      ) VALUES (v_entry_id, v_history_id, user_row.id, 1, 'upsert', 'pill_stock', item_row.id,
        item_row.id, NULL, NULL, NULL, item_row.updated_at, 'legacy_unknown', 'legacy_estimated', NULL,
        NULL, 'unknown', 'none', 'effect_unknown', source_fingerprint, 1, source_snapshot, 'pending')
      ON CONFLICT (user_id, legacy_source_kind, legacy_source_id, source_revision) DO NOTHING;
      payload := jsonb_build_object('kind', 'legacyEstimatedHistory', 'version', 1,
        'historyId', v_history_id, 'historyEntryId', v_entry_id, 'sourceRevision', '1',
        'operation', 'upsert', 'legacySourceKind', 'pill_stock', 'legacySourceId', item_row.id,
        'pillId', item_row.id, 'scheduleId', NULL, 'localDateEvidence', NULL, 'localTimeEvidence', NULL,
        'storedUtc', public.simpastil_utc_iso(item_row.updated_at), 'timeZoneStatus', 'legacy_unknown',
        'provenance', 'legacy_estimated', 'state', NULL, 'historicalInventoryDeltaEvidence', NULL,
        'inventoryDeltaProvenance', 'unknown', 'migrationInventoryEffect', 'none',
        'inventoryDisposition', 'effect_unknown', 'sourceFingerprint', source_fingerprint, 'entityRevision', '1');
      sync_sequence := public.simpastil_seed_sync_change(user_row.id, 'medicationBridge',
        'legacy_medication_history', v_history_id, 'upsert', 'legacy_history_entry', v_entry_id, 1, payload);
      UPDATE public.legacy_medication_history SET coverage_state = 'covered',
        sync_change_id = (SELECT id FROM public.sync_changes WHERE user_id = user_row.id AND server_sequence = sync_sequence),
        mapped_entity_type = 'legacy_medication_history', mapped_entity_id = v_history_id, mapped_at = now()
      WHERE public.legacy_medication_history.user_id = user_row.id
        AND public.legacy_medication_history.history_entry_id = v_entry_id;

      IF item_row.current_stock IS NOT NULL THEN
        event_id := gen_random_uuid();
        event_sequence := public.next_sync_server_sequence(user_row.id);
        INSERT INTO public.inventory_events (
          id, user_id, pill_id, command_id, kind, delta, provenance, server_sequence
        ) VALUES (event_id, user_row.id, item_row.id,
          public.simpastil_deterministic_uuid('legacy-opening|' || lower(item_row.id::text)),
          'opening', item_row.current_stock, 'legacy_backfill', event_sequence);
        payload := jsonb_build_object('kind', 'inventoryEvent', 'id', event_id, 'pillId', item_row.id,
          'commandId', public.simpastil_deterministic_uuid('legacy-opening|' || lower(item_row.id::text)),
          'eventKind', 'opening', 'delta', item_row.current_stock, 'occurrenceEventId', NULL,
          'reversesInventoryEventId', NULL, 'provenance', 'legacy_backfill', 'note', NULL,
          'serverSequence', event_sequence::text, 'recordedAt', public.simpastil_utc_iso(now()));
        PERFORM public.simpastil_seed_sync_change(user_row.id, 'medication', 'inventory_event', event_id,
          'upsert', 'inventory_event', event_id, event_sequence, payload);
      END IF;

      IF item_row.deleted_at IS NULL THEN
        payload := jsonb_build_object('kind', 'bridgeStock', 'pillId', item_row.id,
          'currentStock', item_row.current_stock, 'sourceRevision', item_row.revision::text,
          'updatedAt', public.simpastil_utc_iso(item_row.updated_at));
        PERFORM public.simpastil_seed_sync_change(user_row.id, 'medicationBridge', 'bridge_stock', item_row.id,
          'upsert', 'legacy_pill_stock', item_row.id, item_row.revision, payload);
      ELSE
        payload := jsonb_build_object('kind', 'tombstone', 'entityType', 'bridge_stock', 'id', item_row.id,
          'revision', item_row.revision::text, 'deletedAt', public.simpastil_utc_iso(item_row.deleted_at));
        PERFORM public.simpastil_seed_sync_change(user_row.id, 'medicationBridge', 'bridge_stock', item_row.id,
          'tombstone', 'legacy_pill_stock', item_row.id, item_row.revision, payload);
      END IF;
    END LOOP;
  END LOOP;
END;
$backfill$;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.repair_legacy_schedule(
  p_user_id uuid,
  p_schedule_id uuid,
  p_expected_revision bigint,
  p_mutation_id uuid,
  p_hour integer,
  p_minute integer,
  p_frequency text,
  p_frequency_days integer[],
  p_is_active boolean,
  p_time_zone text,
  p_effective_from_local_date date
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  current_schedule public.schedules%ROWTYPE;
  issue_id uuid;
  affected integer;
BEGIN
  IF session_user <> 'app_user'
     OR p_user_id IS DISTINCT FROM NULLIF(current_setting('app.current_user_id', true), '')::uuid THEN
    RAISE EXCEPTION 'schedule repair requires the owning tenant session' USING ERRCODE = '42501';
  END IF;
  IF p_expected_revision <> 1 OR p_mutation_id IS NULL OR p_effective_from_local_date IS NULL THEN
    RAISE EXCEPTION 'schedule repair requires revision 1, a mutation ID, and an effective local date'
      USING ERRCODE = '23514';
  END IF;
  IF p_hour NOT BETWEEN 0 AND 23 OR p_minute NOT BETWEEN 0 AND 59
     OR p_frequency NOT IN ('daily', 'weekly', 'custom', 'prn')
     OR NOT public.schedule_frequency_days_valid(p_frequency, p_frequency_days)
     OR p_time_zone IS NULL
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = p_time_zone) THEN
    RAISE EXCEPTION 'schedule repair document is invalid' USING ERRCODE = '23514';
  END IF;

  SELECT s.* INTO STRICT current_schedule
  FROM public.schedules s
  JOIN public.pills p ON p.id = s.pill_id
  JOIN public.profiles pr ON pr.id = p.profile_id
  WHERE s.id = p_schedule_id AND p.id = s.pill_id AND pr.user_id = p_user_id
    AND p.deleted_at IS NULL AND pr.deleted_at IS NULL
  FOR UPDATE OF s;
  IF current_schedule.revision <> p_expected_revision OR current_schedule.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'schedule repair revision conflict' USING ERRCODE = '40001';
  END IF;
  IF current_schedule.legacy_quarantine_issue_id IS NULL
     AND current_schedule.timezone_review_issue_id IS NULL THEN
    RAISE EXCEPTION 'schedule has no unresolved repair issue' USING ERRCODE = '23514';
  END IF;

  FOREACH issue_id IN ARRAY ARRAY[
    current_schedule.legacy_quarantine_issue_id,
    current_schedule.timezone_review_issue_id
  ] LOOP
    IF issue_id IS NOT NULL THEN
      UPDATE public.migration_issues
      SET state = 'resolved', revision = 2, resolved_by = p_user_id, resolved_at = now()
      WHERE id = issue_id AND user_id = p_user_id AND entity_type = 'schedules'
        AND entity_id = p_schedule_id AND state = 'unresolved' AND revision = 1;
      GET DIAGNOSTICS affected = ROW_COUNT;
      IF affected <> 1 THEN RAISE EXCEPTION 'schedule repair issue is stale' USING ERRCODE = '40001'; END IF;
    END IF;
  END LOOP;

  UPDATE public.schedules
  SET hour = p_hour,
      minute = p_minute,
      frequency = p_frequency,
      frequency_days = p_frequency_days,
      is_active = p_is_active,
      revision = 2,
      last_mutation_id = p_mutation_id,
      legacy_quarantine_issue_id = NULL,
      legacy_quarantine_origin = NULL,
      legacy_quarantine_source = NULL,
      timezone_review_issue_id = NULL,
      time_zone_status = 'known',
      time_zone = p_time_zone,
      materialize_from_local_date = p_effective_from_local_date,
      updated_at = now()
  WHERE id = p_schedule_id AND pill_id = current_schedule.pill_id AND revision = p_expected_revision;
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected <> 1 THEN RAISE EXCEPTION 'schedule repair revision conflict' USING ERRCODE = '40001'; END IF;
  RETURN p_schedule_id;
END;
$function$;
--> statement-breakpoint

ALTER FUNCTION public.repair_legacy_schedule(uuid, uuid, bigint, uuid, integer, integer, text, integer[], boolean, text, date)
  OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.repair_legacy_schedule(uuid, uuid, bigint, uuid, integer, integer, text, integer[], boolean, text, date)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.repair_legacy_schedule(uuid, uuid, bigint, uuid, integer, integer, text, integer[], boolean, text, date)
  TO app_user;
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
        RAISE EXCEPTION 'tracked stock cannot be removed after ledger activation' USING ERRCODE = '23514';
      END IF;
      IF NEW.current_stock IS NULL THEN
        RAISE EXCEPTION 'tracked stock cannot be removed after ledger activation' USING ERRCODE = '23514';
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

ALTER FUNCTION public.lock_legacy_medication_authority() OWNER TO deployment_authority_owner;
ALTER FUNCTION public.journal_legacy_medication_write() OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.lock_legacy_medication_authority() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.journal_legacy_medication_write() FROM PUBLIC;
--> statement-breakpoint

CREATE TRIGGER dose_logs_authority_lock
  BEFORE INSERT OR UPDATE OR DELETE ON public.dose_logs
  FOR EACH STATEMENT EXECUTE FUNCTION public.lock_legacy_medication_authority();
CREATE TRIGGER pills_stock_authority_lock
  BEFORE INSERT OR UPDATE OF current_stock OR DELETE ON public.pills
  FOR EACH STATEMENT EXECUTE FUNCTION public.lock_legacy_medication_authority();
CREATE TRIGGER dose_logs_handoff_journal
  BEFORE INSERT OR UPDATE OR DELETE ON public.dose_logs
  FOR EACH ROW EXECUTE FUNCTION public.journal_legacy_medication_write();
CREATE TRIGGER pills_stock_handoff_journal
  BEFORE INSERT OR UPDATE OF current_stock OR DELETE ON public.pills
  FOR EACH ROW EXECUTE FUNCTION public.journal_legacy_medication_write();
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
  IF activated THEN
    RAISE EXCEPTION 'legacy dose writes are disabled after ledger activation' USING ERRCODE = '55000';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$function$;
--> statement-breakpoint

ALTER FUNCTION public.reject_legacy_dose_mutation_after_activation() OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.reject_legacy_dose_mutation_after_activation() FROM PUBLIC;
CREATE TRIGGER dose_logs_activation_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.dose_logs
  FOR EACH ROW EXECUTE FUNCTION public.reject_legacy_dose_mutation_after_activation();
--> statement-breakpoint

GRANT SELECT ON public.medication_handoff_journal, public.legacy_medication_history,
  public.inventory_events, public.preactivation_medication_receipts,
  public.medication_command_receipts, public.sync_changes TO deployment_authority_owner;
GRANT INSERT ON public.inventory_events, public.sync_changes TO deployment_authority_owner;
GRANT UPDATE (coverage_state, history_entry_id, mapped_occurrence_id,
  mapped_occurrence_event_id, mapped_inventory_event_id, mapped_at)
  ON public.medication_handoff_journal TO deployment_authority_owner;
GRANT INSERT ON public.medication_command_receipts TO deployment_authority_owner;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.record_medication_ledger_schema_version()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  UPDATE public.deployment_manifest
  SET schema_version = 15, release_id = 'migration-0015',
      migration_completed_at = now(), updated_at = now()
  WHERE singleton_key IS TRUE;
END;
$function$;
--> statement-breakpoint

ALTER FUNCTION public.record_medication_ledger_schema_version() OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.record_medication_ledger_schema_version() FROM PUBLIC;
SELECT public.record_medication_ledger_schema_version();
--> statement-breakpoint
