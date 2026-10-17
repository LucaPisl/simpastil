import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { PostgreSqlContainer, StartedPostgreSqlContainer } from '@testcontainers/postgresql';
import postgres from 'postgres';
import { drizzle } from 'drizzle-orm/postgres-js';
import { migrate } from 'drizzle-orm/postgres-js/migrator';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const migrationsFolder = join(__dirname, '../../db/migrations');

describe('real migrator on empty database', () => {
  let container: StartedPostgreSqlContainer;
  let sql: ReturnType<typeof postgres>;

  beforeAll(async () => {
    const postgresImage = process.env['TEST_POSTGRES_IMAGE'] ?? 'postgres:16-alpine';
    container = await new PostgreSqlContainer(postgresImage).start();
    sql = postgres(container.getConnectionUri(), { max: 1 });
  }, 60_000);

  afterAll(async () => {
    await sql?.end();
    await container?.stop();
  });

  it('runs all migrations from empty without errors', async () => {
    const db = drizzle(sql);
    await migrate(db, { migrationsFolder });

    const tables = await sql`
      SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY 1
    `;
    const tableNames = tables.map((r) => r.tablename as string);

    expect(tableNames).toContain('users');
    expect(tableNames).toContain('profiles');
    expect(tableNames).toContain('pills');
    expect(tableNames).toContain('schedules');
    expect(tableNames).toContain('dose_logs');
    expect(tableNames).toContain('refresh_tokens');
    expect(tableNames).toContain('password_reset_tokens');
    expect(tableNames).toContain('api_keys');
    expect(tableNames).toContain('admin_config');
    expect(tableNames).toContain('admin_refresh_tokens');
    expect(tableNames).toContain('audit_logs');
  }, 30_000);

  it('creates app_user role', async () => {
    const roles = await sql`SELECT rolname FROM pg_roles WHERE rolname = 'app_user'`;
    expect(roles).toHaveLength(1);
  });

  it('enables FORCE ROW LEVEL SECURITY on user-data tables', async () => {
    const result = await sql`
      SELECT relname, relrowsecurity, relforcerowsecurity
      FROM pg_class
      WHERE relname IN ('users','profiles','pills','schedules','dose_logs','refresh_tokens','password_reset_tokens')
      ORDER BY relname
    `;
    for (const row of result) {
      expect(row.relrowsecurity).toBe(true);
      expect(row.relforcerowsecurity).toBe(true);
    }
  });

  it('installs RLS policies on all user-data tables', async () => {
    const policies = await sql`
      SELECT tablename, policyname FROM pg_policies
      WHERE schemaname = 'public'
      ORDER BY tablename, policyname
    `;
    const byTable = new Map<string, string[]>();
    for (const row of policies) {
      const t = row.tablename as string;
      if (!byTable.has(t)) byTable.set(t, []);
      byTable.get(t)!.push(row.policyname as string);
    }

    expect(byTable.get('users')?.length).toBeGreaterThanOrEqual(3);
    expect(byTable.get('profiles')?.length).toBeGreaterThanOrEqual(1);
    expect(byTable.get('pills')?.length).toBeGreaterThanOrEqual(1);
    expect(byTable.get('schedules')?.length).toBeGreaterThanOrEqual(1);
    expect(byTable.get('dose_logs')?.length).toBeGreaterThanOrEqual(1);
    expect(byTable.get('refresh_tokens')?.length).toBeGreaterThanOrEqual(3);
    expect(byTable.get('password_reset_tokens')?.length).toBeGreaterThanOrEqual(2);
  });

  it('creates FK indexes for RLS hot paths', async () => {
    const indexes = await sql`
      SELECT indexname FROM pg_indexes
      WHERE schemaname = 'public'
        AND indexname IN ('profiles_user_id_idx', 'pills_profile_id_idx', 'schedules_pill_id_idx', 'prt_token_hash_idx')
    `;
    expect(indexes).toHaveLength(4);
  });

  it('is idempotent (re-run succeeds)', async () => {
    const db = drizzle(sql);
    await expect(migrate(db, { migrationsFolder })).resolves.toBeUndefined();
  });
});
