-- Fix: add NULLIF wrapper to backup_codes RLS policy (consistent with all other tables)
-- Without NULLIF, an empty string for app.current_user_id causes ''::UUID to throw.
DROP POLICY IF EXISTS backup_codes_user_isolation ON backup_codes;
CREATE POLICY backup_codes_user_isolation ON backup_codes
  FOR ALL
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
