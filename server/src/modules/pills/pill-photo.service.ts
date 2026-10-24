import { createHash, randomUUID } from 'node:crypto';
import { and, eq, isNull, sql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { pillPhotos, pills, profiles } from '../../db/schema.js';
import { TenantTransactionRunner, type TenantTransaction } from '../../db/tenant-transaction.js';
import { ApiError } from '../shared/api-error.js';
import { ErrorCode } from '../shared/errors.js';
import { inspectJpeg } from '../shared/pill-photo.js';
import { appendPillSyncChange } from '../sync/sync-change-writer.js';

export interface PillPhotoResult {
  pillId: string;
  sha256: string;
  revision: string;
  width: number;
  height: number;
  pillRevision: string;
}

function notFound(): ApiError {
  return new ApiError(404, ErrorCode.RESOURCE_NOT_FOUND, 'Resource not found', { retryable: false });
}

/**
 * The photo of a medication. A change advances the pill's revision by one and
 * appends the pill's change row, so every device sees the new reference
 * (sha256 and revision) on its next pull and then fetches the bytes.
 */
export class PillPhotoService {
  private readonly transactions: TenantTransactionRunner;

  constructor(db: Db) {
    this.transactions = new TenantTransactionRunner(db);
  }

  /** The live pill of this account, or a 404 (also for another account's). */
  private async ownedPill(tx: TenantTransaction, userId: string, pillId: string) {
    const [row] = await tx
      .select({ pill: pills })
      .from(pills)
      .innerJoin(profiles, eq(profiles.id, pills.profileId))
      .where(and(eq(pills.id, pillId), eq(profiles.userId, userId), isNull(pills.deletedAt)))
      .for('update', { of: pills });
    if (!row) throw notFound();
    return row.pill;
  }

  private async bumpPill(tx: TenantTransaction, userId: string, pillId: string) {
    const [row] = await tx.update(pills).set({
      revision: sql`${pills.revision} + 1`,
      lastMutationId: randomUUID(),
      updatedAt: new Date(),
    }).where(eq(pills.id, pillId)).returning();
    if (!row) throw notFound();
    await appendPillSyncChange(tx, userId, row);
    return row;
  }

  async get(userId: string, pillId: string) {
    return this.transactions.run(userId, async (tx) => {
      const [row] = await tx
        .select({
          bytes: pillPhotos.bytes,
          sha256: pillPhotos.sha256,
          revision: pillPhotos.revision,
        })
        .from(pillPhotos)
        .innerJoin(pills, eq(pills.id, pillPhotos.pillId))
        .where(and(eq(pillPhotos.pillId, pillId), eq(pillPhotos.userId, userId), isNull(pills.deletedAt)));
      if (!row) throw notFound();
      return { bytes: row.bytes, sha256: row.sha256, revision: row.revision.toString() };
    });
  }

  async put(userId: string, pillId: string, bytes: Buffer): Promise<PillPhotoResult> {
    const { width, height } = inspectJpeg(bytes);
    const sha256 = createHash('sha256').update(bytes).digest('hex');
    return this.transactions.run(userId, async (tx) => {
      const pill = await this.ownedPill(tx, userId, pillId);
      const [existing] = await tx
        .select({ sha256: pillPhotos.sha256, revision: pillPhotos.revision, width: pillPhotos.width, height: pillPhotos.height })
        .from(pillPhotos)
        .where(eq(pillPhotos.pillId, pillId));
      // The same picture again changes nothing, so a retry after a lost
      // response costs no revision and no change row.
      if (existing?.sha256 === sha256) {
        return {
          pillId, sha256, revision: existing.revision.toString(),
          width: existing.width, height: existing.height, pillRevision: pill.revision.toString(),
        };
      }
      const revision = (existing?.revision ?? 0n) + 1n;
      if (existing) {
        await tx.update(pillPhotos).set({
          bytes, width, height, sha256, revision, updatedAt: new Date(),
        }).where(eq(pillPhotos.pillId, pillId));
      } else {
        await tx.insert(pillPhotos).values({ pillId, userId, bytes, width, height, sha256, revision });
      }
      const bumped = await this.bumpPill(tx, userId, pillId);
      return {
        pillId, sha256, revision: revision.toString(), width, height,
        pillRevision: bumped.revision.toString(),
      };
    });
  }

  /** Removes the photo. Returns without a change when there is none. */
  async remove(userId: string, pillId: string): Promise<void> {
    await this.transactions.run(userId, async (tx) => {
      await this.ownedPill(tx, userId, pillId);
      const deleted = await tx.delete(pillPhotos).where(eq(pillPhotos.pillId, pillId)).returning({ id: pillPhotos.pillId });
      if (deleted.length > 0) await this.bumpPill(tx, userId, pillId);
    });
  }
}
