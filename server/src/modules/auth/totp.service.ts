import { randomBytes } from 'node:crypto';
import * as argon2 from 'argon2';
import { TOTP, Secret } from 'otpauth';
import { count, eq, isNull, sql as drizzleSql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { users, adminConfig, backupCodes } from '../../db/schema.js';
import { ErrorCode, type ErrorCodeValue } from '../shared/errors.js';
import type { EncryptionCapabilities } from '../../lib/crypto.js';
import { SessionService } from './session.service.js';

const ARGON2_OPTIONS = { type: argon2.argon2id, memoryCost: 65536, timeCost: 3, parallelism: 4 } as const;
const ISSUER = 'Simpastil';
const BACKUP_CODE_COUNT = 8;
const BACKUP_CODE_BYTES = 4;

export class TotpError extends Error {
  constructor(message: string, readonly statusCode: number, readonly code: ErrorCodeValue) {
    super(message);
    this.name = 'TotpError';
  }
}

function generateBackupCodes(): string[] {
  return Array.from({ length: BACKUP_CODE_COUNT }, () =>
    randomBytes(BACKUP_CODE_BYTES).toString('hex'),
  );
}

function getPlaintextSecret(stored: string, crypto: EncryptionCapabilities): string {
  return crypto.isEncrypted(stored) ? crypto.decrypt(stored) : stored;
}

function createTotp(secret: string, label: string, crypto: EncryptionCapabilities): TOTP {
  const plaintext = getPlaintextSecret(secret, crypto);
  return new TOTP({ issuer: ISSUER, label, secret: Secret.fromBase32(plaintext), digits: 6, period: 30 });
}

// ---------------------------------------------------------------------------
// User TOTP
// ---------------------------------------------------------------------------

export class UserTotpService {
  constructor(
    private readonly db: Db,
    private readonly crypto: EncryptionCapabilities,
    private readonly sessions: SessionService = new SessionService(db),
  ) {}

  async setup(userId: string): Promise<{ secret: string; otpauthUri: string }> {
    const [user] = await this.db.select().from(users).where(eq(users.id, userId));
    if (!user) throw new TotpError('User not found', 404, ErrorCode.AUTH_USER_NOT_FOUND);
    if (user.totpEnabled) throw new TotpError('2FA is already enabled', 409, ErrorCode.TOTP_ALREADY_ENABLED);

    const secret = new Secret({ size: 20 });
    const base32 = secret.base32;
    const totp = new TOTP({ issuer: ISSUER, label: user.email, secret, digits: 6, period: 30 });
    const encrypted = this.crypto.encrypt(base32);

    await this.db.transaction(async (tx) => {
      await tx.execute(drizzleSql`SELECT set_config('app.current_user_id', ${userId}, true)`);
      await tx.update(users).set({ totpSecret: encrypted }).where(eq(users.id, userId));
    });

    return { secret: base32, otpauthUri: totp.toString() };
  }

  async enable(userId: string, code: string): Promise<{ backupCodes: string[] }> {
    const [user] = await this.db.select().from(users).where(eq(users.id, userId));
    if (!user) throw new TotpError('User not found', 404, ErrorCode.AUTH_USER_NOT_FOUND);
    if (user.totpEnabled) throw new TotpError('2FA is already enabled', 409, ErrorCode.TOTP_ALREADY_ENABLED);
    if (!user.totpSecret) throw new TotpError('Call /2fa/setup first', 400, ErrorCode.TOTP_SETUP_REQUIRED);

    const totp = createTotp(user.totpSecret, user.email, this.crypto);
    const delta = totp.validate({ token: code, window: 1 });
    if (delta === null) throw new TotpError('Invalid TOTP code', 400, ErrorCode.TOTP_INVALID_CODE);

    const rawCodes = generateBackupCodes();
    const hashedCodes = await Promise.all(rawCodes.map((c) => argon2.hash(c, ARGON2_OPTIONS)));

    await this.db.transaction(async (tx) => {
      await tx.execute(drizzleSql`SELECT set_config('app.current_user_id', ${userId}, true)`);
      // Write to array column for backwards compat during rollout
      await tx.update(users).set({ totpEnabled: true, totpBackupCodes: hashedCodes }).where(eq(users.id, userId));
      // Also insert into backup_codes table for atomic consumption (H-2)
      await tx.delete(backupCodes).where(eq(backupCodes.userId, userId));
      for (const hash of hashedCodes) {
        await tx.insert(backupCodes).values({ userId, codeHash: hash });
      }
      await this.sessions.invalidateUserSessions(userId, tx);
    });

    return { backupCodes: rawCodes };
  }

  async disable(userId: string, code: string): Promise<void> {
    const [user] = await this.db.select().from(users).where(eq(users.id, userId));
    if (!user) throw new TotpError('User not found', 404, ErrorCode.AUTH_USER_NOT_FOUND);
    if (!user.totpEnabled) throw new TotpError('2FA is not enabled', 400, ErrorCode.TOTP_NOT_ENABLED);

    const valid = await this.verifyCode(user, code, userId);
    if (!valid.ok) throw new TotpError('Invalid code', 400, ErrorCode.TOTP_INVALID_CODE);

    await this.db.transaction(async (tx) => {
      await tx.execute(drizzleSql`SELECT set_config('app.current_user_id', ${userId}, true)`);
      await tx.update(users).set({
        totpEnabled: false,
        totpSecret: null,
        totpBackupCodes: null,
        totpLastUsedStep: null,
      }).where(eq(users.id, userId));
      await tx.delete(backupCodes).where(eq(backupCodes.userId, userId));
      await this.sessions.invalidateUserSessions(userId, tx);
    });
  }

  async verifyChallenge(userId: string, code: string): Promise<void> {
    const [user] = await this.db.select().from(users).where(eq(users.id, userId));
    if (!user || !user.totpEnabled) throw new TotpError('Invalid challenge', 400, ErrorCode.TOTP_CHALLENGE_INVALID);

    const result = await this.verifyCode(user, code, userId);
    if (!result.ok) throw new TotpError('Invalid TOTP code', 400, ErrorCode.TOTP_INVALID_CODE);
  }

  async regenerateBackupCodes(userId: string, code: string): Promise<{ backupCodes: string[] }> {
    const [user] = await this.db.select().from(users).where(eq(users.id, userId));
    if (!user) throw new TotpError('User not found', 404, ErrorCode.AUTH_USER_NOT_FOUND);
    if (!user.totpEnabled || !user.totpSecret) throw new TotpError('2FA is not enabled', 400, ErrorCode.TOTP_NOT_ENABLED);

    const totp = createTotp(user.totpSecret, user.email, this.crypto);
    const delta = totp.validate({ token: code, window: 1 });
    if (delta === null) throw new TotpError('Invalid TOTP code', 400, ErrorCode.TOTP_INVALID_CODE);

    const rawCodes = generateBackupCodes();
    const hashedCodes = await Promise.all(rawCodes.map((c) => argon2.hash(c, ARGON2_OPTIONS)));

    await this.db.transaction(async (tx) => {
      await tx.execute(drizzleSql`SELECT set_config('app.current_user_id', ${userId}, true)`);
      // Update array column for backwards compat
      await tx.update(users).set({ totpBackupCodes: hashedCodes }).where(eq(users.id, userId));
      // Replace all rows in backup_codes table (H-2)
      await tx.delete(backupCodes).where(eq(backupCodes.userId, userId));
      for (const hash of hashedCodes) {
        await tx.insert(backupCodes).values({ userId, codeHash: hash });
      }
      await this.sessions.invalidateUserSessions(userId, tx);
    });

    return { backupCodes: rawCodes };
  }

  private async verifyCode(
    user: { totpSecret: string | null; email: string; totpLastUsedStep: number | null },
    code: string,
    userId: string,
  ): Promise<{ ok: boolean }> {
    // Try TOTP code first
    if (user.totpSecret) {
      const totp = createTotp(user.totpSecret, user.email, this.crypto);
      const delta = totp.validate({ token: code, window: 1 });
      if (delta !== null) {
        // Replay protection (H-3): reject if time-step was already used
        const currentStep = Math.floor(Date.now() / (30 * 1000)) + delta;
        if (user.totpLastUsedStep !== null && currentStep <= user.totpLastUsedStep) {
          return { ok: false };
        }
        // Record the used time-step
        await this.db.transaction(async (tx) => {
          await tx.execute(drizzleSql`SELECT set_config('app.current_user_id', ${userId}, true)`);
          await tx.update(users).set({ totpLastUsedStep: currentStep }).where(eq(users.id, userId));
        });
        return { ok: true };
      }
    }

    // Try backup codes from the backup_codes table (H-2: atomic consumption)
    // Wrap in transaction with RLS context for user-scoped access
    const result = await this.db.transaction(async (tx) => {
      await tx.execute(drizzleSql`SELECT set_config('app.current_user_id', ${userId}, true)`);
      const codes = await tx.select().from(backupCodes).where(eq(backupCodes.userId, userId));
      for (const row of codes) {
        if (await argon2.verify(row.codeHash, code)) {
          // Atomic DELETE — 0 rows returned means another request consumed it first
          const deleted = await tx.delete(backupCodes)
            .where(eq(backupCodes.id, row.id))
            .returning({ id: backupCodes.id });
          if (deleted.length > 0) {
            return { ok: true };
          }
          // Race: code was already consumed by a concurrent request
          return { ok: false };
        }
      }
      return { ok: false };
    });

    return result;
  }
}

// ---------------------------------------------------------------------------
// Admin TOTP
// ---------------------------------------------------------------------------

export class AdminTotpService {
  constructor(
    private readonly db: Db,
    private readonly crypto: EncryptionCapabilities,
    private readonly sessions: SessionService = new SessionService(db),
  ) {}

  /**
   * What the console needs to pick the right screen. `available` is false for
   * an environment-managed administrator that has no database row to hold a
   * secret. Counts only; never a secret, a hash or a code.
   */
  async status(): Promise<{ available: boolean; enabled: boolean; backupCodesRemaining: number }> {
    const [admin] = await this.db.select({ totpEnabled: adminConfig.totpEnabled }).from(adminConfig);
    if (!admin) return { available: false, enabled: false, backupCodesRemaining: 0 };
    if (!admin.totpEnabled) return { available: true, enabled: false, backupCodesRemaining: 0 };
    const [row] = await this.db.select({ remaining: count() }).from(backupCodes).where(isNull(backupCodes.userId));
    return { available: true, enabled: true, backupCodesRemaining: Number(row?.remaining ?? 0) };
  }

  async setup(): Promise<{ secret: string; otpauthUri: string }> {
    const [admin] = await this.db.select().from(adminConfig);
    if (!admin) throw new TotpError('Admin not configured', 404, ErrorCode.ADMIN_UNAUTHORIZED);
    if (admin.totpEnabled) throw new TotpError('2FA is already enabled', 409, ErrorCode.TOTP_ALREADY_ENABLED);

    const secret = new Secret({ size: 20 });
    const base32 = secret.base32;
    const totp = new TOTP({ issuer: ISSUER, label: admin.email, secret, digits: 6, period: 30 });
    const encrypted = this.crypto.encrypt(base32);

    await this.sessions.runAdminSessionTransaction(async (tx) => {
      const current = await this.sessions.lockAdminSession(tx);
      if (current === null) throw new TotpError('Admin not configured', 404, ErrorCode.ADMIN_UNAUTHORIZED);
      await tx.update(adminConfig).set({ totpSecret: encrypted });
    });
    return { secret: base32, otpauthUri: totp.toString() };
  }

  async enable(code: string): Promise<{ backupCodes: string[] }> {
    const [admin] = await this.db.select().from(adminConfig);
    if (!admin) throw new TotpError('Admin not configured', 404, ErrorCode.ADMIN_UNAUTHORIZED);
    if (admin.totpEnabled) throw new TotpError('2FA is already enabled', 409, ErrorCode.TOTP_ALREADY_ENABLED);
    if (!admin.totpSecret) throw new TotpError('Call /2fa/setup first', 400, ErrorCode.TOTP_SETUP_REQUIRED);

    const totp = createTotp(admin.totpSecret, admin.email, this.crypto);
    const delta = totp.validate({ token: code, window: 1 });
    if (delta === null) throw new TotpError('Invalid TOTP code', 400, ErrorCode.TOTP_INVALID_CODE);

    const rawCodes = generateBackupCodes();
    const hashedCodes = await Promise.all(rawCodes.map((c) => argon2.hash(c, ARGON2_OPTIONS)));

    await this.sessions.runAdminSessionTransaction(async (tx) => {
      const current = await this.sessions.lockAdminSession(tx);
      if (current === null) throw new TotpError('Admin not configured', 404, ErrorCode.ADMIN_UNAUTHORIZED);
      // Write to array column for backwards compat
      await tx.update(adminConfig).set({ totpEnabled: true, totpBackupCodes: hashedCodes });
      // Also insert into backup_codes table for atomic consumption (H-2)
      // Admin codes have userId = NULL
      await tx.delete(backupCodes).where(isNull(backupCodes.userId));
      for (const hash of hashedCodes) {
        await tx.insert(backupCodes).values({ userId: null, codeHash: hash });
      }
      return this.sessions.invalidateAdminSessionsInTransaction(tx);
    }, (outcome) => outcome.processOnly ? outcome.version ?? undefined : undefined);
    return { backupCodes: rawCodes };
  }

  async disable(code: string): Promise<void> {
    const [admin] = await this.db.select().from(adminConfig);
    if (!admin) throw new TotpError('Admin not configured', 404, ErrorCode.ADMIN_UNAUTHORIZED);
    if (!admin.totpEnabled) throw new TotpError('2FA is not enabled', 400, ErrorCode.TOTP_NOT_ENABLED);

    const valid = await this.verifyCode(admin, code);
    if (!valid.ok) throw new TotpError('Invalid code', 400, ErrorCode.TOTP_INVALID_CODE);

    await this.sessions.runAdminSessionTransaction(async (tx) => {
      const current = await this.sessions.lockAdminSession(tx);
      if (current === null) throw new TotpError('Admin not configured', 404, ErrorCode.ADMIN_UNAUTHORIZED);
      await tx.update(adminConfig).set({
        totpEnabled: false,
        totpSecret: null,
        totpBackupCodes: null,
        totpLastUsedStep: null,
      });
      await tx.delete(backupCodes).where(isNull(backupCodes.userId));
      return this.sessions.invalidateAdminSessionsInTransaction(tx);
    }, (outcome) => outcome.processOnly ? outcome.version ?? undefined : undefined);
  }

  async verifyChallenge(code: string): Promise<void> {
    const [admin] = await this.db.select().from(adminConfig);
    if (!admin || !admin.totpEnabled) throw new TotpError('Invalid challenge', 400, ErrorCode.TOTP_CHALLENGE_INVALID);

    const result = await this.verifyCode(admin, code);
    if (!result.ok) throw new TotpError('Invalid TOTP code', 400, ErrorCode.TOTP_INVALID_CODE);
  }

  async regenerateBackupCodes(code: string): Promise<{ backupCodes: string[] }> {
    const [admin] = await this.db.select().from(adminConfig);
    if (!admin) throw new TotpError('Admin not configured', 404, ErrorCode.ADMIN_UNAUTHORIZED);
    if (!admin.totpEnabled || !admin.totpSecret) throw new TotpError('2FA is not enabled', 400, ErrorCode.TOTP_NOT_ENABLED);

    const totp = createTotp(admin.totpSecret, admin.email, this.crypto);
    const delta = totp.validate({ token: code, window: 1 });
    if (delta === null) throw new TotpError('Invalid TOTP code', 400, ErrorCode.TOTP_INVALID_CODE);

    const rawCodes = generateBackupCodes();
    const hashedCodes = await Promise.all(rawCodes.map((c) => argon2.hash(c, ARGON2_OPTIONS)));

    await this.sessions.runAdminSessionTransaction(async (tx) => {
      const current = await this.sessions.lockAdminSession(tx);
      if (current === null) throw new TotpError('Admin not configured', 404, ErrorCode.ADMIN_UNAUTHORIZED);
      // Update array column for backwards compat
      await tx.update(adminConfig).set({ totpBackupCodes: hashedCodes });
      // Replace all rows in backup_codes table (H-2)
      await tx.delete(backupCodes).where(isNull(backupCodes.userId));
      for (const hash of hashedCodes) {
        await tx.insert(backupCodes).values({ userId: null, codeHash: hash });
      }
      return this.sessions.invalidateAdminSessionsInTransaction(tx);
    }, (outcome) => outcome.processOnly ? outcome.version ?? undefined : undefined);
    return { backupCodes: rawCodes };
  }

  private async verifyCode(
    admin: { totpSecret: string | null; email: string; totpLastUsedStep: number | null },
    code: string,
  ): Promise<{ ok: boolean }> {
    // Try TOTP code first
    if (admin.totpSecret) {
      const totp = createTotp(admin.totpSecret, admin.email, this.crypto);
      const delta = totp.validate({ token: code, window: 1 });
      if (delta !== null) {
        // Replay protection (H-3): reject if time-step was already used
        const currentStep = Math.floor(Date.now() / (30 * 1000)) + delta;
        if (admin.totpLastUsedStep !== null && currentStep <= admin.totpLastUsedStep) {
          return { ok: false };
        }
        // Record the used time-step
        await this.db.update(adminConfig).set({ totpLastUsedStep: currentStep });
        return { ok: true };
      }
    }

    // Try backup codes from the backup_codes table (H-2: atomic consumption)
    // Admin codes have userId = NULL — wrapped in a transaction for atomicity
    const result = await this.db.transaction(async (tx) => {
      const codes = await tx.select().from(backupCodes).where(isNull(backupCodes.userId));
      for (const row of codes) {
        if (await argon2.verify(row.codeHash, code)) {
          // Atomic DELETE — 0 rows returned means another request consumed it first
          const deleted = await tx.delete(backupCodes)
            .where(eq(backupCodes.id, row.id))
            .returning({ id: backupCodes.id });
          if (deleted.length > 0) {
            return { ok: true };
          }
          // Race: code was already consumed by a concurrent request
          return { ok: false };
        }
      }
      return { ok: false };
    });

    return result;
  }
}
