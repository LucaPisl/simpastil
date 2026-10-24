import rateLimit from '@fastify/rate-limit';
import { eq } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';
import { TenantTransactionRunner } from '../../db/tenant-transaction.js';
import { users } from '../../db/schema.js';
import type { EncryptionCapabilities } from '../../lib/crypto.js';
import type { DeliveryPayloadSealer } from '../../lib/delivery-payload-crypto.js';
import { AuditService } from '../admin/audit.service.js';
import { SessionService } from '../auth/session.service.js';
import { UserTotpService } from '../auth/totp.service.js';
import type { SettingsService } from '../settings/settings.service.js';
import { ApiError, sendApiError } from '../shared/api-error.js';
import { ErrorCode } from '../shared/errors.js';
import { streamAccountExport } from './account-export.js';
import {
  AccountDeleteRequestSchema,
  ChangeEmailRequestSchema,
  ConfirmEmailChangeRequestSchema,
} from './account.schema.js';
import { AccountService } from './account.service.js';

function rateLimitError(_request: unknown, context: { statusCode: number; ttl: number }) {
  const err = new Error('Too Many Requests') as Error & { statusCode: number; code: string; retryAfter: number };
  err.statusCode = context.statusCode;
  err.code = ErrorCode.RATE_LIMIT_EXCEEDED;
  err.retryAfter = Math.ceil(context.ttl / 1000);
  return err;
}

export interface AccountRoutesOptions {
  db: Db;
  crypto: EncryptionCapabilities;
  payloadSealer: DeliveryPayloadSealer;
  sessionService: SessionService;
  settings: SettingsService;
  rateLimitMax?: number;
  rateLimitTimeWindow?: string | number;
}

export default async function accountRoutes(fastify: FastifyInstance, options: AccountRoutesOptions) {
  const totp = new UserTotpService(options.db, options.crypto, options.sessionService);
  const service = new AccountService(options.db, totp, options.payloadSealer, options.settings);
  const audit = new AuditService(options.db);
  const tenants = new TenantTransactionRunner(options.db);
  const guards = [fastify.apiKeyGuardRegistered, fastify.authenticate];

  fastify.get('/account/summary', { preHandler: guards }, async (request, reply) => {
    try {
      return reply.status(200).send(await service.summary(request.user.userId));
    } catch (error) {
      return sendApiError(reply, request, error);
    }
  });

  // Identity-checked actions share one tight limit: a stolen access token must
  // not be able to guess the password through them.
  await fastify.register(async (scope) => {
    await scope.register(rateLimit, {
      max: options.rateLimitMax ?? 5,
      timeWindow: options.rateLimitTimeWindow ?? '15 minutes',
      errorResponseBuilder: rateLimitError,
    });

    scope.post('/account/delete', { preHandler: guards }, async (request, reply) => {
      try {
        const body = AccountDeleteRequestSchema.parse(request.body);
        await service.deleteAccount(request.user.userId, body, request.ip ?? null);
        return reply.status(204).send();
      } catch (error) {
        return sendApiError(reply, request, error);
      }
    });

    scope.post('/auth/change-email', { preHandler: guards }, async (request, reply) => {
      try {
        const body = ChangeEmailRequestSchema.parse(request.body);
        return reply.status(200).send(await service.changeEmail(request.user.userId, body, request.ip ?? null));
      } catch (error) {
        return sendApiError(reply, request, error);
      }
    });
  });

  // The link in the mail opens in a browser with no sign-in.
  await fastify.register(async (scope) => {
    await scope.register(rateLimit, {
      max: options.rateLimitMax ?? 10,
      timeWindow: options.rateLimitTimeWindow ?? '15 minutes',
      errorResponseBuilder: rateLimitError,
    });
    scope.post('/auth/change-email/confirm', async (request, reply) => {
      try {
        const body = ConfirmEmailChangeRequestSchema.parse(request.body);
        await service.confirmEmailChange(body.token, request.ip ?? null);
        return reply.status(200).send({ status: 'changed' });
      } catch (error) {
        return sendApiError(reply, request, error);
      }
    });
  });

  await fastify.register(async (scope) => {
    await scope.register(rateLimit, {
      max: options.rateLimitMax ?? 3,
      timeWindow: options.rateLimitTimeWindow ?? '1 hour',
      errorResponseBuilder: rateLimitError,
    });
    scope.get('/account/export', { preHandler: guards }, async (request, reply) => {
      try {
        const { userId } = request.user;
        const [user] = await tenants.run(userId, (tx) => tx
          .select({ id: users.id, email: users.email, createdAt: users.createdAt, totp: users.totpEnabled })
          .from(users).where(eq(users.id, userId)));
        if (!user) throw new ApiError(404, ErrorCode.AUTH_USER_NOT_FOUND, 'Account not found', { retryable: false });
        await audit.log(`user:${userId}`, 'account.export', 'user', userId, request.ip ?? null);
        const exportedAt = new Date();
        const stream = streamAccountExport(options.db, userId, {
          id: user.id,
          email: user.email,
          createdAt: user.createdAt.toISOString(),
          twoFactorEnabled: user.totp,
        }, exportedAt);
        return reply
          .status(200)
          .header('content-type', 'application/json; charset=utf-8')
          .header('content-disposition', 'attachment; filename="simpastil-data.json"')
          .header('cache-control', 'no-store')
          .send(stream);
      } catch (error) {
        return sendApiError(reply, request, error);
      }
    });
  });
}
