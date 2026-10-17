import { and, asc, eq, gt, lt, isNull, or } from 'drizzle-orm';
import type { Db } from '../db/client.js';
import { TenantTransactionRunner } from '../db/tenant-transaction.js';
import { refreshTokens, adminRefreshTokens } from '../db/schema.js';
import { logProcessEvent } from './process-log.js';

const RETENTION_MS = 7 * 24 * 60 * 60 * 1000; // 7 days
const INTERVAL_MS = 60 * 60 * 1000; // 1 hour

const USER_BATCH = 500;

function purgeableRefreshTokens(now: number) {
  const cutoff = new Date(now - RETENTION_MS);
  return and(
    eq(refreshTokens.revoked, true),
    lt(refreshTokens.createdAt, cutoff),
    or(isNull(refreshTokens.rotatedAt), lt(refreshTokens.rotatedAt, new Date(now - 30 * 24 * 60 * 60 * 1000))),
  );
}

export async function purgeExpiredTokens(db: Db, userBatch: number = USER_BATCH): Promise<void> {
  const now = Date.now();

  // refresh_tokens is FORCE ROW LEVEL SECURITY with a RESTRICTIVE delete policy
  // keyed on app.current_user_id, so the app_user pool can only delete a
  // tenant's rows inside a transaction scoped to that tenant. SELECT is open,
  // which lets the pass discover affected tenants without elevated privileges.
  const tenants = new TenantTransactionRunner(db);
  let lastUserId: string | undefined;
  for (;;) {
    const owners = await db
      .selectDistinct({ userId: refreshTokens.userId })
      .from(refreshTokens)
      .where(and(
        purgeableRefreshTokens(now),
        lastUserId === undefined ? undefined : gt(refreshTokens.userId, lastUserId),
      ))
      .orderBy(asc(refreshTokens.userId))
      .limit(userBatch);
    for (const { userId } of owners) {
      try {
        await tenants.run(userId, (tx) => tx.delete(refreshTokens).where(
          and(eq(refreshTokens.userId, userId), purgeableRefreshTokens(now)),
        ));
      } catch {
        // One bad tenant must not block the rest of the pass.
        logProcessEvent('error', 'token_gc.tenant_purge_failed');
      }
    }
    if (owners.length < userBatch) break;
    lastUserId = owners[owners.length - 1]!.userId;
  }

  await db.delete(adminRefreshTokens).where(
    and(eq(adminRefreshTokens.revoked, true), lt(adminRefreshTokens.createdAt, new Date(now - RETENTION_MS))),
  );
}

export interface TokenGcLifecycle {
  stop(): void;
  drain(deadlineMs: number): Promise<boolean>;
}

/** Registers periodic cleanup and exposes bounded shutdown for its active pass. */
export function startTokenGc(db: Db): TokenGcLifecycle {
  let stopping = false;
  let activePass: Promise<void> | undefined;

  async function runAll() {
    if (stopping || activePass) return;
    const pass = (async () => {
      await purgeExpiredTokens(db);
      // Legacy medication history is protected by tenant journaling and the
      // ledger activation fence. Token cleanup must not mutate medical data.
      // Retain tombstones until a separate authorized retention path exists.
      // Outbox ciphertext is owned by outbox_user and is erased by the isolated worker.
    })();
    activePass = pass;
    try {
      await pass;
    } finally {
      if (activePass === pass) activePass = undefined;
    }
  }

  const timer = setInterval(() => {
    runAll().catch(() => {
      logProcessEvent('error', 'token_gc.periodic_purge_failed');
    });
  }, INTERVAL_MS);

  runAll().catch(() => {
    logProcessEvent('error', 'token_gc.initial_purge_failed');
  });

  return {
    stop(): void {
      stopping = true;
      clearInterval(timer);
    },
    async drain(deadlineMs: number): Promise<boolean> {
      stopping = true;
      clearInterval(timer);
      while (activePass) {
        const remainingMs = deadlineMs - Date.now();
        if (remainingMs <= 0) return false;
        let timeout: NodeJS.Timeout | undefined;
        try {
          await Promise.race([
            activePass,
            new Promise<void>((resolve) => {
              timeout = setTimeout(resolve, remainingMs);
            }),
          ]);
        } finally {
          if (timeout) clearTimeout(timeout);
        }
      }
      return true;
    },
  };
}
