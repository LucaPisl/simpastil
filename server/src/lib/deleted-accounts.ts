import { sql } from 'drizzle-orm';
import type { Db } from '../db/client.js';

/** How long a deleted account's key hashes are remembered (days). */
export const DELETED_ACCOUNT_MARKER_DAYS = 90;

/**
 * True when this key hash (of an api key or a live refresh token) belonged to an account that was
 * deleted. The table
 * has no direct grant: only this SECURITY DEFINER function reads it, and it
 * answers yes/no for one hash, never a list.
 */
export async function isDeletedAccountKey(
  db: Db,
  keyHash: string,
  kind: 'apiKey' | 'refresh' = 'apiKey',
): Promise<boolean> {
  const result = await db.execute(sql`SELECT public.is_deleted_account_key(${keyHash}, ${kind}) AS deleted`);
  const row = (result as unknown as { rows?: Array<{ deleted: boolean }> }).rows?.[0]
    ?? (result as unknown as Array<{ deleted: boolean }>)[0];
  return row?.deleted === true;
}

export async function purgeDeletedAccountMarkers(db: Db): Promise<void> {
  await db.execute(sql`SELECT public.purge_deleted_account_markers()`);
}
