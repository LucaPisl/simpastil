import { randomUUID } from 'node:crypto';
import { and, eq, isNull, sql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { TenantTransactionRunner, type TenantTransaction } from '../../db/tenant-transaction.js';
import { pillPhotos, pills, profiles, schedules } from '../../db/schema.js';
import { reminderRoutineKey } from '../account-settings/account-settings.schema.js';
import { tombstoneAccountSettings } from '../account-settings/account-settings.service.js';
import { EntityMutationService } from '../entities/entity-mutation.service.js';
import { ResourceError } from '../shared/errors.js';
import { formatDbStock, legacyStockInteger } from '../shared/stock-quantity.js';
import type { CreatePillRequest, UpdatePillRequest } from './pills.schema.js';

function pillResult(row: typeof pills.$inferSelect) {
  const { currentStock, stockUnit, stockNeedsRecount, ...rest } = row;
  return {
    ...rest,
    // The whole count older builds read; the exact quantity and its unit are
    // added only once the medicine counts stock in a unit.
    currentStock: legacyStockInteger(currentStock),
    ...(stockUnit === null ? {} : { stockQuantity: formatDbStock(currentStock), stockUnit }),
    // Present only while the count needs a recount, so a row that never did
    // stays byte-identical to what an older reader parses.
    ...(stockNeedsRecount ? { stockNeedsRecount: true } : {}),
    revision: row.revision.toString(),
    deletedAt: row.deletedAt?.toISOString() ?? null,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

export class PillsService {
  private readonly transactions: TenantTransactionRunner;
  private readonly mutations: EntityMutationService;

  constructor(db: Db) {
    this.transactions = new TenantTransactionRunner(db);
    this.mutations = new EntityMutationService(this.transactions);
  }

  private async assertProfileOwnership(
    tx: TenantTransaction,
    userId: string,
    profileId: string,
  ): Promise<void> {
    const [row] = await tx
      .select({ id: profiles.id })
      .from(profiles)
      .where(and(
        eq(profiles.id, profileId),
        eq(profiles.userId, userId),
        isNull(profiles.deletedAt),
      ));
    if (!row) throw new ResourceError('Profile not found', 404);
  }

  private async readOwnedPill(
    tx: TenantTransaction,
    userId: string,
    profileId: string,
    pillId: string,
    includeDeleted = false,
  ) {
    const [row] = await tx
      .select({ pill: pills })
      .from(pills)
      .innerJoin(profiles, eq(pills.profileId, profiles.id))
      .where(and(
        eq(pills.id, pillId),
        eq(pills.profileId, profileId),
        eq(profiles.userId, userId),
        isNull(profiles.deletedAt),
        ...(includeDeleted ? [] : [isNull(pills.deletedAt)]),
      ));
    return row?.pill;
  }

  async listPills(userId: string, profileId: string) {
    return this.transactions.run(userId, async (tx) => {
      await this.assertProfileOwnership(tx, userId, profileId);
      const rows = await tx
        .select({ pill: pills })
        .from(pills)
        .innerJoin(profiles, eq(pills.profileId, profiles.id))
        .where(and(
          eq(pills.profileId, profileId),
          eq(profiles.userId, userId),
          isNull(profiles.deletedAt),
        ));
      return rows.map(({ pill }) => pillResult(pill));
    });
  }

  async createPill(userId: string, profileId: string, data: CreatePillRequest) {
    const pillId = data.id ?? randomUUID();
    const dosage = data.dosage ?? null;
    const notes = data.notes ?? null;
    const color = data.color ?? null;
    const lowStockThreshold = data.lowStockThreshold ?? null;
    const amountPerUse = data.amountPerUse ?? null;
    const packageStrength = data.packageStrength ?? null;
    const form = data.form ?? null;
    const legacyDosageReviewed = data.legacyDosageReviewed ?? false;
    const shape = data.shape ?? null;
    const prnMaxPer24h = data.prnMaxPer24h ?? null;
    const prnMinGapMinutes = data.prnMinGapMinutes ?? null;
    const expiresOn = data.expiresOn ?? null;
    const prescriberName = data.prescriberName ?? null;
    const prescriberPhone = data.prescriberPhone ?? null;
    const pharmacyName = data.pharmacyName ?? null;
    const pharmacyPhone = data.pharmacyPhone ?? null;

    return this.mutations.execute({
      userId,
      mutationId: data.mutationId,
      entityType: 'pills',
      operation: 'create',
      entityId: pillId,
      ...(data.id ? { expectedEntityId: data.id } : {}),
      input: {
        profileId,
        requestedId: data.id ?? null,
        name: data.name,
        dosage,
        notes,
        color,
        lowStockThreshold,
        isPrn: data.isPrn,
        amountPerUse,
        packageStrength,
        form,
        legacyDosageReviewed,
        shape,
        prnMaxPer24h,
        prnMinGapMinutes,
        expiresOn,
        prescriberName,
        prescriberPhone,
        pharmacyName,
        pharmacyPhone,
      },
      write: async (tx) => {
        await this.assertProfileOwnership(tx, userId, profileId);
        const [row] = await tx.insert(pills).values({
          id: pillId,
          profileId,
          name: data.name,
          dosage,
          notes,
          color,
          lowStockThreshold,
          isPrn: data.isPrn,
          amountPerUse,
          packageStrength,
          form,
          legacyDosageReviewed,
          shape,
          prnMaxPer24h,
          prnMinGapMinutes,
          expiresOn,
          prescriberName,
          prescriberPhone,
          pharmacyName,
          pharmacyPhone,
          revision: 1n,
          lastMutationId: data.mutationId,
        }).onConflictDoNothing({ target: pills.id }).returning();
        return row ? { revision: row.revision, entity: pillResult(row) } : undefined;
      },
      readCurrent: async (tx) => {
        const row = await this.readOwnedPill(tx, userId, profileId, pillId, true);
        return row ? { revision: row.revision, entity: pillResult(row) } : undefined;
      },
    });
  }

  async updatePill(
    userId: string,
    profileId: string,
    pillId: string,
    data: UpdatePillRequest,
  ) {
    const { mutationId, baseRevision, ...fields } = data;
    const expectedRevision = BigInt(baseRevision);
    return this.mutations.execute({
      userId,
      mutationId,
      entityType: 'pills',
      operation: 'update',
      entityId: pillId,
      expectedEntityId: pillId,
      baseRevision: expectedRevision,
      input: { profileId, ...fields },
      write: async (tx) => {
        await this.assertProfileOwnership(tx, userId, profileId);
        const [row] = await tx.update(pills).set({
          ...fields,
          revision: sql`${pills.revision} + 1`,
          lastMutationId: mutationId,
          updatedAt: new Date(),
        }).where(and(
          eq(pills.id, pillId),
          eq(pills.profileId, profileId),
          eq(pills.revision, expectedRevision),
          isNull(pills.deletedAt),
        )).returning();
        return row ? { revision: row.revision, entity: pillResult(row) } : undefined;
      },
      readCurrent: async (tx) => {
        const row = await this.readOwnedPill(tx, userId, profileId, pillId, true);
        return row ? { revision: row.revision, entity: pillResult(row) } : undefined;
      },
    });
  }

  async deletePill(
    userId: string,
    profileId: string,
    pillId: string,
    mutationId: string,
    baseRevision: string,
  ): Promise<void> {
    await this.mutations.execute({
      userId,
      mutationId,
      entityType: 'pills',
      operation: 'delete',
      entityId: pillId,
      expectedEntityId: pillId,
      baseRevision: BigInt(baseRevision),
      input: { profileId },
      write: async (tx) => {
        await this.assertProfileOwnership(tx, userId, profileId);
        const deletedAt = new Date();
        const [row] = await tx.update(pills).set({
          deletedAt,
          revision: sql`${pills.revision} + 1`,
          lastMutationId: mutationId,
          updatedAt: deletedAt,
        }).where(and(
          eq(pills.id, pillId),
          eq(pills.profileId, profileId),
          eq(pills.revision, BigInt(baseRevision)),
          isNull(pills.deletedAt),
        )).returning();
        // A deleted medication keeps no photo: the tombstone is all that stays.
        if (row) {
          await tx.delete(pillPhotos).where(eq(pillPhotos.pillId, pillId));
          // Nor does it keep the reminder choices of its routines.
          const routines = await tx.select({ id: schedules.id }).from(schedules).where(eq(schedules.pillId, pillId));
          await tombstoneAccountSettings(tx, userId, routines.map((routine) => reminderRoutineKey(routine.id)));
        }
        return row ? { revision: row.revision, entity: pillResult(row) } : undefined;
      },
      readCurrent: async (tx) => {
        const row = await this.readOwnedPill(tx, userId, profileId, pillId, true);
        return row ? { revision: row.revision, entity: pillResult(row) } : undefined;
      },
    });
  }
}
