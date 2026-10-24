import { z } from 'zod';

const Email = z.string().trim().min(3).max(320).email();
const Password = z.string().min(1).max(1024);
/** A 6-digit code or a backup code (hex). Required only when 2FA is on. */
const Code = z.string().min(1).max(64).optional();

export const AccountDeleteRequestSchema = z.object({
  password: Password,
  code: Code,
}).strict();

export const ChangeEmailRequestSchema = z.object({
  password: Password,
  code: Code,
  newEmail: Email,
}).strict();

export const ConfirmEmailChangeRequestSchema = z.object({
  token: z.string().min(32).max(512),
}).strict();

export type AccountDeleteRequest = z.infer<typeof AccountDeleteRequestSchema>;
export type ChangeEmailRequest = z.infer<typeof ChangeEmailRequestSchema>;

export const EMAIL_CHANGE_TOKEN_TTL_MS = 24 * 60 * 60 * 1000;
