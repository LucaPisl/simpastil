import { randomBytes } from 'node:crypto';
import * as argon2 from 'argon2';
import { and, eq, gt, isNotNull, isNull, sql as drizzleSql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import {
  apiKeys,
  invitationTokens,
  outboxMessages,
  passwordResetTokens,
  users,
} from '../../db/schema.js';
import type { EncryptionCapabilities } from '../../lib/crypto.js';
import { sha256Hex } from '../../lib/crypto.js';
import type { DeliveryPayloadSealer } from '../../lib/delivery-payload-crypto.js';
import { ErrorCode, type ErrorCodeValue } from '../shared/errors.js';
import { SessionService } from '../auth/session.service.js';
import { buildRecoveryLink } from '../../lib/recovery-links.js';
import { INVITATION_LIFETIME_MS, SettingsService } from '../settings/settings.service.js';

const ARGON2_OPTIONS = {
  type: argon2.argon2id,
  memoryCost: 65536,
  timeCost: 3,
  parallelism: 4,
} as const;

const INVITATION_TOKEN_TTL_MS = INVITATION_LIFETIME_MS;

export class RecoveryError extends Error {
  constructor(
    message: string,
    readonly statusCode: number,
    readonly code: ErrorCodeValue,
  ) {
    super(message);
    this.name = 'RecoveryError';
  }
}

export class RecoveryService {
  constructor(
    private readonly db: Db,
    private readonly payloadSealer: DeliveryPayloadSealer,
    private readonly encryption: EncryptionCapabilities,
    private readonly publicAppUrl: string | undefined,
    private readonly sessions: SessionService = new SessionService(db),
    // Without an explicit service the legacy behaviour applies: email delivery
    // and the default one-hour link lifetime.
    private readonly settings: SettingsService = new SettingsService(db, true),
  ) {}

  /**
   * Creates the reset authority and its encrypted delivery job together.
   * Callers deliberately receive no signal about whether an account existed.
   * In manual mode the lookup still runs but nothing is created or queued, so
   * the response and its cost match the email path for an unknown address.
   */
  async requestPasswordReset(email: string): Promise<void> {
    const normalizedEmail = email.trim().toLowerCase();
    // Read the settings before the lookup so manual mode costs the same
    // two queries whether or not the address exists.
    const settings = await this.settings.get();
    const [user] = await this.db
      .select({ id: users.id, email: users.email })
      .from(users)
      .where(eq(users.email, normalizedEmail));
    if (!user || settings.effectivePasswordResetMode !== 'email') return;

    const rawToken = randomBytes(32).toString('hex');
    const expiresAt = new Date(Date.now() + settings.resetLinkLifetimeMinutes * 60_000);

    await this.db.transaction(async (tx) => {
      await tx.execute(
        drizzleSql`SELECT set_config('app.current_user_id', ${user.id}, true)`,
      );
      await this.replaceResetTokens(tx, user.id, rawToken, expiresAt);
      await this.enqueue(tx, 'password-reset', user.email, { token: rawToken }, expiresAt);
    });
  }

  /**
   * Admin-only: issues a one-time reset link for the operator to hand over.
   * Nothing is queued. Returns null when the user does not exist. The raw
   * token is only in the returned link and is never stored or logged.
   */
  async issueManualResetLink(
    userId: string,
    tx: any,
  ): Promise<{ link: string; expiresAt: Date } | null> {
    await tx.execute(drizzleSql`SELECT set_config('app.current_user_id', ${userId}, true)`);
    const [user] = await tx.select({ id: users.id }).from(users).where(eq(users.id, userId));
    if (!user) return null;
    const { resetLinkLifetimeMinutes } = await this.settings.get(tx);
    const rawToken = randomBytes(32).toString('hex');
    const expiresAt = new Date(Date.now() + resetLinkLifetimeMinutes * 60_000);
    await this.replaceResetTokens(tx, userId, rawToken, expiresAt);
    return { link: buildRecoveryLink(this.publicAppUrl, 'reset-password', rawToken), expiresAt };
  }

  /** Whether invitation emails can be sent under the current settings. */
  async invitationEmailAvailable(): Promise<boolean> {
    return (await this.settings.get()).effectivePasswordResetMode === 'email';
  }

  /**
   * A new link supersedes every earlier one: all of the user's existing tokens
   * (unused, used and expired) are removed before the new token is stored.
   * The caller has already set app.current_user_id for the transaction.
   */
  private async replaceResetTokens(tx: any, userId: string, rawToken: string, expiresAt: Date): Promise<void> {
    await tx.delete(passwordResetTokens).where(eq(passwordResetTokens.userId, userId));
    await tx.insert(passwordResetTokens).values({
      userId,
      tokenHash: sha256Hex(rawToken),
      expiresAt,
      used: false,
    });
  }

  /**
   * Claims a reset token conditionally and changes the password/session
   * generation in the same transaction. A rollback leaves the token usable.
   */
  async resetPassword(rawToken: string, newPassword: string): Promise<void> {
    if (newPassword.length < 10) {
      throw new RecoveryError('Password must be at least 10 characters', 400, ErrorCode.AUTH_PASSWORD_WEAK);
    }
    if (newPassword.length > 72) {
      throw new RecoveryError('Password must be at most 72 characters', 400, ErrorCode.AUTH_PASSWORD_LONG);
    }

    const tokenHash = sha256Hex(rawToken);
    const [candidate] = await this.db
      .select({ id: passwordResetTokens.id, userId: passwordResetTokens.userId })
      .from(passwordResetTokens)
      .where(eq(passwordResetTokens.tokenHash, tokenHash));
    if (!candidate) throw this.invalidResetToken();

    const passwordHash = await argon2.hash(newPassword, ARGON2_OPTIONS);
    try {
      await this.db.transaction(async (tx) => {
        // The owner lookup is non-authoritative. The conditional update below
        // is the single-use claim and remains safe under concurrent requests.
        await tx.execute(
          drizzleSql`SELECT set_config('app.current_user_id', ${candidate.userId}, true)`,
        );
        const claimed = await tx
          .update(passwordResetTokens)
          .set({ used: true })
          .where(and(
            eq(passwordResetTokens.id, candidate.id),
            eq(passwordResetTokens.tokenHash, tokenHash),
            eq(passwordResetTokens.used, false),
            gt(passwordResetTokens.expiresAt, new Date()),
          ))
          .returning({ id: passwordResetTokens.id });
        if (claimed.length === 0) throw this.invalidResetToken();

        await this.sessions.invalidateUserSessions(candidate.userId, tx);
        const changed = await tx
          .update(users)
          .set({ passwordHash })
          .where(eq(users.id, candidate.userId))
          .returning({ id: users.id });
        if (changed.length === 0) throw this.invalidResetToken();
      });
    } catch (err) {
      if (err instanceof RecoveryError) throw err;
      throw new RecoveryError('Password reset failed', 500, ErrorCode.INTERNAL);
    }
  }

  /** Creates an invitation linked only to a newly created dedicated key. */
  async createInvitation(
    tx: any,
    email: string,
    apiKeyId: string,
  ): Promise<{ invitationId: string; expiresAt: Date }> {
    const rawToken = randomBytes(32).toString('hex');
    const expiresAt = new Date(Date.now() + INVITATION_TOKEN_TTL_MS);
    const recipient = email.trim().toLowerCase();
    // app_user intentionally has INSERT rights only on these invitation
    // columns. Drizzle's insert builder lists every table column (including
    // DEFAULT-valued columns), which requires broader grants, so keep this
    // statement explicit and least-privilege.
    const inserted = await tx.execute(drizzleSql`
      INSERT INTO public.invitation_tokens (token_hash, recipient_email, api_key_id, expires_at)
      VALUES (${sha256Hex(rawToken)}, ${recipient}, ${apiKeyId}, ${expiresAt.toISOString()}::timestamptz)
      RETURNING id
    `) as Array<{ id: string }>;
    const invitation = inserted[0];
    if (!invitation) throw new Error('Invitation creation failed');

    // The encrypted payload contains only the opaque invitation token. The
    // one-time API key remains recoverable only from its dedicated api_keys row.
    await this.enqueue(tx, 'invite', recipient, { token: rawToken }, expiresAt);
    return { invitationId: invitation.id, expiresAt };
  }

  /**
   * Atomically consumes an invitation, decrypts its dedicated key once, and
   * clears the recoverable copy while retaining the key's authentication hash.
   */
  async acceptInvitation(rawToken: string): Promise<{ serverUrl: string; apiKey: string }> {
    const tokenHash = sha256Hex(rawToken);
    const [candidate] = await this.db
      .select({ id: invitationTokens.id })
      .from(invitationTokens)
      .where(eq(invitationTokens.tokenHash, tokenHash));
    if (!candidate) throw this.invalidInvitationToken();

    try {
      return await this.db.transaction(async (tx) => {
        const [claimed] = await tx
          .update(invitationTokens)
          .set({ consumedAt: new Date() })
          .where(and(
            eq(invitationTokens.id, candidate.id),
            eq(invitationTokens.tokenHash, tokenHash),
            isNull(invitationTokens.consumedAt),
            isNull(invitationTokens.revokedAt),
            gt(invitationTokens.expiresAt, new Date()),
          ))
          .returning({ apiKeyId: invitationTokens.apiKeyId });
        if (!claimed) throw this.invalidInvitationToken();

        const [key] = await tx
          .select({ encryptedKey: apiKeys.encryptedKey, revokedAt: apiKeys.revokedAt })
          .from(apiKeys)
          .where(eq(apiKeys.id, claimed.apiKeyId));
        if (!key || key.revokedAt !== null || !key.encryptedKey) {
          throw this.invalidInvitationToken();
        }

        const apiKey = this.encryption.decrypt(key.encryptedKey);
        const cleared = await tx
          .update(apiKeys)
          .set({ encryptedKey: null })
          .where(and(
            eq(apiKeys.id, claimed.apiKeyId),
            isNull(apiKeys.revokedAt),
            isNotNull(apiKeys.encryptedKey),
          ))
          .returning({ id: apiKeys.id });
        if (cleared.length === 0) throw this.invalidInvitationToken();

        return { serverUrl: this.serverOrigin(), apiKey };
      });
    } catch (err) {
      if (err instanceof RecoveryError) throw err;
      throw new RecoveryError('Invitation could not be accepted', 500, ErrorCode.INTERNAL);
    }
  }

  private async enqueue(
    tx: any,
    kind: 'password-reset' | 'invite',
    recipient: string,
    payload: { token: string },
    expiresAt: Date,
  ): Promise<void> {
    // The API role can insert only the bounded enqueue fields. Avoid granting
    // it rights over worker-maintained lease/failure/sent fields just to
    // accommodate an ORM insert listing all columns with DEFAULT values.
    await tx.execute(drizzleSql`
      INSERT INTO public.outbox_messages (
        message_type,
        recipient_ref,
        encrypted_delivery_payload,
        state,
        attempt_count,
        expires_at
      ) VALUES (
        ${kind},
        ${recipient},
        ${this.payloadSealer.seal(JSON.stringify(payload))},
        'queued',
        0,
        ${expiresAt.toISOString()}::timestamptz
      )
    `);
  }

  private serverOrigin(): string {
    return new URL(this.publicAppUrl ?? 'http://localhost:3000').origin;
  }

  private invalidResetToken(): RecoveryError {
    return new RecoveryError('Reset link is invalid or has expired', 400, ErrorCode.AUTH_RESET_INVALID);
  }

  private invalidInvitationToken(): RecoveryError {
    return new RecoveryError('Invitation is invalid or has expired', 400, ErrorCode.AUTH_INVITATION_INVALID);
  }
}
