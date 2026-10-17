import { timingSafeEqual } from 'node:crypto';
import * as argon2 from 'argon2';
import { eq, sql as drizzleSql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { adminBootstrapState, adminConfig } from '../../db/schema.js';
import { sha256Hex } from '../../lib/crypto.js';
import { ErrorCode, type ErrorCodeValue } from '../shared/errors.js';

const ARGON2_OPTIONS = {
  type: argon2.argon2id,
  memoryCost: 65536,
  timeCost: 3,
  parallelism: 4,
} as const;

export class BootstrapError extends Error {
  constructor(
    message: string,
    readonly statusCode: number,
    readonly code: ErrorCodeValue,
  ) {
    super(message);
    this.name = 'BootstrapError';
  }
}

interface BootstrapRow {
  [key: string]: unknown;
  id: string;
  token_hash: string;
  expires_at: Date | string;
  consumed_at: Date | string | null;
}

// Keep the public rollback seam structural so tests can exercise the exact
// transaction boundary without coupling this service to Drizzle internals.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type BootstrapTransaction = any;

function proofMatches(storedHash: string, presentedHash: string): boolean {
  const stored = Buffer.from(storedHash, 'hex');
  const presented = Buffer.from(presentedHash, 'hex');
  return stored.length === presented.length && timingSafeEqual(stored, presented);
}

function isUniqueViolation(err: unknown): boolean {
  return typeof err === 'object'
    && err !== null
    && 'code' in err
    && (err as { code?: unknown }).code === '23505';
}

/**
 * Consumes the operator proof and creates the administrator in one
 * transaction.  The singleton row lock serializes concurrent setup requests;
 * the database trigger permits the API role to change only consumed_at.
 */
export class BootstrapService {
  constructor(private readonly db: Db) {}

  async consumeAndCreateAdmin(
    email: string,
    password: string,
    proof: string | undefined,
    outerTx?: BootstrapTransaction,
  ): Promise<void> {
    if (!proof) {
      throw new BootstrapError(
        'A bootstrap proof is required',
        401,
        ErrorCode.ADMIN_BOOTSTRAP_INVALID,
      );
    }

    const tokenHash = sha256Hex(proof);
    const passwordHash = await argon2.hash(password, ARGON2_OPTIONS);
    const normalizedEmail = email.trim().toLowerCase();

    try {
      const consume = async (tx: BootstrapTransaction): Promise<void> => {
        const rows = await tx.execute(drizzleSql`
          SELECT id, token_hash, expires_at, consumed_at
          FROM admin_bootstrap_state
          WHERE singleton_key = TRUE
          FOR UPDATE
        `) as BootstrapRow[];
        const state = rows[0];
        if (!state) {
          throw new BootstrapError(
            'Bootstrap state is unavailable',
            503,
            ErrorCode.ADMIN_BOOTSTRAP_INVALID,
          );
        }
        if (state.consumed_at !== null) {
          throw new BootstrapError(
            'Bootstrap proof has already been consumed',
            409,
            ErrorCode.ADMIN_BOOTSTRAP_CONSUMED,
          );
        }
        if (new Date(state.expires_at).getTime() <= Date.now()) {
          throw new BootstrapError(
            'Bootstrap proof has expired',
            403,
            ErrorCode.ADMIN_BOOTSTRAP_EXPIRED,
          );
        }
        if (!proofMatches(state.token_hash, tokenHash)) {
          throw new BootstrapError(
            'Bootstrap proof is invalid',
            403,
            ErrorCode.ADMIN_BOOTSTRAP_INVALID,
          );
        }

        const existing = await tx
          .select({ id: adminConfig.id })
          .from(adminConfig)
          .where(eq(adminConfig.id, adminConfig.id));
        if (existing.length > 0) {
          throw new BootstrapError(
            'Admin already configured',
            409,
            ErrorCode.ADMIN_ALREADY_CONFIGURED,
          );
        }

        await tx.insert(adminConfig).values({
          email: normalizedEmail,
          passwordHash,
          sessionVersion: 1n,
        });

        await tx
          .update(adminBootstrapState)
          .set({ consumedAt: new Date() })
          .where(eq(adminBootstrapState.id, state.id));
      };
      if (outerTx) await consume(outerTx);
      else await this.db.transaction(consume);
    } catch (err) {
      if (err instanceof BootstrapError) throw err;
      if (isUniqueViolation(err)) {
        throw new BootstrapError(
          'Admin already configured',
          409,
          ErrorCode.ADMIN_ALREADY_CONFIGURED,
        );
      }
      throw err;
    }
  }
}
