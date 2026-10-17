ALTER TABLE "occurrence_events" ADD COLUMN "administration_amount" jsonb;--> statement-breakpoint
ALTER TABLE "occurrence_events" ADD CONSTRAINT "occurrence_events_amount_check" CHECK (
    "occurrence_events"."administration_amount" IS NULL OR COALESCE((
      jsonb_typeof("occurrence_events"."administration_amount") = 'object'
      AND "occurrence_events"."administration_amount"->'version' = '1'::jsonb
      AND octet_length("occurrence_events"."administration_amount"::text) <= 512
      AND (
        "occurrence_events"."administration_amount" = '{"version": 1, "state": "unknown"}'::jsonb
        OR (
          "occurrence_events"."administration_amount"->>'state' = 'known'
          AND ("occurrence_events"."administration_amount" - ARRAY['version', 'state', 'quantity', 'unit']) = '{}'::jsonb
          AND jsonb_typeof("occurrence_events"."administration_amount"->'quantity') = 'string'
          AND length("occurrence_events"."administration_amount"->>'quantity') BETWEEN 1 AND 64
          AND jsonb_typeof("occurrence_events"."administration_amount"->'unit') = 'string'
          AND length("occurrence_events"."administration_amount"->>'unit') BETWEEN 1 AND 80
        )
      )
    ), FALSE)
  );
