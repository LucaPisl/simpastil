import { ZodError } from 'zod';
import type { Db } from '../../db/client.js';
import { DoseLogsService } from './dose_logs.service.js';
import {
  CreateDoseLogSchema,
  UpdateDoseLogSchema,
  LogsQuerySchema,
} from './dose_logs.schema.js';
import { ConflictError, ResourceError } from '../shared/errors.js';
import { ApiError, sendApiError, serializeApiError } from '../shared/api-error.js';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';

export default async function doseLogsRoutes(fastify: FastifyInstance, opts: { db: Db }) {
  const service = new DoseLogsService(opts.db);

  // POST /logs/:scheduleId
  fastify.post(
    '/logs/:scheduleId',
    { preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate] },
    async (request, reply) => {
      const { scheduleId } = request.params as { scheduleId: string };
      const { userId } = request.user;
      try {
        const body = CreateDoseLogSchema.parse(request.body);
        const log = await service.recordDose(userId, scheduleId, body);
        return reply.status(201).send(log);
      } catch (err) {
        return sendResourceError(reply, request, err);
      }
    },
  );

  // GET /profiles/:profileId/logs
  fastify.get(
    '/profiles/:profileId/logs',
    { preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate] },
    async (request, reply) => {
      const { profileId } = request.params as { profileId: string };
      const { userId } = request.user;
      try {
        const query = LogsQuerySchema.parse(request.query);
        const result = await service.getLogs(userId, profileId, query);
        return reply.status(200).send(result);
      } catch (err) {
        return sendResourceError(reply, request, err);
      }
    },
  );

  // PATCH /logs/:id
  fastify.patch(
    '/logs/:id',
    { preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate] },
    async (request, reply) => {
      const { id } = request.params as { id: string };
      const { userId } = request.user;
      try {
        const body = UpdateDoseLogSchema.parse(request.body);
        const log = await service.updateLog(userId, id, body);
        return reply.status(200).send(log);
      } catch (err) {
        return sendResourceError(reply, request, err);
      }
    },
  );

  // DELETE /logs/:id
  fastify.delete(
    '/logs/:id',
    { preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate] },
    async (request, reply) => {
      const { id } = request.params as { id: string };
      const { userId } = request.user;
      try {
        await service.deleteLog(userId, id);
        return reply.status(204).send();
      } catch (err) {
        return sendResourceError(reply, request, err);
      }
    },
  );
}

function sendResourceError(reply: FastifyReply, request: FastifyRequest, err: unknown): FastifyReply {
  if (err instanceof ConflictError) {
    return reply.status(409).send({
      error: err.message,
      code: err.code,
      ...(err.existingId ? { existingId: err.existingId } : {}),
    });
  }
  if (err instanceof ResourceError) {
    if (err.code === 'MEDICATION_BRIDGE_REQUIRED') {
      return reply.status(err.statusCode).send(serializeApiError(
        new ApiError(err.statusCode, err.code, err.message),
        request.correlationId,
      ));
    }
    return reply.status(err.statusCode).send({ error: err.message, code: err.code });
  }
  if (err instanceof ZodError) {
    return sendApiError(reply, request, err);
  }
  throw err;
}
