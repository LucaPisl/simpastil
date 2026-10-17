DROP INDEX "refresh_tokens_token_hash_idx";--> statement-breakpoint
ALTER TABLE "refresh_tokens" ADD COLUMN "successor_token_hash" text;--> statement-breakpoint
ALTER TABLE "refresh_tokens" ADD COLUMN "rotated_at" timestamp with time zone;--> statement-breakpoint
CREATE UNIQUE INDEX "refresh_tokens_token_hash_idx" ON "refresh_tokens" USING btree ("token_hash");