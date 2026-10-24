-- compat: breaking
-- Account self-service: change email, delete account, export.
-- Breaking because the delete flow relies on invitation_tokens.api_key_id
-- cascading (an older image's delete fails for an invited account) and an
-- older image answers a deleted account's key with "register again".
-- email_change_tokens: a pending sign-in address change. deleted_account_markers:
-- hashes of api keys and live refresh tokens whose account is gone, so a
-- device that holds either is told so.
CREATE TABLE "deleted_account_markers" (
	"key_hash" text PRIMARY KEY NOT NULL,
	"kind" text DEFAULT 'apiKey' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	CONSTRAINT "deleted_account_markers_kind_check" CHECK ("kind" IN ('apiKey', 'refresh'))
);
--> statement-breakpoint
CREATE TABLE "email_change_tokens" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"new_email" text NOT NULL,
	"token_hash" text NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"consumed_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "invitation_tokens" DROP CONSTRAINT "invitation_tokens_api_key_id_api_keys_id_fk";
--> statement-breakpoint
ALTER TABLE "email_change_tokens" ADD CONSTRAINT "email_change_tokens_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "email_change_tokens_token_hash_idx" ON "email_change_tokens" USING btree ("token_hash");--> statement-breakpoint
CREATE INDEX "email_change_tokens_user_idx" ON "email_change_tokens" USING btree ("user_id");--> statement-breakpoint
ALTER TABLE "invitation_tokens" ADD CONSTRAINT "invitation_tokens_api_key_id_api_keys_id_fk" FOREIGN KEY ("api_key_id") REFERENCES "public"."api_keys"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE public.email_change_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.email_change_tokens FORCE ROW LEVEL SECURITY;
ALTER TABLE public.deleted_account_markers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deleted_account_markers FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
-- Reads are open (the confirm link is opened before sign-in and finds its row
-- by token hash); writes are restricted to the signed-in owner, as for
-- password_reset_tokens in 0007. The confirm step marks the row consumed
-- inside the owner's tenant context.
CREATE POLICY ect_open_policy ON public.email_change_tokens
  FOR ALL TO app_user USING (true) WITH CHECK (true);
CREATE POLICY ect_own_insert_policy ON public.email_change_tokens AS RESTRICTIVE
  FOR INSERT TO app_user
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
CREATE POLICY ect_own_update_policy ON public.email_change_tokens AS RESTRICTIVE
  FOR UPDATE TO app_user
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
CREATE POLICY ect_own_delete_policy ON public.email_change_tokens AS RESTRICTIVE
  FOR DELETE TO app_user
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
--> statement-breakpoint
REVOKE ALL ON TABLE public.email_change_tokens, public.deleted_account_markers
  FROM PUBLIC, app_user, outbox_user, deployment_authority_owner;
GRANT SELECT, INSERT, DELETE ON public.email_change_tokens TO app_user;
GRANT UPDATE (consumed_at) ON public.email_change_tokens TO app_user;
-- deleted_account_markers: no direct grant to anyone. Only the definer
-- functions below read or write it.
--> statement-breakpoint
-- Called inside the account delete transaction, before the user row goes:
-- remember the hashes of the account's api keys. Only the signed-in owner
-- can mark their own account.
CREATE OR REPLACE FUNCTION public.mark_account_deleted(p_user_id uuid, p_expires_at timestamptz)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_count integer;
BEGIN
  IF p_user_id IS NULL
     OR p_user_id IS DISTINCT FROM NULLIF(current_setting('app.current_user_id', true), '')::uuid THEN
    RAISE EXCEPTION 'account marker requires the signed-in owner';
  END IF;
  INSERT INTO public.deleted_account_markers (key_hash, kind, expires_at)
  SELECT k.key_hash, 'apiKey', p_expires_at FROM public.api_keys AS k WHERE k.user_id = p_user_id
  ON CONFLICT (key_hash) DO UPDATE SET expires_at = excluded.expires_at;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  -- Live refresh tokens too: a device that holds only one of them is still
  -- told the account is gone (rotated and revoked tokens are not live).
  INSERT INTO public.deleted_account_markers (key_hash, kind, expires_at)
  SELECT t.token_hash, 'refresh', LEAST(p_expires_at, GREATEST(t.expires_at, now()))
  FROM public.refresh_tokens AS t
  WHERE t.user_id = p_user_id AND NOT t.revoked AND t.expires_at > now()
  ON CONFLICT (key_hash) DO UPDATE SET expires_at = excluded.expires_at;
  RETURN v_count;
END;
$function$;
--> statement-breakpoint
CREATE OR REPLACE FUNCTION public.is_deleted_account_key(p_key_hash text, p_kind text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.deleted_account_markers AS m
    WHERE m.key_hash = p_key_hash AND m.kind = p_kind AND m.expires_at > now()
  );
$function$;
--> statement-breakpoint
CREATE OR REPLACE FUNCTION public.purge_deleted_account_markers()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_count integer;
BEGIN
  DELETE FROM public.deleted_account_markers WHERE expires_at <= now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;
--> statement-breakpoint
-- Called inside the account delete transaction: drops mail still waiting to be
-- sent to the account's address (or to an address it was about to change to),
-- so nothing is delivered after the account is gone. Messages already being
-- sent are left alone. Only the signed-in owner can ask, only for their own
-- address, and only unsent rows go.
CREATE OR REPLACE FUNCTION public.delete_unsent_outbox_for_account(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_count integer;
BEGIN
  IF p_user_id IS NULL
     OR p_user_id IS DISTINCT FROM NULLIF(current_setting('app.current_user_id', true), '')::uuid THEN
    RAISE EXCEPTION 'outbox cleanup requires the signed-in owner';
  END IF;
  DELETE FROM public.outbox_messages AS o
  WHERE o.state IN ('queued', 'retrying')
    AND (o.recipient_ref IN (SELECT u.email FROM public.users AS u WHERE u.id = p_user_id)
      OR o.recipient_ref IN (SELECT c.new_email FROM public.email_change_tokens AS c WHERE c.user_id = p_user_id));
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;
--> statement-breakpoint
REVOKE ALL ON FUNCTION public.mark_account_deleted(uuid, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_deleted_account_key(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_unsent_outbox_for_account(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_deleted_account_markers() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_account_deleted(uuid, timestamptz) TO app_user;
GRANT EXECUTE ON FUNCTION public.is_deleted_account_key(text, text) TO app_user;
GRANT EXECUTE ON FUNCTION public.delete_unsent_outbox_for_account(uuid) TO app_user;
GRANT EXECUTE ON FUNCTION public.purge_deleted_account_markers() TO app_user;
--> statement-breakpoint
SELECT public.raise_migration_compatibility_floor(33);
