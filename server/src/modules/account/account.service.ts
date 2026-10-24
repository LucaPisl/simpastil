import { createHash, randomBytes } from 'node:crypto';
import * as argon2 from 'argon2';
import { and, eq, gt, isNull, sql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { TenantTransactionRunner, type TenantTransaction } from '../../db/tenant-transaction.js';
import { emailChangeTokens, passwordResetTokens, users } from '../../db/schema.js';
import { DELETED_ACCOUNT_MARKER_DAYS } from '../../lib/deleted-accounts.js';
import type { DeliveryPayloadSealer } from '../../lib/delivery-payload-crypto.js';
import { isUniqueViolation } from '../../lib/pg-errors.js';
import { appendAccountSyncChange } from '../sync/sync-change-writer.js';
import { AuditService } from '../admin/audit.service.js';
import { UserTotpService, TotpError } from '../auth/totp.service.js';
import type { SettingsService } from '../settings/settings.service.js';
import { ApiError } from '../shared/api-error.js';
import { ErrorCode } from '../shared/errors.js';
import { EMAIL_CHANGE_TOKEN_TTL_MS, type AccountDeleteRequest, type ChangeEmailRequest } from './account.schema.js';

export interface AccountCounts {
  people: number;
  medications: number;
  routines: number;
  doses: number;
  inventoryEvents: number;
  devices: number;
  settings: number;
}

export interface AccountSummary {
  email: string;
  twoFactorEnabled: boolean;
  counts: AccountCounts;
}

export type ChangeEmailResult = { status: 'changed' | 'confirmationSent' };

function toInt(value: unknown): number {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

function hashToken(raw: string): string {
  return createHash('sha256').update(raw).digest('hex');
}

/** Account self-service: the numbers, change email, and delete. */
export class AccountService {
  private readonly tenants: TenantTransactionRunner;
  private readonly audit: AuditService;

  constructor(
    private readonly db: Db,
    private readonly totp: UserTotpService,
    private readonly payloadSealer: DeliveryPayloadSealer,
    private readonly settings: SettingsService,
  ) {
    this.tenants = new TenantTransactionRunner(db);
    this.audit = new AuditService(db);
  }

  /** What an account holds, counted from the live rows (deleted rows excluded). */
  async summary(userId: string): Promise<AccountSummary> {
    return this.tenants.run(userId, async (tx) => {
      const [user] = await tx.select({ email: users.email, totp: users.totpEnabled })
        .from(users).where(eq(users.id, userId));
      if (!user) throw new ApiError(404, ErrorCode.AUTH_USER_NOT_FOUND, 'Account not found', { retryable: false });
      return { email: user.email, twoFactorEnabled: user.totp, counts: await this.counts(tx, userId) };
    });
  }

  private async counts(tx: TenantTransaction, userId: string): Promise<AccountCounts> {
    const rows = await tx.execute(sql`
      SELECT
        (SELECT count(*) FROM public.profiles WHERE user_id = ${userId}::uuid AND deleted_at IS NULL) AS people,
        (SELECT count(*) FROM public.pills p JOIN public.profiles pr ON pr.id = p.profile_id
           WHERE pr.user_id = ${userId}::uuid AND p.deleted_at IS NULL AND pr.deleted_at IS NULL) AS medications,
        (SELECT count(*) FROM public.schedules s JOIN public.pills p ON p.id = s.pill_id
           JOIN public.profiles pr ON pr.id = p.profile_id
           WHERE pr.user_id = ${userId}::uuid AND s.deleted_at IS NULL AND p.deleted_at IS NULL
             AND pr.deleted_at IS NULL) AS routines,
        greatest(
          (SELECT count(*) FROM public.occurrence_events WHERE user_id = ${userId}::uuid AND action = 'take'),
          (SELECT count(*) FROM public.dose_logs d JOIN public.schedules s ON s.id = d.schedule_id
             JOIN public.pills p ON p.id = s.pill_id JOIN public.profiles pr ON pr.id = p.profile_id
             WHERE pr.user_id = ${userId}::uuid AND d.status = 'taken' AND d.deleted_at IS NULL)
        ) AS doses,
        (SELECT count(*) FROM public.inventory_events WHERE user_id = ${userId}::uuid) AS inventory_events,
        (SELECT count(*) FROM public.api_keys WHERE user_id = ${userId}::uuid AND revoked_at IS NULL) AS devices,
        (SELECT count(*) FROM public.account_settings WHERE user_id = ${userId}::uuid AND value IS NOT NULL) AS settings
    `);
    const row = (rows as unknown as Array<Record<string, unknown>>)[0] ?? {};
    return {
      people: toInt(row['people']),
      medications: toInt(row['medications']),
      routines: toInt(row['routines']),
      doses: toInt(row['doses']),
      inventoryEvents: toInt(row['inventory_events']),
      devices: toInt(row['devices']),
      settings: toInt(row['settings']),
    };
  }

  /**
   * Re-checks who is asking: the password, and the 2FA code when 2FA is on.
   * A wrong password is a 400 (as for change-password), never a 401, which the
   * app would read as an expired sign-in.
   */
  private async verifyIdentity(userId: string, password: string, code: string | undefined): Promise<{ email: string }> {
    const [user] = await this.db
      .select({ email: users.email, passwordHash: users.passwordHash, totpEnabled: users.totpEnabled })
      .from(users).where(eq(users.id, userId));
    if (!user) throw new ApiError(404, ErrorCode.AUTH_USER_NOT_FOUND, 'Account not found', { retryable: false });
    if (!(await argon2.verify(user.passwordHash, password))) {
      throw new ApiError(400, ErrorCode.AUTH_INVALID_CREDENTIALS, 'Password is incorrect', { retryable: false });
    }
    if (user.totpEnabled) {
      if (!code) throw new ApiError(400, ErrorCode.TOTP_REQUIRED, 'A 2FA code is required', { retryable: false });
      try {
        await this.totp.verifyChallenge(userId, code);
      } catch (error) {
        if (error instanceof TotpError) {
          throw new ApiError(error.statusCode, error.code, error.message, { retryable: false });
        }
        throw error;
      }
    }
    return { email: user.email };
  }

  /** Ends the account and everything in it. The caller answers 204. */
  async deleteAccount(userId: string, body: AccountDeleteRequest, ip: string | null): Promise<void> {
    await this.verifyIdentity(userId, body.password, body.code);
    await this.tenants.run(userId, async (tx) => {
      const counts = await this.counts(tx, userId);
      const expires = new Date(Date.now() + DELETED_ACCOUNT_MARKER_DAYS * 86_400_000);
      // Remember the key hashes first (the cascade removes the keys), so a
      // device that still holds one is told the account is gone.
      await tx.execute(sql`SELECT public.mark_account_deleted(${userId}::uuid, ${expires.toISOString()}::timestamptz)`);
      // Mail still waiting for this account's address must not go out after it.
      await tx.execute(sql`SELECT public.delete_unsent_outbox_for_account(${userId}::uuid)`);
      const removed = await tx.delete(users).where(eq(users.id, userId)).returning({ id: users.id });
      if (removed.length !== 1) throw new ApiError(404, ErrorCode.AUTH_USER_NOT_FOUND, 'Account not found', { retryable: false });
      // Counts only: no email, names or medication in the audit trail.
      await this.audit.log(`user:${userId}`, 'account.delete', 'user', userId, ip, { counts }, tx);
    });
  }

  /**
   * Changes the sign-in address. With mail configured the new address must be
   * confirmed first and the old one is told; without mail the change is
   * immediate (the password and 2FA code just checked are the proof). Every
   * session stays signed in.
   */
  async changeEmail(userId: string, body: ChangeEmailRequest, ip: string | null): Promise<ChangeEmailResult> {
    const { email: current } = await this.verifyIdentity(userId, body.password, body.code);
    const next = body.newEmail.trim().toLowerCase();
    if (next === current.toLowerCase()) return { status: 'changed' };

    const mailOn = (await this.settings.get()).smtpConfigured;
    if (!mailOn) {
      await this.applyEmail(userId, next, ip, null);
      return { status: 'changed' };
    }

    const [taken] = await this.db.select({ id: users.id }).from(users).where(eq(users.email, next));
    if (taken) throw new ApiError(409, ErrorCode.AUTH_EMAIL_TAKEN, 'Email is already in use', { retryable: false });

    const raw = randomBytes(32).toString('hex');
    const expiresAt = new Date(Date.now() + EMAIL_CHANGE_TOKEN_TTL_MS);
    await this.tenants.run(userId, async (tx) => {
      // A new request replaces an earlier pending one.
      await tx.delete(emailChangeTokens).where(eq(emailChangeTokens.userId, userId));
      await tx.insert(emailChangeTokens).values({
        userId, newEmail: next, tokenHash: hashToken(raw), expiresAt,
      });
      await this.enqueue(tx, 'email-change-confirm', next, { token: raw }, expiresAt);
      await this.enqueue(tx, 'email-change-notice', current, {}, expiresAt);
      await this.audit.log(`user:${userId}`, 'account.email_change_requested', 'user', userId, ip, undefined, tx);
    });
    return { status: 'confirmationSent' };
  }

  /** Opens from the link in the mail to the new address (no sign-in needed). */
  async confirmEmailChange(token: string, ip: string | null): Promise<void> {
    const invalid = () => new ApiError(400, ErrorCode.AUTH_EMAIL_CHANGE_INVALID,
      'This link is invalid or has expired', { retryable: false });
    const [row] = await this.db.select().from(emailChangeTokens).where(and(
      eq(emailChangeTokens.tokenHash, hashToken(token)),
      isNull(emailChangeTokens.consumedAt),
      gt(emailChangeTokens.expiresAt, new Date()),
    ));
    if (!row) throw invalid();
    await this.applyEmail(row.userId, row.newEmail, ip, row.id);
  }

  private async applyEmail(userId: string, email: string, ip: string | null, tokenId: string | null): Promise<void> {
    try {
      await this.tenants.run(userId, async (tx) => {
        if (tokenId !== null) {
          const used = await tx.update(emailChangeTokens)
            .set({ consumedAt: new Date() })
            .where(and(eq(emailChangeTokens.id, tokenId), isNull(emailChangeTokens.consumedAt)))
            .returning({ id: emailChangeTokens.id });
          if (used.length !== 1) {
            throw new ApiError(400, ErrorCode.AUTH_EMAIL_CHANGE_INVALID, 'This link is invalid or has expired', { retryable: false });
          }
        }
        const [updated] = await tx.update(users).set({ email, updatedAt: new Date() })
          .where(eq(users.id, userId)).returning({
            id: users.id, email: users.email, sessionVersion: users.sessionVersion,
            createdAt: users.createdAt, updatedAt: users.updatedAt,
          });
        if (!updated) throw new ApiError(404, ErrorCode.AUTH_USER_NOT_FOUND, 'Account not found', { retryable: false });
        await tx.delete(emailChangeTokens).where(eq(emailChangeTokens.userId, userId));
        // A reset link already mailed to the old address must not outlive it.
        await tx.delete(passwordResetTokens).where(eq(passwordResetTokens.userId, userId));
        // Every other device shows the new address on its next pull.
        await appendAccountSyncChange(tx, userId, updated);
        await this.audit.log(`user:${userId}`, 'account.email_change', 'user', userId, ip, undefined, tx);
      });
    } catch (error) {
      if (isUniqueViolation(error)) {
        throw new ApiError(409, ErrorCode.AUTH_EMAIL_TAKEN, 'Email is already in use', { retryable: false });
      }
      throw error;
    }
  }

  private async enqueue(
    tx: TenantTransaction,
    kind: 'email-change-confirm' | 'email-change-notice',
    recipient: string,
    payload: Record<string, string>,
    expiresAt: Date,
  ): Promise<void> {
    await tx.execute(sql`
      INSERT INTO public.outbox_messages (
        message_type, recipient_ref, encrypted_delivery_payload, state, attempt_count, expires_at
      ) VALUES (
        ${kind}, ${recipient}, ${this.payloadSealer.seal(JSON.stringify(payload))},
        'queued', 0, ${expiresAt.toISOString()}::timestamptz
      )
    `);
  }
}
