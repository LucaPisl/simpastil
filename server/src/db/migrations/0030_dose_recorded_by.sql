-- compat: breaking
-- Dose events may carry `recorded_by`, the name a dose was recorded under. It is
-- written from the first dose a new app records, and an image built before this
-- migration parses every stored event payload with a strict schema that refuses
-- the unknown `recordedBy` key, so its pulls would fail. It must not serve a
-- database that already holds one, and the next dose would add one: the
-- compatibility floor keeps the older image from serving this database at all.
-- A rollback past this migration needs the pre-migration backup. Events
-- recorded before it stay without a name (unknown) and are never backfilled.
ALTER TABLE "occurrence_events" ADD COLUMN "recorded_by" jsonb;--> statement-breakpoint
ALTER TABLE "occurrence_events" ADD CONSTRAINT "occurrence_events_recorded_by_check" CHECK (
    "occurrence_events"."recorded_by" IS NULL OR COALESCE((
      "occurrence_events"."action" <> 'miss'
      AND jsonb_typeof("occurrence_events"."recorded_by") = 'object'
      AND "occurrence_events"."recorded_by"->'version' = '1'::jsonb
      AND ("occurrence_events"."recorded_by" - ARRAY['version', 'name']) = '{}'::jsonb
      AND "occurrence_events"."recorded_by" ? 'name'
      AND (
        jsonb_typeof("occurrence_events"."recorded_by"->'name') = 'null'
        OR (
          jsonb_typeof("occurrence_events"."recorded_by"->'name') = 'string'
          AND length("occurrence_events"."recorded_by"->>'name') BETWEEN 1 AND 100
          AND "occurrence_events"."recorded_by"->>'name' = btrim("occurrence_events"."recorded_by"->>'name')
        )
      )
    ), FALSE)
  );
--> statement-breakpoint
SELECT public.raise_migration_compatibility_floor(31);
