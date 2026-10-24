import '@fastify/jwt';
import rateLimit from '@fastify/rate-limit';
import { eq } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { apiKeys } from '../../db/schema.js';
import { sha256Hex } from '../../lib/crypto.js';
import { isDeletedAccountKey } from '../../lib/deleted-accounts.js';
import { ErrorCode } from '../shared/errors.js';
import type { FastifyInstance } from 'fastify';
import { AuthService, AuthError } from './auth.service.js';
import { UserTotpService, TotpError } from './totp.service.js';
import type { AppConfig } from '../../config/app-config.js';
import type { EncryptionCapabilities } from '../../lib/crypto.js';
import { SessionService, parseSessionVersionClaim } from './session.service.js';

function rateLimitError(_request: unknown, context: { statusCode: number; ttl: number }) {
  const err = new Error('Too Many Requests') as Error & { statusCode: number; code: string; retryAfter: number };
  err.statusCode = context.statusCode;
  err.code = ErrorCode.RATE_LIMIT_EXCEEDED;
  err.retryAfter = Math.ceil(context.ttl / 1000);
  return err;
}
import {
  RegisterRequestSchema,
  LoginRequestSchema,
  RefreshRequestSchema,
  RecoverableRefreshRequestSchema,
  LogoutRequestSchema,
  ChangePasswordRequestSchema,
} from './auth.schema.js';

/**
 * Auth routes plugin.
 *
 * Registers POST /auth/register, /auth/login, /auth/refresh, /auth/logout.
 *
 * Prerequisites (registered before this plugin in the main app):
 *   - @fastify/jwt  (provides fastify.jwt.sign + request.jwtVerify)
 *   - authenticate plugin (provides fastify.authenticate)
 *
 * Rate limiting: POST /auth/login is limited to 5 requests per IP per 15
 * minutes. The response is 429 (not 401) so that the rate limit cannot be
 * used as a side channel to infer whether an email address is registered.
 */

export default async function authRoutes(fastify: FastifyInstance, opts: { db: Db; config: AppConfig & { role: 'api' | 'test' }; crypto: EncryptionCapabilities; ttlSeconds?: number; rateLimitMax?: number; rateLimitTimeWindow?: string | number; sessionService?: SessionService; testHooks?: { afterRefreshSessionLock?: () => Promise<void> } }) {
  const ttlSeconds = opts.ttlSeconds ?? opts.config.jwt.accessTokenTtlSeconds;

  const database = opts.db;
  const sessions = opts.sessionService ?? new SessionService(database);

  const service = new AuthService(
    database,
    (userId, sessionVersion = '1') => fastify.jwt.sign({ sub: userId, sessionVersion }, { expiresIn: ttlSeconds }),
    (userId, sessionVersion = '1') => fastify.jwt.sign({ sub: userId, sessionVersion, purpose: '2fa-challenge' }, { expiresIn: 300 }),
    {
      nodeEnv: opts.config.nodeEnv,
      ...(opts.testHooks ? { testHooks: opts.testHooks } : {}),
    },
    sessions,
  );

  const totpService = new UserTotpService(database, opts.crypto, sessions);

  // ---------------------------------------------------------------------------
  // Rate limit — applied only to /auth/login to mitigate credential stuffing.
  // The login sub-scope is a child plugin; rateLimit is scoped to it.
  // ---------------------------------------------------------------------------

  await fastify.register(async (loginScope) => {
    await loginScope.register(rateLimit, {
      max: opts.rateLimitMax ?? 10,
      timeWindow: opts.rateLimitTimeWindow ?? '15 minutes',
      errorResponseBuilder: rateLimitError,
    });

    loginScope.post('/auth/login', { preHandler: [fastify.apiKeyGuard] }, async (request, reply) => {
      const body = LoginRequestSchema.parse(request.body);
      try {
        const result = await service.login(body.email, body.password, {
          keyId: request.keyId!,
          keyUserId: request.keyUserId ?? null,
        });
        return reply.status(200).send(result);
      } catch (err) {
        return sendAuthError(reply, err);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Register — rate limited to prevent mass account creation
  // ---------------------------------------------------------------------------

  await fastify.register(async (registerScope) => {
    await registerScope.register(rateLimit, {
      max: opts.rateLimitMax ?? 10,
      timeWindow: opts.rateLimitTimeWindow ?? '15 minutes',
      errorResponseBuilder: rateLimitError,
    });

    registerScope.post('/auth/register', { preHandler: [fastify.apiKeyGuard] }, async (request, reply) => {
      // Reject if the key is already claimed (userId !== null)
      if (request.keyUserId !== null) {
        return reply.status(409).send({ error: 'Key already claimed', code: ErrorCode.AUTH_KEY_CLAIMED });
      }
      const body = RegisterRequestSchema.parse(request.body);
      try {
        // keyId is guaranteed non-null here by the apiKeyGuard preHandler above.
        const result = await service.register(body.email, body.password, request.keyId!);
        return reply.status(201).send(result);
      } catch (err) {
        return sendAuthError(reply, err);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Refresh — rate limited to mitigate token-brute-force / DoS
  // ---------------------------------------------------------------------------

  await fastify.register(async (refreshScope) => {
    await refreshScope.register(rateLimit, {
      max: 20,
      timeWindow: opts.rateLimitTimeWindow ?? '5 minutes',
      errorResponseBuilder: rateLimitError,
    });

    refreshScope.post('/auth/refresh/recoverable', { preHandler: [fastify.apiKeyGuardRegistered] }, async (request, reply) => {
      const body = RecoverableRefreshRequestSchema.parse(request.body);
      try {
        return reply.status(200).send(await service.refresh(body.refreshToken, body.nextRefreshToken));
      } catch (err) {
        return sendAuthError(reply, err);
      }
    });

    refreshScope.post('/auth/refresh', { preHandler: [fastify.apiKeyGuardRegistered] }, async (request, reply) => {
      const body = RefreshRequestSchema.parse(request.body);
      try {
        const result = await service.refresh(body.refreshToken);
        return reply.status(200).send(result);
      } catch (err) {
        return sendAuthError(reply, err);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Logout — requires registered API key (not JWT, so logout works even with
  // an expired access token). The refresh token in the body identifies what to
  // revoke; the API key's userId scopes the operation.
  // ---------------------------------------------------------------------------

  fastify.post(
    '/auth/logout',
    { preHandler: [fastify.apiKeyGuardRegistered] },
    async (request, reply) => {
      const body = LogoutRequestSchema.parse(request.body);
      await service.logout(body.refreshToken);
      return reply.status(204).send();
    },
  );

  fastify.post(
    '/auth/logout-all',
    { preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate] },
    async (request, reply) => {
      try {
        await service.logoutAll(request.user.userId);
        return reply.status(204).send();
      } catch (err) {
        return sendAuthError(reply, err);
      }
    },
  );

  // ---------------------------------------------------------------------------
  // Change password (requires valid access token)
  // Rate-limited: 5 attempts per IP per 15 minutes — same as login.
  // An attacker who obtains a victim's access token should not be able to
  // brute-force the current password via this endpoint.
  // ---------------------------------------------------------------------------

  await fastify.register(async (changePasswordScope) => {
    await changePasswordScope.register(rateLimit, {
      max: opts.rateLimitMax ?? 5,
      timeWindow: opts.rateLimitTimeWindow ?? '15 minutes',
      errorResponseBuilder: rateLimitError,
    });

    changePasswordScope.post(
      '/auth/change-password',
      { preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate] },
      async (request, reply) => {
        const body = ChangePasswordRequestSchema.parse(request.body);
        const { userId } = request.user;
        try {
          await service.changePassword(userId, body.currentPassword, body.newPassword);
          return reply.status(200).send({ message: 'Password updated' });
        } catch (err) {
          return sendAuthError(reply, err);
        }
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 2FA endpoints (all require authenticated user except challenge)
  // ---------------------------------------------------------------------------

  fastify.post('/auth/2fa/setup', { preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate] }, async (request, reply) => {
    try {
      const { userId } = request.user;
      const result = await totpService.setup(userId);
      return reply.status(200).send(result);
    } catch (err) { return sendTotpError(reply, err); }
  });

  fastify.post('/auth/2fa/enable', { preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate] }, async (request, reply) => {
    const { code } = (request.body as { code?: string }) ?? {};
    if (!code) return reply.status(400).send({ error: 'code is required', code: ErrorCode.VALIDATION_ERROR });
    try {
      const { userId } = request.user;
      const result = await totpService.enable(userId, code);
      return reply.status(200).send(result);
    } catch (err) { return sendTotpError(reply, err); }
  });

  fastify.post('/auth/2fa/disable', { preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate] }, async (request, reply) => {
    const { code } = (request.body as { code?: string }) ?? {};
    if (!code) return reply.status(400).send({ error: 'code is required', code: ErrorCode.VALIDATION_ERROR });
    try {
      const { userId } = request.user;
      await totpService.disable(userId, code);
      return reply.status(200).send({ ok: true });
    } catch (err) { return sendTotpError(reply, err); }
  });

  fastify.post('/auth/2fa/backup-codes', { preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate] }, async (request, reply) => {
    const { code } = (request.body as { code?: string }) ?? {};
    if (!code) return reply.status(400).send({ error: 'code is required', code: ErrorCode.VALIDATION_ERROR });
    try {
      const { userId } = request.user;
      const result = await totpService.regenerateBackupCodes(userId, code);
      return reply.status(200).send(result);
    } catch (err) { return sendTotpError(reply, err); }
  });

  // ---------------------------------------------------------------------------
  // 2FA challenge — rate limited: 10 attempts per IP per 5 minutes
  // ---------------------------------------------------------------------------

  await fastify.register(async (challengeScope) => {
    await challengeScope.register(rateLimit, {
      max: opts.rateLimitMax ?? 10,
      timeWindow: opts.rateLimitTimeWindow ?? '5 minutes',
      errorResponseBuilder: rateLimitError,
    });

    challengeScope.post('/auth/2fa/challenge', { preHandler: [fastify.apiKeyGuardRegistered] }, async (request, reply) => {
      const { challengeToken, code } = (request.body as { challengeToken?: string; code?: string }) ?? {};
      if (!challengeToken || !code) {
        return reply.status(400).send({ error: 'challengeToken and code are required', code: ErrorCode.VALIDATION_ERROR });
      }
      try {
        const payload = fastify.jwt.verify<{
          sub: string;
          purpose?: unknown;
          sessionVersion?: unknown;
          exp?: unknown;
        }>(challengeToken);
        if (!Object.prototype.hasOwnProperty.call(payload, 'purpose')
            || payload.purpose !== '2fa-challenge'
            || typeof payload.exp !== 'number'
            || !Number.isFinite(payload.exp)
            || parseSessionVersionClaim(payload.sessionVersion) === null
            || !await sessions.assertUserSession(payload.sub, payload.sessionVersion)) {
          return reply.status(400).send({ error: 'Invalid challenge token', code: ErrorCode.TOTP_CHALLENGE_INVALID });
        }
        await totpService.verifyChallenge(payload.sub, code);
        const result = await service.completeLogin(
          payload.sub,
          parseSessionVersionClaim(payload.sessionVersion)!.toString(10),
        );
        return reply.status(200).send(result);
      } catch (err) {
        if (err instanceof TotpError) return sendTotpError(reply, err);
        return reply.status(400).send({ error: 'Invalid or expired challenge token', code: ErrorCode.TOTP_CHALLENGE_INVALID });
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Verify key (no preHandler — introspection endpoint, works for any key state)
  // lastUsedAt is intentionally NOT updated here — introspection is not data access.
  // ---------------------------------------------------------------------------

  fastify.get('/auth/verify-key', async (request, reply) => {
    const rawKey = request.headers['x-api-key'];
    if (typeof rawKey !== 'string' || !rawKey) return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.AUTH_KEY_INVALID });
    const keyHash = sha256Hex(rawKey);
    const database = opts.db;
    const [row] = await database.select().from(apiKeys).where(eq(apiKeys.keyHash, keyHash));
    if (!row) {
      if (await isDeletedAccountKey(database, keyHash)) {
        return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.ACCOUNT_DELETED });
      }
      return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.AUTH_KEY_INVALID });
    }
    if (row.revokedAt !== null) return reply.status(200).send({ status: 'revoked' });
    return reply.status(200).send({ status: row.userId === null ? 'unclaimed' : 'owned' });
  });

}

// ---------------------------------------------------------------------------
// Error helper
// ---------------------------------------------------------------------------

function sendAuthError(
  reply: import('fastify').FastifyReply,
  err: unknown,
): import('fastify').FastifyReply {
  if (err instanceof AuthError) {
    return reply.status(err.statusCode).send({ error: err.message, code: err.code });
  }
  throw err;
}

function sendTotpError(
  reply: import('fastify').FastifyReply,
  err: unknown,
): import('fastify').FastifyReply {
  if (err instanceof TotpError) {
    return reply.status(err.statusCode).send({ error: err.message, code: err.code });
  }
  throw err;
}
