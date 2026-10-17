import { and, asc, desc, eq, gt, gte, inArray, isNull, lt, sql as drizzleSql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { doseLogs, schedules, pills, profiles } from '../../db/schema.js';
import { ErrorCode, ResourceError } from '../shared/errors.js';
import type {
  CreateDoseLogRequest,
  UpdateDoseLogRequest,
  LogsQuery,
} from './dose_logs.schema.js';

// Keep client replay windows (88 days) below this retention horizon.
export const DOSE_LOG_TOMBSTONE_RETENTION_DAYS = 90;

export class DoseLogsService {
  constructor(private readonly db: Db) {}

  /**
   * Asserts the profile belongs to the user (via RLS).
   */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private async assertProfileOwnership(tx: any, profileId: string): Promise<void> {
    const [row] = await tx
      .select({ id: profiles.id })
      .from(profiles)
      .where(eq(profiles.id, profileId));
    if (!row) throw new ResourceError('Profile not found', 404);
  }

  /** Split dose writes have no command receipt and are never accepted by the remediated API. */
  private rejectLegacySplitWrite(): never {
    throw new ResourceError(
      'Use the atomic medication bridge command for medication changes',
      409,
      ErrorCode.MEDICATION_BRIDGE_REQUIRED,
    );
  }

  async recordDose(
    userId: string,
    scheduleId: string,
    data: CreateDoseLogRequest,
  ) {
    void userId;
    void scheduleId;
    void data;
    this.rejectLegacySplitWrite();
  }

  async getLogs(userId: string, profileId: string, query: LogsQuery) {
    return this.db.transaction(async (tx) => {
      await tx.execute(
        drizzleSql`SELECT set_config('app.current_user_id', ${userId}, true)`,
      );
      await this.assertProfileOwnership(tx, profileId);

      const serverTime = new Date().toISOString();
      const limit = query.limit ?? 500;

      const scheduleSubquery = tx
        .select({ id: schedules.id })
        .from(schedules)
        .innerJoin(pills, eq(schedules.pillId, pills.id))
        .where(eq(pills.profileId, profileId));

      // ── Delta mode (since parameter) ──────────────────────────────────────
      if (query.since) {
        const sinceDate = new Date(query.since);
        const conditions = [
          inArray(doseLogs.scheduleId, scheduleSubquery),
          gt(doseLogs.updatedAt, sinceDate),
        ];

        if (query.cursor) {
          const sepIdx = query.cursor.lastIndexOf('_');
          if (sepIdx === -1) throw new ResourceError('Invalid cursor', 400);
          const cursorTimeStr = query.cursor.slice(0, sepIdx);
          const cursorId = query.cursor.slice(sepIdx + 1);
          if (isNaN(new Date(cursorTimeStr).getTime()) || !cursorId) {
            throw new ResourceError('Invalid cursor', 400);
          }
          conditions.push(
            drizzleSql`(date_trunc('milliseconds', ${doseLogs.updatedAt}), ${doseLogs.id}) > (${cursorTimeStr}::timestamptz, ${cursorId}::uuid)`,
          );
        }

        const rows = await tx
          .select()
          .from(doseLogs)
          .where(and(...conditions))
          .orderBy(drizzleSql`date_trunc('milliseconds', ${doseLogs.updatedAt}) ASC`, asc(doseLogs.id))
          .limit(limit);

        const nextCursor = rows.length >= limit
          ? `${rows[rows.length - 1]!.updatedAt.toISOString()}_${rows[rows.length - 1]!.id}`
          : null;

        return { logs: rows, nextCursor, serverTime };
      }

      // ── Legacy mode (date/from/to/offset) ─────────────────────────────────
      let fromDate: Date | undefined;
      let toDate: Date | undefined;

      if (query.date) {
        fromDate = new Date(`${query.date}T00:00:00.000Z`);
        const next = new Date(fromDate);
        next.setUTCDate(next.getUTCDate() + 1);
        toDate = next;
      } else if (query.from || query.to) {
        if (query.from) {
          fromDate = new Date(`${query.from}T00:00:00.000Z`);
        }
        if (query.to) {
          const to = new Date(`${query.to}T00:00:00.000Z`);
          to.setUTCDate(to.getUTCDate() + 1);
          toDate = to;
        }
      }

      const conditions = [
        inArray(doseLogs.scheduleId, scheduleSubquery),
        isNull(doseLogs.deletedAt),
        ...(fromDate ? [gte(doseLogs.scheduledAt, fromDate)] : []),
        ...(toDate ? [lt(doseLogs.scheduledAt, toDate)] : []),
      ];

      const rows = await tx
        .select()
        .from(doseLogs)
        .where(and(...conditions))
        .orderBy(desc(doseLogs.scheduledAt))
        .limit(limit)
        .offset(query.offset ?? 0);

      return { logs: rows, nextCursor: null, serverTime };
    });
  }

  async updateLog(
    userId: string,
    logId: string,
    data: UpdateDoseLogRequest,
  ) {
    void userId;
    void logId;
    void data;
    this.rejectLegacySplitWrite();
  }

  async deleteLog(userId: string, logId: string): Promise<void> {
    void userId;
    void logId;
    this.rejectLegacySplitWrite();
  }

  async purgeTombstones(maxAgeDays = DOSE_LOG_TOMBSTONE_RETENTION_DAYS): Promise<number> {
    const cutoff = new Date(Date.now() - maxAgeDays * 24 * 60 * 60 * 1000);
    const rows = await this.db
      .delete(doseLogs)
      .where(and(lt(doseLogs.deletedAt!, cutoff)))
      .returning({ id: doseLogs.id });
    return rows.length;
  }
}
