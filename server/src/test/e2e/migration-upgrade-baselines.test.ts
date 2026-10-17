import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PostgreSqlContainer, type StartedPostgreSqlContainer } from '@testcontainers/postgresql';
import { drizzle } from 'drizzle-orm/postgres-js';
import { migrate } from 'drizzle-orm/postgres-js/migrator';
import postgres, { type Sql } from 'postgres';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const sourceMigrations = resolve(dirname(fileURLToPath(import.meta.url)), '../../db/migrations');
const pinnedPostgresImage = process.env['TEST_POSTGRES_IMAGE']
  ?? 'docker.io/library/postgres:16.15-alpine3.24@sha256:3c5c8892d184f738f4fe282d14ddaa613a38f00f4189d2d94725ebe6f2909ddb';

/** Prior journal heads an installed server may be upgraded from. */
const baselines = [11, 12, 13, 14, 15, 16, 17, 22] as const;

type Journal = { entries: Array<{ tag: string; [key: string]: unknown }>; [key: string]: unknown };

async function readJournal(): Promise<Journal> {
  return JSON.parse(await readFile(join(sourceMigrations, 'meta', '_journal.json'), 'utf8')) as Journal;
}

/** A migrations folder whose journal stops at the given migration number. */
async function migrationsThrough(number: number): Promise<string> {
  const journal = await readJournal();
  const entries = journal.entries.filter((entry) => Number(entry.tag.slice(0, 4)) <= number);
  if (entries.at(-1)?.tag.slice(0, 4) !== String(number).padStart(4, '0')) {
    throw new Error(`journal has no migration ${number}`);
  }
  const directory = await mkdtemp(join(tmpdir(), `simpastil-${number}-migrations-`));
  await mkdir(join(directory, 'meta'));
  await writeFile(join(directory, 'meta', '_journal.json'), JSON.stringify({ ...journal, entries }, null, 2));
  for (const entry of entries) {
    await copyFile(join(sourceMigrations, `${entry.tag}.sql`), join(directory, `${entry.tag}.sql`));
  }
  return directory;
}

async function seed(sql: Sql): Promise<void> {
  const hasTimeZone = (await sql.unsafe<Array<{ n: number }>>(`
    SELECT count(*)::int AS n FROM information_schema.columns
    WHERE table_name = 'schedules' AND column_name = 'time_zone_status'`))[0]?.n === 1;
  const zone = hasTimeZone ? ", time_zone_status, time_zone" : '';
  const zoneValue = hasTimeZone ? ", 'known', 'UTC'" : '';
  await sql.begin(async (tx) => {
    await tx.unsafe(`
      INSERT INTO users (id, email, password_hash) VALUES
        ('10000000-0000-4000-8000-000000000001', 'fixture-a@example.invalid', 'fixture-hash-a'),
        ('10000000-0000-4000-8000-000000000002', 'fixture-b@example.invalid', 'fixture-hash-b')`);
    await tx.unsafe(`
      INSERT INTO refresh_tokens (id, user_id, token_hash, family_id, expires_at) VALUES
        ('60000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
         'fixture-token-hash-a', '70000000-0000-4000-8000-000000000001', '2099-01-01T00:00:00Z')`);
    for (const tenant of ['1', '2']) {
      // Later baselines guard legacy medication writes behind a tenant context.
      await tx.unsafe(`SELECT set_config('app.current_user_id', '10000000-0000-4000-8000-00000000000${tenant}', true)`);
      await tx.unsafe(`
        INSERT INTO profiles (id, user_id, name)
        VALUES ('20000000-0000-4000-8000-00000000000${tenant}', '10000000-0000-4000-8000-00000000000${tenant}', 'Fixture profile ${tenant}')`);
      await tx.unsafe(`
        INSERT INTO pills (id, profile_id, name, dosage, current_stock, is_prn)
        VALUES ('30000000-0000-4000-8000-00000000000${tenant}', '20000000-0000-4000-8000-00000000000${tenant}',
                'Fixture medication ${tenant}', '1 unit', ${tenant === '1' ? 12 : 4}, ${tenant === '2'})`);
      if (tenant === '1') {
        await tx.unsafe(`
          INSERT INTO schedules (id, pill_id, hour, minute, frequency, frequency_days, is_active${zone}) VALUES
            ('40000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001', 8, 0, 'daily', NULL, true${zoneValue}),
            ('40000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000001', 9, 30, 'custom', ARRAY[1, 3]::integer[], true${zoneValue})`);
        await tx.unsafe(`
          INSERT INTO dose_logs (id, schedule_id, scheduled_at, taken_at, status) VALUES
            ('50000000-0000-4000-8000-000000000001', '40000000-0000-4000-8000-000000000001', '2026-09-20T08:00:00Z', '2026-09-20T08:04:00Z', 'taken'),
            ('50000000-0000-4000-8000-000000000002', '40000000-0000-4000-8000-000000000001', '2026-09-21T08:00:00Z', NULL, 'skipped')`);
      }
    }
  });
}

type Snapshot = {
  users: number; profiles: number; pills: number; schedules: number; doseLogs: number; refreshTokens: number;
  stock: number[]; weeklyDays: number[]; doseStatuses: string[]; tokenHash: string | null;
};

async function snapshot(sql: Sql): Promise<Snapshot> {
  const [counts] = await sql.unsafe<Array<Omit<Snapshot, 'stock' | 'weeklyDays' | 'doseStatuses' | 'tokenHash'>>>(`
    SELECT (SELECT count(*)::int FROM users) AS users, (SELECT count(*)::int FROM profiles) AS profiles,
           (SELECT count(*)::int FROM pills) AS pills, (SELECT count(*)::int FROM schedules) AS schedules,
           (SELECT count(*)::int FROM dose_logs) AS "doseLogs",
           (SELECT count(*)::int FROM refresh_tokens) AS "refreshTokens"`);
  const stock = await sql.unsafe<Array<{ current_stock: number }>>(`SELECT current_stock FROM pills ORDER BY id`);
  const weekly = await sql.unsafe<Array<{ frequency_days: number[] }>>(
    `SELECT frequency_days FROM schedules WHERE id = '40000000-0000-4000-8000-000000000002'`);
  const statuses = await sql.unsafe<Array<{ status: string }>>(`SELECT status FROM dose_logs ORDER BY id`);
  const token = await sql.unsafe<Array<{ token_hash: string }>>(`SELECT token_hash FROM refresh_tokens`);
  return {
    ...counts!,
    stock: stock.map((row) => Number(row.current_stock)),
    weeklyDays: weekly[0]?.frequency_days ?? [],
    doseStatuses: statuses.map((row) => row.status),
    tokenHash: token[0]?.token_hash ?? null,
  };
}

/** 0011 fixture with two invalid schedules (empty weekly days, duplicate custom days) that the upgrade must quarantine. */
async function seedInvalidScheduleSchema(sql: Sql): Promise<void> {
  await sql.begin(async (tx) => {
    await tx.unsafe(`
      INSERT INTO users (id, email, password_hash) VALUES
        ('10000000-0000-4000-8000-000000000001', 'fixture-a@example.invalid', 'fixture-hash-a'),
        ('10000000-0000-4000-8000-000000000002', 'fixture-b@example.invalid', 'fixture-hash-b')
    `);
    await tx.unsafe(`
      INSERT INTO profiles (id, user_id, name) VALUES
        ('20000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'Fixture profile A'),
        ('20000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000002', 'Fixture profile B')
    `);
    await tx.unsafe(`
      INSERT INTO pills (id, profile_id, name, dosage, current_stock, is_prn) VALUES
        ('30000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000001', 'Fixture scheduled medication', '1 unit', 12, false),
        ('30000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000002', 'Fixture PRN medication', '1 unit', 4, true)
    `);
    await tx.unsafe(`
      INSERT INTO schedules (id, pill_id, hour, minute, frequency, frequency_days, is_active) VALUES
        ('40000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001', 8, 0, 'daily', NULL, true),
        ('40000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000001', 9, 0, 'weekly', ARRAY[]::integer[], true),
        ('40000000-0000-4000-8000-000000000003', '30000000-0000-4000-8000-000000000002', 10, 0, 'custom', ARRAY[1, 1]::integer[], true)
    `);
    await tx.unsafe(`
      INSERT INTO dose_logs (id, schedule_id, scheduled_at, taken_at, status) VALUES
        ('50000000-0000-4000-8000-000000000001', '40000000-0000-4000-8000-000000000001', '2026-09-20T08:00:00Z', '2026-09-20T08:04:00Z', 'taken'),
        ('50000000-0000-4000-8000-000000000002', '40000000-0000-4000-8000-000000000001', '2026-09-21T08:00:00Z', NULL, 'skipped')
    `);
  });
}

describe('server upgrade from each prior migration head', () => {
  let container: StartedPostgreSqlContainer;
  let admin: Sql;
  let headCount = 0;
  const directories: string[] = [];

  beforeAll(async () => {
    container = await new PostgreSqlContainer(pinnedPostgresImage).start();
    admin = postgres(container.getConnectionUri(), { max: 1, connect_timeout: 10 });
    headCount = (await readJournal()).entries.length;
  }, 120_000);

  afterAll(async () => {
    await admin?.end();
    await container?.stop();
    await Promise.all(directories.map((directory) => rm(directory, { recursive: true, force: true })));
  }, 120_000);

  it.each(baselines)('migrates 00%i-baseline data to head without loss', async (baseline) => {
    const database = `upgrade_from_${baseline}`;
    await admin.unsafe(`CREATE DATABASE ${database}`);
    const url = new URL(container.getConnectionUri());
    url.pathname = `/${database}`;
    const sql = postgres(url.toString(), { max: 1, connect_timeout: 10 });
    try {
      const folder = await migrationsThrough(baseline);
      directories.push(folder);
      await migrate(drizzle(sql), { migrationsFolder: folder });
      await seed(sql);
      const before = await snapshot(sql);

      await migrate(drizzle(sql), { migrationsFolder: sourceMigrations });
      const after = await snapshot(sql);
      expect(after).toEqual(before);
      expect(after).toMatchObject({ users: 2, profiles: 2, pills: 2, schedules: 2, doseLogs: 2, refreshTokens: 1 });

      const [journal] = await sql.unsafe<Array<{ count: number }>>(`SELECT count(*)::int AS count FROM drizzle.__drizzle_migrations`);
      expect(journal?.count).toBe(headCount);
      const [manifest] = await sql.unsafe<Array<{ schema_version: number }>>(
        `SELECT schema_version FROM public.deployment_manifest WHERE singleton_key IS TRUE`);
      expect(manifest?.schema_version).toBe(22);

      // A second run at head is a no-op.
      await migrate(drizzle(sql), { migrationsFolder: sourceMigrations });
      expect(await snapshot(sql)).toEqual(before);
    } finally {
      await sql.end();
    }
  }, 180_000);

  it('0023 widens the occurrence event checks to recorded misses and still rejects unknown values', async () => {
    const database = 'upgrade_from_22_recorded_miss';
    await admin.unsafe(`CREATE DATABASE ${database}`);
    const url = new URL(container.getConnectionUri());
    url.pathname = `/${database}`;
    const sql = postgres(url.toString(), { max: 1, connect_timeout: 10 });
    const checks = () => sql.unsafe<Array<{ name: string; definition: string }>>(`
      SELECT conname AS name, pg_get_constraintdef(oid) AS definition
      FROM pg_constraint
      WHERE conrelid = 'public.occurrence_events'::regclass
        AND conname IN ('occurrence_events_action_check', 'occurrence_events_from_state_check',
                        'occurrence_events_to_state_check')
      ORDER BY conname`);
    try {
      const folder = await migrationsThrough(22);
      directories.push(folder);
      await migrate(drizzle(sql), { migrationsFolder: folder });
      const before = await checks();
      expect(before).toHaveLength(3);
      expect(before.some((row) => row.definition.includes('miss'))).toBe(false);

      await migrate(drizzle(sql), { migrationsFolder: sourceMigrations });
      const after = await checks();
      expect(after.map((row) => row.name)).toEqual([
        'occurrence_events_action_check', 'occurrence_events_from_state_check', 'occurrence_events_to_state_check',
      ]);
      expect(after[0]?.definition).toMatch(/'miss'/);
      expect(after[1]?.definition).toMatch(/'missed'/);
      expect(after[2]?.definition).toMatch(/'missed'/);
      // The widening is exact: the previous values stay valid and nothing else is added.
      for (const row of after) {
        expect(row.definition).not.toMatch(/'foo'/);
      }
      expect(after[0]?.definition).toMatch(/'take'.*'skip'.*'undo'.*'correct'.*'miss'/s);
      expect(after[1]?.definition).toMatch(/'pending'.*'taken'.*'skipped'.*'missed'/s);
    } finally {
      await sql.end();
    }
  }, 180_000);

  it('0011 upgrade quarantines invalid schedules and records legacy bridge history exactly once', async () => {
    const database = 'upgrade_from_11_quarantine';
    await admin.unsafe(`CREATE DATABASE ${database}`);
    const url = new URL(container.getConnectionUri());
    url.pathname = `/${database}`;
    const sql = postgres(url.toString(), { max: 1, connect_timeout: 10 });
    const counts = () => sql.unsafe<Array<Record<string, number>>>(`
      SELECT (SELECT count(*)::int FROM users) AS users, (SELECT count(*)::int FROM profiles) AS profiles,
             (SELECT count(*)::int FROM pills) AS pills, (SELECT count(*)::int FROM schedules) AS schedules,
             (SELECT count(*)::int FROM dose_logs) AS dose_logs`);
    try {
      const folder = await migrationsThrough(11);
      directories.push(folder);
      await migrate(drizzle(sql), { migrationsFolder: folder });
      await seedInvalidScheduleSchema(sql);
      const [before] = await counts();
      expect(before).toEqual({ users: 2, profiles: 2, pills: 2, schedules: 3, dose_logs: 2 });

      await migrate(drizzle(sql), { migrationsFolder: sourceMigrations });
      const [after] = await counts();
      expect(after).toEqual(before);

      const [state] = await sql.unsafe<Array<Record<string, number | boolean>>>(`
        SELECT
          (SELECT count(*)::int FROM migration_issues WHERE entity_type = 'schedules' AND state = 'unresolved' AND revision = 1) AS "unresolvedScheduleIssues",
          (SELECT count(*)::int FROM legacy_medication_history
            WHERE legacy_source_kind = 'dose_log' AND provenance = 'legacy_estimated'
              AND coverage_state = 'covered') AS "legacyDoseHistory",
          (SELECT count(*)::int FROM sync_changes
            WHERE component = 'medicationBridge' AND entity_type = 'bridge_dose'
              AND source_kind = 'legacy_dose_log') AS "legacyBridgeDoseEvents",
          (SELECT count(*)::int FROM inventory_events WHERE kind = 'opening' AND provenance = 'legacy_backfill') AS "legacyOpeningEvents",
          (SELECT count(*)::int FROM schedules WHERE id IN (
            '40000000-0000-4000-8000-000000000002', '40000000-0000-4000-8000-000000000003'
          ) AND is_active = false) AS "quarantinedSchedules",
          (SELECT count(*)::int FROM pg_class WHERE relnamespace = 'public'::regnamespace
            AND relname = ANY(ARRAY['users', 'profiles', 'pills', 'schedules', 'dose_logs'])
            AND relforcerowsecurity) AS "forcedRlsTables",
          (SELECT count(*)::int FROM pg_roles WHERE rolname IN ('app_user', 'outbox_user')
            AND NOT rolsuper AND NOT rolbypassrls) AS "leastPrivilegeRoles",
          (SELECT enforced_minimum_client_build FROM deployment_manifest WHERE singleton_key IS TRUE) AS "enforcedBuild",
          (SELECT target_minimum_client_build FROM deployment_manifest WHERE singleton_key IS TRUE) AS "targetBuild",
          (SELECT ledger_activated FROM deployment_manifest WHERE singleton_key IS TRUE) AS "ledgerActivated"`);
      expect(Number(state!['unresolvedScheduleIssues'])).toBeGreaterThanOrEqual(2);
      expect(state).toMatchObject({
        quarantinedSchedules: 2, legacyDoseHistory: 2, legacyBridgeDoseEvents: 2, legacyOpeningEvents: 2,
        forcedRlsTables: 5, leastPrivilegeRoles: 2, enforcedBuild: 1, targetBuild: 2, ledgerActivated: false,
      });
    } finally {
      await sql.end();
    }
  }, 180_000);

  it('0018 fails closed with a duplicate refresh token hash instead of dropping data', async () => {
    const database = 'upgrade_from_17_duplicates';
    await admin.unsafe(`CREATE DATABASE ${database}`);
    const url = new URL(container.getConnectionUri());
    url.pathname = `/${database}`;
    const sql = postgres(url.toString(), { max: 1, connect_timeout: 10 });
    try {
      const folder = await migrationsThrough(17);
      directories.push(folder);
      await migrate(drizzle(sql), { migrationsFolder: folder });
      await seed(sql);
      // The 0017 index is non-unique, so duplicates can exist in the wild.
      await sql.unsafe(`DROP INDEX IF EXISTS refresh_tokens_token_hash_idx`);
      await sql.unsafe(`
        INSERT INTO refresh_tokens (user_id, token_hash, family_id, expires_at)
        VALUES ('10000000-0000-4000-8000-000000000001', 'fixture-token-hash-a',
                '70000000-0000-4000-8000-000000000002', '2099-01-01T00:00:00Z')`);
      await expect(migrate(drizzle(sql), { migrationsFolder: sourceMigrations })).rejects.toThrow();
      const [tokens] = await sql.unsafe<Array<{ count: number }>>(`SELECT count(*)::int AS count FROM refresh_tokens`);
      expect(tokens?.count).toBe(2);
      const [journal] = await sql.unsafe<Array<{ count: number }>>(`SELECT count(*)::int AS count FROM drizzle.__drizzle_migrations`);
      expect(journal?.count).toBe(18);
    } finally {
      await sql.end();
    }
  }, 180_000);
});
