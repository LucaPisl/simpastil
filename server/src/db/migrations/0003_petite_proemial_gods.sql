CREATE TABLE "admin_config" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"email" text NOT NULL,
	"password_hash" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
-- Enforce single-row invariant: only one admin account allowed.
CREATE UNIQUE INDEX "admin_config_single_row" ON "admin_config" ((true));
--> statement-breakpoint
CREATE TABLE "admin_refresh_tokens" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"token_hash" text NOT NULL,
	"family_id" uuid NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"revoked" boolean DEFAULT false NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "api_keys" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid,
	"key_hash" text NOT NULL,
	"label" text NOT NULL,
	"revoked_at" timestamp with time zone,
	"last_used_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "refresh_tokens" ADD COLUMN "device_name" text;--> statement-breakpoint
ALTER TABLE "api_keys" ADD CONSTRAINT "api_keys_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "admin_refresh_tokens_hash_idx" ON "admin_refresh_tokens" USING btree ("token_hash");--> statement-breakpoint
CREATE INDEX "admin_refresh_tokens_family_idx" ON "admin_refresh_tokens" USING btree ("family_id");--> statement-breakpoint
CREATE INDEX "api_keys_key_hash_idx" ON "api_keys" USING btree ("key_hash");--> statement-breakpoint
CREATE INDEX "api_keys_user_id_idx" ON "api_keys" USING btree ("user_id");

-- ── RLS grants ────────────────────────────────────────────────────────────────
-- Guarded: app_user may not exist yet on a fresh DB (created in 0007).

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'app_user') THEN
    GRANT SELECT, INSERT, UPDATE ON api_keys TO app_user;
    GRANT SELECT ON admin_config TO app_user;
    GRANT SELECT, INSERT, UPDATE ON admin_refresh_tokens TO app_user;
  END IF;
END $$;

-- ── Existing-user key backfill ────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (
    SELECT FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'migration_key_hashes'
  ) THEN
    INSERT INTO api_keys (id, user_id, key_hash, label, created_at)
    SELECT
      gen_random_uuid(),
      user_id,
      key_hash,
      'Migrated user key (replace via admin UI)',
      now()
    FROM migration_key_hashes
    WHERE NOT EXISTS (
      SELECT 1 FROM api_keys k WHERE k.user_id = migration_key_hashes.user_id
    );
    DROP TABLE migration_key_hashes;
  END IF;
END $$;