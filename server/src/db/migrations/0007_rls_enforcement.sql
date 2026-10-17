-- =============================================================================
-- Migration 0007 — RLS enforcement & least-privilege role
--
-- All statements are idempotent (IF NOT EXISTS / DROP IF EXISTS / DO blocks)
-- so this migration is safe on both fresh and existing databases.
--
-- Changes:
--   1. Create app_user role if not exists (fixes 0003 crash on fresh DB)
--   2. Grant schema + table + sequence privileges
--   3. Install all RLS policies (idempotent DROP IF EXISTS + CREATE)
--   4. FORCE ROW LEVEL SECURITY on all user-data tables
--   5. Restrict audit_logs to append-only for app_user
--   6. Add missing FK indexes for RLS hot paths
-- =============================================================================


-- ─── 1. Create app_user role ────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_catalog.pg_roles WHERE rolname = 'app_user'
  ) THEN
    CREATE ROLE app_user
      NOSUPERUSER
      NOCREATEDB
      NOCREATEROLE
      NOINHERIT
      LOGIN
      PASSWORD NULL;
  END IF;
END;
$$;
--> statement-breakpoint

-- ─── 2. Grants ──────────────────────────────────────────────────────────────
GRANT USAGE ON SCHEMA public TO app_user;
--> statement-breakpoint
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
--> statement-breakpoint
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user;
--> statement-breakpoint

-- Revoke DELETE on audit_logs so app_user can only append
DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'app_user') THEN
    REVOKE DELETE, UPDATE ON audit_logs FROM app_user;
  END IF;
END $$;
--> statement-breakpoint

-- ─── 3. RLS policies (idempotent: drop-if-exists + create) ─────────────────

-- users
DROP POLICY IF EXISTS users_open_policy ON users;
--> statement-breakpoint
CREATE POLICY users_open_policy ON users FOR ALL USING (true) WITH CHECK (true);
--> statement-breakpoint
DROP POLICY IF EXISTS users_own_rows_write ON users;
--> statement-breakpoint
CREATE POLICY users_own_rows_write ON users AS RESTRICTIVE FOR UPDATE
  USING (id = NULLIF(current_setting('app.current_user_id', true), '')::uuid)
  WITH CHECK (id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
--> statement-breakpoint
DROP POLICY IF EXISTS users_own_rows_delete ON users;
--> statement-breakpoint
CREATE POLICY users_own_rows_delete ON users AS RESTRICTIVE FOR DELETE
  USING (id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
--> statement-breakpoint

-- refresh_tokens
DROP POLICY IF EXISTS refresh_tokens_isolation_policy ON refresh_tokens;
--> statement-breakpoint
DROP POLICY IF EXISTS refresh_tokens_select_policy ON refresh_tokens;
--> statement-breakpoint
CREATE POLICY refresh_tokens_select_policy ON refresh_tokens FOR SELECT USING (true);
--> statement-breakpoint
DROP POLICY IF EXISTS refresh_tokens_write_open_policy ON refresh_tokens;
--> statement-breakpoint
CREATE POLICY refresh_tokens_write_open_policy ON refresh_tokens FOR ALL USING (true) WITH CHECK (true);
--> statement-breakpoint
DROP POLICY IF EXISTS refresh_tokens_own_insert_policy ON refresh_tokens;
--> statement-breakpoint
CREATE POLICY refresh_tokens_own_insert_policy ON refresh_tokens AS RESTRICTIVE FOR INSERT
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
--> statement-breakpoint
DROP POLICY IF EXISTS refresh_tokens_own_update_policy ON refresh_tokens;
--> statement-breakpoint
CREATE POLICY refresh_tokens_own_update_policy ON refresh_tokens AS RESTRICTIVE FOR UPDATE
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
--> statement-breakpoint
DROP POLICY IF EXISTS refresh_tokens_own_delete_policy ON refresh_tokens;
--> statement-breakpoint
CREATE POLICY refresh_tokens_own_delete_policy ON refresh_tokens AS RESTRICTIVE FOR DELETE
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
--> statement-breakpoint

-- profiles
DROP POLICY IF EXISTS profiles_isolation_policy ON profiles;
--> statement-breakpoint
CREATE POLICY profiles_isolation_policy ON profiles FOR ALL
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
--> statement-breakpoint

-- pills
DROP POLICY IF EXISTS pills_isolation_policy ON pills;
--> statement-breakpoint
CREATE POLICY pills_isolation_policy ON pills FOR ALL
  USING (profile_id IN (SELECT id FROM profiles WHERE user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid))
  WITH CHECK (profile_id IN (SELECT id FROM profiles WHERE user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid));
--> statement-breakpoint

-- schedules
DROP POLICY IF EXISTS schedules_isolation_policy ON schedules;
--> statement-breakpoint
CREATE POLICY schedules_isolation_policy ON schedules FOR ALL
  USING (pill_id IN (SELECT p.id FROM pills p JOIN profiles pr ON pr.id = p.profile_id WHERE pr.user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid))
  WITH CHECK (pill_id IN (SELECT p.id FROM pills p JOIN profiles pr ON pr.id = p.profile_id WHERE pr.user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid));
--> statement-breakpoint

-- dose_logs
DROP POLICY IF EXISTS dose_logs_isolation_policy ON dose_logs;
--> statement-breakpoint
CREATE POLICY dose_logs_isolation_policy ON dose_logs FOR ALL
  USING (schedule_id IN (SELECT s.id FROM schedules s JOIN pills p ON p.id = s.pill_id JOIN profiles pr ON pr.id = p.profile_id WHERE pr.user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid))
  WITH CHECK (schedule_id IN (SELECT s.id FROM schedules s JOIN pills p ON p.id = s.pill_id JOIN profiles pr ON pr.id = p.profile_id WHERE pr.user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid));
--> statement-breakpoint

-- password_reset_tokens
DROP POLICY IF EXISTS prt_open_policy ON password_reset_tokens;
--> statement-breakpoint
CREATE POLICY prt_open_policy ON password_reset_tokens FOR ALL USING (true) WITH CHECK (true);
--> statement-breakpoint
DROP POLICY IF EXISTS prt_own_insert_policy ON password_reset_tokens;
--> statement-breakpoint
CREATE POLICY prt_own_insert_policy ON password_reset_tokens AS RESTRICTIVE FOR INSERT
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
--> statement-breakpoint
DROP POLICY IF EXISTS prt_own_update_policy ON password_reset_tokens;
--> statement-breakpoint
CREATE POLICY prt_own_update_policy ON password_reset_tokens AS RESTRICTIVE FOR UPDATE
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
--> statement-breakpoint

-- ─── 4. FORCE ROW LEVEL SECURITY ───────────────────────────────────────────
ALTER TABLE users FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE refresh_tokens FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE profiles FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE pills FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE schedules FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE dose_logs FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE password_reset_tokens FORCE ROW LEVEL SECURITY;
--> statement-breakpoint

-- ─── 5. Missing FK indexes for RLS hot paths ───────────────────────────────
CREATE INDEX IF NOT EXISTS profiles_user_id_idx ON profiles (user_id);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS pills_profile_id_idx ON pills (profile_id);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS schedules_pill_id_idx ON schedules (pill_id);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS prt_token_hash_idx ON password_reset_tokens (token_hash);
