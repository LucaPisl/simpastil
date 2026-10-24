import { randomUUID } from 'node:crypto';
import { and, eq, isNull, sql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { TenantTransactionRunner } from '../../db/tenant-transaction.js';
import { EntityMutationService } from '../entities/entity-mutation.service.js';
import { pills, profiles, schedules } from '../../db/schema.js';
import { ResourceError } from '../shared/errors.js';
import { reminderPersonKey, reminderRoutineKey } from '../account-settings/account-settings.schema.js';
import { tombstoneAccountSettings } from '../account-settings/account-settings.service.js';
import type { CreateProfileRequest, UpdateProfileRequest } from './profiles.schema.js';

function profileResult(row: typeof profiles.$inferSelect) {
  return {
    ...row,
    revision: row.revision.toString(),
    deletedAt: row.deletedAt?.toISOString() ?? null,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

export class ProfilesService {
  private readonly transactions: TenantTransactionRunner;
  private readonly mutations: EntityMutationService;

  constructor(db: Db) {
    this.transactions = new TenantTransactionRunner(db);
    this.mutations = new EntityMutationService(this.transactions);
  }

  async listProfiles(userId: string) {
    return this.transactions.run(userId, async (tx) => (await tx
      .select()
      .from(profiles)
      .where(eq(profiles.userId, userId)))
      .map(profileResult));
  }

  async createProfile(userId: string, data: CreateProfileRequest) {
    const profileId = data.id ?? randomUUID();
    const avatarEmoji = data.avatarEmoji ?? '👤';
    const isActive = data.isActive ?? true;

    return this.mutations.execute({
      userId,
      mutationId: data.mutationId,
      entityType: 'profiles',
      operation: 'create',
      entityId: profileId,
      ...(data.id ? { expectedEntityId: data.id } : {}),
      input: {
        requestedId: data.id ?? null,
        name: data.name,
        avatarEmoji,
        isActive,
      },
      write: async (tx) => {
        const [row] = await tx.insert(profiles).values({
          id: profileId,
          userId,
          name: data.name,
          avatarEmoji,
          isActive,
          revision: 1n,
          lastMutationId: data.mutationId,
        }).onConflictDoNothing({ target: profiles.id }).returning();
        return row ? { revision: row.revision, entity: profileResult(row) } : undefined;
      },
      readCurrent: async (tx) => {
        const [row] = await tx.select().from(profiles).where(and(
          eq(profiles.id, profileId),
          eq(profiles.userId, userId),
        ));
        return row ? { revision: row.revision, entity: profileResult(row) } : undefined;
      },
    });
  }

  async updateProfile(userId: string, profileId: string, data: UpdateProfileRequest) {
    const { mutationId, baseRevision, ...fields } = data;
    const expectedRevision = BigInt(baseRevision);
    return this.mutations.execute({
      userId,
      mutationId,
      entityType: 'profiles',
      operation: 'update',
      entityId: profileId,
      expectedEntityId: profileId,
      baseRevision: expectedRevision,
      input: fields,
      write: async (tx) => {
        const [row] = await tx.update(profiles).set({
          ...fields,
          revision: sql`${profiles.revision} + 1`,
          lastMutationId: mutationId,
          updatedAt: new Date(),
        }).where(and(
          eq(profiles.id, profileId),
          eq(profiles.userId, userId),
          eq(profiles.revision, expectedRevision),
          isNull(profiles.deletedAt),
        )).returning();
        return row ? { revision: row.revision, entity: profileResult(row) } : undefined;
      },
      readCurrent: async (tx) => {
        const [row] = await tx.select().from(profiles).where(and(
          eq(profiles.id, profileId),
          eq(profiles.userId, userId),
        ));
        return row ? { revision: row.revision, entity: profileResult(row) } : undefined;
      },
    });
  }

  async deleteProfile(userId: string, profileId: string, mutationId: string, baseRevision: string): Promise<void> {
    await this.mutations.execute({
      userId,
      mutationId,
      entityType: 'profiles',
      operation: 'delete',
      entityId: profileId,
      expectedEntityId: profileId,
      baseRevision: BigInt(baseRevision),
      input: { profileId },
      write: async (tx) => {
        const deletedAt = new Date();
        const [row] = await tx.update(profiles).set({
          deletedAt,
          revision: sql`${profiles.revision} + 1`,
          lastMutationId: mutationId,
          updatedAt: deletedAt,
        }).where(and(
          eq(profiles.id, profileId),
          eq(profiles.userId, userId),
          eq(profiles.revision, BigInt(baseRevision)),
          isNull(profiles.deletedAt),
        )).returning();
        // The reminder choices for this person and for their medications'
        // routines have no use once they are gone.
        if (row) {
          const routines = await tx.select({ id: schedules.id }).from(schedules)
            .innerJoin(pills, eq(schedules.pillId, pills.id))
            .where(eq(pills.profileId, profileId));
          await tombstoneAccountSettings(tx, userId, [
            reminderPersonKey(profileId),
            ...routines.map((routine) => reminderRoutineKey(routine.id)),
          ]);
        }
        return row ? { revision: row.revision, entity: profileResult(row) } : undefined;
      },
      readCurrent: async (tx) => {
        const [row] = await tx.select().from(profiles).where(and(
          eq(profiles.id, profileId),
          eq(profiles.userId, userId),
        ));
        return row ? { revision: row.revision, entity: profileResult(row) } : undefined;
      },
    });
  }
}
