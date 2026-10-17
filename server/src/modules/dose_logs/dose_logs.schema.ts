import { z } from 'zod';
import { IsoDateSchema } from '../../lib/iso-date.js';
import { createPaginationSchema } from '../../lib/pagination.js';

export const CreateDoseLogSchema = z.object({
  id: z.string().uuid().optional(),
  scheduledAt: z.string().datetime({ offset: true }),
  takenAt: z.string().datetime({ offset: true }).optional(),
  status: z.enum(['taken', 'missed', 'skipped']),
  note: z.string().max(500).nullable().optional(),
});

export const UpdateDoseLogSchema = z
  .object({
    takenAt: z.string().datetime({ offset: true }).nullable().optional(),
    status: z.enum(['taken', 'missed', 'skipped']).optional(),
    note: z.string().max(500).nullable().optional(),
    updatedAt: z.string().datetime({ offset: true }).optional(),
  })
  .refine((d) => Object.values(d).some((v) => v !== undefined), {
    message: 'At least one field required',
  });

export const LogsQuerySchema = z
  .object({
    date: IsoDateSchema.optional(),
    from: IsoDateSchema.optional(),
    to: IsoDateSchema.optional(),
    since: z.string().datetime({ offset: true }).optional(),
    cursor: z.string().optional(),
  })
  .extend(createPaginationSchema({ maxLimit: 1000 }).shape)
  .refine(
    (d) => !(d.date && (d.from || d.to)),
    { message: '?date cannot be combined with ?from or ?to' },
  )
  .refine(
    (d) => !(d.since && (d.date || d.from || d.to || d.offset !== undefined)),
    { message: '?since cannot be combined with ?date, ?from, ?to, or ?offset' },
  )
  .refine(
    (d) => !(d.cursor && !d.since),
    { message: '?cursor requires ?since' },
  )
  .refine(
    (d) => !(d.from && d.to) || d.from <= d.to,
    { message: '?from must be on or before ?to' },
  );

export type CreateDoseLogRequest = z.infer<typeof CreateDoseLogSchema>;
export type UpdateDoseLogRequest = z.infer<typeof UpdateDoseLogSchema>;
export type LogsQuery = z.infer<typeof LogsQuerySchema>;
