import { randomBytes, timingSafeEqual, randomUUID } from 'node:crypto';
import * as argon2 from 'argon2';
import { and, eq, sql as drizzleSql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { adminConfig, adminRefreshTokens, apiKeys, users, refreshTokens } from '../../db/schema.js';
import { sha256Hex } from '../../lib/crypto.js';
import type { EncryptionCapabilities } from '../../lib/crypto.js';
import { ErrorCode, type ErrorCodeValue } from '../shared/errors.js';
import { BootstrapError, BootstrapService } from './bootstrap.service.js';
import { SessionService, sessionVersionClaim } from '../auth/session.service.js';

const ARGON2_OPTIONS = { type: argon2.argon2id, memoryCost: 65536, timeCost: 3, parallelism: 4 } as const;

export class AdminError extends Error {
  constructor(message: string, readonly statusCode: number, readonly code: ErrorCodeValue = ErrorCode.ADMIN_UNAUTHORIZED) { super(message); }
}

export interface AdminRuntimeConfig {
  credentials?: {
    email: string;
    password: string;
  };
}

function timingSafeHexEqual(a: string, b: string) {
  return timingSafeEqual(Buffer.from(a, 'hex'), Buffer.from(b, 'hex'));
}

async function databaseWallClock(tx: any): Promise<Date> {
  const rows = await tx.execute(drizzleSql`SELECT clock_timestamp() AS now`) as Array<{ now: Date | string }>;
  return new Date(rows[0]!.now);
}

export class AdminService {
  constructor(
    private readonly db: Db,
    private readonly signAdminToken: (sessionVersion?: string, sid?: string) => string,
    private readonly signChallengeToken: (sessionVersion?: string) => string,
    private readonly crypto: EncryptionCapabilities,
    private readonly runtime: AdminRuntimeConfig = {},
    private readonly sessions: SessionService = new SessionService(db, { environmentManagedAdmin: runtime.credentials !== undefined }),
  ) {}

  // ── Setup ──────────────────────────────────────────────────────────────────

  async isAdminConfigured(): Promise<boolean> {
    if (this.runtime.credentials) return true;
    const [row] = await this.db.select({ id: adminConfig.id }).from(adminConfig);
    return !!row;
  }

  async setup(email: string, password: string, proof?: string): Promise<void> {
    if (this.runtime.credentials) {
      throw new AdminError(
        'Admin is configured via environment variables — database bootstrap is disabled',
        400,
        ErrorCode.ADMIN_ENV_MANAGED,
      );
    }
    try {
      await new BootstrapService(this.db).consumeAndCreateAdmin(email, password, proof);
    } catch (err) {
      if (err instanceof BootstrapError) {
        throw new AdminError(err.message, err.statusCode, err.code);
      }
      throw err;
    }
  }

  // ── Auth ───────────────────────────────────────────────────────────────────

  async login(password: string): Promise<{ accessToken: string; refreshToken: string } | { requires2fa: true; challengeToken: string }> {
    let totpEnabled = false;
    let sessionVersion: string | null = await this.sessions.getAdminSessionVersion();

    if (this.runtime.credentials) {
      const expected = Buffer.from(sha256Hex(this.runtime.credentials.password), 'hex');
      const provided  = Buffer.from(sha256Hex(password), 'hex');
      const match = timingSafeEqual(expected, provided);
      if (!match) throw new AdminError('Invalid credentials', 401, ErrorCode.ADMIN_INVALID_CREDENTIALS);
      // Env-managed admin: check DB for 2FA state
      const [row] = await this.db.select({ totpEnabled: adminConfig.totpEnabled, sessionVersion: adminConfig.sessionVersion }).from(adminConfig);
      totpEnabled = row?.totpEnabled ?? false;
      if (row) sessionVersion = sessionVersionClaim(row.sessionVersion);
    } else {
      const [row] = await this.db.select().from(adminConfig);
      if (!row || !(await argon2.verify(row.passwordHash, password))) {
        throw new AdminError('Invalid credentials', 401, ErrorCode.ADMIN_INVALID_CREDENTIALS);
      }
      totpEnabled = row.totpEnabled;
      sessionVersion = sessionVersionClaim(row.sessionVersion);
    }

    if (sessionVersion === null) {
      throw new AdminError('Admin is not configured', 401, ErrorCode.ADMIN_UNAUTHORIZED);
    }

    if (totpEnabled && this.signChallengeToken) {
      return { requires2fa: true as const, challengeToken: this.signChallengeToken(sessionVersion) };
    }

    return this.issueTokens(sessionVersion);
  }

  async issueTokens(sessionVersion?: string): Promise<{ accessToken: string; refreshToken: string }> {
    const rawRefreshToken = randomBytes(32).toString('hex');
    const tokenHash = sha256Hex(rawRefreshToken);
    const familyId = randomUUID();

    let accessToken: string | undefined;
    await this.sessions.runAdminSessionTransaction(async (tx) => {
      const currentVersion = await this.sessions.lockAdminSession(tx);
      if (currentVersion === null) {
        throw new AdminError('Admin is not configured', 401, ErrorCode.ADMIN_UNAUTHORIZED);
      }
      if (sessionVersion !== undefined && currentVersion !== sessionVersion) {
        throw new AdminError('Session has been revoked', 401, ErrorCode.AUTH_SESSION_REVOKED);
      }
      const expiresAt = new Date((await databaseWallClock(tx)).getTime() + 30 * 24 * 60 * 60 * 1000);
      accessToken = this.signAdminToken(currentVersion, familyId);
      await tx.insert(adminRefreshTokens).values({ tokenHash, familyId, expiresAt });
    });
    if (!accessToken) throw new AdminError('Token issuance failed', 500);
    return { accessToken, refreshToken: rawRefreshToken };
  }

  async refresh(rawToken: string): Promise<{ accessToken: string; refreshToken: string }> {
    const tokenHash = sha256Hex(rawToken);
    const [token] = await this.db.select().from(adminRefreshTokens).where(eq(adminRefreshTokens.tokenHash, tokenHash));
    if (!token || !timingSafeHexEqual(token.tokenHash, tokenHash)) throw new AdminError('Invalid token', 401);
    const rawNew = randomBytes(32).toString('hex');
    const newHash = sha256Hex(rawNew);

    let accessToken: string | undefined;
    let sessionRevoked = false;
    let expired = false;
    let reuseDetected = false;
    await this.sessions.runAdminSessionTransaction(async (tx) => {
      const currentVersion = await this.sessions.lockAdminSession(tx);
      if (currentVersion === null) {
        sessionRevoked = true;
        return;
      }
      const rows = await tx.execute(drizzleSql`
        SELECT family_id, revoked, expires_at
        FROM admin_refresh_tokens
        WHERE id = ${token.id}
        FOR UPDATE
      `) as Array<{
        family_id: string;
        revoked: boolean;
        expires_at: Date | string;
      }>;
      const current = rows[0];
      if (!current || current.family_id !== token.familyId) {
        sessionRevoked = true;
        return;
      }
      if (current.revoked) {
        await tx.update(adminRefreshTokens).set({ revoked: true }).where(eq(adminRefreshTokens.familyId, token.familyId));
        reuseDetected = true;
        return;
      }
      const now = await databaseWallClock(tx);
      if (new Date(current.expires_at).getTime() <= now.getTime()) {
        expired = true;
        return;
      }
      const expiresAt = new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000);
      await tx.update(adminRefreshTokens).set({ revoked: true }).where(eq(adminRefreshTokens.id, token.id));
      await tx.insert(adminRefreshTokens).values({ tokenHash: newHash, familyId: token.familyId, expiresAt });
      accessToken = this.signAdminToken(currentVersion, token.familyId);
    });

    if (sessionRevoked) throw new AdminError('Session has been revoked', 401, ErrorCode.AUTH_SESSION_REVOKED);
    if (expired) throw new AdminError('Token expired', 401);
    if (reuseDetected) throw new AdminError('Token reuse detected', 401);
    if (!accessToken) throw new AdminError('Token rotation failed', 500);
    return { accessToken, refreshToken: rawNew };
  }

  async changePassword(newPassword: string): Promise<void> {
    if (this.runtime.credentials) {
      throw new AdminError('Admin is configured via environment variables — update ADMIN_PASSWORD env var instead', 400, ErrorCode.ADMIN_ENV_MANAGED);
    }
    const passwordHash = await argon2.hash(newPassword, ARGON2_OPTIONS);
    await this.sessions.runAdminSessionTransaction(async (tx) => {
      const current = await this.sessions.lockAdminSession(tx);
      if (current === null) throw new AdminError('Admin is not configured', 401, ErrorCode.ADMIN_UNAUTHORIZED);
      await tx.update(adminConfig).set({ passwordHash });
      return this.sessions.invalidateAdminSessionsInTransaction(tx);
    }, (outcome) => outcome.processOnly ? outcome.version ?? undefined : undefined);
  }

  /** Ends one sign-in. Safe to repeat: a session that is already over is not an error. */
  async logout(sid: string | undefined): Promise<void> {
    if (sid) await this.sessions.revokeAdminSession(sid);
  }

  async logoutAll(): Promise<void> {
    await this.sessions.invalidateAdminSessions();
  }

  // ── Keys ───────────────────────────────────────────────────────────────────

  async listKeys() {
    return this.db.select().from(apiKeys);
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  async createKey(label: string, userId?: string, tx?: any): Promise<{ rawKey: string; keyId: string }> {
    const conn = tx ?? this.db;
    const rawKey = randomBytes(32).toString('hex');
    const keyHash = sha256Hex(rawKey);
    const encryptedKey: string | null = this.crypto.encrypt(rawKey);
    const [row] = await conn
      .insert(apiKeys)
      .values({ keyHash, encryptedKey, label, userId: userId ?? null })
      .returning({ id: apiKeys.id });
    if (!row) throw new AdminError('Key creation failed', 500);
    return { rawKey, keyId: row.id };
  }

  /** Creates a fresh, unclaimed key reserved for a one-time invitation. */
  async createInviteKey(label: string, tx: any): Promise<{ rawKey: string; keyId: string }> {
    return this.createKey(label, undefined, tx);
  }

  async revealKey(keyId: string): Promise<string | null> {
    const [row] = await this.db.select({ encryptedKey: apiKeys.encryptedKey }).from(apiKeys).where(eq(apiKeys.id, keyId));
    if (!row) throw new AdminError('Key not found', 404);
    if (!row.encryptedKey) return null;
    return this.crypto.decrypt(row.encryptedKey);
  }

  async listUserKeys(userId: string) {
    return this.db.select().from(apiKeys).where(eq(apiKeys.userId, userId));
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  async revokeKey(keyId: string, tx?: any): Promise<void> {
    const conn = tx ?? this.db;
    await conn.update(apiKeys).set({ revokedAt: new Date() }).where(eq(apiKeys.id, keyId));
  }

  // ── Users ──────────────────────────────────────────────────────────────────
  // NOTE: These queries work because the RLS-protected tables have permissive
  // FOR SELECT USING (true) policies. Tightening those SELECT policies to
  // restrict by user_id would break admin list/device operations.

  async listUsers() {
    return this.db.select({ id: users.id, email: users.email, createdAt: users.createdAt }).from(users);
  }

  async listDevices(userId: string) {
    const rows = await this.db.execute<{
      family_id: string; device_name: string | null; logged_in_at: Date; last_used_at: Date;
    }>(drizzleSql`
      SELECT DISTINCT ON (family_id)
             family_id,
             device_name,
             MIN(created_at) OVER (PARTITION BY family_id) AS logged_in_at,
             created_at AS last_used_at
      FROM refresh_tokens
      WHERE user_id = ${userId}
        AND revoked = false
        AND expires_at > now()
      ORDER BY family_id, created_at DESC
    `);
    return rows;
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  async logoutDevice(userId: string, familyId: string, outerTx?: any): Promise<number> {
    const run = async (tx: any) => {
      await this.sessions.lockUserSession(tx, userId);
      const rows = await tx
        .update(refreshTokens)
        .set({ revoked: true })
        .where(and(eq(refreshTokens.familyId, familyId), eq(refreshTokens.userId, userId)))
        .returning({ id: refreshTokens.id });
      return rows.length;
    };
    return outerTx ? run(outerTx) : this.db.transaction(run);
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  async deleteUser(userId: string, outerTx?: any): Promise<number> {
    const run = async (tx: any) => {
      await tx.execute(drizzleSql`SELECT set_config('app.current_user_id', ${userId}, true)`);
      const rows = await tx.delete(users).where(eq(users.id, userId)).returning({ id: users.id });
      return rows.length;
    };
    return outerTx ? run(outerTx) : this.db.transaction(run);
  }
}
