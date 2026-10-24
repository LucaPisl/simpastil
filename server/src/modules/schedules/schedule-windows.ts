import { eq, sql } from 'drizzle-orm';
import type { TenantTransaction } from '../../db/tenant-transaction.js';
import { users } from '../../db/schema.js';

/**
 * The first app build that understands interval schedules, start and end
 * dates, and version 3 occurrence snapshots. Builds up to 6 reject the
 * 'interval' frequency and snapshot version 3, so an account that stores
 * either is held to this build by the per-account client build gate.
 *
 * The deployment-wide minimum (`deployment_manifest`) is not touched: only
 * accounts that actually use the new shapes are asked to update.
 */
export const SCHEDULE_WINDOWS_MIN_CLIENT_BUILD = 7;

export const SCHEDULE_FREQUENCIES = ['daily', 'weekly', 'custom', 'interval', 'prn'] as const;
export type ScheduleFrequency = (typeof SCHEDULE_FREQUENCIES)[number];

/** The schedule fields that describe an every-N-days routine and its date window. */
export interface ScheduleWindowFields {
  everyDays: number | null;
  anchorDate: string | null;
  startDate: string | null;
  endDate: string | null;
}

/** True when a routine needs the interval or window fields (and so snapshot version 3). */
export function usesScheduleWindows(input: {
  frequency: string;
  everyDays?: number | null | undefined;
  anchorDate?: string | null | undefined;
  startDate?: string | null | undefined;
  endDate?: string | null | undefined;
}): boolean {
  return input.frequency === 'interval'
    || (input.everyDays ?? null) !== null
    || (input.anchorDate ?? null) !== null
    || (input.startDate ?? null) !== null
    || (input.endDate ?? null) !== null;
}

/**
 * Raises, never lowers, the account's minimum client build. Call it in the
 * transaction that writes data an older build cannot read.
 */
export async function raiseUserMinimumClientBuild(
  tx: TenantTransaction,
  userId: string,
  build: number = SCHEDULE_WINDOWS_MIN_CLIENT_BUILD,
): Promise<void> {
  await tx.update(users).set({
    minimumClientBuild: sql`GREATEST(${users.minimumClientBuild}, ${build})`,
  }).where(eq(users.id, userId));
}

const DAY_MS = 86_400_000;

function localDateEpoch(value: string): number {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) throw new TypeError('date must be YYYY-MM-DD');
  const date = new Date(0);
  date.setUTCFullYear(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
  date.setUTCHours(0, 0, 0, 0);
  return date.getTime();
}

/** Whole calendar days from `from` to `to` (negative when `to` is earlier). */
export function daysBetweenLocalDates(from: string, to: string): number {
  return Math.round((localDateEpoch(to) - localDateEpoch(from)) / DAY_MS);
}

/**
 * The interval rule shared with the client: a local date D matches when
 * D >= anchorDate and daysBetween(anchorDate, D) % everyDays == 0.
 */
export function intervalIncludes(everyDays: number, anchorDate: string, localDate: string): boolean {
  const offset = daysBetweenLocalDates(anchorDate, localDate);
  return offset >= 0 && offset % everyDays === 0;
}

/** The window rule shared with the client; both bounds are inclusive and optional. */
export function windowIncludes(
  window: { startDate: string | null; endDate: string | null },
  localDate: string,
): boolean {
  return (window.startDate === null || localDate >= window.startDate)
    && (window.endDate === null || localDate <= window.endDate);
}
