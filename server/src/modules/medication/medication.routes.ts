import { ZodError } from 'zod';
import type { Db } from '../../db/client.js';
import { ApiError, sendApiError, serializeApiError } from '../shared/api-error.js';
import { ConflictError, ResourceError } from '../shared/errors.js';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { BridgeMedicationCommandSchema } from './bridge-medication-command.schema.js';
import { BridgeMedicationCommandService } from './bridge-medication-command.service.js';
import { LegacySplitReconciliationSchema } from './legacy-split-reconciliation.schema.js';
import { LegacySplitReconciliationService } from './legacy-split-reconciliation.service.js';
import { InventoryCommandSchema, MedicationCommandSchema } from './medication-command.schema.js';
import { MedicationCommandService } from './medication-command.service.js';
import { BridgePrnCommandSchema } from './bridge-prn-command.schema.js';
import { BridgePrnCommandService } from './bridge-prn-command.service.js';
import { MovedHistoryRequestSchema } from './moved-history.schema.js';
import { MovedHistoryService } from './moved-history.service.js';

export default async function medicationRoutes(fastify: FastifyInstance, opts: { db: Db }) {
  const activeCommands = new MedicationCommandService(opts.db);
  const bridgeCommands = new BridgeMedicationCommandService(opts.db);
  const bridgePrnCommands = new BridgePrnCommandService(opts.db);
  const movedHistory = new MovedHistoryService(opts.db);
  const splitReconciliation = new LegacySplitReconciliationService(opts.db);
  const guards = [fastify.apiKeyGuardRegistered, fastify.authenticate, fastify.clientBuildGate];
  const gated = { config: { clientBuildGate: true }, preHandler: guards };

  fastify.post('/medication/commands', gated, async (request, reply) => {
    const { userId } = request.user;
    try {
      const command = MedicationCommandSchema.parse(request.body);
      return reply.status(200).send(await activeCommands.execute(userId, command));
    } catch (error) {
      return sendMedicationError(reply, request, error);
    }
  });

  fastify.post('/medication/inventory/commands', gated, async (request, reply) => {
    const { userId } = request.user;
    try {
      const command = InventoryCommandSchema.parse(request.body);
      return reply.status(200).send(await activeCommands.executeInventory(userId, command));
    } catch (error) {
      return sendMedicationError(reply, request, error);
    }
  });

  fastify.post('/medication/bridge/commands', gated, async (request, reply) => {
    const { userId } = request.user;
    try {
      const command = BridgeMedicationCommandSchema.parse(request.body);
      return reply.status(200).send(await bridgeCommands.execute(userId, command));
    } catch (error) {
      return sendMedicationError(reply, request, error);
    }
  });

  fastify.post('/medication/bridge/prn/commands', gated, async (request, reply) => {
    const { userId } = request.user;
    try {
      const command = BridgePrnCommandSchema.parse(request.body);
      return reply.status(200).send(await bridgePrnCommands.execute(userId, command, request.clientBuild));
    } catch (error) {
      return sendMedicationError(reply, request, error);
    }
  });

  fastify.post('/medication/moved-history', gated, async (request, reply) => {
    const { userId } = request.user;
    try {
      const body = MovedHistoryRequestSchema.parse(request.body);
      return reply.status(200).send(await movedHistory.execute(userId, body));
    } catch (error) {
      return sendMedicationError(reply, request, error);
    }
  });

  fastify.post('/medication/legacy-split/reconcile', gated, async (request, reply) => {
    const { userId } = request.user;
    try {
      const command = LegacySplitReconciliationSchema.parse(request.body);
      const result = await splitReconciliation.execute(userId, command);
      return reply.status(command.operation === 'record' ? 201 : 200).send(result);
    } catch (error) {
      return sendMedicationError(reply, request, error);
    }
  });
}

function sendMedicationError(
  reply: FastifyReply,
  request: FastifyRequest,
  error: unknown,
): FastifyReply {
  if (error instanceof ZodError) return sendApiError(reply, request, error);
  if (error instanceof ConflictError) {
    return reply.status(409).send(serializeApiError(
      new ApiError(409, error.code, error.message),
      request.correlationId,
    ));
  }
  if (error instanceof ResourceError) {
    return reply.status(error.statusCode).send(serializeApiError(
      new ApiError(error.statusCode, error.code, error.message),
      request.correlationId,
    ));
  }
  return sendApiError(reply, request, error);
}
