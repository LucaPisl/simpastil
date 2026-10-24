import { eq, sql } from 'drizzle-orm';
import { pillPhotos, pills, syncChanges } from '../../db/schema.js';
import type { TenantTransaction } from '../../db/tenant-transaction.js';
import { serializeSyncChangePayload } from './sync-payload.js';
import { formatDbStock, legacyStockInteger } from '../shared/stock-quantity.js';

async function allocateServerSequence(tx: TenantTransaction, userId: string): Promise<bigint> {
  const [row] = await tx.execute<{ sequence: string }>(sql`
    SELECT public.next_sync_server_sequence(${userId}::uuid)::text AS sequence
  `);
  if (!row?.sequence) throw new Error('sync server sequence was not allocated');
  return BigInt(row.sequence);
}

export async function appendSyncChange(
  tx: TenantTransaction,
  userId: string,
  input: unknown,
): Promise<bigint> {
  const change = serializeSyncChangePayload(input).value;
  const serverSequence = await allocateServerSequence(tx, userId);
  await tx.insert(syncChanges).values({
    userId,
    component: change.component,
    entityType: change.entityType,
    entityId: change.entityId,
    operation: change.operation,
    sourceKind: change.sourceIdentity.sourceKind,
    sourceId: change.sourceIdentity.sourceId,
    sourceRevision: BigInt(change.sourceIdentity.sourceRevision),
    serverSequence,
    payloadSchemaVersion: change.schemaVersion,
    payload: change as unknown as Record<string, unknown>,
  });
  return serverSequence;
}

export async function appendPillSyncChange(
  tx: TenantTransaction,
  userId: string,
  row: typeof pills.$inferSelect,
): Promise<void> {
  const revision = row.revision.toString();
  const photo = await readPhotoRef(tx, row.id);
  await appendSyncChange(tx, userId, {
    schemaVersion: 2,
    component: 'stable',
    entityType: 'pill',
    entityId: row.id,
    operation: 'upsert',
    sourceIdentity: { sourceKind: 'pill', sourceId: row.id, sourceRevision: revision },
    payload: {
      kind: 'pill',
      id: row.id,
      profileId: row.profileId,
      name: row.name,
      dosage: row.dosage,
      notes: row.notes,
      color: row.color,
      currentStock: legacyStockInteger(row.currentStock),
      lowStockThreshold: row.lowStockThreshold,
      isPrn: row.isPrn,
      amountPerUse: row.amountPerUse ?? null,
      packageStrength: row.packageStrength,
      form: row.form,
      legacyDosageReviewed: row.legacyDosageReviewed,
      // Written only once a shape is picked, so the change rows of a medicine
      // that never chose one stay readable by the previous release's strict
      // payload schema (an image-only rollback re-parses every stored row).
      ...(row.shape === null ? {} : { shape: row.shape }),
      // The limits, expiry and contacts follow the same rule: each key is
      // written only once it is set (migration 0033).
      ...detailsExtraPayload(row),
      // The photo reference, only while a photo is set (migration 0034).
      ...(photo === null ? {} : { photo }),
      // Written only once stock is counted in a unit, for the same reason: an
      // account that never used one keeps change rows the old payload reads.
      ...(row.stockUnit === null ? {} : {
        stockQuantity: formatDbStock(row.currentStock),
        stockUnit: row.stockUnit,
      }),
      ...(row.stockNeedsRecount ? { stockNeedsRecount: true } : {}),
      revision,
      deletedAt: row.deletedAt?.toISOString() ?? null,
      createdAt: row.createdAt.toISOString(),
      updatedAt: row.updatedAt.toISOString(),
    },
  });
}

export interface AccountSyncRow {
  id: string;
  email: string;
  sessionVersion: bigint | number | string;
  createdAt: Date;
  updatedAt: Date;
}

/**
 * Appends the account change. Its revision is the session version, or one past
 * the last account revision when that is higher: an email change leaves the
 * session version alone, yet every device must still see a newer revision.
 * Callers update the users row first, which serialises concurrent writers.
 */
export async function appendAccountSyncChange(
  tx: TenantTransaction,
  userId: string,
  account: AccountSyncRow,
): Promise<bigint> {
  const [last] = await tx.execute<{ revision: string | null }>(sql`
    SELECT max(source_revision)::text AS revision FROM public.sync_changes
    WHERE user_id = ${userId}::uuid AND source_kind = 'account' AND source_id = ${account.id}::uuid
  `);
  const floor = last?.revision ? BigInt(last.revision) + 1n : 1n;
  const session = BigInt(account.sessionVersion);
  const revision = (session > floor ? session : floor).toString();
  return appendSyncChange(tx, userId, {
    schemaVersion: 2,
    component: 'account',
    entityType: 'account',
    entityId: account.id,
    operation: 'upsert',
    sourceIdentity: { sourceKind: 'account', sourceId: account.id, sourceRevision: revision },
    payload: {
      kind: 'account',
      id: account.id,
      email: account.email,
      revision,
      createdAt: account.createdAt.toISOString(),
      updatedAt: account.updatedAt.toISOString(),
    },
  });
}

const DETAILS_EXTRA_KEYS = [
  'prnMaxPer24h', 'prnMinGapMinutes', 'expiresOn',
  'prescriberName', 'prescriberPhone', 'pharmacyName', 'pharmacyPhone',
] as const;

/** The optional limit, expiry and contact keys that are set, and only those. */
export function detailsExtraPayload(
  row: Readonly<Record<string, unknown>>,
): Record<string, string | number> {
  const out: Record<string, string | number> = {};
  for (const key of DETAILS_EXTRA_KEYS) {
    const value = row[key];
    if (typeof value === 'string' || typeof value === 'number') out[key] = value;
  }
  return out;
}

export interface PhotoRef {
  sha256: string;
  revision: string;
}

/**
 * The photo reference a pill's sync payload carries, or null without a photo.
 * Reads the small columns only, never the bytes.
 */
export async function readPhotoRef(tx: TenantTransaction, pillId: string): Promise<PhotoRef | null> {
  const [row] = await tx
    .select({ sha256: pillPhotos.sha256, revision: pillPhotos.revision })
    .from(pillPhotos)
    .where(eq(pillPhotos.pillId, pillId));
  return row ? { sha256: row.sha256, revision: row.revision.toString() } : null;
}
