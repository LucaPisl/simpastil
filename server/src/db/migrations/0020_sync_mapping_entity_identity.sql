-- Ledger activation writes an identity_mapping sync change for every covered
-- stock journal row whose target is the opening/correction inventory event. The
-- 0014 guard compared the envelope entity with payload.historyId first, so those
-- rows (entityId = the inventory event) were rejected and activation could not
-- complete on any database with tracked stock. Mappings are identified by their
-- target entity; every other entity type is unchanged.
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
  -- An identity mapping is addressed by its target entity. Its payload also
  -- carries historyId, which equals the target only for history targets; an
  -- inventory-event target must not be compared with the history identity.
  expected_entity_id := CASE
    WHEN NEW.entity_type = 'identity_mapping'
      THEN NEW.payload#>>'{payload,targetEntityId}'
    ELSE COALESCE(
      NEW.payload#>>'{payload,id}',
      NEW.payload#>>'{payload,historyId}',
      NEW.payload#>>'{payload,targetEntityId}',
      CASE WHEN NEW.entity_type = 'bridge_stock' AND NEW.operation = 'upsert'
        THEN NEW.payload#>>'{payload,pillId}' END
    )
  END;
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
--> statement-breakpoint

CREATE OR REPLACE FUNCTION public.record_deployment_schema_version_0020()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  UPDATE public.deployment_manifest
  SET schema_version = 20, release_id = 'migration-0020',
      migration_completed_at = now(), updated_at = now()
  WHERE singleton_key IS TRUE;
END;
$function$;
--> statement-breakpoint

ALTER FUNCTION public.record_deployment_schema_version_0020() OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.record_deployment_schema_version_0020() FROM PUBLIC;
SELECT public.record_deployment_schema_version_0020();
--> statement-breakpoint

DROP FUNCTION public.record_deployment_schema_version_0020();
