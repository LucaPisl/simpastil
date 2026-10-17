-- Let the runtime role (app_user) read the applied migration head so readiness
-- can compare it with the journal bundled in the image. The drizzle schema is
-- not readable by app_user, so expose only count, newest timestamp and hash.
CREATE OR REPLACE FUNCTION public.read_applied_migration_head()
RETURNS TABLE (migration_count bigint, head_created_at bigint, head_hash text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
  SELECT (SELECT count(*) FROM drizzle.__drizzle_migrations),
         newest.created_at,
         newest.hash
  FROM (SELECT 1) AS anchor
  LEFT JOIN LATERAL (
    SELECT migration.created_at, migration.hash
    FROM drizzle.__drizzle_migrations AS migration
    ORDER BY migration.created_at DESC
    LIMIT 1
  ) AS newest ON TRUE;
$function$;
--> statement-breakpoint

REVOKE ALL ON FUNCTION public.read_applied_migration_head() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.read_applied_migration_head() TO app_user;
--> statement-breakpoint

-- Advance the deployment manifest so it names the schema this image ships.
-- 0016-0018 did not; readiness now relies on the migration head instead of
-- this label, but operators and backup manifests still read it.
CREATE OR REPLACE FUNCTION public.record_deployment_schema_version_0019()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  UPDATE public.deployment_manifest
  SET schema_version = 19, release_id = 'migration-0019',
      migration_completed_at = now(), updated_at = now()
  WHERE singleton_key IS TRUE;
END;
$function$;
--> statement-breakpoint

ALTER FUNCTION public.record_deployment_schema_version_0019() OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.record_deployment_schema_version_0019() FROM PUBLIC;
SELECT public.record_deployment_schema_version_0019();
--> statement-breakpoint

DROP FUNCTION public.record_deployment_schema_version_0019();
