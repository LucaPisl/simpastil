import { sql } from 'drizzle-orm';
import { pills, syncChanges } from '../../db/schema.js';
import type { TenantTransaction } from '../../db/tenant-transaction.js';
import { serializeSyncChangePayload } from './sync-payload.js';

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
      currentStock: row.currentStock,
      lowStockThreshold: row.lowStockThreshold,
      isPrn: row.isPrn,
      amountPerUse: row.amountPerUse ?? null,
      packageStrength: row.packageStrength,
      form: row.form,
      legacyDosageReviewed: row.legacyDosageReviewed,
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

export function appendAccountSyncChange(
  tx: TenantTransaction,
  userId: string,
  account: AccountSyncRow,
): Promise<bigint> {
  const revision = BigInt(account.sessionVersion).toString();
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
