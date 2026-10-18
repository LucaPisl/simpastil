import { sql as drizzleSql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import type { ApiConfig } from '../../config/app-config.js';
import { ReadinessService } from './readiness.service.js';
import { SafeLogger } from '../../lib/safe-logger.js';
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
  // The probe runs every few seconds; log only when the answer or its reason
  // changes, so a stuck deployment produces one clear line, not thousands.
  let lastReadiness: string | undefined;

  fastify.get('/health/live', async (_request, reply) => reply.status(200).send({
    status: 'ok',
    version: appVersion,
    uptime: Math.floor(process.uptime()),
  }));

  fastify.get('/health/ready', async (request, reply) => {
    const result = await readiness.check();
    const state = result.ready ? 'ready' : result.reason;
    if (state !== lastReadiness) {
      const logger = new SafeLogger({
        info: (record) => request.log.info(record),
        warn: (record) => request.log.warn(record),
        error: (record) => request.log.error(record),
      });
      if (!result.ready) {
        logger.warn('readiness.not_ready', { readinessReason: result.reason, ...result.cause });
      } else if (lastReadiness !== undefined) {
        logger.info('readiness.recovered');
      }
      lastReadiness = state;
    }
    // The response never carries the reason: it is for the operator's log.
    return reply.status(result.ready ? 200 : 503).send({ status: result.ready ? 'ready' : 'not_ready' });
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
