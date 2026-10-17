import type { Db } from '../../db/client.js';
import { PillsService } from './pills.service.js';
import { CreatePillSchema, DeletePillSchema, UpdatePillSchema } from './pills.schema.js';
import { sendApiError } from '../shared/api-error.js';
import type { FastifyInstance } from 'fastify';

export default async function pillsRoutes(fastify: FastifyInstance, opts: { db: Db }) {
  const service = new PillsService(opts.db);

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
}
