-- compat: expand
-- Seven nullable columns on pills and their checks: as-needed limits, an
-- expiry date and the prescriber and pharmacy contacts. An older image never
-- reads or writes them, so it keeps serving this database. The change rows of a
-- medicine carry each key only once it is set, so an image-only rollback stays
-- readable until then; a medicine with any of these set has change rows the
-- previous release's strict payload schema cannot read, so roll back before
-- they are set or restore the pre-migration backup. The contacts are personal
-- data: they never appear in a log.
ALTER TABLE "pills" ADD COLUMN "prn_max_per_24h" integer;--> statement-breakpoint
ALTER TABLE "pills" ADD COLUMN "prn_min_gap_minutes" integer;--> statement-breakpoint
ALTER TABLE "pills" ADD COLUMN "expires_on" date;--> statement-breakpoint
ALTER TABLE "pills" ADD COLUMN "prescriber_name" text;--> statement-breakpoint
ALTER TABLE "pills" ADD COLUMN "prescriber_phone" text;--> statement-breakpoint
ALTER TABLE "pills" ADD COLUMN "pharmacy_name" text;--> statement-breakpoint
ALTER TABLE "pills" ADD COLUMN "pharmacy_phone" text;--> statement-breakpoint
ALTER TABLE "pills" ADD CONSTRAINT "pills_prn_max_per_24h_check" CHECK ("pills"."prn_max_per_24h" IS NULL OR "pills"."prn_max_per_24h" BETWEEN 1 AND 48);--> statement-breakpoint
ALTER TABLE "pills" ADD CONSTRAINT "pills_prn_min_gap_minutes_check" CHECK ("pills"."prn_min_gap_minutes" IS NULL OR "pills"."prn_min_gap_minutes" BETWEEN 1 AND 2880);--> statement-breakpoint
ALTER TABLE "pills" ADD CONSTRAINT "pills_prescriber_name_check" CHECK ("pills"."prescriber_name" IS NULL OR length("pills"."prescriber_name") BETWEEN 1 AND 120);--> statement-breakpoint
ALTER TABLE "pills" ADD CONSTRAINT "pills_pharmacy_name_check" CHECK ("pills"."pharmacy_name" IS NULL OR length("pills"."pharmacy_name") BETWEEN 1 AND 120);--> statement-breakpoint
ALTER TABLE "pills" ADD CONSTRAINT "pills_prescriber_phone_check" CHECK ("pills"."prescriber_phone" IS NULL OR "pills"."prescriber_phone" ~ '^[0-9+()./#* -]{3,40}$');--> statement-breakpoint
ALTER TABLE "pills" ADD CONSTRAINT "pills_pharmacy_phone_check" CHECK ("pills"."pharmacy_phone" IS NULL OR "pills"."pharmacy_phone" ~ '^[0-9+()./#* -]{3,40}$');