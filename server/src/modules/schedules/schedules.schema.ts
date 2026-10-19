import { z } from 'zod';

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

const IanaTimeZoneSchema = z.string().min(1).max(128).refine(
  isIanaTimeZone,
  'timeZone must be a supported IANA timezone',
);

function validateCompleteFrequency(
  data: { frequency: 'daily' | 'weekly' | 'custom' | 'prn'; frequencyDays: number[] | null },
  ctx: z.RefinementCtx,
): void {
  const days = data.frequencyDays;
  if (days && new Set(days).size !== days.length) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: 'frequencyDays must not contain duplicate weekdays',
      path: ['frequencyDays'],
    });
  }
  if ((data.frequency === 'daily' || data.frequency === 'prn') && days !== null) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: `${data.frequency} frequency requires frequencyDays to be null`,
      path: ['frequencyDays'],
    });
  }
  if (data.frequency === 'weekly' && (!days || days.length !== 1)) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: 'weekly frequency requires exactly one day in frequencyDays',
      path: ['frequencyDays'],
    });
  }
  if (data.frequency === 'custom' && (!days || days.length === 0)) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: 'custom frequency requires at least one day in frequencyDays',
      path: ['frequencyDays'],
    });
  }
}

const ScheduleDocumentFields = {
  hour: ScheduleTimeSchema.min(0).max(23),
  minute: ScheduleTimeSchema.min(0).max(59),
  frequency: z.enum(['daily', 'weekly', 'custom', 'prn']),
  frequencyDays: z.array(FrequencyDaySchema).nullable(),
  isActive: z.boolean(),
  timeZone: IanaTimeZoneSchema,
};

export const ScheduleDocumentSchema = z.object(ScheduleDocumentFields)
  .superRefine(validateCompleteFrequency);

export const CreateScheduleSchema = z.object({
  mutationId: z.guid(),
  id: z.guid().optional(),
  hour: ScheduleTimeSchema.min(0).max(23),
  minute: ScheduleTimeSchema.min(0).max(59),
  frequency: z.enum(['daily', 'weekly', 'custom', 'prn']),
  frequencyDays: z.array(FrequencyDaySchema).nullable().optional(),
  isActive: z.boolean().optional(),
  timeZone: IanaTimeZoneSchema,
}).strict().superRefine((data, ctx) => validateCompleteFrequency({
  frequency: data.frequency,
  frequencyDays: data.frequencyDays ?? null,
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
  frequency: z.enum(['daily', 'weekly', 'custom', 'prn']).optional(),
  frequencyDays: z.array(FrequencyDaySchema).nullable().optional(),
  isActive: z.boolean().optional(),
  timeZone: IanaTimeZoneSchema.optional(),
}).strict().refine((data) => [
  'hour', 'minute', 'frequency', 'frequencyDays', 'isActive', 'timeZone',
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

const LocalDateSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).refine((value) => {
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}, 'effectiveFromLocalDate must be a valid Gregorian date');

export const ScheduleRepairSchema = z.object({
  mutationId: z.guid(),
  baseRevision: z.string().refine(
    (value) => value.length <= 19 && /^[1-9]\d*$/.test(value)
      && BigInt(value) <= 9_223_372_036_854_775_807n,
    'baseRevision must be a positive signed-64 decimal string',
  ),
  effectiveFromLocalDate: LocalDateSchema,
  schedule: ScheduleDocumentSchema,
}).strict();

export type CreateScheduleRequest = z.infer<typeof CreateScheduleSchema>;
export type UpdateScheduleRequest = z.infer<typeof UpdateScheduleSchema>;
export type DeleteScheduleRequest = z.infer<typeof DeleteScheduleSchema>;
export type ScheduleRepairRequest = z.infer<typeof ScheduleRepairSchema>;
export type ScheduleDocument = z.infer<typeof ScheduleDocumentSchema>;
