import type { ScheduleWindowFields } from '../schedules/schedule-windows.js';
import { usesScheduleWindows } from '../schedules/schedule-windows.js';

/**
 * The original snapshot. A schedule that is not an interval and has no start
 * or end date keeps writing exactly this shape, byte for byte.
 */
export interface ScheduleSnapshotV1 {
  version: 1;
  pillName: string;
  dosage: string | null;
  frequency: 'daily' | 'weekly' | 'custom' | 'prn';
  frequencyDays: number[] | null;
  hour: number | null;
  minute: number | null;
  timeZone: string;
  profileId: string;
  profileName: string;
}

/**
 * Version 3: every V1 field plus the interval and window fields. Version 2 is
 * reserved for the device-local snapshots the app writes (frequency 'local-v2').
 */
export interface ScheduleSnapshotV3 extends Omit<ScheduleSnapshotV1, 'version' | 'frequency'>, ScheduleWindowFields {
  version: 3;
  frequency: 'daily' | 'weekly' | 'custom' | 'interval';
}

export type ScheduleSnapshot = ScheduleSnapshotV1 | ScheduleSnapshotV3;

export type ScheduleSnapshotInput = Omit<ScheduleSnapshotV1, 'version' | 'frequencyDays' | 'frequency'> & {
  frequency: ScheduleSnapshotV1['frequency'] | 'interval';
  frequencyDays: number[] | null;
} & Partial<ScheduleWindowFields>;

/**
 * Builds the immutable snapshot for one occurrence: V1 unless the routine is an
 * interval or has a start or end date, then V3.
 */
export function createScheduleSnapshot(input: ScheduleSnapshotInput): ScheduleSnapshot {
  const frequencyDays = input.frequencyDays === null
    ? null
    : Object.freeze([...input.frequencyDays].sort((left, right) => left - right)) as unknown as number[];
  const base = {
    pillName: input.pillName,
    dosage: input.dosage,
    frequencyDays,
    hour: input.hour,
    minute: input.minute,
    timeZone: input.timeZone,
    profileId: input.profileId,
    profileName: input.profileName,
  };
  if (usesScheduleWindows(input)) {
    return Object.freeze({
      version: 3,
      ...base,
      frequency: input.frequency as ScheduleSnapshotV3['frequency'],
      everyDays: input.everyDays ?? null,
      anchorDate: input.anchorDate ?? null,
      startDate: input.startDate ?? null,
      endDate: input.endDate ?? null,
    });
  }
  return Object.freeze({
    version: 1,
    pillName: base.pillName,
    dosage: base.dosage,
    frequency: input.frequency as ScheduleSnapshotV1['frequency'],
    frequencyDays,
    hour: base.hour,
    minute: base.minute,
    timeZone: base.timeZone,
    profileId: base.profileId,
    profileName: base.profileName,
  });
}
