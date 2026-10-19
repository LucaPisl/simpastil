import rateLimit from '@fastify/rate-limit';
import { z } from 'zod';
import type { FastifyInstance, FastifyReply } from 'fastify';
import type { ApiConfig } from '../../config/app-config.js';
import type { Db } from '../../db/client.js';
import type { EncryptionCapabilities } from '../../lib/crypto.js';
import type { DeliveryPayloadSealer } from '../../lib/delivery-payload-crypto.js';
import { ErrorCode } from '../shared/errors.js';
import { ForgotPasswordRequestSchema, ResetPasswordRequestSchema } from '../auth/auth.schema.js';
import { SessionService } from '../auth/session.service.js';
import { RecoveryError, RecoveryService } from './recovery.service.js';
import type { SettingsService } from '../settings/settings.service.js';

const InvitationAcceptSchema = z.object({ token: z.string().min(1).max(4096) });

function rateLimitError(_request: unknown, context: { statusCode: number; ttl: number }) {
  const err = new Error('Too Many Requests') as Error & { statusCode: number; code: string; retryAfter: number };
  err.statusCode = context.statusCode;
  err.code = ErrorCode.RATE_LIMIT_EXCEEDED;
  err.retryAfter = Math.ceil(context.ttl / 1000);
  return err;
}

function sendRecoveryError(reply: FastifyReply, err: unknown): FastifyReply {
  if (err instanceof RecoveryError) {
    return reply.status(err.statusCode).send({ error: err.message, code: err.code });
  }
  throw err;
}

export default async function recoveryRoutes(
  fastify: FastifyInstance,
  opts: {
    db: Db;
    config: ApiConfig;
    encryption: EncryptionCapabilities;
    payloadSealer: DeliveryPayloadSealer;
    rateLimitMax?: number;
    rateLimitTimeWindow?: string | number;
    forgotPasswordRateLimitMax?: number;
    sessionService?: SessionService;
    settings?: SettingsService;
  },
) {
  const service = new RecoveryService(
    opts.db,
    opts.payloadSealer,
    opts.encryption,
    opts.config.publicAppUrl,
    opts.sessionService,
    opts.settings,
  );

  await fastify.register(async (forgotScope) => {
    await forgotScope.register(rateLimit, {
      max: opts.forgotPasswordRateLimitMax ?? opts.rateLimitMax ?? 10,
      timeWindow: '1 hour',
      errorResponseBuilder: rateLimitError,
    });
    forgotScope.post('/auth/forgot-password', async (request, reply) => {
      const body = ForgotPasswordRequestSchema.parse(request.body);
      try {
        await service.requestPasswordReset(body.email);
      } catch {
        // Database and delivery failures are intentionally indistinguishable
        // from an unknown email at this public boundary.
      }
      return reply.status(200).send({ message: 'If that email is registered, a reset link has been sent.' });
    });
  });

  await fastify.register(async (resetScope) => {
    await resetScope.register(rateLimit, {
      max: opts.rateLimitMax ?? 5,
      timeWindow: opts.rateLimitTimeWindow ?? '15 minutes',
      errorResponseBuilder: rateLimitError,
    });
    resetScope.post('/auth/reset-password', async (request, reply) => {
      const body = ResetPasswordRequestSchema.parse(request.body);
      try {
        await service.resetPassword(body.token, body.newPassword);
        return reply.status(200).send({ message: 'Password has been reset.' });
      } catch (err) {
        return sendRecoveryError(reply, err);
      }
    });
  });

  await fastify.register(async (inviteScope) => {
    await inviteScope.register(rateLimit, {
      max: opts.rateLimitMax ?? 5,
      timeWindow: opts.rateLimitTimeWindow ?? '15 minutes',
      errorResponseBuilder: rateLimitError,
    });
    inviteScope.post('/auth/invite/accept', async (request, reply) => {
      const body = InvitationAcceptSchema.parse(request.body);
      try {
        const result = await service.acceptInvitation(body.token);
        return reply.status(200).send(result);
      } catch (err) {
        return sendRecoveryError(reply, err);
      }
    });
  });
}
