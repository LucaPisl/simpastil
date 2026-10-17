-- =============================================================================
-- Migration 0009 — Encrypted API key storage for admin reveal
--
-- Adds an encrypted_key column (AES-256-GCM, same TOTP_ENC_KEY) so the admin
-- can reveal API key values after creation. Legacy keys (created before this
-- migration) will have encrypted_key = NULL and show "rotate to view" in the UI.
--
-- All statements are idempotent (IF NOT EXISTS / DO blocks).
-- =============================================================================

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'api_keys' AND column_name = 'encrypted_key'
  ) THEN
    ALTER TABLE api_keys ADD COLUMN encrypted_key TEXT;
  END IF;
END $$;

-- Grant the new column to app_user if the role exists (matches RLS setup pattern).
DO $$ BEGIN
  IF EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'app_user') THEN
    GRANT SELECT, INSERT, UPDATE ON api_keys TO app_user;
  END IF;
END $$;
