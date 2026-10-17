-- compat: expand
ALTER TABLE "pills" ADD COLUMN "amount_per_use" jsonb;--> statement-breakpoint
ALTER TABLE "pills" ADD COLUMN "package_strength" text;--> statement-breakpoint
ALTER TABLE "pills" ADD COLUMN "form" text;--> statement-breakpoint
ALTER TABLE "pills" ADD COLUMN "legacy_dosage_reviewed" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "pills" ADD CONSTRAINT "pills_package_strength_check" CHECK ("pills"."package_strength" IS NULL OR length("pills"."package_strength") <= 500);--> statement-breakpoint
ALTER TABLE "pills" ADD CONSTRAINT "pills_form_check" CHECK ("pills"."form" IS NULL OR length("pills"."form") <= 500);--> statement-breakpoint
ALTER TABLE "pills" ADD CONSTRAINT "pills_amount_per_use_check" CHECK (
    "pills"."amount_per_use" IS NULL OR COALESCE((
      jsonb_typeof("pills"."amount_per_use") = 'object'
      AND "pills"."amount_per_use"->'version' = '1'::jsonb
      AND octet_length("pills"."amount_per_use"::text) <= 512
      AND (
        "pills"."amount_per_use" = '{"version": 1, "state": "unknown"}'::jsonb
        OR (
          "pills"."amount_per_use"->>'state' = 'known'
          AND ("pills"."amount_per_use" - ARRAY['version', 'state', 'quantity', 'unit']) = '{}'::jsonb
          AND jsonb_typeof("pills"."amount_per_use"->'quantity') = 'string'
          AND length("pills"."amount_per_use"->>'quantity') BETWEEN 1 AND 64
          AND jsonb_typeof("pills"."amount_per_use"->'unit') = 'string'
          AND length("pills"."amount_per_use"->>'unit') BETWEEN 1 AND 80
        )
      )
    ), FALSE)
  );