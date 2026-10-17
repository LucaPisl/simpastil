import { randomBytes as nodeRandomBytes } from 'node:crypto';
import { sql as drizzleSql } from 'drizzle-orm';
import { sha256Hex } from '../../lib/crypto.js';

// The caller supplies a transaction opened by the privileged provisioner.
// This module intentionally has no database/env imports and cannot elevate an
// API connection or expose a route by itself.
export interface BootstrapRotationTransaction {
  execute<T = Record<string, unknown>>(query: unknown): Promise<T[]>;
}

export interface BootstrapRotationOptions {
  now?: Date;
  ttlMs?: number;
  randomBytes?: () => Buffer;
}

export interface RotatedBootstrapProof {
  proof: string;
  generation: string;
  expiresAt: Date;
}

export async function rotateBootstrapProof(
  transaction: <T>(callback: (tx: BootstrapRotationTransaction) => Promise<T>) => Promise<T>,
  options: BootstrapRotationOptions = {},
): Promise<RotatedBootstrapProof> {
  const now = options.now ?? new Date();
  const ttlMs = options.ttlMs ?? 30 * 60 * 1000;
  if (!Number.isSafeInteger(ttlMs) || ttlMs <= 0) {
    throw new Error('bootstrap proof TTL must be a positive safe integer');
  }

  const random = options.randomBytes ?? (() => nodeRandomBytes(32));
  const proof = random().toString('hex');
  const expiresAt = new Date(now.getTime() + ttlMs);
  const expiresAtIso = expiresAt.toISOString();
  const rows = await transaction(async (tx) => tx.execute<{ generation: string | bigint }>(drizzleSql`
    UPDATE admin_bootstrap_state
    SET token_hash = ${sha256Hex(proof)},
        generation = generation + 1,
        expires_at = ${expiresAtIso}::timestamptz,
        consumed_at = NULL
    WHERE singleton_key = TRUE
    RETURNING generation
  `));

  if (rows.length !== 1 || rows[0] === undefined) {
    throw new Error('bootstrap state singleton is unavailable');
  }

  return {
    // This is the only return of the raw proof.  Callers are responsible for
    // displaying it once and must never persist or log it.
    proof,
    generation: BigInt(rows[0].generation).toString(10),
    expiresAt,
  };
}
