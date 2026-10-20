import { eq, sql as drizzleSql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { serverSettings } from '../../db/schema.js';
import { ErrorCode, type ErrorCodeValue } from '../shared/errors.js';

export type PasswordResetMode = 'email' | 'manual';

export const DEFAULT_RESET_LINK_LIFETIME_MINUTES = 60;
export const MIN_RESET_LINK_LIFETIME_MINUTES = 5;
export const MAX_RESET_LINK_LIFETIME_MINUTES = 1440;

/** Invitation links keep a fixed lifetime regardless of the reset setting. */
export const INVITATION_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000;

export interface StoredServerSettings {
  /** NULL means automatic: email when SMTP is configured, otherwise manual. */
  passwordResetMode: PasswordResetMode | null;
  resetLinkLifetimeMinutes: number;
  updatedAt: Date | null;
}

export interface ServerSettingsView extends StoredServerSettings {
  effectivePasswordResetMode: PasswordResetMode;
  smtpConfigured: boolean;
}

export interface SettingsPatch {
  passwordResetMode?: PasswordResetMode | null;
  resetLinkLifetimeMinutes?: number;
}

export interface EmailStatus {
  configured: boolean;
  effectiveMode: PasswordResetMode;
  /** Messages that failed for good in the last seven days. */
  recentPermanentFailures: number;
  /** The most recent of those failures, or null when there is none in the last seven days. */
  lastPermanentFailureAt: string | null;
}

export const EMAIL_STATUS_WINDOW_DAYS = 7;

export class SettingsError extends Error {
  constructor(message: string, readonly statusCode: number, readonly code: ErrorCodeValue) {
    super(message);
    this.name = 'SettingsError';
  }
}

/** Anything that can run a query: the pool or an open transaction. */
type Executor = Pick<Db, 'select' | 'update'>;

/**
 * Reads and writes the single server_settings row. The effective password
 * reset mode never exceeds what the deployment can do: email requires SMTP.
 */
export class SettingsService {
  constructor(
    private readonly db: Db,
    private readonly smtpConfigured: boolean,
  ) {}

  get isSmtpConfigured(): boolean {
    return this.smtpConfigured;
  }

  effectiveMode(stored: PasswordResetMode | null): PasswordResetMode {
    if (!this.smtpConfigured) return 'manual';
    return stored ?? 'email';
  }

  async readStored(executor: Executor = this.db): Promise<StoredServerSettings> {
    const [row] = await executor.select({
      passwordResetMode: serverSettings.passwordResetMode,
      resetLinkLifetimeMinutes: serverSettings.resetLinkLifetimeMinutes,
      updatedAt: serverSettings.updatedAt,
    }).from(serverSettings).where(eq(serverSettings.singletonKey, true));
    if (!row) {
      return {
        passwordResetMode: null,
        resetLinkLifetimeMinutes: DEFAULT_RESET_LINK_LIFETIME_MINUTES,
        updatedAt: null,
      };
    }
    return {
      passwordResetMode: row.passwordResetMode === 'email' || row.passwordResetMode === 'manual'
        ? row.passwordResetMode
        : null,
      resetLinkLifetimeMinutes: clampLifetime(row.resetLinkLifetimeMinutes),
      updatedAt: row.updatedAt,
    };
  }

  async get(executor: Executor = this.db): Promise<ServerSettingsView> {
    const stored = await this.readStored(executor);
    return {
      ...stored,
      effectivePasswordResetMode: this.effectiveMode(stored.passwordResetMode),
      smtpConfigured: this.smtpConfigured,
    };
  }

  /** Throws when the patch asks for email delivery on a server without SMTP. */
  async update(patch: SettingsPatch, executor: Executor = this.db): Promise<ServerSettingsView> {
    if (patch.passwordResetMode === 'email' && !this.smtpConfigured) {
      throw new SettingsError(
        'Email password reset needs SMTP_HOST to be configured on the server',
        409,
        ErrorCode.ADMIN_EMAIL_RESET_UNAVAILABLE,
      );
    }
    const set: Partial<typeof serverSettings.$inferInsert> = { updatedAt: new Date() };
    if (patch.passwordResetMode !== undefined) set.passwordResetMode = patch.passwordResetMode;
    if (patch.resetLinkLifetimeMinutes !== undefined) {
      set.resetLinkLifetimeMinutes = clampLifetime(patch.resetLinkLifetimeMinutes);
    }
    const updated = await executor.update(serverSettings)
      .set(set)
      .where(eq(serverSettings.singletonKey, true))
      .returning({ key: serverSettings.singletonKey });
    if (updated.length === 0) {
      throw new SettingsError('Server settings are not initialised', 500, ErrorCode.INTERNAL);
    }
    return this.get(executor);
  }

  /**
   * Admin-only delivery health. The API role cannot read the outbox, so the
   * two aggregates come from a definer function that returns no recipients,
   * payloads, ids or error text.
   */
  async emailStatus(): Promise<EmailStatus> {
    const stored = await this.readStored();
    const rows = await this.db.execute(drizzleSql`
      SELECT recent_permanent_failures, last_permanent_failure_at
      FROM public.read_email_delivery_status(${EMAIL_STATUS_WINDOW_DAYS})
    `) as unknown as Array<{
      recent_permanent_failures: string | number;
      last_permanent_failure_at: Date | string | null;
    }>;
    const row = rows[0];
    const recent = Number(row?.recent_permanent_failures ?? 0);
    const last = row?.last_permanent_failure_at ?? null;
    // The SQL function reports the newest failure of all time; the count covers
    // only the window. Drop a date older than the window so the two always agree.
    const windowStart = Date.now() - EMAIL_STATUS_WINDOW_DAYS * 86_400_000;
    const lastTime = last === null ? Number.NaN : new Date(last).getTime();
    return {
      configured: this.smtpConfigured,
      effectiveMode: this.effectiveMode(stored.passwordResetMode),
      recentPermanentFailures: recent,
      lastPermanentFailureAt: recent > 0 && lastTime >= windowStart ? new Date(lastTime).toISOString() : null,
    };
  }
}

function clampLifetime(minutes: number): number {
  if (!Number.isFinite(minutes)) return DEFAULT_RESET_LINK_LIFETIME_MINUTES;
  return Math.min(
    MAX_RESET_LINK_LIFETIME_MINUTES,
    Math.max(MIN_RESET_LINK_LIFETIME_MINUTES, Math.trunc(minutes)),
  );
}
