import '@fastify/jwt';
import fp from 'fastify-plugin';
import { ErrorCode } from '../modules/shared/errors.js';
import type { FastifyRequest, FastifyReply } from 'fastify';
import type { Db } from '../db/client.js';
import { SessionService, parseSessionVersionClaim } from '../modules/auth/session.service.js';

// Extend @fastify/jwt's FastifyJWT interface so `request.user` is typed everywhere.
// @fastify/jwt derives FastifyRequest.user from FastifyJWT.user via UserType.
declare module '@fastify/jwt' {
  interface FastifyJWT {
    user: { userId: string };
  }
}

// Extend Fastify's type system so `fastify.authenticate` is typed everywhere.
declare module 'fastify' {
  interface FastifyInstance {
    authenticate: (request: FastifyRequest, reply: FastifyReply) => Promise<void>;
  }
}

// Compiled once at module load; blocks non-UUID sub claims (e.g. admin JWTs).
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Registers `fastify.authenticate` — a preHandler hook that verifies the
 * RS256 access token from the Authorization header.
 *
 * On success: attaches { userId } to request.user.
 * On failure: returns 401 { error: 'Unauthorized' } — JWT error details are
 *             never forwarded to the client to avoid information leakage.
 *
 * This plugin is stateless: it only verifies the JWT signature and expiry.
 * Refresh token validity is checked inside AuthService.refresh() (stateful).
 *
 * Usage (in routes):
 *   { preHandler: [fastify.authenticate] }
 */
export default fp(async (fastify, opts: { db: Db; sessionService?: SessionService }) => {
  const sessions = opts.sessionService ?? new SessionService(opts.db);
  fastify.decorate(
    'authenticate',
    async (request: FastifyRequest, reply: FastifyReply) => {
      try {
        // @fastify/jwt reads the Authorization: Bearer <token> header automatically.
        // jwtVerify() validates signature, algorithm, and expiry.
        // The payload type is inferred from @fastify/jwt's FastifyJWT interface.
        await request.jwtVerify();
        const payload = (request.user as unknown) as {
          sub: string;
          exp?: unknown;
          sessionVersion?: unknown;
          purpose?: unknown;
        };
        // Security, token purpose: 2FA challenge JWTs use the same signing
        // key as access JWTs. Reject every token carrying an own purpose
        // property, including null/empty/unknown values; only an absent
        // property is an access credential.
        if (Object.prototype.hasOwnProperty.call(payload, 'purpose')) {
          return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.AUTH_UNAUTHORIZED });
        }
        if (typeof payload.exp !== 'number' || !Number.isFinite(payload.exp) || payload.exp <= 0) {
          return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.AUTH_UNAUTHORIZED });
        }
        if (!UUID_RE.test(payload.sub)) {
          return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.AUTH_UNAUTHORIZED });
        }
        if (parseSessionVersionClaim(payload.sessionVersion) === null
            || !await sessions.assertUserSession(payload.sub, payload.sessionVersion)) {
          return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.AUTH_SESSION_REVOKED });
        }
        request.user = { userId: payload.sub };
        // Cross-check: if an API key was validated, it must belong to this user.
        // (keyUserId is undefined for routes that skip apiKeyGuard, e.g. health.)
        if (request.keyUserId !== undefined && request.keyUserId !== null &&
            request.keyUserId !== request.user.userId) {
          return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.AUTH_UNAUTHORIZED });
        }
      } catch {
        // Intentionally swallow the JWT error — never expose internal JWT
        // error messages (e.g., "jwt expired", "invalid signature") to clients.
        return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.AUTH_UNAUTHORIZED });
      }
    },
  );
});
