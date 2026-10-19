import { and, desc, eq, gte, lt, type SQL } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { auditLogs } from '../../db/schema.js';

export type AuditAction =
  | 'admin.login'
  | 'admin.password_change'
  | 'admin.2fa_enable'
  | 'admin.2fa_disable'
  | 'admin.2fa_backup_codes'
  | 'admin.logout'
  | 'admin.logout_all'
  | 'admin.login_failed'
  | 'key.create'
  | 'key.revoke'
  | 'key.reveal'
  | 'key.invite'
  | 'user.delete'
  | 'user.reset_link'
  | 'settings.update'
  | 'device.logout';

export class AuditService {
  constructor(private readonly db: Db) {}

  /**
   * Write an audit log entry.
   *
   * When `tx` is supplied the INSERT runs inside that transaction,
   * guaranteeing atomicity with the audited action.  When omitted
   * the service falls back to the default connection pool.
   */
  async log(
    actor: string,
    action: AuditAction,
    targetType: string,
    targetId: string | null,
    ip: string | null,
    metadata?: Record<string, unknown>,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    tx?: { insert: Db['insert'] },
  ): Promise<void> {
    const conn = tx ?? this.db;
    await conn.insert(auditLogs).values({
      actor,
      action,
      targetType,
      targetId,
      ipAddress: ip,
      metadata: metadata ?? null,
    });
  }

  /**
   * Newest first. Asks the database for one row more than `limit` so the
   * caller can tell whether another page exists without a second count query.
   */
  async list(opts: {
    limit: number;
    offset: number;
    action?: string | undefined;
    from?: Date | undefined;
    to?: Date | undefined;
  }) {
    const conditions: SQL[] = [];
    if (opts.action) conditions.push(eq(auditLogs.action, opts.action));
    if (opts.from) conditions.push(gte(auditLogs.createdAt, opts.from));
    if (opts.to) conditions.push(lt(auditLogs.createdAt, opts.to));

    const rows = await this.db
      .select()
      .from(auditLogs)
      .where(conditions.length ? and(...conditions) : undefined)
      // id breaks ties so entries written in the same instant never swap
      // between pages.
      .orderBy(desc(auditLogs.createdAt), desc(auditLogs.id))
      .limit(opts.limit + 1)
      .offset(opts.offset);

    return { entries: rows.slice(0, opts.limit), hasMore: rows.length > opts.limit };
  }
}

/**
 * Records failed admin sign-ins without letting the audit log become a
 * target: at most one entry per client address per window. The entry holds
 * the time and the address and nothing else, so no email, username, password
 * or code can reach the log through it.
 *
 * The throttle is per process, in memory. Several API processes each keep
 * their own, so a deployment behind more than one replica can log up to one
 * entry per address per window per replica; a restart forgets the window.
 * Both only make the log slightly longer, never shorter than one per window.
 */
export class FailedLoginAudit {
  static readonly WINDOW_MS = 60_000;
  private static readonly MAX_TRACKED = 1000;
  private readonly lastLogged = new Map<string, number>();

  constructor(private readonly audit: AuditService, private readonly now: () => number = Date.now) {}

  /** Returns whether an entry was written. Never throws: a failed audit write must not change the sign-in reply. */
  async record(ip: string | null): Promise<boolean> {
    const key = ip ?? 'unknown';
    const at = this.now();
    const previous = this.lastLogged.get(key);
    if (previous !== undefined && at - previous < FailedLoginAudit.WINDOW_MS) return false;
    // Re-insert so the map stays ordered by last write, oldest first.
    this.lastLogged.delete(key);
    this.lastLogged.set(key, at);
    this.prune(at);
    try {
      await this.audit.log('anonymous', 'admin.login_failed', 'admin', null, ip);
      return true;
    } catch {
      // Let the next failure from this address try again.
      this.lastLogged.delete(key);
      return false;
    }
  }

  private prune(at: number): void {
    for (const [key, when] of this.lastLogged) {
      const expired = at - when >= FailedLoginAudit.WINDOW_MS;
      if (!expired && this.lastLogged.size <= FailedLoginAudit.MAX_TRACKED) break;
      this.lastLogged.delete(key);
    }
  }
}
