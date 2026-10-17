import { z } from 'zod';

import { AdministrationAmountSchema } from '../shared/administration-amount.js';

// The reviewed details. `dosage` stays the original free text; these carry
// what it was reviewed into, so every device shows the same amount.
const detailFields = {
  amountPerUse: AdministrationAmountSchema.nullable().optional(),
  packageStrength: z.string().max(500).nullable().optional(),
  form: z.string().max(500).nullable().optional(),
  legacyDosageReviewed: z.boolean().optional(),
};

// Build-2 clients send unset optional text fields as explicit nulls on create.
// Null and absent mean the same unset value here (the service stores both as
// NULL and fingerprints the normalized input), so accepting null keeps replay
// and mutation-reuse semantics unchanged.
export const CreatePillSchema = z.object({
  mutationId: z.string().uuid(),
  id: z.string().uuid().optional(),
  name: z.string().min(1).max(100),
  dosage: z.string().max(50).nullable().optional(),
  notes: z.string().max(500).nullable().optional(),
  color: z
    .string()
    .regex(/^#[0-9A-Fa-f]{6}$/, 'color must be a hex code like #FF5733')
    .nullable()
    .optional(),
  lowStockThreshold: z.number().int().min(0).nullable().optional(),
  isPrn: z.boolean().optional().default(false),
  ...detailFields,
}).strict();

const UpdatePillFields = z.object({
    mutationId: z.string().uuid(),
    baseRevision: z.string().refine(
      (value) => value.length <= 19 && /^[1-9]\d*$/.test(value)
        && BigInt(value) <= 9_223_372_036_854_775_807n,
      'baseRevision must be a positive signed-64 decimal string',
    ),
    name: z.string().min(1).max(100).optional(),
    dosage: z.string().max(50).nullable().optional(),
    notes: z.string().max(500).nullable().optional(),
    color: z
      .string()
      .regex(/^#[0-9A-Fa-f]{6}$/)
      .nullable()
      .optional(),
    lowStockThreshold: z.number().int().min(0).nullable().optional(),
    isPrn: z.boolean().optional(),
    ...detailFields,
  }).strict();

export const UpdatePillSchema = UpdatePillFields
  .refine((data) => [
    'name', 'dosage', 'notes', 'color', 'lowStockThreshold', 'isPrn',
    'amountPerUse', 'packageStrength', 'form', 'legacyDosageReviewed',
  ].some((key) => data[key as keyof typeof data] !== undefined), {
    message: 'At least one field required',
  });

export const DeletePillSchema = UpdatePillFields
  .pick({ mutationId: true, baseRevision: true })
  .strict();

export type CreatePillRequest = z.infer<typeof CreatePillSchema>;
export type UpdatePillRequest = z.infer<typeof UpdatePillSchema>;
export type DeletePillRequest = z.infer<typeof DeletePillSchema>;
