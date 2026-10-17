-- Keep runtime reads and narrowly guarded migration-issue writes behind the
-- authority owner; app_user must never receive UPDATE on deployment authority.
CREATE OR REPLACE FUNCTION public.lock_medication_ledger_authority()
RETURNS TABLE (ledger_activated boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  RETURN QUERY
    SELECT manifest.ledger_activated
    FROM public.deployment_manifest AS manifest
    WHERE manifest.singleton_key IS TRUE
    FOR SHARE;
END;
$function$;
--> statement-breakpoint

ALTER FUNCTION public.lock_medication_ledger_authority() OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.lock_medication_ledger_authority() FROM PUBLIC, app_user, outbox_user;
GRANT EXECUTE ON FUNCTION public.lock_medication_ledger_authority() TO app_user;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.record_legacy_split_checkpoint_issue(
  p_user_id uuid,
  p_issue_id uuid,
  p_command_id uuid,
  p_safe_snapshot jsonb
)
RETURNS TABLE (issue_id uuid, inserted boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  selected_issue_id uuid;
  inserted_rows integer;
BEGIN
  IF NULLIF(current_setting('app.current_user_id', true), '') IS DISTINCT FROM p_user_id::text THEN
    RAISE EXCEPTION 'split checkpoint tenant does not match transaction context'
      USING ERRCODE = '42501';
  END IF;
  IF p_user_id IS NULL OR p_issue_id IS NULL OR p_command_id IS NULL
     OR p_safe_snapshot IS NULL OR jsonb_typeof(p_safe_snapshot) <> 'object'
     OR octet_length(p_safe_snapshot::text) > 16384 THEN
    RAISE EXCEPTION 'split checkpoint issue input is invalid'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.migration_issues (
    id, user_id, entity_type, entity_id, issue_code, safe_snapshot, revision, state
  ) VALUES (
    p_issue_id, p_user_id, 'medication_split', p_command_id,
    'legacy_split_checkpoint', p_safe_snapshot, 1, 'unresolved'
  ) ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS inserted_rows = ROW_COUNT;

  SELECT issue.id INTO selected_issue_id
  FROM public.migration_issues AS issue
  WHERE issue.id = p_issue_id AND issue.user_id = p_user_id
  FOR UPDATE;
  IF NOT FOUND THEN
    SELECT issue.id INTO selected_issue_id
    FROM public.migration_issues AS issue
    WHERE issue.user_id = p_user_id
      AND issue.entity_type = 'medication_split'
      AND issue.entity_id = p_command_id
      AND issue.issue_code = 'legacy_split_checkpoint'
    FOR UPDATE;
  END IF;
  IF selected_issue_id IS NULL THEN
    RAISE EXCEPTION 'split checkpoint issue identity is already in use'
      USING ERRCODE = '23505';
  END IF;
  issue_id := selected_issue_id;
  inserted := inserted_rows = 1;
  RETURN NEXT;
END;
$function$;
--> statement-breakpoint

ALTER FUNCTION public.record_legacy_split_checkpoint_issue(uuid, uuid, uuid, jsonb)
  OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.record_legacy_split_checkpoint_issue(uuid, uuid, uuid, jsonb)
  FROM PUBLIC, app_user, outbox_user;
GRANT EXECUTE ON FUNCTION public.record_legacy_split_checkpoint_issue(uuid, uuid, uuid, jsonb)
  TO app_user;
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.resolve_legacy_split_checkpoint_issue(
  p_user_id uuid,
  p_issue_id uuid,
  p_checkpoint_command_id uuid,
  p_base_revision bigint
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  resolved_issue_id uuid;
BEGIN
  IF NULLIF(current_setting('app.current_user_id', true), '') IS DISTINCT FROM p_user_id::text THEN
    RAISE EXCEPTION 'split checkpoint tenant does not match transaction context'
      USING ERRCODE = '42501';
  END IF;
  IF p_user_id IS NULL OR p_issue_id IS NULL OR p_checkpoint_command_id IS NULL
     OR p_base_revision IS NULL OR p_base_revision <> 1 THEN
    RETURN NULL;
  END IF;

  UPDATE public.migration_issues AS issue
  SET revision = issue.revision + 1,
      state = 'resolved',
      resolved_by = p_user_id,
      resolved_at = now()
  WHERE issue.id = p_issue_id
    AND issue.user_id = p_user_id
    AND issue.entity_type = 'medication_split'
    AND issue.entity_id = p_checkpoint_command_id
    AND issue.issue_code = 'legacy_split_checkpoint'
    AND issue.revision = p_base_revision
    AND issue.state = 'unresolved'
  RETURNING issue.id INTO resolved_issue_id;

  RETURN resolved_issue_id;
END;
$function$;
--> statement-breakpoint

ALTER FUNCTION public.resolve_legacy_split_checkpoint_issue(uuid, uuid, uuid, bigint)
  OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.resolve_legacy_split_checkpoint_issue(uuid, uuid, uuid, bigint)
  FROM PUBLIC, app_user, outbox_user;
GRANT EXECUTE ON FUNCTION public.resolve_legacy_split_checkpoint_issue(uuid, uuid, uuid, bigint)
  TO app_user;
--> statement-breakpoint
