import type { Db } from '../../db/client.js';
import { PillsService } from './pills.service.js';
import { PillPhotoService } from './pill-photo.service.js';
import { PILL_PHOTO_BODY_LIMIT } from '../shared/pill-photo.js';
import { ApiError } from '../shared/api-error.js';
import { ErrorCode } from '../shared/errors.js';
import { z } from 'zod';
import { CreatePillSchema, DeletePillSchema, UpdatePillSchema } from './pills.schema.js';
import { sendApiError } from '../shared/api-error.js';
import rateLimit from '@fastify/rate-limit';
import type { FastifyInstance } from 'fastify';

export interface PillsRoutesOptions {
  db: Db;
  rateLimitMax?: number;
  rateLimitTimeWindow?: string | number;
}

/** Photo uploads per account and minute: a handful of edits, never a flood. */
const PHOTO_UPLOADS_PER_MINUTE = 20;

export default async function pillsRoutes(fastify: FastifyInstance, opts: PillsRoutesOptions) {
  const service = new PillsService(opts.db);
  const photos = new PillPhotoService(opts.db);
  const PhotoParams = z.object({ id: z.string().uuid() });

  // A photo travels as the raw JPEG. The parser exists only for this content
  // type and carries its own, small limit (the Fastify default is 1 MiB).
  fastify.addContentTypeParser(
    'image/jpeg',
    { parseAs: 'buffer', bodyLimit: PILL_PHOTO_BODY_LIMIT },
    (_request, body, done) => done(null, body),
  );

  fastify.get(
    '/profiles/:profileId/pills',
    { preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate] },
    async (request, reply) => {
      const { profileId } = request.params as { profileId: string };
      const { userId } = request.user;
      try {
        const result = await service.listPills(userId, profileId);
        return reply.status(200).send({ pills: result });
      } catch (err) {
        return sendApiError(reply, request, err);
      }
    },
  );

  fastify.post(
    '/profiles/:profileId/pills',
    { config: { clientBuildGate: true }, preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate, fastify.clientBuildGate] },
    async (request, reply) => {
      const { profileId } = request.params as { profileId: string };
      const { userId } = request.user;
      try {
        const body = CreatePillSchema.parse(request.body);
        const pill = await service.createPill(userId, profileId, body);
        return reply.status(201).send(pill);
      } catch (err) {
        return sendApiError(reply, request, err);
      }
    },
  );

  fastify.patch(
    '/profiles/:profileId/pills/:id',
    { config: { clientBuildGate: true }, preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate, fastify.clientBuildGate] },
    async (request, reply) => {
      const { profileId, id } = request.params as { profileId: string; id: string };
      const { userId } = request.user;
      try {
        const body = UpdatePillSchema.parse(request.body);
        const pill = await service.updatePill(userId, profileId, id, body);
        return reply.status(200).send(pill);
      } catch (err) {
        return sendApiError(reply, request, err);
      }
    },
  );

  fastify.delete(
    '/profiles/:profileId/pills/:id',
    { config: { clientBuildGate: true }, preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate, fastify.clientBuildGate] },
    async (request, reply) => {
      const { profileId, id } = request.params as { profileId: string; id: string };
      const { userId } = request.user;
      try {
        const body = DeletePillSchema.parse(request.body);
        await service.deletePill(userId, profileId, id, body.mutationId, body.baseRevision);
        return reply.status(204).send();
      } catch (err) {
        return sendApiError(reply, request, err);
      }
    },
  );

  fastify.get(
    '/pills/:id/photo',
    { preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate] },
    async (request, reply) => {
      try {
        const { id } = PhotoParams.parse(request.params);
        const photo = await photos.get(request.user.userId, id);
        return reply
          .status(200)
          .type('image/jpeg')
          .header('ETag', `"${photo.sha256}"`)
          .header('X-Photo-Revision', photo.revision)
          .header('Cache-Control', 'private, no-store')
          .send(photo.bytes);
      } catch (err) {
        return sendApiError(reply, request, err);
      }
    },
  );

  await fastify.register(async (scope) => {
    await scope.register(rateLimit, {
      global: false,
      hook: 'onRequest',
      errorResponseBuilder: (_request, context) => {
        const err = new Error('Too Many Requests') as Error & { statusCode: number; code: string; retryAfter: number };
        err.statusCode = context.statusCode;
        err.code = ErrorCode.RATE_LIMIT_EXCEEDED;
        err.retryAfter = Math.ceil(context.ttl / 1000);
        return err;
      },
    });
    scope.put(
      '/pills/:id/photo',
      {
        bodyLimit: PILL_PHOTO_BODY_LIMIT,
        // Checked in onRequest, before the body is read: an unauthenticated or
        // over-budget caller is refused without buffering up to 600 KB.
        onRequest: [fastify.apiKeyGuardRegistered, fastify.authenticate, fastify.clientBuildGate],
        // Counted per signed-in account; the plugin appends its hook after the
        // onRequest hooks above, so an unauthenticated caller never spends the budget.
        config: {
          clientBuildGate: true,
          rateLimit: {
            max: opts.rateLimitMax ?? PHOTO_UPLOADS_PER_MINUTE,
            timeWindow: opts.rateLimitTimeWindow ?? '1 minute',
            keyGenerator: (request: { user?: { userId?: string }; ip: string }) => request.user?.userId ?? request.ip,
          },
        },
      },
      async (request, reply) => {
        try {
          const { id } = PhotoParams.parse(request.params);
          if (!Buffer.isBuffer(request.body)) {
            throw new ApiError(415, ErrorCode.VALIDATION_ERROR, 'Send the photo as image/jpeg', { retryable: false });
          }
          const result = await photos.put(request.user.userId, id, request.body);
          return reply.status(200).send(result);
        } catch (err) {
          return sendApiError(reply, request, err);
        }
      },
    );
  });

  fastify.delete(
    '/pills/:id/photo',
    {
      config: { clientBuildGate: true },
      preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate, fastify.clientBuildGate],
    },
    async (request, reply) => {
      try {
        const { id } = PhotoParams.parse(request.params);
        await photos.remove(request.user.userId, id);
        return reply.status(204).send();
      } catch (err) {
        return sendApiError(reply, request, err);
      }
    },
  );
}
