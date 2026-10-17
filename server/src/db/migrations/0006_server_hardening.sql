-- =============================================================================
-- Migration 0006 — Server hardening & ops
--
-- All statements are idempotent (IF NOT EXISTS / IF EXISTS / CREATE OR REPLACE)
-- so this migration is safe on both fresh and existing databases.
--
-- Changes:
--   1. RLS reconciliation — ensure all user-data tables have RLS enabled
--   2. updated_at trigger reconciliation
--   3. 2FA columns on users and admin_config
--   4. audit_logs table
--   5. Grants for new tables
-- =============================================================================


-- ─── 1. RLS reconciliation ───────────────────────────────────────────────────
-- ENABLE ROW LEVEL SECURITY is idempotent — no error if already enabled.

ALTER TABLE "users" ENABLE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "refresh_tokens" ENABLE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "profiles" ENABLE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "pills" ENABLE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "schedules" ENABLE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "dose_logs" ENABLE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "password_reset_tokens" ENABLE ROW LEVEL SECURITY;
--> statement-breakpoint

-- ─── 2. updated_at trigger reconciliation ────────────────────────────────────
-- CREATE OR REPLACE is idempotent for both functions and triggers.

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;
--> statement-breakpoint

-- Drop-if-exists + create pattern for triggers (CREATE OR REPLACE TRIGGER
-- requires PG 14+; DROP IF EXISTS is universally safe).
DROP TRIGGER IF EXISTS users_updated_at ON users;
--> statement-breakpoint
CREATE TRIGGER users_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
--> statement-breakpoint

DROP TRIGGER IF EXISTS profiles_updated_at ON profiles;
--> statement-breakpoint
CREATE TRIGGER profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
--> statement-breakpoint

DROP TRIGGER IF EXISTS pills_updated_at ON pills;
--> statement-breakpoint
CREATE TRIGGER pills_updated_at
  BEFORE UPDATE ON pills
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
--> statement-breakpoint

DROP TRIGGER IF EXISTS schedules_updated_at ON schedules;
--> statement-breakpoint
CREATE TRIGGER schedules_updated_at
  BEFORE UPDATE ON schedules
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
--> statement-breakpoint

-- ─── 3. 2FA columns ─────────────────────────────────────────────────────────

ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "totp_secret" text;
--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "totp_enabled" boolean NOT NULL DEFAULT false;
--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "totp_backup_codes" text[];
--> statement-breakpoint

ALTER TABLE "admin_config" ADD COLUMN IF NOT EXISTS "totp_secret" text;
--> statement-breakpoint
ALTER TABLE "admin_config" ADD COLUMN IF NOT EXISTS "totp_enabled" boolean NOT NULL DEFAULT false;
--> statement-breakpoint
ALTER TABLE "admin_config" ADD COLUMN IF NOT EXISTS "totp_backup_codes" text[];
--> statement-breakpoint

-- ─── 4. audit_logs table ─────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS "audit_logs" (
  "id"          uuid        PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "actor"       text        NOT NULL,
  "action"      text        NOT NULL,
  "target_type" text        NOT NULL,
  "target_id"   text,
  "metadata"    jsonb,
  "ip_address"  text,
  "created_at"  timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint

CREATE INDEX IF NOT EXISTS "audit_logs_action_idx" ON "audit_logs" ("action");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "audit_logs_created_at_idx" ON "audit_logs" ("created_at");
--> statement-breakpoint

-- ─── 5. Grants ───────────────────────────────────────────────────────────────
-- app_user needs access to the new audit_logs table (admin routes write to it).

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'app_user') THEN
    GRANT SELECT, INSERT ON audit_logs TO app_user;
  END IF;
END $$;
