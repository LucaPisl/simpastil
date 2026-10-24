import fp from 'fastify-plugin';
import { timingSafeEqual } from 'node:crypto';
import { eq } from 'drizzle-orm';
import { apiKeys } from '../db/schema.js';
import { sha256Hex } from '../lib/crypto.js';
import { ErrorCode } from '../modules/shared/errors.js';
import type { FastifyRequest, FastifyReply } from 'fastify';
import type { Db } from '../db/client.js';
import { isDeletedAccountKey } from '../lib/deleted-accounts.js';

export { sha256Hex };

declare module 'fastify' {
  interface FastifyRequest {
    keyUserId: string | null;
    /** Set by apiKeyGuard/apiKeyGuardRegistered. Undefined on routes that skip the guard. */
    keyId: string | undefined;
  }
  interface FastifyInstance {
    apiKeyGuard: (request: FastifyRequest, reply: FastifyReply) => Promise<void>;
    apiKeyGuardRegistered: (request: FastifyRequest, reply: FastifyReply) => Promise<void>;
  }
}

export default fp(async (fastify, opts: { db: Db }) => {
  const database = opts.db;

  async function guard(
    request: FastifyRequest,
    reply: FastifyReply,
    requireRegistered: boolean,
  ): Promise<void> {
    const rawKey = request.headers['x-api-key'];
    if (typeof rawKey !== 'string' || !rawKey) {
      return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.AUTH_KEY_INVALID });
    }

    const keyHash = sha256Hex(rawKey);

    const [row] = await database
      .select()
      .from(apiKeys)
      .where(eq(apiKeys.keyHash, keyHash));

    if (!row) {
      // A key whose account was deleted gets its own answer, so the device can
      // clear itself instead of offering to register a new account.
      if (await isDeletedAccountKey(database, keyHash)) {
        return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.ACCOUNT_DELETED });
      }
      return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.AUTH_KEY_INVALID });
    }

    const stored = Buffer.from(row.keyHash, 'hex');
    const given  = Buffer.from(keyHash,     'hex');
    if (!timingSafeEqual(stored, given)) {
      return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.AUTH_KEY_INVALID });
    }

    if (row.revokedAt !== null) {
      return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.AUTH_KEY_REVOKED });
    }

    if (requireRegistered && row.userId === null) {
      return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.AUTH_KEY_INVALID });
    }

    request.keyUserId = row.userId ?? null;
    request.keyId = row.id;

    // Fire-and-forget: update lastUsedAt without blocking the request.
    // NOTE: This UPDATE runs outside the request transaction and without RLS
    // context. It works because api_keys has no RLS policy. Adding RLS to
    // api_keys would break this fire-and-forget pattern.
    database
      .update(apiKeys)
      .set({ lastUsedAt: new Date() })
      .where(eq(apiKeys.id, row.id))
      .catch(() => { /* non-fatal */ });
  }

  fastify.decorate(
    'apiKeyGuard',
    (req: FastifyRequest, reply: FastifyReply) => guard(req, reply, false),
  );
  fastify.decorate(
    'apiKeyGuardRegistered',
    (req: FastifyRequest, reply: FastifyReply) => guard(req, reply, true),
  );
});
