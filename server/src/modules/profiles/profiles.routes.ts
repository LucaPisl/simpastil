import type { Db } from '../../db/client.js';
import { ProfilesService } from './profiles.service.js';
import { CreateProfileSchema, DeleteProfileSchema, UpdateProfileSchema } from './profiles.schema.js';
import { sendApiError } from '../shared/api-error.js';
import type { FastifyInstance } from 'fastify';

export default async function profilesRoutes(fastify: FastifyInstance, opts: { db: Db }) {
  const service = new ProfilesService(opts.db);

  // GET /profiles
  fastify.get(
    '/profiles',
    { preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate] },
    async (request, reply) => {
      const { userId } = request.user;
      const result = await service.listProfiles(userId);
      return reply.status(200).send({ profiles: result });
    },
  );

  // POST /profiles
  fastify.post(
    '/profiles',
    { config: { clientBuildGate: true }, preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate, fastify.clientBuildGate] },
    async (request, reply) => {
      const { userId } = request.user;
      try {
        const body = CreateProfileSchema.parse(request.body);
        const profile = await service.createProfile(userId, body);
        return reply.status(201).send(profile);
      } catch (err) {
        return sendApiError(reply, request, err);
      }
    },
  );

  // PATCH /profiles/:id
  fastify.patch(
    '/profiles/:id',
    { config: { clientBuildGate: true }, preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate, fastify.clientBuildGate] },
    async (request, reply) => {
      const { id } = request.params as { id: string };
      const { userId } = request.user;
      try {
        const body = UpdateProfileSchema.parse(request.body);
        const profile = await service.updateProfile(userId, id, body);
        return reply.status(200).send(profile);
      } catch (err) {
        return sendApiError(reply, request, err);
      }
    },
  );

  // DELETE /profiles/:id
  fastify.delete(
    '/profiles/:id',
    { config: { clientBuildGate: true }, preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate, fastify.clientBuildGate] },
    async (request, reply) => {
      const { id } = request.params as { id: string };
      const { userId } = request.user;
      try {
        const body = DeleteProfileSchema.parse(request.body);
        await service.deleteProfile(userId, id, body.mutationId, body.baseRevision);
        return reply.status(204).send();
      } catch (err) {
        return sendApiError(reply, request, err);
      }
    },
  );
}
