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

export const UpdateLabelSchema = z.object({
  label: z.string().min(1).max(100),
});

export const ChangePasswordSchema = z.object({
  newPassword: z.string().min(10).max(72),
});

export const AdminAuditLogsQuerySchema = createPaginationSchema({ maxLimit: 200 }).extend({
  action: z.string().trim().min(1).max(100).optional(),
});
