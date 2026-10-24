-- compat: breaking
-- A schedule can now repeat every N days and carry start and end dates, and an
-- occurrence may hold a version 3 snapshot. An image built before this
-- migration switches on the frequency and the snapshot version and would fail
-- every pull that carries such a row, so older images must not serve this
-- database. The per-account minimum_client_build gate keeps older apps away
-- from the same data.
--
-- The validity function gains the interval case (frequency_days must be NULL).
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
    WHEN p_frequency IN ('daily', 'interval', 'prn') THEN p_frequency_days IS NULL
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
ALTER TABLE "medication_occurrences" DROP CONSTRAINT "medication_occurrences_snapshot_check";--> statement-breakpoint
ALTER TABLE "schedules" DROP CONSTRAINT "schedules_frequency_check";--> statement-breakpoint
ALTER TABLE "schedules" ADD COLUMN "every_days" integer;--> statement-breakpoint
ALTER TABLE "schedules" ADD COLUMN "anchor_date" date;--> statement-breakpoint
ALTER TABLE "schedules" ADD COLUMN "start_date" date;--> statement-breakpoint
ALTER TABLE "schedules" ADD COLUMN "end_date" date;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "minimum_client_build" integer DEFAULT 1 NOT NULL;--> statement-breakpoint
ALTER TABLE "medication_occurrences" ADD CONSTRAINT "medication_occurrences_snapshot_check" CHECK (
    jsonb_typeof("medication_occurrences"."schedule_snapshot") = 'object'
    AND "medication_occurrences"."schedule_snapshot"->>'version' IN ('1', '3')
    AND octet_length("medication_occurrences"."schedule_snapshot"::text) <= 16384
  );--> statement-breakpoint
ALTER TABLE "schedules" ADD CONSTRAINT "schedules_interval_shape_check" CHECK (("schedules"."frequency" = 'interval')
        = ("schedules"."every_days" IS NOT NULL AND "schedules"."anchor_date" IS NOT NULL)
        AND ("schedules"."frequency" = 'interval'
          OR ("schedules"."every_days" IS NULL AND "schedules"."anchor_date" IS NULL)));--> statement-breakpoint
ALTER TABLE "schedules" ADD CONSTRAINT "schedules_every_days_check" CHECK ("schedules"."every_days" IS NULL OR "schedules"."every_days" BETWEEN 1 AND 36500);--> statement-breakpoint
ALTER TABLE "schedules" ADD CONSTRAINT "schedules_window_order_check" CHECK ("schedules"."start_date" IS NULL OR "schedules"."end_date" IS NULL OR "schedules"."end_date" >= "schedules"."start_date");--> statement-breakpoint
ALTER TABLE "schedules" ADD CONSTRAINT "schedules_prn_no_window_check" CHECK ("schedules"."frequency" <> 'prn' OR ("schedules"."start_date" IS NULL AND "schedules"."end_date" IS NULL));--> statement-breakpoint
ALTER TABLE "schedules" ADD CONSTRAINT "schedules_frequency_check" CHECK ("schedules"."frequency" IN ('daily', 'weekly', 'custom', 'interval', 'prn'));--> statement-breakpoint
ALTER TABLE "users" ADD CONSTRAINT "users_minimum_client_build_check" CHECK ("users"."minimum_client_build" >= 1);
--> statement-breakpoint
SELECT public.raise_migration_compatibility_floor(28);
