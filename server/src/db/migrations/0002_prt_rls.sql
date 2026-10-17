-- =============================================================================
-- Migration 0002: Enable Row-Level Security on password_reset_tokens
--
-- This table was created in 0001_sturdy_thena.sql without RLS. This migration
-- adds the same isolation controls as the other user-owned tables.
--
-- Policy design mirrors refresh_tokens:
--   SELECT is open — the caller does not know the user_id before the
--   hash-based lookup in resetPassword().
--
--   INSERT is restricted — forgotPassword() now sets app.current_user_id
--   before inserting, so only tokens owned by the session user can be
--   inserted. (Changed in auth.service.ts alongside this migration.)
--
--   UPDATE is restricted — resetPassword() sets app.current_user_id before
--   marking the token used=true.
--
--   DELETE is open — cleanup deletes expired/used tokens for a user after
--   app.current_user_id is set; CASCADE from users runs as superuser.
--   The permissive base policy covers both cases.
-- =============================================================================

ALTER TABLE "password_reset_tokens" ENABLE ROW LEVEL SECURITY;

-- Permissive base: required for SELECT and DELETE to pass.
CREATE POLICY prt_open_policy ON password_reset_tokens
  FOR ALL
  USING (true)
  WITH CHECK (true);

-- Restrictive INSERT: forgotPassword sets app.current_user_id before insert.
CREATE POLICY prt_own_insert_policy ON password_reset_tokens
  AS RESTRICTIVE
  FOR INSERT
  WITH CHECK (
    user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
  );

-- Restrictive UPDATE: resetPassword sets app.current_user_id before marking used.
CREATE POLICY prt_own_update_policy ON password_reset_tokens
  AS RESTRICTIVE
  FOR UPDATE
  USING (
    user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
  )
  WITH CHECK (
    user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
  );
