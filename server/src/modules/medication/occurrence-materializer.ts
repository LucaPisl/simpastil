import { randomUUID } from 'node:crypto';
import { and, eq, gt, isNull, lt, notExists, sql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { TenantTransactionRunner, type TenantTransaction } from '../../db/tenant-transaction.js';
import {
  medicationOccurrences,
  occurrenceEvents,
  pills,
  profiles,
  schedules,
} from '../../db/schema.js';
import { appendSyncChange } from '../sync/sync-change-writer.js';
export { appendSyncChange } from '../sync/sync-change-writer.js';
import { ScheduleDocumentSchema } from '../schedules/schedules.schema.js';
import { canonicalLocalTime, prnOccurrenceKey, scheduledOccurrenceKey } from './occurrence-key.js';
import {
  intervalIncludes,
  raiseUserMinimumClientBuild,
  usesScheduleWindows,
  windowIncludes,
} from '../schedules/schedule-windows.js';
import { createScheduleSnapshot, type ScheduleSnapshot } from './schedule-snapshot.js';

const DAY_MS = 86_400_000;
const HOUR_MS = 3_600_000;
const UTC_PARTS_FORMATTERS = new Map<string, Intl.DateTimeFormat>();

export interface LocalDateTimeParts {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
}

export interface ScheduledOccurrenceSlot {
  occurrenceKey: string;
  plannedLocalDate: string;
  plannedLocalTime: string;
  timeZone: string;
  plannedAt: Date;
  scheduleSnapshot: ScheduleSnapshot;
}

export interface ScheduledOccurrenceSource {
  id: string;
  userId: string;
  revision: bigint;
  pillId: string;
  hour: number;
  minute: number;
  frequency: 'daily' | 'weekly' | 'custom' | 'interval' | 'prn';
  frequencyDays: number[] | null;
  // Optional so a caller that predates the interval and window fields still
  // type-checks; absent means null.
  everyDays?: number | null | undefined;
  anchorDate?: string | null | undefined;
  startDate?: string | null | undefined;
  endDate?: string | null | undefined;
  isActive: boolean;
  deletedAt: Date | null;
  legacyQuarantineIssueId: string | null;
  timeZoneStatus: 'known' | 'legacy_unknown';
  timeZone: string | null;
  materializeFromLocalDate: string | null;
  updatedAt: Date;
  pillName: string;
  dosage: string | null;
  profileId: string;
  profileName: string;
}

function utcEpoch(parts: Pick<LocalDateTimeParts, 'year' | 'month' | 'day' | 'hour' | 'minute' | 'second'>): number {
  const date = new Date(0);
  date.setUTCFullYear(parts.year, parts.month - 1, parts.day);
  date.setUTCHours(parts.hour, parts.minute, parts.second, 0);
  return date.getTime();
}

function formatterFor(timeZone: string): Intl.DateTimeFormat {
  let formatter = UTC_PARTS_FORMATTERS.get(timeZone);
  if (!formatter) {
    formatter = new Intl.DateTimeFormat('en-US', {
      timeZone,
      calendar: 'iso8601',
      numberingSystem: 'latn',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hourCycle: 'h23',
    });
    UTC_PARTS_FORMATTERS.set(timeZone, formatter);
  }
  return formatter;
}

export function localDateTimePartsAt(instant: Date, timeZone: string): LocalDateTimeParts {
  if (!Number.isFinite(instant.getTime())) throw new TypeError('instant must be valid');
  const parts = formatterFor(timeZone).formatToParts(instant);
  const values = new Map<Intl.DateTimeFormatPartTypes, string>(
    parts.map((part) => [part.type, part.value]),
  );
  const value = (name: Intl.DateTimeFormatPartTypes) => {
    const part = values.get(name);
    if (part === undefined) throw new TypeError(`timezone formatter omitted ${name}`);
    return Number(part);
  };
  return {
    year: value('year'),
    month: value('month'),
    day: value('day'),
    hour: value('hour') % 24,
    minute: value('minute'),
    second: value('second'),
  };
}

function formatLocalDate(parts: Pick<LocalDateTimeParts, 'year' | 'month' | 'day'>): string {
  return `${String(parts.year).padStart(4, '0')}-${String(parts.month).padStart(2, '0')}-${String(parts.day).padStart(2, '0')}`;
}

export function localDateAt(instant: Date, timeZone: string): string {
  return formatLocalDate(localDateTimePartsAt(instant, timeZone));
}

function parseLocalDate(value: string): { year: number; month: number; day: number } {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new TypeError('date must be YYYY-MM-DD');
  const dateParts = value.split('-').map(Number);
  const year = dateParts[0]!;
  const month = dateParts[1]!;
  const day = dateParts[2]!;
  const epoch = utcEpoch({ year, month, day, hour: 0, minute: 0, second: 0 });
  if (year === 0 || new Date(epoch).toISOString().slice(0, 10) !== value) {
    throw new TypeError('date must be a valid Gregorian date');
  }
  return { year, month, day };
}

export function addLocalDays(value: string, amount: number): string {
  if (!Number.isSafeInteger(amount)) throw new TypeError('day offset must be a safe integer');
  const parts = parseLocalDate(value);
  const date = new Date(utcEpoch({ ...parts, hour: 0, minute: 0, second: 0 }) + amount * DAY_MS);
  return formatLocalDate({ year: date.getUTCFullYear(), month: date.getUTCMonth() + 1, day: date.getUTCDate() });
}

function localTimelineAt(instantMs: number, timeZone: string): number {
  const secondAligned = Math.floor(instantMs / 1000) * 1000;
  return utcEpoch(localDateTimePartsAt(new Date(secondAligned), timeZone));
}

function offsetAt(instantMs: number, timeZone: string): number {
  const secondAligned = Math.floor(instantMs / 1000) * 1000;
  return localTimelineAt(secondAligned, timeZone) - secondAligned;
}

function sameLocalMinute(left: LocalDateTimeParts, right: LocalDateTimeParts): boolean {
  return left.year === right.year && left.month === right.month && left.day === right.day
    && left.hour === right.hour && left.minute === right.minute;
}

function firstInstantAfterGap(
  intendedLocalEpoch: number,
  timeZone: string,
  samples: Array<{ instant: number; offset: number }>,
): Date | undefined {
  for (let index = 1; index < samples.length; index += 1) {
    const before = samples[index - 1]!;
    const after = samples[index]!;
    if (after.offset <= before.offset) continue;

    let low = before.instant;
    let high = after.instant;
    while (high - low > 1000) {
      const middle = Math.floor((low + high) / 2000) * 1000;
      if (offsetAt(middle, timeZone) === before.offset) low = middle;
      else high = middle;
    }
    const transition = high;
    const oldLocalEnd = transition + before.offset;
    const newLocalStart = transition + after.offset;
    if (intendedLocalEpoch >= oldLocalEnd && intendedLocalEpoch < newLocalStart) {
      return new Date(transition);
    }
  }
  return undefined;
}

/** Resolve a wall-clock slot without consulting the process timezone. */
export function resolveLocalPlannedInstant(
  localDate: string,
  hour: number,
  minute: number,
  timeZone: string,
): Date {
  const date = parseLocalDate(localDate);
  if (!Number.isInteger(hour) || hour < 0 || hour > 23
      || !Number.isInteger(minute) || minute < 0 || minute > 59) {
    throw new RangeError('scheduled local time is outside the supported day');
  }
  const intended = { ...date, hour, minute, second: 0 };
  const intendedEpoch = utcEpoch(intended);
  const samples: Array<{ instant: number; offset: number }> = [];
  const offsets = new Set<number>();
  for (let instant = intendedEpoch - 48 * HOUR_MS; instant <= intendedEpoch + 48 * HOUR_MS; instant += 3 * HOUR_MS) {
    const offset = offsetAt(instant, timeZone);
    samples.push({ instant, offset });
    offsets.add(offset);
  }

  const candidates = [...offsets]
    .map((offset) => intendedEpoch - offset)
    .filter((candidate) => sameLocalMinute(localDateTimePartsAt(new Date(candidate), timeZone), intended))
    .sort((left, right) => left - right);
  if (candidates.length > 0) return new Date(candidates[0]!);

  const gapInstant = firstInstantAfterGap(intendedEpoch, timeZone, samples);
  if (gapInstant) return gapInstant;
  throw new RangeError(`could not resolve local time in ${timeZone}`);
}

function isoWeekday(localDate: string): number {
  const { year, month, day } = parseLocalDate(localDate);
  const dayIndex = new Date(utcEpoch({ year, month, day, hour: 0, minute: 0, second: 0 })).getUTCDay();
  return dayIndex === 0 ? 7 : dayIndex;
}

export function calculateScheduledOccurrenceSlots(
  source: ScheduledOccurrenceSource,
  userId: string,
  fromLocalDate: string,
  throughLocalDate: string,
): ScheduledOccurrenceSlot[] {
  if (!source.isActive || source.deletedAt || source.legacyQuarantineIssueId
      || source.timeZoneStatus !== 'known' || !source.timeZone || source.frequency === 'prn') return [];
  const document = ScheduleDocumentSchema.parse({
    hour: source.hour,
    minute: source.minute,
    frequency: source.frequency,
    frequencyDays: source.frequencyDays,
    everyDays: source.everyDays ?? null,
    anchorDate: source.anchorDate ?? null,
    startDate: source.startDate ?? null,
    endDate: source.endDate ?? null,
    isActive: source.isActive,
    timeZone: source.timeZone,
  });
  let start = source.materializeFromLocalDate && source.materializeFromLocalDate > fromLocalDate
    ? source.materializeFromLocalDate
    : fromLocalDate;
  // No dose before the start date or after the end date.
  if (document.startDate !== null && document.startDate > start) start = document.startDate;
  const through = document.endDate !== null && document.endDate < throughLocalDate
    ? document.endDate
    : throughLocalDate;
  if (through < start) return [];
  let current = start;
  const slots: ScheduledOccurrenceSlot[] = [];
  while (current <= through) {
    const weekday = isoWeekday(current);
    const matches = windowIncludes(document, current) && (
      document.frequency === 'daily'
      || (document.frequency === 'weekly' && document.frequencyDays?.includes(weekday) === true)
      || (document.frequency === 'custom' && document.frequencyDays?.includes(weekday) === true)
      || (document.frequency === 'interval'
        && document.everyDays !== null && document.anchorDate !== null
        && intervalIncludes(document.everyDays, document.anchorDate, current)));
    if (matches) {
      const localTime = canonicalLocalTime(document.hour, document.minute);
      const plannedAt = resolveLocalPlannedInstant(current, document.hour, document.minute, document.timeZone);
      slots.push({
        occurrenceKey: scheduledOccurrenceKey({
          userId,
          scheduleId: source.id,
          scheduleRevision: source.revision,
          intendedLocalDate: current,
          intendedLocalTime: localTime,
          timeZone: document.timeZone,
          resolvedInstant: plannedAt,
        }),
        plannedLocalDate: current,
        plannedLocalTime: `${localTime}:00`,
        timeZone: document.timeZone,
        plannedAt,
        scheduleSnapshot: createScheduleSnapshot({
          pillName: source.pillName,
          dosage: source.dosage,
          frequency: document.frequency,
          frequencyDays: document.frequencyDays,
          everyDays: document.everyDays,
          anchorDate: document.anchorDate,
          startDate: document.startDate,
          endDate: document.endDate,
          hour: document.hour,
          minute: document.minute,
          timeZone: document.timeZone,
          profileId: source.profileId,
          profileName: source.profileName,
        }),
      });
    }
    current = addLocalDays(current, 1);
  }
  return slots;
}

export async function appendScheduleSyncChange(
  tx: TenantTransaction,
  userId: string,
  row: typeof schedules.$inferSelect,
): Promise<bigint> {
  const revision = row.revision.toString();
  const operation = row.deletedAt ? 'tombstone' : 'upsert';
  const payload = operation === 'tombstone'
    ? {
      kind: 'tombstone',
      entityType: 'schedule',
      id: row.id,
      revision,
      deletedAt: row.deletedAt!.toISOString(),
    }
    : {
      kind: 'schedule',
      id: row.id,
      pillId: row.pillId,
      hour: row.hour,
      minute: row.minute,
      frequency: row.frequency,
      frequencyDays: row.frequencyDays,
      // The interval and window keys appear only when the schedule uses them,
      // so every other schedule keeps producing today's exact payload.
      ...(usesScheduleWindows(row) ? {
        everyDays: row.everyDays,
        anchorDate: row.anchorDate,
        startDate: row.startDate,
        endDate: row.endDate,
      } : {}),
      isActive: row.isActive,
      revision,
      timeZoneStatus: row.timeZoneStatus,
      timeZone: row.timeZone,
      deletedAt: null,
      createdAt: row.createdAt.toISOString(),
      updatedAt: row.updatedAt.toISOString(),
    };
  return appendSyncChange(tx, userId, {
    schemaVersion: 2,
    component: 'stable',
    entityType: 'schedule',
    entityId: row.id,
    operation,
    sourceIdentity: { sourceKind: 'schedule', sourceId: row.id, sourceRevision: revision },
    payload,
  });
}

export async function appendOccurrenceSyncChange(
  tx: TenantTransaction,
  userId: string,
  row: typeof medicationOccurrences.$inferSelect,
): Promise<bigint> {
  return appendSyncChange(tx, userId, {
    schemaVersion: 2,
    component: 'medication',
    entityType: 'medication_occurrence',
    entityId: row.id,
    operation: 'upsert',
    sourceIdentity: {
      sourceKind: 'occurrence',
      sourceId: row.id,
      sourceRevision: (row.stateVersion + 1n).toString(),
    },
    payload: {
      kind: 'medicationOccurrence',
      id: row.id,
      pillId: row.pillId,
      scheduleId: row.scheduleId,
      occurrenceKey: row.occurrenceKey,
      source: row.source,
      scheduleRevision: row.scheduleRevision?.toString() ?? null,
      plannedLocalDate: row.plannedLocalDate,
      plannedLocalTime: row.plannedLocalTime,
      timeZone: row.timeZone,
      plannedAt: row.plannedAt?.toISOString() ?? null,
      expected: row.expected,
      snapshotVersion: row.snapshotVersion,
      scheduleSnapshot: row.scheduleSnapshot,
      provenance: row.provenance,
      supersededAt: row.supersededAt?.toISOString() ?? null,
      supersededByOccurrenceId: row.supersededByOccurrenceId,
      stateVersion: row.stateVersion.toString(),
    },
  });
}

export class OccurrenceMaterializer {
  private readonly transactions: TenantTransactionRunner;

  constructor(db: Db) {
    this.transactions = new TenantTransactionRunner(db);
  }

  async ensureWindow(userId: string, throughLocalDate?: string): Promise<number> {
    return this.transactions.run(userId, (tx) => this.ensureWindowInTransaction(tx, userId, throughLocalDate));
  }

  async ensureWindowInTransaction(
    tx: TenantTransaction,
    userId: string,
    throughLocalDate?: string,
  ): Promise<number> {
    const scheduleIds = await tx.select({ id: schedules.id })
      .from(schedules)
      .innerJoin(pills, eq(schedules.pillId, pills.id))
      .innerJoin(profiles, eq(pills.profileId, profiles.id))
      .where(and(eq(profiles.userId, userId), isNull(profiles.deletedAt), isNull(pills.deletedAt), isNull(schedules.deletedAt)));
    let created = 0;
    for (const { id } of scheduleIds) {
      created += (await this.materializeSchedule(tx, userId, id, throughLocalDate)).length;
    }
    return created;
  }

  async materializeSchedule(
    tx: TenantTransaction,
    userId: string,
    scheduleId: string,
    throughLocalDate?: string,
  ): Promise<Array<typeof medicationOccurrences.$inferSelect>> {
    const [joined] = await tx.select({ schedule: schedules, pill: pills, profile: profiles })
      .from(schedules)
      .innerJoin(pills, eq(schedules.pillId, pills.id))
      .innerJoin(profiles, eq(pills.profileId, profiles.id))
      .where(and(eq(schedules.id, scheduleId), eq(profiles.userId, userId)))
      .for('update');
    if (!joined) return [];

    const schedule = joined.schedule;
    const source: ScheduledOccurrenceSource = {
      id: schedule.id,
      userId,
      revision: schedule.revision,
      pillId: schedule.pillId,
      hour: schedule.hour,
      minute: schedule.minute,
      frequency: schedule.frequency as ScheduledOccurrenceSource['frequency'],
      frequencyDays: schedule.frequencyDays,
      everyDays: schedule.everyDays,
      anchorDate: schedule.anchorDate,
      startDate: schedule.startDate,
      endDate: schedule.endDate,
      isActive: schedule.isActive,
      deletedAt: schedule.deletedAt,
      legacyQuarantineIssueId: schedule.legacyQuarantineIssueId,
      timeZoneStatus: schedule.timeZoneStatus as ScheduledOccurrenceSource['timeZoneStatus'],
      timeZone: schedule.timeZone,
      materializeFromLocalDate: schedule.materializeFromLocalDate,
      updatedAt: schedule.updatedAt,
      pillName: joined.pill.name,
      dosage: joined.pill.dosage,
      profileId: joined.profile.id,
      profileName: joined.profile.name,
    };
    if (!source.isActive || source.deletedAt || source.legacyQuarantineIssueId
        || source.timeZoneStatus !== 'known' || !source.timeZone || source.frequency === 'prn') return [];

    const today = localDateAt(new Date(), source.timeZone);
    const through = throughLocalDate ?? addLocalDays(today, 30);
    parseLocalDate(through);
    const [latest] = await tx.select({
      date: sql<string | null>`max(${medicationOccurrences.plannedLocalDate})`,
    }).from(medicationOccurrences).where(and(
      eq(medicationOccurrences.userId, userId),
      eq(medicationOccurrences.scheduleId, scheduleId),
      eq(medicationOccurrences.scheduleRevision, schedule.revision),
      eq(medicationOccurrences.source, 'scheduled'),
    ));
    const revisionStart = localDateAt(schedule.updatedAt, source.timeZone);
    const startFloor = source.materializeFromLocalDate ?? revisionStart;
    const firstMissing = latest?.date ? addLocalDays(latest.date, 1) : startFloor;
    const start = firstMissing > startFloor ? firstMissing : startFloor;
    if (through < start) return [];

    const slots = calculateScheduledOccurrenceSlots(source, userId, start, through);
    const created: Array<typeof medicationOccurrences.$inferSelect> = [];
    for (const slot of slots) {
      const [row] = await tx.insert(medicationOccurrences).values({
        id: randomUUID(),
        userId,
        pillId: source.pillId,
        scheduleId,
        occurrenceKey: slot.occurrenceKey,
        source: 'scheduled',
        scheduleRevision: schedule.revision,
        plannedLocalDate: slot.plannedLocalDate,
        plannedLocalTime: slot.plannedLocalTime,
        timeZone: slot.timeZone,
        plannedAt: slot.plannedAt,
        expected: true,
        snapshotVersion: slot.scheduleSnapshot.version,
        scheduleSnapshot: slot.scheduleSnapshot,
        provenance: 'exact',
        stateVersion: 0n,
      }).onConflictDoNothing({
        target: [medicationOccurrences.userId, medicationOccurrences.occurrenceKey],
      }).returning();
      if (row) {
        created.push(row);
        await appendOccurrenceSyncChange(tx, userId, row);
      }
    }
    // A version 3 snapshot needs a build that can read it; hold the account to
    // it in the same transaction that wrote the rows.
    if (created.some((row) => row.snapshotVersion === 3)) await raiseUserMinimumClientBuild(tx, userId);
    return created;
  }

  async supersedePriorFuture(
    tx: TenantTransaction,
    userId: string,
    scheduleId: string,
    newRevision: bigint,
    now = new Date(),
  ): Promise<number> {
    const oldRows = await tx.select().from(medicationOccurrences).where(and(
      eq(medicationOccurrences.userId, userId),
      eq(medicationOccurrences.scheduleId, scheduleId),
      lt(medicationOccurrences.scheduleRevision, newRevision),
      eq(medicationOccurrences.source, 'scheduled'),
      eq(medicationOccurrences.expected, true),
      eq(medicationOccurrences.stateVersion, 0n),
      isNull(medicationOccurrences.supersededAt),
      gt(medicationOccurrences.plannedAt, now),
      notExists(tx.select({ id: occurrenceEvents.id }).from(occurrenceEvents).where(and(
        eq(occurrenceEvents.userId, userId),
        eq(occurrenceEvents.occurrenceId, medicationOccurrences.id),
      ))),
    ));
    if (oldRows.length === 0) return 0;

    const replacements = await tx.select({ id: medicationOccurrences.id, date: medicationOccurrences.plannedLocalDate })
      .from(medicationOccurrences)
      .where(and(
        eq(medicationOccurrences.userId, userId),
        eq(medicationOccurrences.scheduleId, scheduleId),
        eq(medicationOccurrences.scheduleRevision, newRevision),
        eq(medicationOccurrences.source, 'scheduled'),
        eq(medicationOccurrences.expected, true),
      ));
    const byDate = new Map(replacements.map((row) => [row.date, row.id]));
    let changed = 0;
    for (const oldRow of oldRows) {
      const [row] = await tx.update(medicationOccurrences).set({
        supersededAt: now,
        supersededByOccurrenceId: byDate.get(oldRow.plannedLocalDate) ?? null,
        stateVersion: sql`${medicationOccurrences.stateVersion} + 1`,
      }).where(and(
        eq(medicationOccurrences.id, oldRow.id),
        eq(medicationOccurrences.userId, userId),
        eq(medicationOccurrences.stateVersion, 0n),
        isNull(medicationOccurrences.supersededAt),
      )).returning();
      if (row) {
        changed += 1;
        await appendOccurrenceSyncChange(tx, userId, row);
      }
    }
    return changed;
  }
}

export { prnOccurrenceKey };
