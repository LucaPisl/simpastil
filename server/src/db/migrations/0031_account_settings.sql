-- compat: expand
-- Two new tables that no older image reads: the settings that follow an
-- account across devices and their per-account revision counter. They travel
-- on dedicated routes, never in sync_changes, so an older image keeps parsing
-- every stored change row and keeps serving this database. Values written
-- while this migration is live stay only on the server if the image is rolled
-- back; the app keeps working with its device-local values.
CREATE TABLE "account_settings" (
	"user_id" uuid NOT NULL,
	"key" text NOT NULL,
	"value" jsonb,
	"revision" bigint NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "account_settings_user_id_key_pk" PRIMARY KEY("user_id","key"),
	CONSTRAINT "account_settings_revision_check" CHECK ("account_settings"."revision" > 0),
	CONSTRAINT "account_settings_value_size_check" CHECK ("account_settings"."value" IS NULL OR octet_length("account_settings"."value"::text) <= 8192),
	CONSTRAINT "account_settings_key_check" CHECK ("account_settings"."key" ~ '^(reminders\.snoozeMinutes|reminders\.(routine|person)\.[0-9a-f-]{36}|recordedBy|asNeeded\.inStats|medications\.siblingDetection|today\.noticesLater|appearance\.(text|colors)|language)$')
);
--> statement-breakpoint
CREATE TABLE "account_settings_heads" (
	"user_id" uuid PRIMARY KEY NOT NULL,
	"revision" bigint DEFAULT 0 NOT NULL,
	CONSTRAINT "account_settings_heads_revision_check" CHECK ("account_settings_heads"."revision" >= 0)
);
--> statement-breakpoint
ALTER TABLE "account_settings" ADD CONSTRAINT "account_settings_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "account_settings_heads" ADD CONSTRAINT "account_settings_heads_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "account_settings_user_revision_idx" ON "account_settings" USING btree ("user_id","revision");
--> statement-breakpoint
ALTER TABLE public.account_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_settings FORCE ROW LEVEL SECURITY;
ALTER TABLE public.account_settings_heads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_settings_heads FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
CREATE POLICY account_settings_app_tenant ON public.account_settings
  FOR ALL TO app_user
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
CREATE POLICY account_settings_heads_app_tenant ON public.account_settings_heads
  FOR ALL TO app_user
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);
--> statement-breakpoint
-- Explicit grants: 0007 granted only the tables that existed then. The API
-- never deletes a setting (a cleared key is a tombstone row) and never
-- rewrites a row's identity.
REVOKE ALL ON TABLE public.account_settings, public.account_settings_heads
  FROM PUBLIC, app_user, outbox_user, deployment_authority_owner;
GRANT SELECT, INSERT ON public.account_settings, public.account_settings_heads TO app_user;
GRANT UPDATE (value, revision, updated_at) ON public.account_settings TO app_user;
GRANT UPDATE (revision) ON public.account_settings_heads TO app_user;
