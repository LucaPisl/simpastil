-- compat: expand
-- A nullable column and a check on it: an older image never reads or writes it,
-- so it keeps serving this database. The change rows of a medicine carry
-- `shape` only once one is picked, so an image-only rollback stays readable
-- until then; a medicine whose shape was picked has change rows the previous
-- release's strict payload schema cannot read, so roll back before shapes are
-- picked or restore the pre-migration backup.
ALTER TABLE "pills" ADD COLUMN "shape" text;--> statement-breakpoint
ALTER TABLE "pills" ADD CONSTRAINT "pills_shape_check" CHECK ("pills"."shape" IS NULL OR "pills"."shape" IN ('round', 'caplet', 'oval', 'softgel', 'capsule', 'triangle', 'square', 'diamond', 'drop'));