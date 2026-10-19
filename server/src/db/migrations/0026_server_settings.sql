-- compat: expand
CREATE TABLE "server_settings" (
	"singleton_key" boolean PRIMARY KEY DEFAULT true NOT NULL,
	"password_reset_mode" text,
	"reset_link_lifetime_minutes" integer DEFAULT 60 NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "server_settings_singleton_check" CHECK ("server_settings"."singleton_key" IS TRUE),
	CONSTRAINT "server_settings_reset_mode_check" CHECK ("server_settings"."password_reset_mode" IS NULL OR "server_settings"."password_reset_mode" IN ('email', 'manual')),
	CONSTRAINT "server_settings_reset_lifetime_check" CHECK ("server_settings"."reset_link_lifetime_minutes" BETWEEN 5 AND 1440)
);

--> statement-breakpoint
-- One settings row, seeded here. The API may read it and update the two
-- operator-controlled columns; it can never insert or delete the row.
INSERT INTO "server_settings" ("singleton_key") VALUES (true);
--> statement-breakpoint
REVOKE ALL ON "server_settings" FROM PUBLIC, app_user, outbox_user, deployment_authority_owner;
--> statement-breakpoint
GRANT SELECT ON "server_settings" TO app_user;
GRANT UPDATE ("password_reset_mode", "reset_link_lifetime_minutes", "updated_at") ON "server_settings" TO app_user;
--> statement-breakpoint
ALTER TABLE "server_settings" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "server_settings" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
CREATE POLICY server_settings_app_select_policy ON "server_settings"
  FOR SELECT TO app_user USING (true);
--> statement-breakpoint
CREATE POLICY server_settings_app_update_policy ON "server_settings"
  FOR UPDATE TO app_user
  USING ("singleton_key" IS TRUE)
  WITH CHECK ("singleton_key" IS TRUE);
--> statement-breakpoint

-- app_user cannot read outbox_messages (forced RLS, insert-only policy). The
-- admin email status needs only two aggregates, so expose exactly those
-- through a definer function: no recipients, payloads, ids or error text.
CREATE OR REPLACE FUNCTION public.read_email_delivery_status(p_window_days integer)
RETURNS TABLE (recent_permanent_failures bigint, last_permanent_failure_at timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
  SELECT
    count(*) FILTER (
      WHERE m.updated_at >= now() - make_interval(days => least(greatest(coalesce(p_window_days, 7), 1), 90))
    ),
    max(m.updated_at)
  FROM public.outbox_messages AS m
  WHERE m.state = 'failedPermanent';
$function$;
--> statement-breakpoint
REVOKE ALL ON FUNCTION public.read_email_delivery_status(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.read_email_delivery_status(integer) TO app_user;
