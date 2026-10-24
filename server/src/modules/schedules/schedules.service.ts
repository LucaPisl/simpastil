import { randomUUID } from 'node:crypto';
import { and, eq, isNull, sql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { TenantTransactionRunner, type TenantTransaction } from '../../db/tenant-transaction.js';
import { pills, profiles, schedules } from '../../db/schema.js';
import { EntityMutationService } from '../entities/entity-mutation.service.js';
import { ApiError } from '../shared/api-error.js';
import { ErrorCode, ResourceError } from '../shared/errors.js';
import {
  appendScheduleSyncChange,
  localDateAt,
  OccurrenceMaterializer,
} from '../medication/occurrence-materializer.js';
import { raiseUserMinimumClientBuild, usesScheduleWindows } from './schedule-windows.js';
import { reminderRoutineKey } from '../account-settings/account-settings.schema.js';
import { tombstoneAccountSettings } from '../account-settings/account-settings.service.js';
import {
  ScheduleDocumentSchema,
  type CreateScheduleRequest,
  type ScheduleDocument,
  type UpdateScheduleRequest,
} from './schedules.schema.js';

function scheduleResult(row: typeof schedules.$inferSelect) {
  const {
    legacyQuarantineIssueId: _legacyQuarantineIssueId,
    legacyQuarantineOrigin: _legacyQuarantineOrigin,
    legacyQuarantineSource: _legacyQuarantineSource,
    timezoneReviewIssueId: _timezoneReviewIssueId,
    ...safeRow
  } = row;
  return {
    ...safeRow,
    revision: row.revision.toString(),
    deletedAt: row.deletedAt?.toISOString() ?? null,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

export class SchedulesService {
  private readonly transactions: TenantTransactionRunner;
  private readonly mutations: EntityMutationService;
  private readonly occurrences: OccurrenceMaterializer;

  constructor(db: Db) {
    this.transactions = new TenantTransactionRunner(db);
    this.mutations = new EntityMutationService(this.transactions);
    this.occurrences = new OccurrenceMaterializer(db);
  }

  private async assertPillOwnership(
    tx: TenantTransaction,
    userId: string,
    pillId: string,
  ): Promise<void> {
    const [row] = await tx
      .select({ id: pills.id })
      .from(pills)
      .innerJoin(profiles, eq(pills.profileId, profiles.id))
      .where(and(
        eq(pills.id, pillId),
        eq(profiles.userId, userId),
        isNull(profiles.deletedAt),
        isNull(pills.deletedAt),
      ));
    if (!row) throw new ResourceError('Pill not found', 404);
  }

  private async readOwnedSchedule(
    tx: TenantTransaction,
    userId: string,
    pillId: string,
    scheduleId: string,
    includeDeleted = false,
  ) {
    const [row] = await tx
      .select({ schedule: schedules })
      .from(schedules)
      .innerJoin(pills, eq(schedules.pillId, pills.id))
      .innerJoin(profiles, eq(pills.profileId, profiles.id))
      .where(and(
        eq(schedules.id, scheduleId),
        eq(schedules.pillId, pillId),
        eq(profiles.userId, userId),
        isNull(profiles.deletedAt),
        isNull(pills.deletedAt),
        ...(includeDeleted ? [] : [isNull(schedules.deletedAt)]),
      ));
    return row?.schedule;
  }

  async listSchedules(userId: string, pillId: string) {
    return this.transactions.run(userId, async (tx) => {
      await this.assertPillOwnership(tx, userId, pillId);
      const rows = await tx
        .select({ schedule: schedules })
        .from(schedules)
        .innerJoin(pills, eq(schedules.pillId, pills.id))
        .innerJoin(profiles, eq(pills.profileId, profiles.id))
        .where(and(
          eq(schedules.pillId, pillId),
          eq(profiles.userId, userId),
          isNull(profiles.deletedAt),
          isNull(pills.deletedAt),
        ));
      return rows.map(({ schedule }) => scheduleResult(schedule));
    });
  }

  async createSchedule(userId: string, pillId: string, data: CreateScheduleRequest) {
    const scheduleId = data.id ?? randomUUID();
    const document: ScheduleDocument = {
      hour: data.hour,
      minute: data.minute,
      frequency: data.frequency,
      frequencyDays: data.frequencyDays ?? null,
      everyDays: data.everyDays ?? null,
      anchorDate: data.anchorDate ?? null,
      startDate: data.startDate ?? null,
      endDate: data.endDate ?? null,
      isActive: data.isActive ?? true,
      timeZone: data.timeZone,
    };
    // The replay fingerprint covers the interval and window fields only when
    // the request used them, so a mutation sent before they existed keeps its
    // fingerprint and can still be replayed.
    const { everyDays, anchorDate, startDate, endDate, ...baseDocument } = document;
    const fingerprintInput = usesScheduleWindows(document)
      ? { ...baseDocument, everyDays, anchorDate, startDate, endDate }
      : baseDocument;

    return this.mutations.execute({
      userId,
      mutationId: data.mutationId,
      entityType: 'schedules',
      operation: 'create',
      entityId: scheduleId,
      ...(data.id ? { expectedEntityId: data.id } : {}),
      input: { pillId, requestedId: data.id ?? null, ...fingerprintInput },
      write: async (tx) => {
        await this.assertPillOwnership(tx, userId, pillId);
        const [row] = await tx.insert(schedules).values({
          id: scheduleId,
          pillId,
          ...document,
          revision: 1n,
          lastMutationId: data.mutationId,
        }).onConflictDoNothing({ target: schedules.id }).returning();
        if (row) {
          if (usesScheduleWindows(row)) await raiseUserMinimumClientBuild(tx, userId);
          await appendScheduleSyncChange(tx, userId, row);
          await this.occurrences.materializeSchedule(tx, userId, scheduleId);
        }
        return row ? { revision: row.revision, entity: scheduleResult(row) } : undefined;
      },
      readCurrent: async (tx) => {
        const row = await this.readOwnedSchedule(tx, userId, pillId, scheduleId, true);
        return row ? { revision: row.revision, entity: scheduleResult(row) } : undefined;
      },
    });
  }

  async updateSchedule(
    userId: string,
    pillId: string,
    scheduleId: string,
    data: UpdateScheduleRequest,
  ) {
    const { mutationId, baseRevision, ...patch } = data;
    const expectedRevision = BigInt(baseRevision);
    return this.mutations.execute({
      userId,
      mutationId,
      entityType: 'schedules',
      operation: 'update',
      entityId: scheduleId,
      expectedEntityId: scheduleId,
      baseRevision: expectedRevision,
      input: { pillId, ...patch },
      write: async (tx) => {
        await this.assertPillOwnership(tx, userId, pillId);
        const [current] = await tx
          .select()
          .from(schedules)
          .where(and(
            eq(schedules.id, scheduleId),
            eq(schedules.pillId, pillId),
            isNull(schedules.deletedAt),
          ))
          .for('update');
        if (!current || current.revision !== expectedRevision) return undefined;
        if (current.timeZoneStatus === 'legacy_unknown') {
          throw new ApiError(409, ErrorCode.SCHEDULE_TIMEZONE_REVIEW_REQUIRED,
            'Schedule timezone must be reviewed before editing', { retryable: false });
        }
        if (current.legacyQuarantineIssueId !== null) {
          throw new ApiError(409, ErrorCode.SCHEDULE_MIGRATION_REVIEW_REQUIRED,
            'Schedule migration data must be reviewed before editing', { retryable: false });
        }

        if (current.timeZone) {
          const throughLocalDate = localDateAt(new Date(), current.timeZone);
          await this.occurrences.materializeSchedule(tx, userId, scheduleId, throughLocalDate);
        }

        const merged = {
          hour: current.hour,
          minute: current.minute,
          frequency: current.frequency as ScheduleDocument['frequency'],
          frequencyDays: current.frequencyDays,
          everyDays: current.everyDays,
          anchorDate: current.anchorDate,
          startDate: current.startDate,
          endDate: current.endDate,
          isActive: current.isActive,
          timeZone: current.timeZone,
          ...patch,
        };
        const document = ScheduleDocumentSchema.parse(merged);
        const [row] = await tx.update(schedules).set({
          ...document,
          revision: sql`${schedules.revision} + 1`,
          lastMutationId: mutationId,
          updatedAt: new Date(),
        }).where(and(
          eq(schedules.id, scheduleId),
          eq(schedules.pillId, pillId),
          eq(schedules.revision, expectedRevision),
          isNull(schedules.deletedAt),
        )).returning();
        if (row) {
          if (usesScheduleWindows(row)) await raiseUserMinimumClientBuild(tx, userId);
          await appendScheduleSyncChange(tx, userId, row);
          await this.occurrences.materializeSchedule(tx, userId, scheduleId);
          await this.occurrences.supersedePriorFuture(tx, userId, scheduleId, row.revision);
        }
        return row ? { revision: row.revision, entity: scheduleResult(row) } : undefined;
      },
      readCurrent: async (tx) => {
        const row = await this.readOwnedSchedule(tx, userId, pillId, scheduleId, true);
        return row ? { revision: row.revision, entity: scheduleResult(row) } : undefined;
      },
    });
  }

  async deleteSchedule(
    userId: string,
    pillId: string,
    scheduleId: string,
    mutationId: string,
    baseRevision: string,
  ): Promise<void> {
    await this.mutations.execute({
      userId,
      mutationId,
      entityType: 'schedules',
      operation: 'delete',
      entityId: scheduleId,
      expectedEntityId: scheduleId,
      baseRevision: BigInt(baseRevision),
      input: { pillId },
      write: async (tx) => {
        await this.assertPillOwnership(tx, userId, pillId);
        const current = await this.readOwnedSchedule(tx, userId, pillId, scheduleId);
        if (!current || current.revision !== BigInt(baseRevision)) return undefined;
        if (current.timeZone) {
          const throughLocalDate = localDateAt(new Date(), current.timeZone);
          await this.occurrences.materializeSchedule(tx, userId, scheduleId, throughLocalDate);
        }
        const [row] = await tx.update(schedules).set({
          deletedAt: new Date(),
          revision: sql`${schedules.revision} + 1`,
          lastMutationId: mutationId,
          updatedAt: new Date(),
        }).where(and(
          eq(schedules.id, scheduleId),
          eq(schedules.pillId, pillId),
          eq(schedules.revision, BigInt(baseRevision)),
          isNull(schedules.deletedAt),
        )).returning();
        if (row) {
          await appendScheduleSyncChange(tx, userId, row);
          await this.occurrences.supersedePriorFuture(tx, userId, scheduleId, row.revision);
          // The reminder choice for this routine has no use once it is gone.
          await tombstoneAccountSettings(tx, userId, [reminderRoutineKey(scheduleId)]);
        }
        return row ? { revision: row.revision, entity: scheduleResult(row) } : undefined;
      },
      readCurrent: async (tx) => {
        const row = await this.readOwnedSchedule(tx, userId, pillId, scheduleId, true);
        return row ? { revision: row.revision, entity: scheduleResult(row) } : undefined;
      },
    });
  }
}
