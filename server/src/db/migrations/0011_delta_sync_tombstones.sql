-- =============================================================================
-- Migration 0011 — Delta sync & dose_log tombstones (M-14, M-15)
--
-- All statements are idempotent (IF NOT EXISTS / DO blocks).
--
-- Changes:
--   1. Add deleted_at column to dose_logs (soft-delete / tombstone support)
--   2. Add keyset cursor index on (updated_at, id) for delta sync pagination
--   3. Convert unique constraint to partial index (exclude tombstones)
--   4. Grant privileges to app_user (if role exists)
-- =============================================================================


-- ─── 1. deleted_at on dose_logs ───────────────────────────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'dose_logs' AND column_name = 'deleted_at'
  ) THEN
    ALTER TABLE dose_logs ADD COLUMN deleted_at TIMESTAMPTZ;
  END IF;
END $$;


-- ─── 2. Keyset cursor index ──────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_dose_logs_updated_at_id
  ON dose_logs(updated_at ASC, id ASC);


-- ─── 3. Partial unique constraint ────────────────────────────────────────────
-- The old constraint blocked re-takes after an un-take (soft-delete) because
-- the tombstone row still occupied the (schedule_id, scheduled_at) slot.
-- Replace with a partial unique index that only covers live rows.
DO $$ BEGIN
  -- Drop the named constraint if it exists (Drizzle-generated name)
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'dose_logs_schedule_at_unique'
      AND conrelid = 'dose_logs'::regclass
  ) THEN
    ALTER TABLE dose_logs DROP CONSTRAINT dose_logs_schedule_at_unique;
  END IF;
END $$;

-- Also drop if it was already converted to an index in a previous run
DROP INDEX IF EXISTS dose_logs_schedule_at_unique;

CREATE UNIQUE INDEX IF NOT EXISTS dose_logs_schedule_at_live_unique
  ON dose_logs(schedule_id, scheduled_at) WHERE deleted_at IS NULL;


-- ─── 4. System GC policy ─────────────────────────────────────────────────────
-- Allow deleting tombstoned dose_logs when no user context is set (system GC).
-- Without this, FORCE RLS blocks the token-gc purge process.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_catalog.pg_roles WHERE rolname = 'app_user'
  ) THEN
    RETURN;
  END IF;

  DROP POLICY IF EXISTS dose_logs_system_gc ON dose_logs;
  CREATE POLICY dose_logs_system_gc ON dose_logs FOR DELETE
    USING (
      deleted_at IS NOT NULL
      AND NULLIF(current_setting('app.current_user_id', true), '') IS NULL
    );
END $$;
