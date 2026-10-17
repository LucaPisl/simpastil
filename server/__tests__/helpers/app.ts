import Fastify, { type FastifyInstance, type FastifyRequest, type FastifyReply } from 'fastify';
import fp from 'fastify-plugin';
import jwtPlugin from '@fastify/jwt';
import postgres from 'postgres';
import { drizzle } from 'drizzle-orm/postgres-js';
import * as schema from '../../src/db/schema.js';
import authenticatePlugin from '../../src/plugins/authenticate.js';
import { loadKeys } from '../../src/config/keys.js';
import type { Db } from '../../src/db/client.js';

/**
 * Stub plugin that decorates the Fastify instance with no-op
 * apiKeyGuard and apiKeyGuardRegistered preHandlers. This lets
 * module routes register without error while bypassing API key
 * validation in unit-style tests that only need JWT auth.
 */
const apiKeyGuardStub = fp(async (fastify: FastifyInstance) => {
  const noop = async (_req: FastifyRequest, _reply: FastifyReply) => { /* bypass */ };
  fastify.decorate('apiKeyGuard', noop);
  fastify.decorate('apiKeyGuardRegistered', noop);
  fastify.decorate('clientBuildGate', noop);
  // Ensure request.keyUserId is always defined (null = no API key user)
  fastify.addHook('onRequest', async (request) => {
    (request as FastifyRequest & { keyUserId: string | null }).keyUserId = null;
  });
});

/**
 * Builds a Fastify test app registered with:
 *  - @fastify/jwt (RS256, keys from JWT_PRIVATE_KEY / JWT_PUBLIC_KEY env)
 *  - authenticate plugin (provides fastify.authenticate preHandler)
 *  - apiKeyGuardStub (no-op guards so routes that use apiKeyGuardRegistered work)
 *  - the supplied routes plugin (receives the test DB instance)
 *
 * Returns the app and the raw postgres client so the caller can close it
 * in afterAll.
 *
 * Usage:
 *   const { app, pgClient } = await buildTestApp(profilesRoutes);
 *   const token = signTestToken(app, userId);
 *   const res = await app.inject({ method: 'GET', url: '/profiles',
 *     headers: { authorization: `Bearer ${token}` } });
 */
export async function buildTestApp(
  routesPlugin: (fastify: FastifyInstance, opts: { db: Db }) => Promise<void>,
): Promise<{ app: FastifyInstance; pgClient: postgres.Sql; db: Db }> {
  const appUrl = process.env['DATABASE_URL_APP'];
  if (!appUrl) throw new Error('DATABASE_URL_APP must be set');

  const pgClient = postgres(appUrl, { max: 3 });
  const db = drizzle(pgClient, { schema }) as Db;

  const keys = loadKeys(process.env);
  const app = Fastify({ logger: false });

  await app.register(jwtPlugin, {
    secret: {
      private: keys.privateKey,
      public: keys.publicKey,
    },
    sign: { algorithm: 'RS256', expiresIn: 900 },
  });

  await app.register(authenticatePlugin, { db });
  await app.register(apiKeyGuardStub);

  // Pass the test DB instance into the module plugin via opts
  await app.register(routesPlugin, { db });

  await app.ready();
  return { app, pgClient, db };
}

/**
 * Signs a real RS256 JWT for a given userId.
 * The token is accepted by fastify.authenticate in the test app.
 */
export function signTestToken(app: FastifyInstance, userId: string): string {
  return app.jwt.sign({ sub: userId, sessionVersion: '1' });
}

/** Install explicit tenant identity for superuser-owned legacy-row fixtures. */
export async function setTenantContext(sql: postgres.Sql, userId: string): Promise<void> {
  await sql.unsafe("SELECT set_config('app.current_user_id', $1, false)", [userId]);
}
