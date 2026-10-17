import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';
import { sendApiError } from '../shared/api-error.js';
import { ComponentSyncService } from './component-sync.service.js';
import { ComponentSyncParamsSchema, ComponentSyncQuerySchema } from './sync.schema.js';

const pathComponent = {
  account: 'account',
  stable: 'stable',
  'medication-bridge': 'medicationBridge',
  medication: 'medication',
} as const;

export default async function syncRoutes(
  fastify: FastifyInstance,
  options: { db: Db; cursorSecret: string },
) {
  const sync = new ComponentSyncService(options.db, options.cursorSecret);

  fastify.get('/sync/:component', {
    config: { clientBuildGate: true },
    preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate, fastify.clientBuildGate],
  }, async (request, reply) => {
    try {
      const params = ComponentSyncParamsSchema.parse(request.params);
      const query = ComponentSyncQuerySchema.parse(request.query);
      const response = await sync.read(request.user.userId, {
        component: pathComponent[params.component],
        contractVersion: query.contractVersion,
        ...(query.cursor ? { cursor: query.cursor } : {}),
        ...(query.afterSequence ? { afterSequence: query.afterSequence } : {}),
        ...(query.pageSize === undefined ? {} : { pageSize: query.pageSize }),
      });
      return reply.status(200).send(response);
    } catch (error) {
      return sendApiError(reply, request, error);
    }
  });
}
