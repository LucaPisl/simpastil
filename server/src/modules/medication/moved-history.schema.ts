import { z } from 'zod';
import { IanaTimeZoneSchema, LocalDateSchema, validateScheduleShape } from '../schedules/schedules.schema.js';

const UuidSchema = z.guid();

/**
 * The shape a past dose was planned under. It feeds only the occurrence
 * snapshot, so it is validated like a schedule document minus the fields that
 * belong to the live schedule (time, zone, active flag). PRN has no planned
 * past dose and is rejected.
 */
export const MovedHistoryRoutineSchema = z.object({
  frequency: z.enum(['daily', 'weekly', 'custom', 'interval']),
  frequencyDays: z.array(z.number().int().min(1).max(7)).max(7).nullable().default(null),
  everyDays: z.number().int().min(1).max(36500).nullable().default(null),
  anchorDate: LocalDateSchema.nullable().default(null),
  startDate: LocalDateSchema.nullable().default(null),
  endDate: LocalDateSchema.nullable().default(null),
}).strict().superRefine(validateScheduleShape);

export const MovedHistoryItemSchema = z.object({
  occurrenceId: UuidSchema,
  plannedLocalDate: LocalDateSchema,
  plannedLocalTime: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/),
  timeZone: IanaTimeZoneSchema,
  routine: MovedHistoryRoutineSchema,
}).strict();

export const MovedHistoryRequestSchema = z.object({
  scheduleId: UuidSchema,
  items: z.array(MovedHistoryItemSchema).min(1).max(200),
}).strict();

export type MovedHistoryRequest = z.infer<typeof MovedHistoryRequestSchema>;
