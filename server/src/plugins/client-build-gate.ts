import fp from 'fastify-plugin';
import { eq } from 'drizzle-orm';
import type { FastifyReply, FastifyRequest } from 'fastify';
import type { Db } from '../db/client.js';
import { deploymentManifest } from '../db/schema.js';
import { ApiError, serializeApiError } from '../modules/shared/api-error.js';
import { ErrorCode } from '../modules/shared/errors.js';

export const CLIENT_BUILD_HEADER = 'x-simpastil-client-build';
export const CLIENT_BUILD_GATE_MARKER = 'clientBuildGate';

declare module 'fastify' {
  interface FastifyContextConfig {
    clientBuildGate?: boolean;
  }
  interface FastifyInstance {
    clientBuildGate: (request: FastifyRequest, reply: FastifyReply) => Promise<void>;
  }
  interface FastifyRequest {
    clientBuild: number;
  }
}

export default fp(async (fastify, options: { db: Db }) => {
  fastify.decorateRequest('clientBuild', 1);
  fastify.decorate('clientBuildGate', async (request, reply) => {
    if (request.routeOptions.config[CLIENT_BUILD_GATE_MARKER] !== true) return;

    const raw = request.headers[CLIENT_BUILD_HEADER];
    let clientBuild = 1;
    if (raw !== undefined) {
      if (typeof raw !== 'string' || !/^[1-9]\d*$/.test(raw)) {
        const malformed = new ApiError(400, ErrorCode.VALIDATION_ERROR, 'Client build header must be a positive integer', { retryable: false });
        reply.status(malformed.statusCode).send(serializeApiError(malformed, request.correlationId));
        return;
      }
      clientBuild = Number(raw);
      if (!Number.isSafeInteger(clientBuild)) {
        const malformed = new ApiError(400, ErrorCode.VALIDATION_ERROR, 'Client build header must be a positive integer', { retryable: false });
        reply.status(malformed.statusCode).send(serializeApiError(malformed, request.correlationId));
        return;
      }
    }
    request.clientBuild = clientBuild;

    const buildProfile = process.env['SIMPASTIL_BUILD_PROFILE'] ?? 'production';
    if (buildProfile !== 'production' && buildProfile !== 'compatibility') {
      const unavailable = new ApiError(503, ErrorCode.INTERNAL, 'Client build profile is unavailable');
      reply.status(unavailable.statusCode).send(serializeApiError(unavailable, request.correlationId));
      return;
    }
    // Compatibility images relax only the minimum-client gate. They do not
    // change the deployment manifest or any medication-ledger authority check.
    if (buildProfile === 'compatibility') return;

    const minimumClientBuild = await options.db.transaction(async (tx) => {
      const [manifest] = await tx.select({
        minimumClientBuild: deploymentManifest.enforcedMinimumClientBuild,
      }).from(deploymentManifest)
        .where(eq(deploymentManifest.singletonKey, true));
      return manifest?.minimumClientBuild;
    });
    if (minimumClientBuild === undefined) {
      const unavailable = new ApiError(503, ErrorCode.INTERNAL, 'Client build authority is unavailable');
      reply.status(unavailable.statusCode).send(serializeApiError(unavailable, request.correlationId));
      return;
    }
    if (clientBuild < minimumClientBuild) {
      const upgrade = new ApiError(426, ErrorCode.CLIENT_UPGRADE_REQUIRED, 'Update the app before using this operation', { retryable: false });
      reply.status(upgrade.statusCode).send(serializeApiError(upgrade, request.correlationId));
    }
  });
});
