import { z } from 'zod';

export const CreateProfileSchema = z.object({
  mutationId: z.string().uuid(),
  id: z.string().uuid().optional(),
  name: z.string().min(1).max(100),
  avatarEmoji: z.string().min(1).max(32).optional(),
  isActive: z.boolean().optional(),
}).strict();

const UpdateProfileFields = z.object({
    mutationId: z.string().uuid(),
    baseRevision: z.string().refine(
      (value) => value.length <= 19 && /^[1-9]\d*$/.test(value)
        && BigInt(value) <= 9_223_372_036_854_775_807n,
      'baseRevision must be a positive signed-64 decimal string',
    ),
    name: z.string().min(1).max(100).optional(),
    avatarEmoji: z.string().min(1).max(32).optional(),
    isActive: z.boolean().optional(),
  }).strict();

export const UpdateProfileSchema = UpdateProfileFields
  .refine((data) => ['name', 'avatarEmoji', 'isActive'].some(
    (key) => data[key as keyof typeof data] !== undefined,
  ), {
    message: 'At least one field required',
  });

export const DeleteProfileSchema = UpdateProfileFields
  .pick({ mutationId: true, baseRevision: true })
  .strict();

export type CreateProfileRequest = z.infer<typeof CreateProfileSchema>;
export type UpdateProfileRequest = z.infer<typeof UpdateProfileSchema>;
export type DeleteProfileRequest = z.infer<typeof DeleteProfileSchema>;
