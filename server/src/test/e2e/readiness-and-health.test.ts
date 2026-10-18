import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { sql } from 'drizzle-orm';
import { createDbs } from '../helpers/db-helpers.js';
import { buildApp } from '../helpers/app-factory.js';
import Fastify from 'fastify';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';
import type { ApiConfig } from '../../config/app-config.js';
import healthRoutes from '../../modules/health/health.routes.js';
import { ReadinessService, readBundledMigrationHead } from '../../modules/health/readiness.service.js';

describe('readiness verifies the applied migration head', () => {
  const dbs = createDbs();
  const bundled = readBundledMigrationHead();

  beforeAll(async () => {
    const applied = await dbs.superDb.execute<{ count: number }>(
      sql`SELECT count(*)::int AS count FROM drizzle.__drizzle_migrations`,
    );
    expect(applied[0]?.count).toBe(bundled.count);
  });

  afterAll(async () => {
    await dbs.cleanup();
  });

  it('is ready when the database is at the bundled journal head', async () => {
    expect(await new ReadinessService(dbs.appDb).isReady()).toBe(true);
  });

  it('is ready on a stock install with no RELEASE_ID and not ready for a different one', async () => {
    expect(await new ReadinessService(dbs.appDb, undefined).isReady()).toBe(true);
    expect(await new ReadinessService(dbs.appDb, 'migration-0012').isReady()).toBe(false);
  });

  it('is not ready when the newest migration row is missing', async () => {
    const removed = await dbs.superDb.execute<{ id: number; hash: string; created_at: string }>(sql`
      DELETE FROM drizzle.__drizzle_migrations
      WHERE id = (SELECT max(id) FROM drizzle.__drizzle_migrations)
      RETURNING id, hash, created_at
    `);
    try {
      expect(removed).toHaveLength(1);
      expect(await new ReadinessService(dbs.appDb).isReady()).toBe(false);
    } finally {
      const row = removed[0]!;
      await dbs.superDb.execute(sql`
        INSERT INTO drizzle.__drizzle_migrations (id, hash, created_at)
        VALUES (${row.id}, ${row.hash}, ${row.created_at})
      `);
    }
    expect(await new ReadinessService(dbs.appDb).isReady()).toBe(true);
  });

  async function withLaterMigration(check: () => Promise<void>): Promise<void> {
    const inserted = await dbs.superDb.execute<{ id: number }>(sql`
      INSERT INTO drizzle.__drizzle_migrations (hash, created_at)
      VALUES ('later-release-hash', ${bundled.createdAt + 1})
      RETURNING id
    `);
    try {
      await check();
    } finally {
      await dbs.superDb.execute(sql`DELETE FROM drizzle.__drizzle_migrations WHERE id = ${inserted[0]!.id}`);
    }
    expect(await new ReadinessService(dbs.appDb).isReady()).toBe(true);
  }

  // The manifest guard only lets deployment_authority_owner write; tests set
  // the floor directly and put it back, which no migration ever does.
  async function setCompatibilityFloor(count: number): Promise<void> {
    await dbs.superDb.transaction(async (tx) => {
      await tx.execute(sql`SET LOCAL ROLE deployment_authority_owner`);
      await tx.execute(sql`
        UPDATE public.deployment_manifest SET compatible_from_migration_count = ${count}
        WHERE singleton_key IS TRUE
      `);
    });
  }

  it('is ready on a newer database when later migrations kept the compatibility floor', async () => {
    await withLaterMigration(async () => {
      expect(await new ReadinessService(dbs.appDb).isReady()).toBe(true);
    });
  });

  it('is not ready on a newer database once a breaking migration raised the floor', async () => {
    await withLaterMigration(async () => {
      await setCompatibilityFloor(bundled.count + 1);
      try {
        expect(await new ReadinessService(dbs.appDb).isReady()).toBe(false);
      } finally {
        await setCompatibilityFloor(bundled.count);
      }
    });
  });

  it('is not ready on a newer database that does not contain this image head', async () => {
    await withLaterMigration(async () => {
      const service = new ReadinessService(dbs.appDb, undefined, () => ({ ...bundled, hash: 'edited-migration-hash' }));
      expect(await service.isReady()).toBe(false);
    });
  });

  it('only raises the compatibility floor through its function', async () => {
    await expect(dbs.superDb.execute(sql`
      UPDATE public.deployment_manifest SET compatible_from_migration_count = 1
    `)).rejects.toThrow();
    const floor = await dbs.superDb.execute<{ count: number }>(sql`
      SELECT compatible_from_migration_count AS count FROM public.deployment_manifest
    `);
    expect(floor[0]?.count).toBe(bundled.count);
  });

  it('lets migrate record the server image version but not app_user', async () => {
    await expect(dbs.appDb.execute(sql`SELECT public.record_server_image('9.9.9')`)).rejects.toThrow();
    await expect(dbs.appDb.execute(sql`SELECT public.raise_migration_compatibility_floor(99)`)).rejects.toThrow();
  });

  it('is not ready when the head hash differs from the bundled migration file', async () => {
    const service = new ReadinessService(dbs.appDb, undefined, () => ({ ...bundled, hash: 'edited-migration-hash' }));
    expect(await service.isReady()).toBe(false);
  });

  it('reads the bundled journal once across probes', async () => {
    let reads = 0;
    const service = new ReadinessService(dbs.appDb, undefined, () => {
      reads += 1;
      return bundled;
    });
    expect(await service.isReady()).toBe(true);
    expect(await service.isReady()).toBe(true);
    expect(await service.isReady()).toBe(true);
    expect(reads).toBe(1);
  });

  it('stays not ready on a mismatching cached head and retries a failed journal read', async () => {
    let reads = 0;
    const mismatch = new ReadinessService(dbs.appDb, undefined, () => {
      reads += 1;
      return { ...bundled, count: bundled.count + 1 };
    });
    expect(await mismatch.isReady()).toBe(false);
    expect(await mismatch.isReady()).toBe(false);
    expect(reads).toBe(1);

    let attempts = 0;
    const flaky = new ReadinessService(dbs.appDb, undefined, () => {
      attempts += 1;
      if (attempts === 1) throw new Error('journal unreadable');
      return bundled;
    });
    expect(await flaky.isReady()).toBe(false);
    expect(await flaky.isReady()).toBe(true);
    expect(attempts).toBe(2);
  });
});

describe('readiness says why it is not ready', () => {
  const dbs = createDbs();
  const bundled = readBundledMigrationHead();

  afterAll(async () => {
    await dbs.cleanup();
  });

  it('reports no reason when ready', async () => {
    expect(await new ReadinessService(dbs.appDb).check()).toEqual({ ready: true });
  });

  it('names a different release as release_mismatch', async () => {
    expect(await new ReadinessService(dbs.appDb, 'migration-0012').check())
      .toEqual({ ready: false, reason: 'release_mismatch' });
  });

  it('names a runtime connection with owner rights as runtime_role_unsafe', async () => {
    expect(await new ReadinessService(dbs.superDb as unknown as Db).check())
      .toEqual({ ready: false, reason: 'runtime_role_unsafe' });
  });

  it('names a database behind this image as migrations_behind', async () => {
    const removed = await dbs.superDb.execute<{ id: number; hash: string; created_at: string }>(sql`
      DELETE FROM drizzle.__drizzle_migrations
      WHERE id = (SELECT max(id) FROM drizzle.__drizzle_migrations)
      RETURNING id, hash, created_at
    `);
    try {
      expect(await new ReadinessService(dbs.appDb).check())
        .toEqual({ ready: false, reason: 'migrations_behind' });
    } finally {
      const row = removed[0]!;
      await dbs.superDb.execute(sql`
        INSERT INTO drizzle.__drizzle_migrations (id, hash, created_at)
        VALUES (${row.id}, ${row.hash}, ${row.created_at})
      `);
    }
  });

  it('names a database ahead of this image as migrations_incompatible', async () => {
    const inserted = await dbs.superDb.execute<{ id: number }>(sql`
      INSERT INTO drizzle.__drizzle_migrations (hash, created_at)
      VALUES ('later-release-hash', ${bundled.createdAt + 1})
      RETURNING id
    `);
    try {
      const service = new ReadinessService(dbs.appDb, undefined, () => ({ ...bundled, hash: 'edited-migration-hash' }));
      expect(await service.check()).toEqual({ ready: false, reason: 'migrations_incompatible' });
    } finally {
      await dbs.superDb.execute(sql`DELETE FROM drizzle.__drizzle_migrations WHERE id = ${inserted[0]!.id}`);
    }
  });

  it('names an unreadable bundled journal as migrations_unreadable, with a cause', async () => {
    const service = new ReadinessService(dbs.appDb, undefined, () => {
      throw Object.assign(new Error('read /app/dist/db/migrations/meta/_journal.json'), { code: 'ENOENT' });
    });
    const result = await service.check();
    expect(result).toMatchObject({ ready: false, reason: 'migrations_unreadable', cause: { causeCode: 'ENOENT' } });
    expect(JSON.stringify(result)).not.toContain('_journal.json');
  });

  it('names an unreachable database with the network cause and nothing else', async () => {
    const unreachable = {
      $client: {
        begin: async () => {
          throw Object.assign(new Error('connect ECONNREFUSED 10.20.30.40:5432 as canary-user'), { code: 'ECONNREFUSED' });
        },
      },
    } as unknown as Db;
    const result = await new ReadinessService(unreachable).check();
    expect(result).toMatchObject({
      ready: false,
      reason: 'database_unreachable',
      cause: { causeKind: 'network', causeCode: 'ECONNREFUSED' },
    });
    expect(JSON.stringify(result)).not.toContain('10.20.30.40');
    expect(JSON.stringify(result)).not.toContain('canary-user');
  });
});

describe('GET /api/v1/health/ready logs only when the answer changes', () => {
  const dbs = createDbs();
  let app: FastifyInstance;
  let down = true;
  const lines: Record<string, unknown>[] = [];

  beforeAll(async () => {
    // Delegates to the real database once `down` is switched off.
    const flaky = {
      $client: {
        begin: (work: unknown) => {
          if (down) {
            return Promise.reject(Object.assign(new Error('connect ECONNREFUSED 10.20.30.40:5432'), { code: 'ECONNREFUSED' }));
          }
          return (dbs.appDb.$client.begin as unknown as (w: unknown) => Promise<unknown>)(work);
        },
      },
    } as unknown as Db;
    app = Fastify({
      logger: {
        level: 'info',
        stream: { write: (line: string) => { lines.push(JSON.parse(line) as Record<string, unknown>); } },
      },
    });
    await app.register(healthRoutes, { db: flaky, config: {} as ApiConfig, prefix: '/api/v1' });
    await app.ready();
  });

  afterAll(async () => {
    await app.close();
    await dbs.cleanup();
  });

  const readinessLines = () => lines.filter((line) => typeof line['event'] === 'string'
    && (line['event'] as string).startsWith('readiness.'));

  it('logs one line per change and keeps the response body free of the reason', async () => {
    for (let probe = 0; probe < 3; probe += 1) {
      const res = await app.inject({ method: 'GET', url: '/api/v1/health/ready' });
      expect(res.statusCode).toBe(503);
      expect(JSON.parse(res.body)).toEqual({ status: 'not_ready' });
    }
    expect(readinessLines()).toHaveLength(1);
    expect(readinessLines()[0]).toMatchObject({
      event: 'readiness.not_ready',
      readinessReason: 'database_unreachable',
      causeKind: 'network',
      causeCode: 'ECONNREFUSED',
      msg: expect.stringMatching(/^Server is not ready: the database cannot be reached or did not answer the readiness query \(network error ECONNREFUSED( at src\/[\w./-]+:\d+)?\)$/),
    });
    expect(JSON.stringify(lines)).not.toContain('10.20.30.40');

    down = false;
    for (let probe = 0; probe < 2; probe += 1) {
      const res = await app.inject({ method: 'GET', url: '/api/v1/health/ready' });
      expect(res.statusCode).toBe(200);
      expect(JSON.parse(res.body)).toEqual({ status: 'ready' });
    }
    expect(readinessLines()).toHaveLength(2);
    expect(readinessLines()[1]).toMatchObject({ event: 'readiness.recovered', msg: 'Server is ready again' });
  });
});

describe('GET /api/v1/health', () => {
  let app: FastifyInstance;
  let cleanup: () => Promise<void>;

  beforeAll(async () => {
    const dbs = createDbs();
    cleanup = dbs.cleanup;
    app = await buildApp({
      db: dbs.appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey:  process.env['JWT_PUBLIC_KEY']!,
    });
  });

  afterAll(async () => {
    await app.close();
    await cleanup();
  });

  it('returns 200 with DB status, version, and uptime', async () => {
    const res = await app.inject({ method: 'GET', url: '/api/v1/health' });
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body);
    expect(body.status).toBe('ok');
    expect(body.version).toMatch(/^\d+\.\d+\.\d+/);
    expect(body.db.status).toBe('ok');
    expect(body.db.latencyMs).toBeGreaterThanOrEqual(0);
    expect(body.uptime).toBeGreaterThanOrEqual(0);
  });
});
