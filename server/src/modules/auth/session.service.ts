import { randomBytes } from 'node:crypto';
import { and, eq, gt, sql as drizzleSql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import {
  adminConfig,
  adminRefreshTokens,
  refreshTokens,
  users,
} from '../../db/schema.js';
import { appendAccountSyncChange } from '../sync/sync-change-writer.js';

const MAX_SIGNED_64 = 9_223_372_036_854_775_807n;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const POSITIVE_DECIMAL_RE = /^[1-9]\d{0,18}$/;

// The transaction type is deliberately structural.  Drizzle's concrete
// Postgres transaction type is an implementation detail and changes between
// minor releases; these methods only require the query methods they call.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type SessionTransaction = any;

export interface AdminSessionInvalidation {
  version: string | null;
  processOnly: boolean;
}

export function sessionVersionClaim(value: bigint | number | string): string {
  const parsed = BigInt(value);
  if (parsed < 1n || parsed > MAX_SIGNED_64) {
    throw new Error('session version must be a positive signed 64-bit integer');
  }
  return parsed.toString(10);
}

export function parseSessionVersionClaim(value: unknown): bigint | null {
  if (typeof value !== 'string' || !POSITIVE_DECIMAL_RE.test(value)) return null;
  const parsed = BigInt(value);
  return parsed <= MAX_SIGNED_64 ? parsed : null;
}

function newRuntimeGeneration(): bigint {
  const value = BigInt(`0x${randomBytes(8).toString('hex')}`) & MAX_SIGNED_64;
  return value === 0n ? 1n : value;
}

const ENVIRONMENT_ADMIN_LOCK_KEY = 8_614_273_901n;

/**
 * Stateful credential generation and refresh-family invalidation.
 *
 * Access JWTs carry the decimal session version.  Refresh credentials remain
 * opaque; their database rows are checked against the same generation and
 * are revoked in the transaction that changes security state.
 */
export class SessionService {
  private environmentAdminGeneration: bigint;
  private adminMutationTail: Promise<void> = Promise.resolve();

  constructor(
    private readonly db: Db,
    private readonly options: { environmentManagedAdmin?: boolean } = {},
  ) {
    this.environmentAdminGeneration = newRuntimeGeneration();
  }

  /**
   * Environment-managed administrators have no database row whose committed
   * value can publish a new generation. Serialize the whole transaction and
   * publish the replacement only after commit, so issuance cannot insert a
   * refresh row into the gap between revocation and publication.
   */
  async runAdminSessionTransaction<T>(
    work: (tx: SessionTransaction) => Promise<T>,
    publishGeneration?: (result: T) => string | undefined,
  ): Promise<T> {
    if (!this.options.environmentManagedAdmin) {
      return this.db.transaction(work);
    }

    const previous = this.adminMutationTail;
    let release!: () => void;
    this.adminMutationTail = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    try {
      const result = await this.db.transaction(work);
      const nextGeneration = publishGeneration?.(result);
      if (nextGeneration !== undefined) {
        this.environmentAdminGeneration = BigInt(nextGeneration);
      }
      return result;
    } finally {
      release();
    }
  }

  async getUserSessionVersion(userId: string): Promise<string | null> {
    const [row] = await this.db
      .select({ sessionVersion: users.sessionVersion })
      .from(users)
      .where(eq(users.id, userId));
    return row ? sessionVersionClaim(row.sessionVersion) : null;
  }

  /**
   * Lock a user generation before issuing credentials or changing security
   * state. Every caller that inserts/revokes user refresh rows uses this same
   * row lock, so a generation transition cannot race credential issuance.
   */
  async lockUserSession(tx: SessionTransaction, userId: string): Promise<string | null> {
    await tx.execute(
      drizzleSql`SELECT set_config('app.current_user_id', ${userId}, true)`,
    );
    const rows = await tx.execute(drizzleSql`
      SELECT session_version
      FROM users
      WHERE id = ${userId}
      FOR UPDATE
    `) as Array<{ session_version: bigint | string }>;
    const row = rows[0];
    return row ? sessionVersionClaim(row.session_version) : null;
  }

  async assertUserSession(userId: string, claim: unknown): Promise<boolean> {
    const expected = parseSessionVersionClaim(claim);
    if (expected === null) return false;
    const [row] = await this.db
      .select({ sessionVersion: users.sessionVersion })
      .from(users)
      .where(eq(users.id, userId));
    return row !== undefined && BigInt(row.sessionVersion) === expected;
  }

  async invalidateUserSessions(userId: string, outerTx?: SessionTransaction): Promise<string> {
    const run = async (tx: SessionTransaction): Promise<string> => {
      // The users and refresh_tokens policies are intentionally restrictive.
      // Keep the tenant context transaction-local and retain the explicit
      // user_id predicates as defense in depth. The row lock serializes this
      // transition with every credential issuance for the same user.
      const current = await this.lockUserSession(tx, userId);
      if (current === null) throw new Error('user session owner not found');
      const updated = await tx
        .update(users)
        .set({ sessionVersion: drizzleSql`${users.sessionVersion} + 1` })
        .where(eq(users.id, userId))
        .returning({ sessionVersion: users.sessionVersion });
      if (updated.length === 0) throw new Error('user session owner not found');

      await tx
        .update(refreshTokens)
        .set({ revoked: true })
        .where(and(eq(refreshTokens.userId, userId), eq(refreshTokens.revoked, false)));

      const [account] = await tx.select({
        id: users.id,
        email: users.email,
        sessionVersion: users.sessionVersion,
        createdAt: users.createdAt,
        updatedAt: users.updatedAt,
      }).from(users).where(eq(users.id, userId));
      if (!account) throw new Error('user session owner not found');
      await appendAccountSyncChange(tx, userId, account);

      return sessionVersionClaim(updated[0]!.sessionVersion);
    };

    return outerTx ? run(outerTx) : this.db.transaction(run);
  }

  async getAdminSessionVersion(outerTx?: SessionTransaction): Promise<string | null> {
    const connection = outerTx ?? this.db;
    const [row] = await connection
      .select({ sessionVersion: adminConfig.sessionVersion })
      .from(adminConfig);
    if (row) return sessionVersionClaim(row.sessionVersion);
    return this.options.environmentManagedAdmin
      ? sessionVersionClaim(this.environmentAdminGeneration)
      : null;
  }

  /**
   * Lock the persisted administrator row, or an advisory process-wide
   * generation when the administrator is environment-managed and therefore
   * has no database row. The same lock is used by issuance, rotation, and
   * invalidation.
   */
  async lockAdminSession(tx: SessionTransaction): Promise<string | null> {
    if (this.options.environmentManagedAdmin) {
      await tx.execute(
        drizzleSql`SELECT pg_advisory_xact_lock(${ENVIRONMENT_ADMIN_LOCK_KEY}::bigint)`,
      );
    }
    const rows = await tx.execute(drizzleSql`
      SELECT session_version
      FROM admin_config
      FOR UPDATE
    `) as Array<{ session_version: bigint | string }>;
    const row = rows[0];
    if (row) return sessionVersionClaim(row.session_version);
    return this.options.environmentManagedAdmin
      ? sessionVersionClaim(this.environmentAdminGeneration)
      : null;
  }

  async assertAdminSession(claim: unknown): Promise<boolean> {
    const expected = parseSessionVersionClaim(claim);
    if (expected === null) return false;
    const [row] = await this.db
      .select({ sessionVersion: adminConfig.sessionVersion })
      .from(adminConfig);
    if (row) return BigInt(row.sessionVersion) === expected;
    return this.options.environmentManagedAdmin === true && this.environmentAdminGeneration === expected;
  }

  /**
   * Whether the refresh family named by an access token's `sid` claim still
   * has a live credential. Logout, reuse detection and "sign out everywhere"
   * revoke every row of a family, and a family that has outlived its last
   * refresh token has expired, so any of them ends the access token early.
   */
  async isAdminSessionLive(sid: unknown): Promise<boolean> {
    if (typeof sid !== 'string' || !UUID_RE.test(sid)) return false;
    const rows = await this.db
      .select({ id: adminRefreshTokens.id })
      .from(adminRefreshTokens)
      .where(and(
        eq(adminRefreshTokens.familyId, sid),
        eq(adminRefreshTokens.revoked, false),
        gt(adminRefreshTokens.expiresAt, drizzleSql`now()`),
      ))
      .limit(1);
    return rows.length > 0;
  }

  /**
   * End one admin sign-in: revoke every refresh row of its family. Serialized
   * with issuance and rotation by the same admin lock, so a refresh in flight
   * cannot slip a fresh row in after this commits. Idempotent: returns whether
   * anything was still live.
   */
  async revokeAdminSession(sid: string): Promise<boolean> {
    if (!UUID_RE.test(sid)) return false;
    return this.runAdminSessionTransaction(async (tx) => {
      await this.lockAdminSession(tx);
      const revoked = await tx
        .update(adminRefreshTokens)
        .set({ revoked: true })
        .where(and(eq(adminRefreshTokens.familyId, sid), eq(adminRefreshTokens.revoked, false)))
        .returning({ id: adminRefreshTokens.id });
      return revoked.length > 0;
    });
  }

  async invalidateAdminSessionsInTransaction(tx: SessionTransaction): Promise<AdminSessionInvalidation> {
    const current = await this.lockAdminSession(tx);
    if (current === null) return { version: null, processOnly: false };
    const updated = await tx
      .update(adminConfig)
      .set({ sessionVersion: drizzleSql`${adminConfig.sessionVersion} + 1` })
      .returning({ sessionVersion: adminConfig.sessionVersion });

    await tx
      .update(adminRefreshTokens)
      .set({ revoked: true })
      .where(eq(adminRefreshTokens.revoked, false));

    if (updated[0]) {
      return { version: sessionVersionClaim(updated[0].sessionVersion), processOnly: false };
    }
    if (!this.options.environmentManagedAdmin) return { version: null, processOnly: false };
    let next = newRuntimeGeneration();
    while (next === this.environmentAdminGeneration) next = newRuntimeGeneration();
    return { version: sessionVersionClaim(next), processOnly: true };
  }

  async invalidateAdminSessions(): Promise<string | null> {
    const result = await this.runAdminSessionTransaction(
      (tx) => this.invalidateAdminSessionsInTransaction(tx),
      (outcome) => outcome.processOnly ? outcome.version ?? undefined : undefined,
    );
    return result.version;
  }

  /**
   * Environment-managed administrators do not have a password row to own
   * their process generation.  On every process start, revoke all persisted
   * refresh rows and advance the persisted generation when a row exists; when
   * it does not, the fresh random process generation invalidates old access
   * JWTs as well.
   */
  async initializeEnvironmentManagedAdmin(): Promise<void> {
    if (!this.options.environmentManagedAdmin) return;
    await this.invalidateAdminSessions();
  }
}
