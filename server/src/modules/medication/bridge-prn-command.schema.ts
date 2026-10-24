import { z } from 'zod';

const UuidSchema = z.guid();
const PositiveRevisionSchema = z.string().refine(
  (value) => /^[1-9]\d{0,18}$/.test(value) && BigInt(value) <= 9_223_372_036_854_775_807n,
  'revision must be a canonical positive signed-64 decimal string',
);

import { AdministrationAmountSchema } from '../shared/administration-amount.js';

import { RecordedBySchema } from '../shared/recorded-by.js';

export { AdministrationAmountSchema };

const TakeSchema = z.object({
  operation: z.literal('take'),
  commandId: UuidSchema,
  eventId: UuidSchema,
  occurrenceId: UuidSchema,
  occurrenceKey: z.string().min(1).max(256),
  profileId: UuidSchema,
  pillId: UuidSchema,
  scheduleId: UuidSchema,
  scheduleRevision: PositiveRevisionSchema,
  plannedLocalDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  timeZone: z.string().min(1).max(128).refine((value) => {
    try {
      new Intl.DateTimeFormat('en-US', { timeZone: value });
      return true;
    } catch {
      return false;
    }
  }, 'must be a supported IANA timezone'),
  actualAt: z.string().datetime({ offset: true }).nullable(),
  actualTimeKnown: z.boolean(),
  amount: AdministrationAmountSchema,
  note: z.string().max(500).nullable(),
  recordedBy: RecordedBySchema.optional(),
}).strict();

const UndoSchema = z.object({
  operation: z.literal('undo'),
  commandId: UuidSchema,
  eventId: UuidSchema,
  occurrenceId: UuidSchema,
  occurrenceKey: z.string().min(1).max(256),
  baseVersion: PositiveRevisionSchema,
  reversesEventId: UuidSchema,
  note: z.string().max(500).nullable(),
  recordedBy: RecordedBySchema.optional(),
}).strict();

export const BridgePrnCommandSchema = z.discriminatedUnion('operation', [TakeSchema, UndoSchema]).superRefine((command, ctx) => {
  if (command.occurrenceKey !== `prn:v1:${command.occurrenceId}`) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'PRN occurrence key must match its immutable occurrence ID', path: ['occurrenceKey'] });
  }
  if (command.operation === 'take' && command.actualTimeKnown !== (command.actualAt !== null)) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'actualTimeKnown must match actualAt', path: ['actualTimeKnown'] });
  }
  if (command.operation === 'undo' && command.eventId === command.reversesEventId) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'Undo event cannot reverse itself', path: ['eventId'] });
  }
});

export type BridgePrnCommand = z.infer<typeof BridgePrnCommandSchema>;
export type AdministrationAmount = z.infer<typeof AdministrationAmountSchema>;
