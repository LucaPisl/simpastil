-- =============================================================================
-- Migration 0005 — Logging extensions (PRN meds + per-dose notes)
--
-- Uses IF NOT EXISTS / IF EXISTS guards so this migration is safe on databases
-- where these changes were previously applied manually.
-- =============================================================================

ALTER TABLE "pills" ADD COLUMN IF NOT EXISTS "is_prn" boolean NOT NULL DEFAULT false;
--> statement-breakpoint
ALTER TABLE "dose_logs" ADD COLUMN IF NOT EXISTS "note" text;
--> statement-breakpoint
ALTER TABLE "schedules" DROP CONSTRAINT IF EXISTS "schedules_frequency_check";
--> statement-breakpoint
ALTER TABLE "schedules" ADD CONSTRAINT "schedules_frequency_check" CHECK ("schedules"."frequency" IN ('daily', 'weekly', 'custom', 'prn'));
