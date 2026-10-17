import { sql as drizzleSql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import type { ApiConfig } from '../../config/app-config.js';
import { ReadinessService } from './readiness.service.js';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

let appVersion = '0.0.0';
try {
  const pkg = JSON.parse(readFileSync(join(process.cwd(), 'package.json'), 'utf8'));
  appVersion = pkg.version ?? '0.0.0';
} catch { /* fallback */ }

export default async function healthRoutes(
  fastify: import('fastify').FastifyInstance,
  opts: { db: Db; config: ApiConfig },
) {
  const database = opts.db;
  const readiness = new ReadinessService(database, opts.config.releaseId);

  fastify.get('/health/live', async (_request, reply) => reply.status(200).send({
    status: 'ok',
    version: appVersion,
    uptime: Math.floor(process.uptime()),
  }));

  fastify.get('/health/ready', async (_request, reply) => {
    const ready = await readiness.isReady();
    return reply.status(ready ? 200 : 503).send({ status: ready ? 'ready' : 'not_ready' });
  });

  fastify.get('/health', async (_request, reply) => {
    let dbStatus: 'ok' | 'error' = 'error';
    let dbLatencyMs = -1;

    try {
      const start = performance.now();
      await Promise.race([
        database.execute(drizzleSql`SELECT 1`),
        new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), 3000)),
      ]);
      dbLatencyMs = Math.round(performance.now() - start);
      dbStatus = 'ok';
    } catch { /* db unreachable */ }

    const status = dbStatus === 'ok' ? 'ok' : 'degraded';
    const httpStatus = status === 'ok' ? 200 : 503;

    return reply.status(httpStatus).send({
      status,
      version: appVersion,
      db: { status: dbStatus, latencyMs: dbLatencyMs > 0 ? dbLatencyMs : undefined },
      uptime: Math.floor(process.uptime()),
    });
  });
}
