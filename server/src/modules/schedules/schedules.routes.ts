import type { Db } from '../../db/client.js';
import { SchedulesService } from './schedules.service.js';
import { CreateScheduleSchema, DeleteScheduleSchema, ScheduleRepairSchema, UpdateScheduleSchema } from './schedules.schema.js';
import { ScheduleRepairService } from './schedule-repair.service.js';
import { sendApiError } from '../shared/api-error.js';
import type { FastifyInstance } from 'fastify';

export default async function schedulesRoutes(fastify: FastifyInstance, opts: { db: Db }) {
  const service = new SchedulesService(opts.db);
  const repairService = new ScheduleRepairService(opts.db);

  fastify.get(
    '/pills/:pillId/schedules',
    { preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate] },
    async (request, reply) => {
      const { pillId } = request.params as { pillId: string };
      const { userId } = request.user;
      try {
        const result = await service.listSchedules(userId, pillId);
        return reply.status(200).send({ schedules: result });
      } catch (err) {
        return sendApiError(reply, request, err);
      }
    },
  );

  fastify.post(
    '/pills/:pillId/schedules',
    { config: { clientBuildGate: true }, preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate, fastify.clientBuildGate] },
    async (request, reply) => {
      const { pillId } = request.params as { pillId: string };
      const { userId } = request.user;
      try {
        const body = CreateScheduleSchema.parse(request.body);
        const schedule = await service.createSchedule(userId, pillId, body);
        return reply.status(201).send(schedule);
      } catch (err) {
        return sendApiError(reply, request, err);
      }
    },
  );

  fastify.patch(
    '/pills/:pillId/schedules/:id',
    { config: { clientBuildGate: true }, preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate, fastify.clientBuildGate] },
    async (request, reply) => {
      const { pillId, id } = request.params as { pillId: string; id: string };
      const { userId } = request.user;
      try {
        const body = UpdateScheduleSchema.parse(request.body);
        const schedule = await service.updateSchedule(userId, pillId, id, body);
        return reply.status(200).send(schedule);
      } catch (err) {
        return sendApiError(reply, request, err);
      }
    },
  );

  fastify.delete(
    '/pills/:pillId/schedules/:id',
    { config: { clientBuildGate: true }, preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate, fastify.clientBuildGate] },
    async (request, reply) => {
      const { pillId, id } = request.params as { pillId: string; id: string };
      const { userId } = request.user;
      try {
        const body = DeleteScheduleSchema.parse(request.body);
        await service.deleteSchedule(userId, pillId, id, body.mutationId, body.baseRevision);
        return reply.status(204).send();
      } catch (err) {
        return sendApiError(reply, request, err);
      }
    },
  );

  fastify.post(
    '/pills/:pillId/schedules/:id/repair',
    { config: { clientBuildGate: true }, preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate, fastify.clientBuildGate] },
    async (request, reply) => {
      const { pillId, id } = request.params as { pillId: string; id: string };
      const { userId } = request.user;
      try {
        const body = ScheduleRepairSchema.parse(request.body);
        const schedule = await repairService.repair(userId, pillId, id, body);
        return reply.status(200).send(schedule);
      } catch (err) {
        return sendApiError(reply, request, err);
      }
    },
  );
}
