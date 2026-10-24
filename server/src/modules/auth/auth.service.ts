import {
  randomBytes,
  timingSafeEqual,
  randomUUID,
} from 'node:crypto';
import * as argon2 from 'argon2';
import { and, eq, isNull, sql as drizzleSql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { sha256Hex } from '../../lib/crypto.js';
import type { DeliverySubmitter } from '../../lib/delivery.js';
import { buildRecoveryLink } from '../../lib/recovery-links.js';
import { users, refreshTokens, apiKeys } from '../../db/schema.js';
import { ErrorCode, type ErrorCodeValue } from '../shared/errors.js';
import { SessionService, sessionVersionClaim } from './session.service.js';
import { appendAccountSyncChange } from '../sync/sync-change-writer.js';
import { isUniqueViolation } from '../../lib/pg-errors.js';
import { isDeletedAccountKey } from '../../lib/deleted-accounts.js';

export interface AuthRuntimeConfig {
  nodeEnv: 'development' | 'test' | 'production';
  apiBaseUrl?: string;
  submitDelivery?: DeliverySubmitter;
  /** Test-only barrier used to prove refresh/device invalidation ordering. */
  testHooks?: {
    afterRefreshSessionLock?: () => Promise<void>;
  };
}

export function buildPasswordResetUrl(baseUrl: string | undefined, rawToken: string): string {
  return buildRecoveryLink(baseUrl, 'reset-password', rawToken);
}

// ---------------------------------------------------------------------------
// Error type
// ---------------------------------------------------------------------------

export class AuthError extends Error {
  constructor(
    message: string,
    readonly statusCode: number,
    readonly code: ErrorCodeValue = ErrorCode.AUTH_UNAUTHORIZED,
  ) {
    super(message);
    this.name = 'AuthError';
  }
}

// ---------------------------------------------------------------------------
// Argon2id configuration
//
// Parameters are tuned so that hashing takes ~300ms on commodity hardware:
//   memoryCost: 65536 KiB (64 MiB) — GPU brute-force is prohibitively expensive
//   timeCost:   3 iterations        — increases time cost without RAM overhead
//   parallelism: 4 threads          — exploits multi-core hardware
//
// See: NIST SP 800-63B §5.1.1.2 and the Argon2 RFC (RFC 9106).
// ---------------------------------------------------------------------------

const ARGON2_OPTIONS = {
  type: argon2.argon2id,
  memoryCost: 65536,
  timeCost: 3,
  parallelism: 4,
} as const;

// Pre-computed hash used when the user is not found during login.
// argon2.verify() is always called regardless of whether the user exists,
// which prevents timing-based user enumeration attacks (an attacker cannot
// determine whether an email is registered by measuring response time).
//
// Top-level await is valid here: this file is an ES module (package.json has
// "type": "module") and tsconfig uses "module": "NodeNext" which supports it.
// The hash is computed once at server startup (~300ms) and reused for all
// future requests — no per-request overhead.
const DUMMY_HASH = await argon2.hash('dummy-sentinel-value', ARGON2_OPTIONS);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------


/**
 * Constant-time comparison of two SHA-256 hex strings.
 *
 * SHA-256 output is always 64 hex characters (32 bytes), so the lengths
 * are guaranteed equal — timingSafeEqual will never throw a length error.
 */
function timingSafeHexEqual(a: string, b: string): boolean {
  return timingSafeEqual(Buffer.from(a, 'hex'), Buffer.from(b, 'hex'));
}

async function databaseWallClock(tx: any): Promise<Date> {
  const rows = await tx.execute(drizzleSql`SELECT clock_timestamp() AS now`) as Array<{ now: Date | string }>;
  return new Date(rows[0]!.now);
}

// ---------------------------------------------------------------------------
// AuthService
// ---------------------------------------------------------------------------

export class AuthService {
  constructor(
    private readonly db: Db,
    private readonly signAccessToken: (userId: string, sessionVersion?: string) => string,
    private readonly signChallengeToken?: (userId: string, sessionVersion?: string) => string,
    private readonly runtime: AuthRuntimeConfig = { nodeEnv: 'development' },
    private readonly sessions: SessionService = new SessionService(db),
  ) {}

  // -------------------------------------------------------------------------
  // register
  // -------------------------------------------------------------------------

  async register(
    email: string,
    password: string,
    apiKeyId: string,
  ): Promise<{ userId: string }> {
    // Input validation (also enforced at the route layer via Zod, but the
    // service validates independently so it can be used without HTTP layer).
    if (password.length < 10) {
      throw new AuthError('Password must be at least 10 characters', 400, ErrorCode.AUTH_PASSWORD_WEAK);
    }
    if (password.length > 72) {
      throw new AuthError('Password must be at most 72 characters', 400, ErrorCode.AUTH_PASSWORD_LONG);
    }

    const normalizedEmail = email.trim().toLowerCase();
    const passwordHash = await argon2.hash(password, ARGON2_OPTIONS);

    // Pre-generate the UUID so we can set app.current_user_id before INSERT.
    //
    // Why: the users table has a RESTRICTIVE RLS policy on SELECT that limits
    // row visibility to the current app.current_user_id. The INSERT … RETURNING
    // clause implicitly runs a SELECT to return the new row, so RLS is checked.
    // By setting app.current_user_id = newId before the INSERT, the RETURNING
    // clause can see the just-inserted row without any extra query.
    const newId = randomUUID();

    try {
      const rows = await this.db.transaction(async (tx) => {
        // Set the session variable so the RETURNING SELECT passes RLS.
        // LOCAL scope: the setting is automatically cleared when the
        // transaction ends, leaving the connection in a clean state.
        await tx.execute(
          drizzleSql`SELECT set_config('app.current_user_id', ${newId}, true)`,
        );

        const inserted = await tx
          .insert(users)
          .values({ id: newId, email: normalizedEmail, passwordHash })
          .returning({
            id: users.id,
            email: users.email,
            sessionVersion: users.sessionVersion,
            createdAt: users.createdAt,
            updatedAt: users.updatedAt,
          });

        // BIND the API key to the new user. user_id IS NULL keeps the claim
        // atomic against a concurrent login/register racing for the same key.
        const claimed = await tx
          .update(apiKeys)
          .set({ userId: newId })
          .where(and(eq(apiKeys.id, apiKeyId), isNull(apiKeys.userId)))
          .returning({ id: apiKeys.id });
        if (claimed.length === 0) {
          throw new AuthError('Key already claimed', 409, ErrorCode.AUTH_KEY_CLAIMED);
        }

        const account = inserted[0];
        if (!account) throw new AuthError('Registration failed unexpectedly', 500);
        await appendAccountSyncChange(tx, newId, account);

        return inserted;
      });

      const row = rows[0];
      if (!row) throw new AuthError('Registration failed unexpectedly', 500);

      return { userId: row.id };
    } catch (err) {
      if (err instanceof AuthError) throw err;
      if (isUniqueViolation(err)) {
        throw new AuthError('Email already registered', 409, ErrorCode.AUTH_EMAIL_TAKEN);
      }
      throw err;
    }
  }

  // -------------------------------------------------------------------------
  // login
  // -------------------------------------------------------------------------

  async login(
    email: string,
    password: string,
    key: { keyId: string; keyUserId: string | null },
  ): Promise<{ accessToken: string; refreshToken: string } | { requires2fa: true; challengeToken: string }> {
    const normalizedEmail = email.trim().toLowerCase();

    const [user] = await this.db
      .select()
      .from(users)
      .where(eq(users.email, normalizedEmail));

    // Always call argon2.verify() — even when the user is not found — so that
    // response time is constant regardless of whether the email is registered.
    // Without this, a timing oracle would reveal registered emails.
    const hashToVerify = user?.passwordHash ?? DUMMY_HASH;
    const valid = await argon2.verify(hashToVerify, password);

    if (!user || !valid) {
      throw new AuthError('Invalid credentials', 401, ErrorCode.AUTH_INVALID_CREDENTIALS);
    }

    if (key.keyUserId !== null && key.keyUserId !== user.id) {
      throw new AuthError('API key belongs to a different account', 403, ErrorCode.AUTH_KEY_CLAIMED);
    }

    const signChallengeToken = this.signChallengeToken;
    if (user.totpEnabled && signChallengeToken) {
      const authenticatedVersion = sessionVersionClaim(user.sessionVersion);
      // Lock the principal while issuing the challenge. A concurrent security
      // transition either happens first (and changes the expected version) or
      // after this challenge is signed (and then invalidates it).
      return this.db.transaction(async (tx) => {
        const currentVersion = await this.sessions.lockUserSession(tx, user.id);
        if (currentVersion !== authenticatedVersion) {
          throw new AuthError('Session has been revoked', 401, ErrorCode.AUTH_SESSION_REVOKED);
        }
        // Claim unclaimed key before returning challenge (same atomic logic).
        if (key.keyUserId === null) {
          const claimed = await tx
            .update(apiKeys)
            .set({ userId: user.id })
            .where(and(eq(apiKeys.id, key.keyId), isNull(apiKeys.userId)))
            .returning({ id: apiKeys.id });
          if (claimed.length === 0) {
            throw new AuthError('API key belongs to a different account', 403, ErrorCode.AUTH_KEY_CLAIMED);
          }
        }
        return {
          requires2fa: true as const,
          challengeToken: signChallengeToken(user.id, currentVersion),
        };
      });
    }

    // Refresh token: 256-bit cryptographically random opaque value.
    // Only the SHA-256 hash is stored — a DB breach cannot replay tokens.
    const rawRefreshToken = randomBytes(32).toString('hex');
    const tokenHash = sha256Hex(rawRefreshToken);
    const familyId = randomUUID();

    // Set app.current_user_id so the INSERT passes the refresh_tokens RLS policy
    // (RLS requires user_id = current_setting('app.current_user_id')::UUID).
    let accessToken: string | undefined;
    await this.db.transaction(async (tx) => {
      const currentVersion = await this.sessions.lockUserSession(tx, user.id);
      if (currentVersion !== sessionVersionClaim(user.sessionVersion)) {
        throw new AuthError('Session has been revoked', 401, ErrorCode.AUTH_SESSION_REVOKED);
      }

      if (key.keyUserId === null) {
        // First login on this installation: claim the key, exactly as
        // register() does for new accounts. The user_id IS NULL predicate
        // makes the claim atomic — if a concurrent login or register won
        // the race, zero rows match and we abort instead of overwriting.
        const claimed = await tx
          .update(apiKeys)
          .set({ userId: user.id })
          .where(and(eq(apiKeys.id, key.keyId), isNull(apiKeys.userId)))
          .returning({ id: apiKeys.id });
        if (claimed.length === 0) {
          throw new AuthError('API key belongs to a different account', 403, ErrorCode.AUTH_KEY_CLAIMED);
        }
      }

      const expiresAt = new Date((await databaseWallClock(tx)).getTime() + 30 * 24 * 60 * 60 * 1000);
      accessToken = this.signAccessToken(user.id, currentVersion);
      await tx.insert(refreshTokens).values({
        userId: user.id,
        tokenHash,
        familyId,
        expiresAt,
      });
    });

    if (!accessToken) throw new AuthError('Token issuance failed', 500);
    return { accessToken, refreshToken: rawRefreshToken };
  }

  // -------------------------------------------------------------------------
  // completeLogin — issues tokens for a user whose credentials are already verified
  // Used by the 2FA challenge flow after TOTP is validated.
  // -------------------------------------------------------------------------

  async completeLogin(userId: string, expectedSessionVersion?: string): Promise<{ accessToken: string; refreshToken: string }> {
    const rawRefreshToken = randomBytes(32).toString('hex');
    const tokenHash = sha256Hex(rawRefreshToken);
    const familyId = randomUUID();

    let accessToken: string | undefined;
    await this.db.transaction(async (tx) => {
      const sessionVersion = await this.sessions.lockUserSession(tx, userId);
      if (sessionVersion === null
          || (expectedSessionVersion !== undefined && sessionVersion !== expectedSessionVersion)) {
        throw new AuthError('User session is no longer valid', 401, ErrorCode.AUTH_SESSION_REVOKED);
      }
      const expiresAt = new Date((await databaseWallClock(tx)).getTime() + 30 * 24 * 60 * 60 * 1000);
      accessToken = this.signAccessToken(userId, sessionVersion);
      await tx.insert(refreshTokens).values({
        userId,
        tokenHash,
        familyId,
        expiresAt,
      });
    });

    if (!accessToken) throw new AuthError('Token issuance failed', 500);
    return { accessToken, refreshToken: rawRefreshToken };
  }

  // -------------------------------------------------------------------------
  // refresh
  // -------------------------------------------------------------------------

  async refresh(
    rawToken: string,
    proposedSuccessor?: string,
  ): Promise<{ accessToken: string; refreshToken: string }> {
    const tokenHash = sha256Hex(rawToken);

    // Phase 1: Read the token state to distinguish reuse from not-found.
    // Timing-safe comparison: even though we queried by hash index, we
    // explicitly verify with timingSafeEqual to prevent any code path that
    // performs an early-exit string comparison on token material.
    const [token] = await this.db
      .select()
      .from(refreshTokens)
      .where(eq(refreshTokens.tokenHash, tokenHash));

    if (!token || !timingSafeHexEqual(token.tokenHash, tokenHash)) {
      // A token of a deleted account: say so, so the device clears itself.
      if (await isDeletedAccountKey(this.db, tokenHash, 'refresh')) {
        throw new AuthError('Account was deleted', 401, ErrorCode.ACCOUNT_DELETED);
      }
      throw new AuthError('Invalid refresh token', 401, ErrorCode.AUTH_UNAUTHORIZED);
    }

    // Phase 2: rotate under the same principal and token-row locks used by
    // invalidation. Reuse is recorded and committed before its error returns.
    if (proposedSuccessor !== undefined && (!/^[0-9a-f]{64}$/.test(proposedSuccessor) || proposedSuccessor === rawToken)) {
      throw new AuthError('Invalid refresh proposal', 400);
    }
    const rawNewToken = proposedSuccessor ?? randomBytes(32).toString('hex');
    const newTokenHash = sha256Hex(rawNewToken);

    let accessToken: string | undefined;
    let sessionRevoked = false;
    let expired = false;
    let reuseDetected = false;

    await this.db.transaction(async (tx) => {
      const sessionVersion = await this.sessions.lockUserSession(tx, token.userId);
      if (sessionVersion === null) {
        sessionRevoked = true;
        return;
      }
      await this.runtime.testHooks?.afterRefreshSessionLock?.();

      const rows = await tx.execute(drizzleSql`
        SELECT user_id, family_id, revoked, expires_at, successor_token_hash
        FROM refresh_tokens
        WHERE id = ${token.id}
        FOR UPDATE
      `) as Array<{
        user_id: string;
        family_id: string;
        revoked: boolean;
        expires_at: Date | string;
        successor_token_hash: string | null;
      }>;
      const current = rows[0];
      if (!current || current.user_id !== token.userId || current.family_id !== token.familyId) {
        sessionRevoked = true;
        return;
      }
      const now = await databaseWallClock(tx);
      if (current.revoked && proposedSuccessor !== undefined &&
          current.successor_token_hash !== null &&
          timingSafeHexEqual(current.successor_token_hash, newTokenHash)) {
        // Both secrets prove this exact transaction. Never mint credentials for
        // a revoked, expired, or subsequently rotated successor.
        const [successor] = await tx.select().from(refreshTokens).where(and(
          eq(refreshTokens.userId, token.userId),
          eq(refreshTokens.familyId, token.familyId),
          eq(refreshTokens.tokenHash, newTokenHash),
        ));
        if (!successor || successor.revoked || successor.expiresAt <= now) {
          sessionRevoked = true;
          return;
        }
        accessToken = this.signAccessToken(token.userId, sessionVersion);
        return;
      }
      if (current.revoked) {
        await tx.update(refreshTokens).set({ revoked: true }).where(eq(refreshTokens.familyId, token.familyId));
        reuseDetected = true;
        return;
      }
      if (new Date(current.expires_at).getTime() <= now.getTime()) {
        expired = true;
        return;
      }
      const expiresAt = new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000);

      await tx.update(refreshTokens).set({
        revoked: true,
        successorTokenHash: proposedSuccessor === undefined ? null : newTokenHash,
        rotatedAt: proposedSuccessor === undefined ? null : now,
      }).where(eq(refreshTokens.id, token.id));

      await tx.insert(refreshTokens).values({
        userId: token.userId,
        tokenHash: newTokenHash,
        familyId: token.familyId, // preserve family for reuse detection
        expiresAt,
        deviceName: token.deviceName ?? null,  // carry forward on rotation
      });

      accessToken = this.signAccessToken(token.userId, sessionVersion);
    });

    if (sessionRevoked) throw new AuthError('Session has been revoked', 401, ErrorCode.AUTH_SESSION_REVOKED);
    if (expired) throw new AuthError('Refresh token expired', 401, ErrorCode.AUTH_TOKEN_EXPIRED);
    if (reuseDetected) throw new AuthError('Refresh token reuse detected', 401, ErrorCode.AUTH_TOKEN_REUSE);
    if (!accessToken) throw new AuthError('Token rotation failed', 500);

    return { accessToken, refreshToken: rawNewToken };
  }

  // -------------------------------------------------------------------------
  // changePassword
  // -------------------------------------------------------------------------

  async changePassword(
    userId: string,
    currentPassword: string,
    newPassword: string,
  ): Promise<void> {
    if (newPassword.length < 10) {
      throw new AuthError('Password must be at least 10 characters', 400, ErrorCode.AUTH_PASSWORD_WEAK);
    }
    if (newPassword.length > 72) {
      throw new AuthError('Password must be at most 72 characters', 400, ErrorCode.AUTH_PASSWORD_LONG);
    }

    try {
      const [user] = await this.db
        .select({ id: users.id, passwordHash: users.passwordHash })
        .from(users)
        .where(eq(users.id, userId));

      if (!user) {
        throw new AuthError('User not found', 404, ErrorCode.AUTH_USER_NOT_FOUND);
      }

      const valid = await argon2.verify(user.passwordHash, currentPassword);
      if (!valid) {
        throw new AuthError('Current password is incorrect', 400, ErrorCode.AUTH_INVALID_CREDENTIALS);
      }

      const newHash = await argon2.hash(newPassword, ARGON2_OPTIONS);

      await this.db.transaction(async (tx) => {
        await tx.execute(
          drizzleSql`SELECT set_config('app.current_user_id', ${userId}, true)`,
        );

        await tx
          .update(users)
          .set({ passwordHash: newHash })
          .where(eq(users.id, userId));

        // Revoke ALL refresh tokens — force re-login on other devices.
        await tx
          .update(refreshTokens)
          .set({ revoked: true })
          .where(eq(refreshTokens.userId, userId));

        await this.sessions.invalidateUserSessions(userId, tx);
      });
    } catch (err) {
      if (err instanceof AuthError) throw err;
      throw new AuthError('Password change failed', 500);
    }
  }

  // -------------------------------------------------------------------------
  // logout
  // -------------------------------------------------------------------------

  async logout(rawToken: string): Promise<void> {
    const tokenHash = sha256Hex(rawToken);

    const [token] = await this.db
      .select({ userId: refreshTokens.userId, familyId: refreshTokens.familyId })
      .from(refreshTokens)
      .where(eq(refreshTokens.tokenHash, tokenHash));

    if (!token) {
      // Token not found — idempotent, no error.
      return;
    }

    await this.db.transaction(async (tx) => {
      await this.sessions.lockUserSession(tx, token.userId);
      await tx
        .update(refreshTokens)
        .set({ revoked: true })
        .where(and(eq(refreshTokens.userId, token.userId), eq(refreshTokens.familyId, token.familyId)));
    });
  }

  async logoutAll(userId: string): Promise<void> {
    try {
      await this.sessions.invalidateUserSessions(userId);
    } catch (err) {
      throw new AuthError('Session invalidation failed', 500, ErrorCode.INTERNAL);
    }
  }
}
