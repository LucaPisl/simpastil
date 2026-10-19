import { z } from 'zod';

const EmailSchema = z.string().max(320).email();
const OpaqueTokenSchema = z.string().min(1).max(4096);

// ---------------------------------------------------------------------------
// Request schemas
// ---------------------------------------------------------------------------

export const RegisterRequestSchema = z.object({
  email: EmailSchema,
  // min 10: security floor — short passwords are easily brute-forced.
  // max 72: Argon2id internally processes input in 1024-bit (128-byte) blocks,
  // but its reference implementation silently truncates passwords at 72 bytes.
  // Rejecting at the boundary prevents users from believing a 100-char password
  // is stronger than a 72-char one — they would hash identically.
  password: z.string().min(10).max(72),
});

export const LoginRequestSchema = z.object({
  email: EmailSchema,
  password: z.string(),
});

export const RefreshRequestSchema = z.object({
  refreshToken: OpaqueTokenSchema,
});

export const RecoverableRefreshRequestSchema = RefreshRequestSchema.extend({
  nextRefreshToken: z.string().regex(/^[0-9a-f]{64}$/),
}).strict().refine((value) => value.refreshToken !== value.nextRefreshToken);

export const LogoutRequestSchema = z.object({
  refreshToken: OpaqueTokenSchema,
});

export const ChangePasswordRequestSchema = z.object({
  currentPassword: z.string().min(1),
  newPassword: z.string().min(10).max(72),
});

export const ForgotPasswordRequestSchema = z.object({
  email: EmailSchema,
});

export const ResetPasswordRequestSchema = z.object({
  token: OpaqueTokenSchema,
  newPassword: z.string().min(10).max(72),
});

// ---------------------------------------------------------------------------
// Response schemas
// ---------------------------------------------------------------------------

export const RegisterResponseSchema = z.object({
  userId: z.guid(),
});

export const LoginResponseSchema = z.object({
  accessToken: z.string(),
  refreshToken: z.string(),
});

export const RefreshResponseSchema = z.object({
  accessToken: z.string(),
  refreshToken: z.string(),
});

// ---------------------------------------------------------------------------
// Inferred TypeScript types (zero duplication: schema IS the type)
// ---------------------------------------------------------------------------

export type RegisterRequest = z.infer<typeof RegisterRequestSchema>;
export type RegisterResponse = z.infer<typeof RegisterResponseSchema>;
export type LoginRequest = z.infer<typeof LoginRequestSchema>;
export type LoginResponse = z.infer<typeof LoginResponseSchema>;
export type RefreshRequest = z.infer<typeof RefreshRequestSchema>;
export type RefreshResponse = z.infer<typeof RefreshResponseSchema>;
export type LogoutRequest = z.infer<typeof LogoutRequestSchema>;
export type ChangePasswordRequest = z.infer<typeof ChangePasswordRequestSchema>;
export type ForgotPasswordRequest = z.infer<typeof ForgotPasswordRequestSchema>;
export type ResetPasswordRequest = z.infer<typeof ResetPasswordRequestSchema>;
