import { and, eq, isNull } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { TenantTransactionRunner } from '../../db/tenant-transaction.js';
import { medicationOccurrences, pills, profiles, schedules } from '../../db/schema.js';
import { ApiError } from '../shared/api-error.js';
import { ConflictError, ErrorCode, ResourceError } from '../shared/errors.js';
import { raiseUserMinimumClientBuild } from '../schedules/schedule-windows.js';
import {
  appendOccurrenceSyncChange,
  OccurrenceMaterializer,
  resolveLocalPlannedInstant,
} from './occurrence-materializer.js';
import { scheduledOccurrenceKey } from './occurrence-key.js';
import { createScheduleSnapshot } from './schedule-snapshot.js';
import type { MovedHistoryRequest } from './moved-history.schema.js';

export interface MovedHistoryItemResult {
  occurrenceId: string;
  occurrenceKey: string;
  stateVersion: string;
  created: boolean;
}

/**
 * Creates the past scheduled occurrences of care that moved from a device to
 * this server. It only inserts occurrences (append-only, keyed by the same
 * canonical occurrence key the materializer uses, so a dose the materializer
 * already produced is reused, never duplicated). The doses' history is then
 * recorded through the normal medication commands.
 */
export class MovedHistoryService {
  private readonly transactions: TenantTransactionRunner;
  private readonly materializer: OccurrenceMaterializer;

  constructor(db: Db) {
    this.transactions = new TenantTransactionRunner(db);
    this.materializer = new OccurrenceMaterializer(db);
  }

  execute(userId: string, request: MovedHistoryRequest): Promise<{ items: MovedHistoryItemResult[] }> {
    return this.transactions.run(userId, async (tx) => {
      // Produce the schedule's own occurrences first so a moved dose that
      // coincides with one of them (today's earlier dose) finds it by key, and
      // so the materializer's "latest date" cursor already sits past today.
      await this.materializer.materializeSchedule(tx, userId, request.scheduleId);

      const [joined] = await tx.select({ schedule: schedules, pill: pills, profile: profiles })
        .from(schedules)
        .innerJoin(pills, eq(schedules.pillId, pills.id))
        .innerJoin(profiles, eq(pills.profileId, profiles.id))
        .where(and(
          eq(schedules.id, request.scheduleId),
          eq(profiles.userId, userId),
          isNull(schedules.deletedAt),
          isNull(pills.deletedAt),
          isNull(profiles.deletedAt),
        ))
        .for('update');
      if (!joined) throw new ResourceError('Schedule not found', 404);
      const { schedule, pill, profile } = joined;
      if (schedule.frequency === 'prn' || schedule.timeZoneStatus !== 'known' || schedule.legacyQuarantineIssueId !== null) {
        throw new ConflictError('This schedule cannot receive past scheduled doses', request.scheduleId, ErrorCode.CONFLICT_REVISION);
      }

      const now = new Date();
      const results: MovedHistoryItemResult[] = [];
      let insertedVersion3 = false;
      for (const item of request.items) {
        const [hour, minute] = item.plannedLocalTime.split(':').map(Number) as [number, number];
        let plannedAt: Date;
        try {
          plannedAt = resolveLocalPlannedInstant(item.plannedLocalDate, hour, minute, item.timeZone);
        } catch {
          throw new ApiError(400, ErrorCode.VALIDATION_ERROR, 'A moved dose has an unresolvable planned time');
        }
        if (plannedAt.getTime() > now.getTime()) {
          throw new ApiError(400, ErrorCode.VALIDATION_ERROR, 'A moved dose cannot be planned in the future');
        }
        const occurrenceKey = scheduledOccurrenceKey({
          userId,
          scheduleId: schedule.id,
          scheduleRevision: schedule.revision,
          intendedLocalDate: item.plannedLocalDate,
          intendedLocalTime: item.plannedLocalTime,
          timeZone: item.timeZone,
          resolvedInstant: plannedAt,
        });

        // The id may be taken by a different occurrence: never retarget it.
        const [sameId] = await tx.select({ key: medicationOccurrences.occurrenceKey })
          .from(medicationOccurrences)
          .where(and(eq(medicationOccurrences.userId, userId), eq(medicationOccurrences.id, item.occurrenceId)));
        if (sameId && sameId.key !== occurrenceKey) {
          throw new ConflictError('Occurrence ID is already used by a different dose', item.occurrenceId, ErrorCode.CONFLICT_MUTATION_REUSE);
        }

        const snapshot = createScheduleSnapshot({
          pillName: pill.name,
          dosage: pill.dosage,
          frequency: item.routine.frequency,
          frequencyDays: item.routine.frequencyDays,
          everyDays: item.routine.everyDays,
          anchorDate: item.routine.anchorDate,
          startDate: item.routine.startDate,
          endDate: item.routine.endDate,
          hour,
          minute,
          timeZone: item.timeZone,
          profileId: profile.id,
          profileName: profile.name,
        });
        const [inserted] = await tx.insert(medicationOccurrences).values({
          id: item.occurrenceId,
          userId,
          pillId: pill.id,
          scheduleId: schedule.id,
          occurrenceKey,
          source: 'scheduled',
          scheduleRevision: schedule.revision,
          plannedLocalDate: item.plannedLocalDate,
          plannedLocalTime: item.plannedLocalTime,
          timeZone: item.timeZone,
          plannedAt,
          expected: true,
          snapshotVersion: snapshot.version,
          scheduleSnapshot: snapshot,
          provenance: 'exact',
          stateVersion: 0n,
        }).onConflictDoNothing({
          target: [medicationOccurrences.userId, medicationOccurrences.occurrenceKey],
        }).returning();
        if (inserted) {
          await appendOccurrenceSyncChange(tx, userId, inserted);
          if (inserted.snapshotVersion === 3) insertedVersion3 = true;
          results.push({
            occurrenceId: inserted.id,
            occurrenceKey: inserted.occurrenceKey,
            stateVersion: inserted.stateVersion.toString(),
            created: true,
          });
          continue;
        }
        const [existing] = await tx.select().from(medicationOccurrences).where(and(
          eq(medicationOccurrences.userId, userId),
          eq(medicationOccurrences.occurrenceKey, occurrenceKey),
        ));
        if (!existing) throw new Error('moved-history occurrence vanished after a key conflict');
        results.push({
          occurrenceId: existing.id,
          occurrenceKey: existing.occurrenceKey,
          stateVersion: existing.stateVersion.toString(),
          created: false,
        });
      }
      if (insertedVersion3) await raiseUserMinimumClientBuild(tx, userId);
      return { items: results };
    });
  }
}
