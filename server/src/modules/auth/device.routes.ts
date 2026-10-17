import { z } from 'zod';
import { eq, and } from 'drizzle-orm';
import { sql as drizzleSql } from 'drizzle-orm';
import { refreshTokens } from '../../db/schema.js';
import { sha256Hex } from '../../lib/crypto.js';
import { ErrorCode } from '../shared/errors.js';
import type { FastifyInstance, FastifyReply } from 'fastify';
import type { Db } from '../../db/client.js';

const DeviceSchema = z.object({
  refreshToken: z.string().min(1),
  deviceName: z.string().min(1).max(100),
});

export default async function deviceRoutes(fastify: FastifyInstance, opts: { db: Db }) {
  const database = opts.db;

  async function setDeviceName(
    rawRefreshToken: string,
    name: string,
    userId: string,
    reply: FastifyReply,
  ) {
    const hash = sha256Hex(rawRefreshToken);

    const result = await database.transaction(async (tx) => {
      await tx.execute(
        drizzleSql`SELECT set_config('app.current_user_id', ${userId}, true)`,
      );

      const [token] = await tx.select().from(refreshTokens).where(
        and(eq(refreshTokens.tokenHash, hash), eq(refreshTokens.userId, userId)),
      );
      if (!token || token.revoked || token.expiresAt < new Date()) {
        return null;
      }

      await tx
        .update(refreshTokens)
        .set({ deviceName: name })
        .where(and(eq(refreshTokens.familyId, token.familyId), eq(refreshTokens.revoked, false)));

      return true;
    });

    if (!result) {
      return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.AUTH_UNAUTHORIZED });
    }

    return reply.status(200).send({ ok: true });
  }

  fastify.post('/auth/device', { preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate] }, async (request, reply) => {
    const body = DeviceSchema.parse(request.body);
    return setDeviceName(body.refreshToken, body.deviceName, request.user.userId, reply);
  });

  fastify.patch('/auth/device', { preHandler: [fastify.apiKeyGuardRegistered, fastify.authenticate] }, async (request, reply) => {
    const body = DeviceSchema.parse(request.body);
    return setDeviceName(body.refreshToken, body.deviceName, request.user.userId, reply);
  });
}
