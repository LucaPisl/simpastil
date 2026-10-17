-- compat: expand
-- Rollback groundwork. Readiness in images from this migration on accepts a
-- database that is ahead of the image when every migration in between left
-- the compatibility floor at or below the image's bundled migration count.
ALTER TABLE "deployment_manifest" ADD COLUMN "compatible_from_migration_count" integer DEFAULT 25 NOT NULL;--> statement-breakpoint
ALTER TABLE "deployment_manifest" ADD CONSTRAINT "deployment_manifest_compatible_from_check" CHECK ("deployment_manifest"."compatible_from_migration_count" > 0);--> statement-breakpoint

-- Lets app_user ask whether an image's bundled head is applied, how many
-- migrations are applied up to it and in total, and the compatibility floor.
-- The drizzle schema is not readable by app_user; expose only these values.
CREATE OR REPLACE FUNCTION public.read_migration_compatibility(p_head_hash text, p_head_created_at bigint)
RETURNS TABLE (
  bundled_head_applied boolean,
  applied_through_bundled bigint,
  applied_count bigint,
  compatible_from_count integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
  SELECT EXISTS (
           SELECT 1 FROM drizzle.__drizzle_migrations AS migration
           WHERE migration.hash = p_head_hash AND migration.created_at = p_head_created_at
         ),
         (SELECT count(*) FROM drizzle.__drizzle_migrations AS migration
          WHERE migration.created_at <= p_head_created_at),
         (SELECT count(*) FROM drizzle.__drizzle_migrations),
         (SELECT manifest.compatible_from_migration_count
          FROM public.deployment_manifest AS manifest
          WHERE manifest.singleton_key IS TRUE);
$function$;
--> statement-breakpoint

REVOKE ALL ON FUNCTION public.read_migration_compatibility(text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.read_migration_compatibility(text, bigint) TO app_user;
--> statement-breakpoint

-- Records which server image version last completed migrations. Called by
-- the migrate service (superuser) only.
CREATE OR REPLACE FUNCTION public.record_server_image(p_version text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF p_version IS NULL OR length(p_version) NOT BETWEEN 1 AND 128 THEN
    RAISE EXCEPTION 'server image version is invalid';
  END IF;
  UPDATE public.deployment_manifest
  SET server_image_digest = p_version, updated_at = now()
  WHERE singleton_key IS TRUE;
END;
$function$;
--> statement-breakpoint

ALTER FUNCTION public.record_server_image(text) OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.record_server_image(text) FROM PUBLIC;
--> statement-breakpoint

-- A breaking migration calls this with its own migration count, so images
-- bundling fewer migrations stop reporting ready on this database. The floor
-- never moves down.
CREATE OR REPLACE FUNCTION public.raise_migration_compatibility_floor(p_count integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF p_count IS NULL OR p_count < 1 THEN
    RAISE EXCEPTION 'migration compatibility floor is invalid';
  END IF;
  UPDATE public.deployment_manifest
  SET compatible_from_migration_count = greatest(compatible_from_migration_count, p_count),
      updated_at = now()
  WHERE singleton_key IS TRUE;
END;
$function$;
--> statement-breakpoint

ALTER FUNCTION public.raise_migration_compatibility_floor(integer) OWNER TO deployment_authority_owner;
REVOKE ALL ON FUNCTION public.raise_migration_compatibility_floor(integer) FROM PUBLIC;
