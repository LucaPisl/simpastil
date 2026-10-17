import { and, eq, inArray, isNull, sql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { TenantTransactionRunner, type TenantTransaction } from '../../db/tenant-transaction.js';
import { migrationIssues, pills, profiles, schedules } from '../../db/schema.js';
import { EntityMutationService, type SafeMutationEntity } from '../entities/entity-mutation.service.js';
import { ApiError } from '../shared/api-error.js';
import { ErrorCode, ResourceError } from '../shared/errors.js';
import { appendScheduleSyncChange, appendSyncChange, OccurrenceMaterializer } from '../medication/occurrence-materializer.js';
import type { ScheduleRepairRequest } from './schedules.schema.js';

function scheduleResult(row: typeof schedules.$inferSelect): SafeMutationEntity {
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

export class ScheduleRepairService {
  private readonly transactions: TenantTransactionRunner;
  private readonly mutations: EntityMutationService;
  private readonly occurrences: OccurrenceMaterializer;

  constructor(db: Db) {
    this.transactions = new TenantTransactionRunner(db);
    this.mutations = new EntityMutationService(this.transactions);
    this.occurrences = new OccurrenceMaterializer(db);
  }

  async repair(
    userId: string,
    pillId: string,
    scheduleId: string,
    data: ScheduleRepairRequest,
  ): Promise<SafeMutationEntity> {
    const expectedRevision = BigInt(data.baseRevision);
    return this.mutations.execute({
      userId,
      mutationId: data.mutationId,
      entityType: 'schedules',
      operation: 'update',
      entityId: scheduleId,
      expectedEntityId: scheduleId,
      baseRevision: expectedRevision,
      input: { pillId, effectiveFromLocalDate: data.effectiveFromLocalDate, schedule: data.schedule },
      write: async (tx) => {
        const current = await this.readOwned(tx, userId, pillId, scheduleId, true);
        if (!current || current.revision !== expectedRevision) return undefined;
        if (current.legacyQuarantineIssueId === null && current.timezoneReviewIssueId === null) {
          throw new ApiError(409, ErrorCode.CONFLICT_REVISION, 'Schedule has no unresolved repair issue', {
            retryable: false,
          });
        }
        if (expectedRevision !== 1n || current.deletedAt !== null) {
          throw new ApiError(409, ErrorCode.CONFLICT_REVISION, 'Only an unresolved revision-1 schedule can be repaired', {
            retryable: false,
          });
        }

        const issueIds = [current.legacyQuarantineIssueId, current.timezoneReviewIssueId]
          .filter((id): id is string => id !== null);
        await tx.execute(sql`SELECT public.repair_legacy_schedule(
          ${userId}::uuid,
          ${scheduleId}::uuid,
          ${expectedRevision}::bigint,
          ${data.mutationId}::uuid,
          ${data.schedule.hour}::integer,
          ${data.schedule.minute}::integer,
          ${data.schedule.frequency}::text,
          ${data.schedule.frequencyDays}::integer[],
          ${data.schedule.isActive}::boolean,
          ${data.schedule.timeZone}::text,
          ${data.effectiveFromLocalDate}::date
        )`);

        const repaired = await this.readOwned(tx, userId, pillId, scheduleId, true);
        if (!repaired) throw new Error('Repaired schedule was not visible in its tenant transaction');
        const resolvedIssues = await tx.select().from(migrationIssues).where(and(
          eq(migrationIssues.userId, userId),
          inArray(migrationIssues.id, issueIds),
        ));
        for (const issue of resolvedIssues) {
          await appendSyncChange(tx, userId, {
            schemaVersion: 2,
            component: 'account',
            entityType: 'migration_issue',
            entityId: issue.id,
            operation: 'upsert',
            sourceIdentity: {
              sourceKind: 'migration_issue',
              sourceId: issue.id,
              sourceRevision: issue.revision.toString(),
            },
            payload: {
              kind: 'migrationIssue',
              id: issue.id,
              entityType: issue.entityType,
              entityId: issue.entityId,
              issueCode: issue.issueCode,
              safeSnapshot: issue.safeSnapshot,
              revision: issue.revision.toString(),
              state: issue.state,
              resolvedAt: issue.resolvedAt?.toISOString() ?? null,
              createdAt: issue.createdAt.toISOString(),
            },
          });
        }
        await appendScheduleSyncChange(tx, userId, repaired);
        await this.occurrences.materializeSchedule(tx, userId, scheduleId);
        await this.occurrences.supersedePriorFuture(tx, userId, scheduleId, repaired.revision);
        return { revision: repaired.revision, entity: scheduleResult(repaired) };
      },
      readCurrent: async (tx) => {
        const row = await this.readOwned(tx, userId, pillId, scheduleId, true);
        return row ? { revision: row.revision, entity: scheduleResult(row) } : undefined;
      },
    });
  }

  private async readOwned(
    tx: TenantTransaction,
    userId: string,
    pillId: string,
    scheduleId: string,
    lock = false,
  ) {
    const query = tx.select({ schedule: schedules })
      .from(schedules)
      .innerJoin(pills, eq(schedules.pillId, pills.id))
      .innerJoin(profiles, eq(pills.profileId, profiles.id))
      .where(and(
        eq(schedules.id, scheduleId),
        eq(schedules.pillId, pillId),
        eq(profiles.userId, userId),
        isNull(profiles.deletedAt),
        isNull(pills.deletedAt),
      ));
    const [row] = lock ? await query.for('update') : await query;
    if (!row) throw new ResourceError('Schedule not found', 404);
    return row.schedule;
  }
}
