-- compat: expand
-- Adds one nullable column no older image reads or writes: when the stock was last
-- started or counted, so a count that confirmed the same number (no ledger
-- event) still settles earlier doses. Existing rows stay NULL and fall back to
-- the ledger events.
-- The same migration keeps a count that changed nothing else from moving
-- updated_at (see the trigger below).
ALTER TABLE "pills" ADD COLUMN "stock_counted_at" timestamp with time zone;
--> statement-breakpoint
-- A count that confirmed the same number writes only stock_counted_at. That is
-- not a pill change (no revision bump, nothing on the wire), so it must not
-- move updated_at either: every other update still touches it, as before.
CREATE OR REPLACE FUNCTION public.pills_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  IF NEW.stock_counted_at IS DISTINCT FROM OLD.stock_counted_at
     AND (to_jsonb(NEW) - 'stock_counted_at') = (to_jsonb(OLD) - 'stock_counted_at') THEN
    RETURN NEW;
  END IF;
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$;
--> statement-breakpoint
DROP TRIGGER IF EXISTS pills_updated_at ON public.pills;
--> statement-breakpoint
CREATE TRIGGER pills_updated_at
  BEFORE UPDATE ON public.pills
  FOR EACH ROW EXECUTE FUNCTION public.pills_touch_updated_at();
