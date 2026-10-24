import { z } from 'zod';
import { SCHEDULE_FREQUENCIES } from './schedule-windows.js';

const FrequencyDaySchema = z.number().int().min(1).max(7);
const ScheduleTimeSchema = z.number().int().finite();

function isIanaTimeZone(value: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: value });
    return true;
  } catch {
    return false;
  }
}

export const IanaTimeZoneSchema = z.string().min(1).max(128).refine(
  isIanaTimeZone,
  'timeZone must be a supported IANA timezone',
);

export const ScheduleFrequencySchema = z.enum(SCHEDULE_FREQUENCIES);

/** A valid Gregorian local date, `YYYY-MM-DD`, from year 0001. */
export const LocalDateSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).refine((value) => {
  if (value.startsWith('0000-')) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}, 'must be a valid Gregorian date (YYYY-MM-DD)');

const EveryDaysSchema = z.number().int().min(1).max(36500);

/** The fields that decide which local dates a routine covers. */
export interface ScheduleShape {
  frequency: 'daily' | 'weekly' | 'custom' | 'interval' | 'prn';
  frequencyDays: number[] | null;
  everyDays: number | null;
  anchorDate: string | null;
  startDate: string | null;
  endDate: string | null;
}

/**
 * Cross-field rules for a complete routine. Shared by the schedule document,
 * the create request and the moved-history routine so they cannot drift.
 */
export function validateScheduleShape(data: ScheduleShape, ctx: z.RefinementCtx): void {
  const days = data.frequencyDays;
  const issue = (message: string, path: string) => ctx.addIssue({
    code: z.ZodIssueCode.custom,
    message,
    path: [path],
  });
  if (days && new Set(days).size !== days.length) {
    issue('frequencyDays must not contain duplicate weekdays', 'frequencyDays');
  }
  if ((data.frequency === 'daily' || data.frequency === 'interval' || data.frequency === 'prn')
      && days !== null) {
    issue(`${data.frequency} frequency requires frequencyDays to be null`, 'frequencyDays');
  }
  if (data.frequency === 'weekly' && (!days || days.length !== 1)) {
    issue('weekly frequency requires exactly one day in frequencyDays', 'frequencyDays');
  }
  if (data.frequency === 'custom' && (!days || days.length === 0)) {
    issue('custom frequency requires at least one day in frequencyDays', 'frequencyDays');
  }
  if (data.frequency === 'interval') {
    if (data.everyDays === null) issue('interval frequency requires everyDays', 'everyDays');
    if (data.anchorDate === null) issue('interval frequency requires anchorDate', 'anchorDate');
  } else {
    if (data.everyDays !== null) issue('everyDays is valid only for the interval frequency', 'everyDays');
    if (data.anchorDate !== null) issue('anchorDate is valid only for the interval frequency', 'anchorDate');
  }
  if (data.frequency === 'prn') {
    if (data.startDate !== null) issue('prn schedules cannot have a startDate', 'startDate');
    if (data.endDate !== null) issue('prn schedules cannot have an endDate', 'endDate');
  }
  if (data.startDate !== null && data.endDate !== null && data.endDate < data.startDate) {
    issue('endDate must not be before startDate', 'endDate');
  }
}

// The interval and window fields default to null so a document written before
// they existed (a stored row, an older client's request) stays valid.
const ScheduleDocumentFields = {
  hour: ScheduleTimeSchema.min(0).max(23),
  minute: ScheduleTimeSchema.min(0).max(59),
  frequency: ScheduleFrequencySchema,
  frequencyDays: z.array(FrequencyDaySchema).nullable(),
  everyDays: EveryDaysSchema.nullable().default(null),
  anchorDate: LocalDateSchema.nullable().default(null),
  startDate: LocalDateSchema.nullable().default(null),
  endDate: LocalDateSchema.nullable().default(null),
  isActive: z.boolean(),
  timeZone: IanaTimeZoneSchema,
};

export const ScheduleDocumentSchema = z.object(ScheduleDocumentFields)
  .superRefine(validateScheduleShape);

/**
 * Legacy repair restores a quarantined revision-1 schedule through a database
 * function that only knows the original four frequencies and no date window.
 * Interval routines and windows are set with an ordinary edit afterwards.
 */
export const LegacyRepairDocumentSchema = ScheduleDocumentSchema.superRefine((data, ctx) => {
  if (data.frequency === 'interval') {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: 'a legacy repair cannot use the interval frequency; edit the schedule afterwards',
      path: ['frequency'],
    });
  }
  for (const key of ['startDate', 'endDate'] as const) {
    if (data[key] !== null) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `a legacy repair cannot set ${key}; edit the schedule afterwards`,
        path: [key],
      });
    }
  }
});

export const CreateScheduleSchema = z.object({
  mutationId: z.guid(),
  id: z.guid().optional(),
  hour: ScheduleTimeSchema.min(0).max(23),
  minute: ScheduleTimeSchema.min(0).max(59),
  frequency: ScheduleFrequencySchema,
  frequencyDays: z.array(FrequencyDaySchema).nullable().optional(),
  everyDays: EveryDaysSchema.nullable().optional(),
  anchorDate: LocalDateSchema.nullable().optional(),
  startDate: LocalDateSchema.nullable().optional(),
  endDate: LocalDateSchema.nullable().optional(),
  isActive: z.boolean().optional(),
  timeZone: IanaTimeZoneSchema,
}).strict().superRefine((data, ctx) => validateScheduleShape({
  frequency: data.frequency,
  frequencyDays: data.frequencyDays ?? null,
  everyDays: data.everyDays ?? null,
  anchorDate: data.anchorDate ?? null,
  startDate: data.startDate ?? null,
  endDate: data.endDate ?? null,
}, ctx));

export const UpdateScheduleSchema = z.object({
  mutationId: z.guid(),
  baseRevision: z.string().refine(
    (value) => value.length <= 19 && /^[1-9]\d*$/.test(value)
      && BigInt(value) <= 9_223_372_036_854_775_807n,
    'baseRevision must be a positive signed-64 decimal string',
  ),
  hour: ScheduleTimeSchema.min(0).max(23).optional(),
  minute: ScheduleTimeSchema.min(0).max(59).optional(),
  frequency: ScheduleFrequencySchema.optional(),
  frequencyDays: z.array(FrequencyDaySchema).nullable().optional(),
  // An explicit null clears the field; an absent key leaves it unchanged.
  everyDays: EveryDaysSchema.nullable().optional(),
  anchorDate: LocalDateSchema.nullable().optional(),
  startDate: LocalDateSchema.nullable().optional(),
  endDate: LocalDateSchema.nullable().optional(),
  isActive: z.boolean().optional(),
  timeZone: IanaTimeZoneSchema.optional(),
}).strict().refine((data) => [
  'hour', 'minute', 'frequency', 'frequencyDays', 'everyDays', 'anchorDate',
  'startDate', 'endDate', 'isActive', 'timeZone',
].some((key) => data[key as keyof typeof data] !== undefined), {
  message: 'At least one schedule field is required',
}).superRefine((data, ctx) => {
  if (data.frequencyDays && new Set(data.frequencyDays).size !== data.frequencyDays.length) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: 'frequencyDays must not contain duplicate weekdays',
      path: ['frequencyDays'],
    });
  }
});

export const DeleteScheduleSchema = z.object({
  mutationId: z.guid(),
  baseRevision: z.string().refine(
    (value) => value.length <= 19 && /^[1-9]\d*$/.test(value)
      && BigInt(value) <= 9_223_372_036_854_775_807n,
    'baseRevision must be a positive signed-64 decimal string',
  ),
}).strict();

export const ScheduleRepairSchema = z.object({
  mutationId: z.guid(),
  baseRevision: z.string().refine(
    (value) => value.length <= 19 && /^[1-9]\d*$/.test(value)
      && BigInt(value) <= 9_223_372_036_854_775_807n,
    'baseRevision must be a positive signed-64 decimal string',
  ),
  effectiveFromLocalDate: LocalDateSchema,
  schedule: LegacyRepairDocumentSchema,
}).strict();

export type CreateScheduleRequest = z.infer<typeof CreateScheduleSchema>;
export type UpdateScheduleRequest = z.infer<typeof UpdateScheduleSchema>;
export type DeleteScheduleRequest = z.infer<typeof DeleteScheduleSchema>;
export type ScheduleRepairRequest = z.infer<typeof ScheduleRepairSchema>;
export type ScheduleDocument = z.infer<typeof ScheduleDocumentSchema>;
