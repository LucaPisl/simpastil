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

export function createScheduleSnapshot(input: Omit<ScheduleSnapshotV1, 'version' | 'frequencyDays'> & {
  frequencyDays: number[] | null;
}): ScheduleSnapshotV1 {
  const frequencyDays = input.frequencyDays === null
    ? null
    : Object.freeze([...input.frequencyDays].sort((left, right) => left - right)) as unknown as number[];
  return Object.freeze({
    version: 1,
    pillName: input.pillName,
    dosage: input.dosage,
    frequency: input.frequency,
    frequencyDays,
    hour: input.hour,
    minute: input.minute,
    timeZone: input.timeZone,
    profileId: input.profileId,
    profileName: input.profileName,
  });
}
