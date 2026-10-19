import { desc, eq } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { auditLogs } from '../../db/schema.js';

export type AuditAction =
  | 'admin.login'
  | 'admin.password_change'
  | 'admin.2fa_enable'
  | 'admin.2fa_disable'
  | 'admin.2fa_backup_codes'
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

  async list(opts: { limit: number; offset: number; action?: string | undefined }) {
    let query = this.db
      .select()
      .from(auditLogs)
      .orderBy(desc(auditLogs.createdAt))
      .limit(opts.limit)
      .offset(opts.offset);

    if (opts.action) {
      query = query.where(eq(auditLogs.action, opts.action)) as typeof query;
    }

    return query;
  }
}
