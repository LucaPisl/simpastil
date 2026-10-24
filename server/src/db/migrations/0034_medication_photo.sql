-- compat: expand
-- One new table that no older image reads: the photo of a medication, kept apart
-- from pills and sync_changes so no pill read or change row carries the bytes.
-- It cascades with the pill and with the account. The pill's sync payload names
-- the photo (sha256 and revision) only once one is set; a medicine with a photo
-- therefore has change rows the previous release's strict payload schema cannot
-- read, so roll back an image before photos are added or restore the
-- pre-migration backup. Photos are health-adjacent personal data: they never
-- appear in a log. pg_dump carries the table, so backups and restores keep it.
CREATE TABLE "pill_photos" (
	"pill_id" uuid PRIMARY KEY NOT NULL,
	"user_id" uuid NOT NULL,
	"bytes" "bytea" NOT NULL,
	"mime" text DEFAULT 'image/jpeg' NOT NULL,
	"width" integer NOT NULL,
	"height" integer NOT NULL,
	"sha256" text NOT NULL,
	"revision" bigint DEFAULT 1 NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "pill_photos_bytes_check" CHECK (octet_length("pill_photos"."bytes") BETWEEN 1 AND 524288),
	CONSTRAINT "pill_photos_mime_check" CHECK ("pill_photos"."mime" = 'image/jpeg'),
	CONSTRAINT "pill_photos_width_check" CHECK ("pill_photos"."width" BETWEEN 1 AND 1600),
	CONSTRAINT "pill_photos_height_check" CHECK ("pill_photos"."height" BETWEEN 1 AND 1600),
	CONSTRAINT "pill_photos_sha256_check" CHECK ("pill_photos"."sha256" ~ '^[0-9a-f]{64}$'),
	CONSTRAINT "pill_photos_revision_check" CHECK ("pill_photos"."revision" > 0)
);
--> statement-breakpoint
ALTER TABLE "pill_photos" ADD CONSTRAINT "pill_photos_pill_id_pills_id_fk" FOREIGN KEY ("pill_id") REFERENCES "public"."pills"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "pill_photos" ADD CONSTRAINT "pill_photos_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "pill_photos_user_id_idx" ON "pill_photos" USING btree ("user_id");
--> statement-breakpoint
ALTER TABLE public.pill_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pill_photos FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
CREATE POLICY pill_photos_app_tenant ON public.pill_photos
  FOR ALL TO app_user
  USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid)
  WITH CHECK (
    user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
    AND pill_id IN (
      SELECT p.id FROM public.pills p
      JOIN public.profiles pr ON pr.id = p.profile_id
      WHERE pr.user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
    )
  );
--> statement-breakpoint
-- Explicit grants, as for the other tables since 0007. A photo's identity
-- (pill and owner) never changes; replacing it rewrites the content columns.
REVOKE ALL ON TABLE public.pill_photos
  FROM PUBLIC, app_user, outbox_user, deployment_authority_owner;
GRANT SELECT, INSERT, DELETE ON public.pill_photos TO app_user;
GRANT UPDATE (bytes, width, height, sha256, revision, updated_at) ON public.pill_photos TO app_user;
