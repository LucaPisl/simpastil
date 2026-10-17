import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PostgreSqlContainer, type StartedPostgreSqlContainer } from '@testcontainers/postgresql';
import postgres, { type Sql } from 'postgres';
import { readMigrationFiles } from 'drizzle-orm/migrator';
import { drizzle } from 'drizzle-orm/postgres-js';
import { migrate } from 'drizzle-orm/postgres-js/migrator';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const migrationsFolder = join(__dirname, '../../db/migrations');
const through0012 = [
  '0000_initial.sql',
  '0001_sturdy_thena.sql',
  '0002_prt_rls.sql',
  '0003_petite_proemial_gods.sql',
  '0004_pill_inventory.sql',
  '0005_logging_extensions.sql',
  '0006_server_hardening.sql',
  '0007_rls_enforcement.sql',
  '0008_sync_hardening.sql',
  '0009_api_key_encrypted_storage.sql',
  '0010_rls_nullif_backup_codes.sql',
  '0011_delta_sync_tombstones.sql',
  '0012_auth_recovery_operations.sql',
] as const;

type ScheduleState = {
  id: string;
  frequency: string;
  frequency_days: number[] | null;
  is_active: boolean;
  time_zone_status: string;
  time_zone: string | null;
  timezone_review_issue_id: string | null;
  legacy_quarantine_issue_id: string | null;
  legacy_quarantine_origin: string | null;
  legacy_quarantine_source: Record<string, unknown> | null;
};

type MigrationIssue = {
  id: string;
  safe_snapshot: Record<string, unknown>;
};

async function seedThrough0012(sql: Sql): Promise<void> {
  for (const migration of through0012) {
    await sql.unsafe(readFileSync(join(migrationsFolder, migration), 'utf8'));
  }

  const priorMigrations = readMigrationFiles({ migrationsFolder }).slice(0, through0012.length);
  await sql.unsafe('CREATE SCHEMA IF NOT EXISTS drizzle');
  await sql.unsafe(
    'CREATE TABLE IF NOT EXISTS drizzle.__drizzle_migrations (' +
      'id SERIAL PRIMARY KEY, hash TEXT NOT NULL, created_at BIGINT)',
  );
  for (const migration of priorMigrations) {
    await sql.unsafe(
      'INSERT INTO drizzle.__drizzle_migrations (hash, created_at) VALUES ($1, $2)',
      [migration.hash, migration.folderMillis],
    );
  }
}

async function insertSchedule(
  sql: Sql,
  pillId: string,
  frequency: string,
  frequencyDays: number[],
): Promise<string> {
  const rows = await sql.unsafe<{ id: string }[]>(
    'INSERT INTO public.schedules (pill_id, hour, minute, frequency, frequency_days) ' +
      'VALUES ($1, 8, 0, $2, $3) RETURNING id',
    [pillId, frequency, frequencyDays],
  );
  const id = rows[0]?.id;
  if (!id) throw new Error('schedule fixture was not created');
  return id;
}

describe('migration 0013 replaces a legacy schedule frequency constraint', () => {
  let container: StartedPostgreSqlContainer;
  let admin: Sql;

  beforeAll(async () => {
    container = await new PostgreSqlContainer(
      process.env['TEST_POSTGRES_IMAGE'] ?? 'postgres:16-alpine',
    ).start();
    admin = postgres(container.getConnectionUri(), { max: 2 });
  }, 120_000);

  afterAll(async () => {
    await admin?.end();
    await container?.stop();
  });

  async function migrateScenario(suffix: string, withLegacyConstraint: boolean): Promise<void> {
    const databaseName = 'migration_0013_' + suffix;
    await admin.unsafe('CREATE DATABASE "' + databaseName + '"');
    let sql: Sql | undefined;
    try {
      const url = new URL(container.getConnectionUri());
      url.pathname = '/' + databaseName;
      sql = postgres(url.toString(), { max: 4 });
      await seedThrough0012(sql);

      const users = await sql.unsafe<{ id: string }[]>(
        "INSERT INTO public.users (email, password_hash) VALUES ('migration-0013@example.invalid', 'unused') RETURNING id",
      );
      const userId = users[0]?.id;
      if (!userId) throw new Error('user fixture was not created');
      const profiles = await sql.unsafe<{ id: string }[]>(
        "INSERT INTO public.profiles (user_id, name) VALUES ($1, 'Migration fixture') RETURNING id",
        [userId],
      );
      const profileId = profiles[0]?.id;
      if (!profileId) throw new Error('profile fixture was not created');
      const pills = await sql.unsafe<{ id: string }[]>(
        "INSERT INTO public.pills (profile_id, name) VALUES ($1, 'Fixture medication') RETURNING id",
        [profileId],
      );
      const pillId = pills[0]?.id;
      if (!pillId) throw new Error('pill fixture was not created');

      const ids = {
        dailyWithExtraDays: await insertSchedule(sql, pillId, 'daily', [1, 2]),
        validWeekly: await insertSchedule(sql, pillId, 'weekly', [3]),
        invalidWeekly: await insertSchedule(sql, pillId, 'weekly', [8]),
        duplicateCustom: await insertSchedule(sql, pillId, 'custom', [2, 2]),
      };

      const legacyBefore = await sql.unsafe<{ count: string }[]>(
        "SELECT count(*)::text AS count FROM pg_constraint WHERE conrelid = 'public.schedules'::regclass AND conname = $1",
        ['schedules_frequency_days_check'],
      );
      expect(legacyBefore[0]?.count).toBe('0');

      if (withLegacyConstraint) {
        await sql.unsafe(
          "ALTER TABLE public.schedules ADD CONSTRAINT schedules_frequency_days_check " +
            "CHECK ((frequency = 'daily') OR " +
            "(frequency = 'weekly' AND array_length(frequency_days, 1) = 1) OR " +
            "(frequency = 'custom' AND array_length(frequency_days, 1) >= 1))",
        );
      }

      await migrate(drizzle(sql), { migrationsFolder });

      const constraints = await sql.unsafe<{ definition: string; convalidated: boolean }[]>(
        "SELECT pg_get_constraintdef(oid) AS definition, convalidated FROM pg_constraint " +
          "WHERE conrelid = 'public.schedules'::regclass AND conname = 'schedules_frequency_days_check'",
      );
      expect(constraints).toHaveLength(1);
      expect(constraints[0]?.definition).toContain('schedule_frequency_days_valid');
      expect(constraints[0]?.convalidated).toBe(true);

      const rows = await sql.unsafe<ScheduleState[]>(
        'SELECT id, frequency, frequency_days, is_active, time_zone_status, time_zone, ' +
          'timezone_review_issue_id, legacy_quarantine_issue_id, legacy_quarantine_origin, ' +
          'legacy_quarantine_source FROM public.schedules ORDER BY id',
      );
      expect(rows).toHaveLength(4);
      expect(rows.map((row) => row.id).sort()).toEqual(Object.values(ids).sort());
      const byId = new Map(rows.map((row) => [row.id, row]));
      const daily = byId.get(ids.dailyWithExtraDays)!;
      const validWeekly = byId.get(ids.validWeekly)!;
      const invalidWeekly = byId.get(ids.invalidWeekly)!;
      const duplicateCustom = byId.get(ids.duplicateCustom)!;

      expect(daily.frequency_days).toBeNull();
      expect(daily.is_active).toBe(true);
      expect(validWeekly.frequency_days).toEqual([3]);
      expect(validWeekly.is_active).toBe(true);
      expect(validWeekly.legacy_quarantine_issue_id).toBeNull();

      for (const row of rows) {
        expect(row.time_zone_status).toBe('legacy_unknown');
        expect(row.time_zone).toBeNull();
        expect(row.timezone_review_issue_id).toBeTruthy();
      }

      expect(invalidWeekly.frequency_days).toEqual([8]);
      expect(invalidWeekly.is_active).toBe(false);
      expect(invalidWeekly.legacy_quarantine_origin).toBe('migration-0013');
      expect(invalidWeekly.legacy_quarantine_source).toMatchObject({
        scheduleId: ids.invalidWeekly,
        sourceScheduleRevision: '1',
        frequency: 'weekly',
        frequencyDays: [8],
        isActive: true,
        timeZoneStatus: 'legacy_unknown',
        timeZone: null,
      });
      expect(duplicateCustom.frequency_days).toEqual([2, 2]);
      expect(duplicateCustom.is_active).toBe(false);
      expect(duplicateCustom.legacy_quarantine_origin).toBe('migration-0013');
      expect(duplicateCustom.legacy_quarantine_source).toMatchObject({
        frequency: 'custom',
        frequencyDays: [2, 2],
        isActive: true,
      });

      const timezoneIssues = await sql.unsafe<MigrationIssue[]>(
        "SELECT id, safe_snapshot FROM public.migration_issues " +
          "WHERE entity_id = $1 AND issue_code = 'schedule_timezone_review_required'",
        [ids.dailyWithExtraDays],
      );
      expect(timezoneIssues).toHaveLength(1);
      expect(timezoneIssues[0]?.id).toBe(daily.timezone_review_issue_id);
      expect(timezoneIssues[0]?.safe_snapshot).toMatchObject({
        frequency: 'daily',
        frequencyDays: [1, 2],
        isActive: true,
        timeZoneStatus: 'legacy_unknown',
        timeZone: null,
      });

      const invalidIssues = await sql.unsafe<MigrationIssue[]>(
        "SELECT id, safe_snapshot FROM public.migration_issues " +
          "WHERE entity_id = $1 AND issue_code = 'invalid_schedule_frequency_days'",
        [ids.invalidWeekly],
      );
      expect(invalidIssues).toHaveLength(1);
      expect(invalidIssues[0]?.safe_snapshot).toMatchObject({
        frequency: 'weekly',
        frequencyDays: [8],
        isActive: true,
      });

      await expect(
        sql.unsafe(
          'UPDATE public.schedules SET legacy_quarantine_issue_id = NULL, ' +
            'legacy_quarantine_origin = NULL, legacy_quarantine_source = NULL, is_active = TRUE WHERE id = $1',
          [ids.invalidWeekly],
        ),
      ).rejects.toThrow('schedules_frequency_days_check');

      const migrationCount = readMigrationFiles({ migrationsFolder }).length;
      const journalBefore = await sql.unsafe<{ count: string }[]>(
        'SELECT count(*)::text AS count FROM drizzle.__drizzle_migrations',
      );
      expect(Number(journalBefore[0]?.count)).toBe(migrationCount);
      await migrate(drizzle(sql), { migrationsFolder });
      const journalAfter = await sql.unsafe<{ count: string }[]>(
        'SELECT count(*)::text AS count FROM drizzle.__drizzle_migrations',
      );
      expect(journalAfter[0]?.count).toBe(journalBefore[0]?.count);
    } finally {
      await sql?.end();
      await admin.unsafe('DROP DATABASE "' + databaseName + '"');
    }
  }

  it('preserves and quarantines legacy schedules when the old check exists', async () => {
    await migrateScenario('legacy', true);
  }, 120_000);

  it('applies the same schedule invariants to a fresh pre-0013 schema', async () => {
    await migrateScenario('fresh', false);
  }, 120_000);
});
