-- =============================================================================
-- Simpastil — Least-Privilege Role + Row-Level Security Policies
--
-- Run this AFTER 0000_initial.sql (which creates tables and enables RLS).
--
-- The application connects as 'app_user', which:
--   - Is NOT a superuser
--   - Does NOT have BYPASSRLS (so RLS is always enforced)
--   - Has ONLY DML permissions on the public schema
--   - Cannot perform DDL (CREATE, ALTER, DROP, TRUNCATE)
--
-- The app sets the session variable 'app.current_user_id' at the start of
-- every authenticated transaction. RLS policies read this variable to filter
-- rows to the requesting user's data only.
--
-- NOTE: current_setting(name, true) returns '' (empty string) when the
-- variable is not set — not NULL. NULLIF(..., '') converts it to NULL so
-- that the uuid cast never throws "invalid input syntax for type uuid: ''".
-- NULL::uuid never equals any id, so unset sessions see zero rows.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- Least-privilege application role
-- ---------------------------------------------------------------------------

-- Create the role if it doesn't already exist.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_catalog.pg_roles WHERE rolname = 'app_user'
  ) THEN
    CREATE ROLE app_user
      NOSUPERUSER    -- no superuser bypass
      NOCREATEDB     -- cannot create databases
      NOCREATEROLE   -- cannot create or modify roles
      NOINHERIT      -- does not inherit privileges from other roles
      LOGIN          -- can open a connection
      PASSWORD NULL; -- password set separately (environment / Docker secret)
    -- IMPORTANT: app_user does NOT have BYPASSRLS, so PostgreSQL enforces
    -- all RLS policies for every query this role issues.
  END IF;
END;
$$;

-- Grant connection to the database (replace 'simpastil' with your DB name).
-- Run manually: GRANT CONNECT ON DATABASE simpastil TO app_user;

-- Allow app_user to use the public schema.
GRANT USAGE ON SCHEMA public TO app_user;

-- Grant DML-only on every current and future table in public.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_user;

-- Allow app_user to use sequences (needed for any serial/identity columns
-- and for gen_random_uuid() indirectly via the default value expressions).
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO app_user;


-- ---------------------------------------------------------------------------
-- users
--
-- Design: permissive base + restrictive per-command policies.
--
-- The application (app_user role) is a trusted server process that must be
-- able to SELECT any user row (e.g., to look up a user by email during login
-- or to verify a token). RLS on SELECT for users is therefore not applied —
-- the application-level code is responsible for only reading rows it needs.
--
-- INSERT: open to all app_user sessions (registration creates a new user
-- without a pre-existing app.current_user_id session variable).
-- The service pre-generates the UUID and sets app.current_user_id = newId
-- before INSERT … RETURNING so the implicit RETURNING SELECT also passes.
--
-- UPDATE / DELETE: restricted to own row only, guarded by the session
-- variable app.current_user_id that routes set before each authenticated
-- transaction.
--
-- users_open_policy (PERMISSIVE FOR ALL, USING true): required as the base
-- pass-through. Without at least one permissive USING (true) clause,
-- PostgreSQL's default-deny blocks all rows.
--
-- users_own_rows_write  (RESTRICTIVE FOR UPDATE): limits updates to own row.
-- users_own_rows_delete (RESTRICTIVE FOR DELETE): limits deletes to own row.
--
-- NOTE: current_setting(name, true) returns '' (empty string) when unset.
-- NULLIF(..., '') converts it to NULL so the uuid cast never throws.
-- ---------------------------------------------------------------------------

-- Permissive: required as the base pass-through for all commands.
CREATE POLICY users_open_policy ON users
  FOR ALL
  USING (true)
  WITH CHECK (true);

-- Restrictive: limit UPDATE to own row only.
CREATE POLICY users_own_rows_write ON users
  AS RESTRICTIVE
  FOR UPDATE
  USING (
    id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
  )
  WITH CHECK (
    id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
  );

-- Restrictive: limit DELETE to own row only.
CREATE POLICY users_own_rows_delete ON users
  AS RESTRICTIVE
  FOR DELETE
  USING (
    id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
  );


-- ---------------------------------------------------------------------------
-- refresh_tokens
--
-- SELECT: open to the application role so that refresh() can look up a token
-- by its hash before knowing the owning user (the token IS the credential).
-- The service validates the hash with timingSafeEqual and enforces all
-- business rules (expiry, revocation, reuse detection) in application code.
--
-- INSERT / UPDATE / DELETE: restricted to the token owner. The service sets
-- app.current_user_id (discovered from the SELECT) before issuing writes.
-- ---------------------------------------------------------------------------

-- Drop the old single-policy that replaced the above design (idempotent).
DROP POLICY IF EXISTS refresh_tokens_isolation_policy ON refresh_tokens;

-- Permissive SELECT: the app looks up any token by hash — user is unknown
-- until after the lookup. Application code enforces all security invariants.
CREATE POLICY refresh_tokens_select_policy ON refresh_tokens
  FOR SELECT
  USING (true);

-- Permissive base for INSERT/UPDATE/DELETE — required so that the
-- restrictive policies below have a permissive baseline to intersect.
CREATE POLICY refresh_tokens_write_open_policy ON refresh_tokens
  FOR ALL
  USING (true)
  WITH CHECK (true);

-- Restrictive INSERT: only insert tokens owned by the current session user.
CREATE POLICY refresh_tokens_own_insert_policy ON refresh_tokens
  AS RESTRICTIVE
  FOR INSERT
  WITH CHECK (
    user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
  );

-- Restrictive UPDATE: only update tokens owned by the current session user.
CREATE POLICY refresh_tokens_own_update_policy ON refresh_tokens
  AS RESTRICTIVE
  FOR UPDATE
  USING (
    user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
  )
  WITH CHECK (
    user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
  );

-- Restrictive DELETE: only delete tokens owned by the current session user.
CREATE POLICY refresh_tokens_own_delete_policy ON refresh_tokens
  AS RESTRICTIVE
  FOR DELETE
  USING (
    user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
  );


-- ---------------------------------------------------------------------------
-- profiles
--
-- A user may only access profiles they own.
-- ---------------------------------------------------------------------------

CREATE POLICY profiles_isolation_policy ON profiles
  FOR ALL
  USING (
    user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
  )
  WITH CHECK (
    user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
  );


-- ---------------------------------------------------------------------------
-- pills
--
-- Pills are owned via a profile. Check that the pill's profile belongs to the
-- current user.
-- ---------------------------------------------------------------------------

CREATE POLICY pills_isolation_policy ON pills
  FOR ALL
  USING (
    profile_id IN (
      SELECT id FROM profiles
      WHERE user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
    )
  )
  WITH CHECK (
    profile_id IN (
      SELECT id FROM profiles
      WHERE user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
    )
  );


-- ---------------------------------------------------------------------------
-- schedules
--
-- Schedules are owned via pill → profile → user.
-- ---------------------------------------------------------------------------

CREATE POLICY schedules_isolation_policy ON schedules
  FOR ALL
  USING (
    pill_id IN (
      SELECT p.id FROM pills p
      JOIN profiles pr ON pr.id = p.profile_id
      WHERE pr.user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
    )
  )
  WITH CHECK (
    pill_id IN (
      SELECT p.id FROM pills p
      JOIN profiles pr ON pr.id = p.profile_id
      WHERE pr.user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
    )
  );


-- ---------------------------------------------------------------------------
-- dose_logs
--
-- Dose logs are owned via schedule → pill → profile → user.
-- ---------------------------------------------------------------------------

CREATE POLICY dose_logs_isolation_policy ON dose_logs
  FOR ALL
  USING (
    schedule_id IN (
      SELECT s.id FROM schedules s
      JOIN pills p    ON p.id  = s.pill_id
      JOIN profiles pr ON pr.id = p.profile_id
      WHERE pr.user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
    )
  )
  WITH CHECK (
    schedule_id IN (
      SELECT s.id FROM schedules s
      JOIN pills p    ON p.id  = s.pill_id
      JOIN profiles pr ON pr.id = p.profile_id
      WHERE pr.user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
    )
  );


-- ---------------------------------------------------------------------------
-- password_reset_tokens
--
-- SELECT: open — the caller does not know the user before the hash lookup.
-- INSERT: restricted — forgotPassword() sets app.current_user_id before insert.
-- UPDATE: restricted — resetPassword() sets app.current_user_id before marking used.
-- DELETE: open — opportunistic cleanup runs after user_id is known; CASCADE
--         from users table runs as superuser (RLS not applied).
--
-- NOTE: RLS is enabled by migration 0002_prt_rls.sql.
-- ---------------------------------------------------------------------------

-- Permissive base for SELECT and DELETE (and fallback for INSERT/UPDATE
-- before the restrictive policies are evaluated).
CREATE POLICY prt_open_policy ON password_reset_tokens
  FOR ALL
  USING (true)
  WITH CHECK (true);

-- Restrictive INSERT: only insert tokens owned by the current session user.
CREATE POLICY prt_own_insert_policy ON password_reset_tokens
  AS RESTRICTIVE
  FOR INSERT
  WITH CHECK (
    user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
  );

-- Restrictive UPDATE: only mark tokens used when the session user matches.
CREATE POLICY prt_own_update_policy ON password_reset_tokens
  AS RESTRICTIVE
  FOR UPDATE
  USING (
    user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
  )
  WITH CHECK (
    user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
  );
