import { createHash } from 'node:crypto';

export interface ScheduledOccurrenceKeyInput {
  userId: string;
  scheduleId: string;
  scheduleRevision: bigint | string;
  intendedLocalDate: string;
  intendedLocalTime: string;
  timeZone: string;
  resolvedInstant: Date;
}

function canonicalUuid(value: string, field: string): string {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new TypeError(`${field} must be a UUID`);
  }
  return value.toLowerCase();
}

function assertLocalDate(value: string): void {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new TypeError('intendedLocalDate must be YYYY-MM-DD');
  const dateParts = value.split('-').map(Number);
  const year = dateParts[0]!;
  const month = dateParts[1]!;
  const day = dateParts[2]!;
  const date = new Date(0);
  date.setUTCFullYear(year, month - 1, day);
  date.setUTCHours(0, 0, 0, 0);
  if (year === 0 || date.toISOString().slice(0, 10) !== value) {
    throw new TypeError('intendedLocalDate must be a valid Gregorian date');
  }
}

function assertZone(value: string): void {
  if (!/^[A-Za-z0-9_+/-]{1,128}$/.test(value)) throw new TypeError('timeZone must be an IANA identifier');
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: value });
  } catch {
    throw new TypeError('timeZone must be a supported IANA identifier');
  }
}

export function canonicalLocalTime(hour: number, minute: number): string {
  if (!Number.isInteger(hour) || hour < 0 || hour > 23
      || !Number.isInteger(minute) || minute < 0 || minute > 59) {
    throw new RangeError('Scheduled local time is outside the supported day');
  }
  return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
}

export function scheduledOccurrenceKey(input: ScheduledOccurrenceKeyInput): string {
  const userId = canonicalUuid(input.userId, 'userId');
  const scheduleId = canonicalUuid(input.scheduleId, 'scheduleId');
  const scheduleRevision = String(input.scheduleRevision);
  if (!/^[1-9]\d{0,18}$/.test(scheduleRevision) || BigInt(scheduleRevision) > 9_223_372_036_854_775_807n) {
    throw new TypeError('scheduleRevision must be a canonical positive signed-64 decimal');
  }
  assertLocalDate(input.intendedLocalDate);
  if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(input.intendedLocalTime)) {
    throw new TypeError('intendedLocalTime must be canonical HH:mm');
  }
  assertZone(input.timeZone);
  if (!(input.resolvedInstant instanceof Date) || !Number.isFinite(input.resolvedInstant.getTime())) {
    throw new TypeError('resolvedInstant must be a valid instant');
  }

  const canonicalInput = [
    'simpastil-occurrence-key-v1',
    userId,
    scheduleId,
    scheduleRevision,
    input.intendedLocalDate,
    input.intendedLocalTime,
    input.timeZone,
    input.resolvedInstant.toISOString(),
  ].join('\n');
  const digest = createHash('sha256').update(canonicalInput, 'utf8').digest('hex');
  return `scheduled:v1:${digest}`;
}

export function prnOccurrenceKey(occurrenceId: string): string {
  return `prn:${canonicalUuid(occurrenceId, 'occurrenceId')}`;
}
