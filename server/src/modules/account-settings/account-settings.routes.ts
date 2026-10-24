import rateLimit from '@fastify/rate-limit';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';
import { sendApiError } from '../shared/api-error.js';
import { ErrorCode } from '../shared/errors.js';
import { AccountSettingsPutSchema, AccountSettingsQuerySchema } from './account-settings.schema.js';
import { AccountSettingsService } from './account-settings.service.js';

function rateLimitError(_request: unknown, context: { statusCode: number; ttl: number }) {
  const err = new Error('Too Many Requests') as Error & { statusCode: number; code: string; retryAfter: number };
  err.statusCode = context.statusCode;
  err.code = ErrorCode.RATE_LIMIT_EXCEEDED;
  err.retryAfter = Math.ceil(context.ttl / 1000);
  return err;
}

export default async function accountSettingsRoutes(
  fastify: FastifyInstance,
  options: { db: Db; rateLimitMax?: number; rateLimitTimeWindow?: string | number },
) {
  const service = new AccountSettingsService(options.db);
  const guards = [fastify.apiKeyGuardRegistered, fastify.authenticate, fastify.clientBuildGate];

  fastify.get('/account/settings', {
    config: { clientBuildGate: true },
    preHandler: guards,
  }, async (request, reply) => {
    try {
      const query = AccountSettingsQuerySchema.parse(request.query);
      return reply.status(200).send(await service.read(request.user.userId, query.afterRevision));
    } catch (error) {
      return sendApiError(reply, request, error);
    }
  });

  // Writes are limited per client address: 60 a minute is far above what the
  // app sends (one batch per sync) and stops a loop from hammering the table.
  await fastify.register(async (writeScope) => {
    await writeScope.register(rateLimit, {
      max: options.rateLimitMax ?? 60,
      timeWindow: options.rateLimitTimeWindow ?? '1 minute',
      errorResponseBuilder: rateLimitError,
    });
    writeScope.put('/account/settings', {
      config: { clientBuildGate: true },
      preHandler: guards,
    }, async (request, reply) => {
      try {
        const body = AccountSettingsPutSchema.parse(request.body);
        return reply.status(200).send(await service.write(request.user.userId, body.changes));
      } catch (error) {
        return sendApiError(reply, request, error);
      }
    });
  });
}
