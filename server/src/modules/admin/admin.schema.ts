import { z } from 'zod';
import { createPaginationSchema } from '../../lib/pagination.js';

export const AdminSetupSchema = z.object({
  email: z.string().email(),
  password: z.string().min(10).max(72),
  // Optional at the schema boundary so a missing proof reaches the typed
  // bootstrap error path instead of becoming a generic validation response.
  proof: z.string().min(1).max(4096).optional(),
});

export const AdminLoginSchema = z.object({
  password: z.string().min(1),
});

export const AdminRefreshSchema = z.object({
  refreshToken: z.string().min(1),
});

export const CreateKeySchema = z.object({
  label: z.string().min(1).max(100),
});

export const InviteSchema = z.object({
  email: z.string().trim().email(),
  label: z.string().trim().min(1).max(100).optional(),
});

export const UserIdParamSchema = z.object({ id: z.string().uuid() });

export const UpdateSettingsSchema = z.object({
  // null selects automatic mode (email when SMTP is configured, else manual).
  passwordResetMode: z.enum(['email', 'manual']).nullable().optional(),
  resetLinkLifetimeMinutes: z.number().int().min(5).max(1440).optional(),
}).strict().refine(
  (value) => value.passwordResetMode !== undefined || value.resetLinkLifetimeMinutes !== undefined,
  { message: 'At least one setting is required' },
);

export const UpdateLabelSchema = z.object({
  label: z.string().min(1).max(100),
});

export const ChangePasswordSchema = z.object({
  newPassword: z.string().min(10).max(72),
});

export const AdminAuditLogsQuerySchema = createPaginationSchema({ maxLimit: 200 }).extend({
  action: z.string().trim().min(1).max(100).optional(),
  /** Entries at or after this instant. */
  from: z.string().datetime({ offset: true }).optional(),
  /** Entries strictly before this instant. */
  to: z.string().datetime({ offset: true }).optional(),
});
