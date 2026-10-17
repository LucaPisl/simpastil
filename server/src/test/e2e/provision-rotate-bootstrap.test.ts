import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { PostgreSqlContainer, type StartedPostgreSqlContainer } from '@testcontainers/postgresql';
import postgres, { type Sql } from 'postgres';
import { drizzle } from 'drizzle-orm/postgres-js';
import { migrate } from 'drizzle-orm/postgres-js/migrator';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { runProvisionCommand } from '../../db/provision.js';

const migrationsFolder = join(dirname(fileURLToPath(import.meta.url)), '../../db/migrations');

/**
 * Runs the real `provision.ts rotate-bootstrap` command path as the superuser
 * (DATABASE_URL_SUPER), exactly as the Compose migration service does, so the
 * deployment_authority_owner role switch inside rotateBootstrap is exercised.
 */
describe('provision rotate-bootstrap command', () => {
  let container: StartedPostgreSqlContainer;
  let sql: Sql;

  beforeAll(async () => {
    container = await new PostgreSqlContainer(process.env['TEST_POSTGRES_IMAGE'] ??
      'docker.io/library/postgres:16.15-alpine3.24@sha256:3c5c8892d184f738f4fe282d14ddaa613a38f00f4189d2d94725ebe6f2909ddb').start();
    sql = postgres(container.getConnectionUri(), { max: 2 });
    vi.stubEnv('DATABASE_URL_SUPER', container.getConnectionUri());
    vi.stubEnv('APP_USER_PASSWORD', 'a'.repeat(40));
    vi.stubEnv('OUTBOX_USER_PASSWORD', 'b'.repeat(40));
    vi.spyOn(console, 'log').mockImplementation(() => undefined);
    // Same order as the Compose stack: roles, schema migrations, role grants.
    await runProvisionCommand('provision');
    await migrate(drizzle(sql), { migrationsFolder });
    await runProvisionCommand('provision');
  }, 180_000);

  afterAll(async () => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
    await sql?.end();
    await container?.stop();
  });

  it('rotates the first-admin proof as the superuser without weakening the table guard', async () => {
    const write = vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
    let printed: string;
    try {
      await runProvisionCommand('rotate-bootstrap');
      printed = write.mock.calls.map((call) => String(call[0])).join('');
    } finally {
      write.mockRestore();
    }
    const output = JSON.parse(printed.trim()) as { proof: string; generation: string; expiresAt: string };

    expect(output.proof).toMatch(/^[0-9a-f]{64}$/);
    const [state] = await sql.unsafe<{ token_hash: string; generation: string; consumed_at: Date | null }[]>(
      'SELECT token_hash, generation::text, consumed_at FROM admin_bootstrap_state',
    );
    expect(state?.token_hash).toBe(createHash('sha256').update(output.proof).digest('hex'));
    expect(state?.generation).toBe(output.generation);
    expect(state?.consumed_at).toBeNull();

    // The guard trigger is untouched: even a superuser cannot rewrite the state
    // directly outside the deployment authority role.
    await expect(sql.unsafe('UPDATE admin_bootstrap_state SET generation = generation + 1'))
      .rejects.toThrow();
  }, 60_000);
});
