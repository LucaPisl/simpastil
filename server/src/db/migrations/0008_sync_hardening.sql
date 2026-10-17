-- =============================================================================
-- Migration 0008 — Sync hardening, 2FA defense-in-depth, LWW support
--
-- All statements are idempotent (IF NOT EXISTS / DO blocks).
--
-- Changes:
--   1. H-2:  backup_codes table (atomic single-use via DELETE...RETURNING)
--   2. H-3:  totp_last_used_step on users + admin_config (replay protection)
--   3. H-12: deleted_at on profiles/pills/schedules (server-side tombstones)
--   4. M-3:  updated_at on dose_logs (LWW support — was the only entity missing it)
--   5. RLS policies for backup_codes
--   6. Migrate existing backup codes from array columns to new table
-- =============================================================================


-- ─── 1. backup_codes table ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS backup_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  code_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS backup_codes_user_id_idx
  ON backup_codes(user_id) WHERE user_id IS NOT NULL;


-- ─── 2. totp_last_used_step ────────────────────────────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'users' AND column_name = 'totp_last_used_step'
  ) THEN
    ALTER TABLE users ADD COLUMN totp_last_used_step BIGINT;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'admin_config' AND column_name = 'totp_last_used_step'
  ) THEN
    ALTER TABLE admin_config ADD COLUMN totp_last_used_step BIGINT;
  END IF;
END $$;


-- ─── 3. deleted_at (tombstones) ────────────────────────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'profiles' AND column_name = 'deleted_at'
  ) THEN
    ALTER TABLE profiles ADD COLUMN deleted_at TIMESTAMPTZ;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'pills' AND column_name = 'deleted_at'
  ) THEN
    ALTER TABLE pills ADD COLUMN deleted_at TIMESTAMPTZ;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'schedules' AND column_name = 'deleted_at'
  ) THEN
    ALTER TABLE schedules ADD COLUMN deleted_at TIMESTAMPTZ;
  END IF;
END $$;


-- ─── 4. updated_at on dose_logs ────────────────────────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'dose_logs' AND column_name = 'updated_at'
  ) THEN
    ALTER TABLE dose_logs ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
  END IF;
END $$;


-- ─── 5. RLS policy for backup_codes ────────────────────────────────────────
ALTER TABLE backup_codes ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_catalog.pg_roles WHERE rolname = 'app_user'
  ) THEN
    RETURN;
  END IF;

  GRANT SELECT, INSERT, DELETE ON backup_codes TO app_user;

  DROP POLICY IF EXISTS backup_codes_user_isolation ON backup_codes;
  CREATE POLICY backup_codes_user_isolation ON backup_codes
    FOR ALL
    USING (user_id = current_setting('app.current_user_id', true)::UUID)
    WITH CHECK (user_id = current_setting('app.current_user_id', true)::UUID);

  -- Admin backup codes (user_id IS NULL) — accessible without RLS context
  DROP POLICY IF EXISTS backup_codes_admin ON backup_codes;
  CREATE POLICY backup_codes_admin ON backup_codes
    FOR ALL
    USING (user_id IS NULL)
    WITH CHECK (user_id IS NULL);
END $$;

DO $$ BEGIN
  IF EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'app_user') THEN
    ALTER TABLE backup_codes FORCE ROW LEVEL SECURITY;
  END IF;
END $$;


-- ─── 6. Migrate existing backup codes ─────────────────────────────────────
-- Move hashed codes from users.totp_backup_codes array to backup_codes table.
-- Only runs if the array column still has data (idempotent).
INSERT INTO backup_codes (user_id, code_hash)
SELECT u.id, unnest(u.totp_backup_codes)
FROM users u
WHERE u.totp_backup_codes IS NOT NULL
  AND array_length(u.totp_backup_codes, 1) > 0
  AND NOT EXISTS (
    SELECT 1 FROM backup_codes bc WHERE bc.user_id = u.id
  );

-- Admin backup codes (user_id = NULL)
INSERT INTO backup_codes (code_hash)
SELECT unnest(ac.totp_backup_codes)
FROM admin_config ac
WHERE ac.totp_backup_codes IS NOT NULL
  AND array_length(ac.totp_backup_codes, 1) > 0
  AND NOT EXISTS (
    SELECT 1 FROM backup_codes bc WHERE bc.user_id IS NULL
  );
