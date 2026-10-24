import { z } from 'zod';

// The name a dose was recorded under, snapshotted when it was recorded. It is
// display-only: it never identifies an account or a device, and it is neither
// logged nor used to decide anything. `name: null` means a person recorded the
// dose but no name could be resolved; an absent field means unknown.
export const RecordedBySchema = z.object({
  version: z.literal(1),
  name: z.string().min(1).max(100).refine((value) => value === value.trim(), 'name must be trimmed').nullable(),
}).strict();

export type RecordedBy = z.infer<typeof RecordedBySchema>;
