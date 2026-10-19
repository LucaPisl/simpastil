import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PostgreSqlContainer, type StartedPostgreSqlContainer } from '@testcontainers/postgresql';
import postgres, { type Sql } from 'postgres';
import { readMigrationFiles } from 'drizzle-orm/migrator';
import { drizzle } from 'drizzle-orm/postgres-js';
import { migrate } from 'drizzle-orm/postgres-js/migrator';
import { createHash, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { canonicalJson, SyncChangePayloadV2Schema } from '../../modules/sync/sync-payload.js';

const migrationsFolder = join(dirname(fileURLToPath(import.meta.url)), '../../db/migrations');
const scheduledAt = '2026-01-01T08:00:00.000Z';
const takenAt = '2026-01-01T08:05:00.000Z';
const deletedAt = '2026-01-02T09:00:00.000Z';

type History = {
  history_entry_id: string;
  history_id: string;
  legacy_source_kind: string;
  legacy_source_id: string;
  operation: string;
  source_revision: string;
  source_snapshot: Record<string, unknown>;
  source_fingerprint: string;
  coverage_state: string;
  migration_inventory_effect: string;
  provenance: string;
  sync_change_id: string;
};

type Fixture = { sql: Sql; userId: string; activeId: string; deletedId: string; scheduleId: string; pillId: string };

describe('migration 0015 preserves immutable legacy history sync identities', () => {
  let container: StartedPostgreSqlContainer;
  let admin: Sql;

  beforeAll(async () => {
    container = await new PostgreSqlContainer(process.env['TEST_POSTGRES_IMAGE'] ??
      'docker.io/library/postgres:16.15-alpine3.24@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea').start();
    admin = postgres(container.getConnectionUri(), { max: 2 });
  }, 120_000);

  afterAll(async () => {
    await admin?.end();
    await container?.stop();
  });

  async function withFixture(check: (fixture: Fixture, before: unknown[]) => Promise<void>): Promise<void> {
    const database = 'migration_history_' + randomUUID().replaceAll('-', '');
    await admin.unsafe('CREATE DATABASE "' + database + '"');
    let sql: Sql | undefined;
    try {
      const uri = new URL(container.getConnectionUri());
      uri.pathname = '/' + database;
      sql = postgres(uri.toString(), { max: 2 });
      const migrations = readMigrationFiles({ migrationsFolder });
      // Reproduce the legacy upgrade boundary using the real historical SQL.
      for (const migration of migrations.slice(0, 13)) {
        for (const statement of migration.sql) await sql.unsafe(statement);
      }
      await sql.unsafe('CREATE SCHEMA drizzle');
      await sql.unsafe('CREATE TABLE drizzle.__drizzle_migrations (id serial PRIMARY KEY, hash text NOT NULL, created_at bigint)');
      for (const migration of migrations.slice(0, 13)) {
        await sql.unsafe('INSERT INTO drizzle.__drizzle_migrations (hash,created_at) VALUES ($1,$2)',
          [migration.hash, migration.folderMillis]);
      }
      const userId = randomUUID();
      const pillId = randomUUID();
      const profileId = randomUUID();
      const scheduleId = randomUUID();
      const activeId = randomUUID();
      const deletedId = randomUUID();
      await sql.unsafe("INSERT INTO users (id,email,password_hash) VALUES ($1,'history-fixture@example.invalid','unused')", [userId]);
      await sql.unsafe("INSERT INTO profiles (id,user_id,name) VALUES ($1,$2,'Synthetic profile')", [profileId, userId]);
      await sql.unsafe("INSERT INTO pills (id,profile_id,name,current_stock) VALUES ($1,$2,'Synthetic medication',4)", [pillId, profileId]);
      await sql.unsafe("INSERT INTO schedules (id,pill_id,hour,minute,frequency) VALUES ($1,$2,8,0,'daily')", [scheduleId, pillId]);
      await sql.unsafe(
        "INSERT INTO dose_logs (id,schedule_id,scheduled_at,taken_at,status,deleted_at) VALUES " +
        "($1,$3,$4,$5,'taken',NULL),($2,$3,$4,$5,'taken',$6)",
        [activeId, deletedId, scheduleId, scheduledAt, takenAt, deletedAt],
      );
      const before = await sql.unsafe('SELECT to_jsonb(d) AS data FROM dose_logs d ORDER BY id');
      // This must succeed through the actual journal-backed production mechanism.
      await migrate(drizzle(sql), { migrationsFolder });
      await check({ sql, userId, activeId, deletedId, scheduleId, pillId }, before);
    } finally {
      await sql?.end();
      await admin.unsafe('DROP DATABASE "' + database + '"');
    }
  }

  it('covers active and deleted legacy doses without changing source evidence or sync semantics', async () => {
    await withFixture(async ({ sql, activeId, deletedId, scheduleId, pillId }, before) => {
      expect(await sql.unsafe('SELECT to_jsonb(d) AS data FROM dose_logs d ORDER BY id')).toEqual(before);
      const histories = await sql.unsafe<History[]>(
        'SELECT * FROM legacy_medication_history ORDER BY legacy_source_kind,legacy_source_id',
      );
      expect(histories).toHaveLength(3); // Two dose entries and one stock snapshot.
      for (const [id, operation, deletion] of [
        [activeId, 'upsert', null], [deletedId, 'tombstone', deletedAt],
      ] as const) {
        const history = histories.find((row) => row.legacy_source_id === id)!;
        const expectedSnapshot = { id, scheduleId, scheduledAt, takenAt, status: 'taken', deletedAt: deletion };
        expect(history.operation).toBe(operation);
        expect(history.source_snapshot).toEqual(expectedSnapshot);
        expect(history.source_fingerprint).toBe(createHash('sha256').update(canonicalJson(expectedSnapshot)).digest('hex'));
      }
      for (const history of histories) {
        expect(history.coverage_state).toBe('covered');
        expect(history.migration_inventory_effect).toBe('none');
        expect(history.provenance).toBe('legacy_estimated');
        const [change] = await sql.unsafe<{ payload: Record<string, unknown> }[]>(
          'SELECT payload FROM sync_changes WHERE id=$1', [history.sync_change_id],
        );
        const envelope = SyncChangePayloadV2Schema.parse(change!.payload);
        expect(envelope.operation).toBe('upsert');
        expect(envelope.entityType).toBe('legacy_medication_history');
        expect(envelope.entityId).toBe(history.history_id);
        expect(envelope.sourceIdentity).toEqual({
          sourceKind: 'legacy_history_entry', sourceId: history.history_entry_id, sourceRevision: '1',
        });
        expect(envelope.payload).toMatchObject({
          kind: 'legacyEstimatedHistory', operation: history.operation,
          historyId: history.history_id, historyEntryId: history.history_entry_id,
          sourceFingerprint: history.source_fingerprint,
        });
      }
      expect(histories.find((row) => row.legacy_source_id === pillId)?.operation).toBe('upsert');
      expect(await sql.unsafe('SELECT current_stock FROM pills WHERE id=$1', [pillId])).toEqual([{ current_stock: 4 }]);
      const journal = await sql.unsafe('SELECT * FROM drizzle.__drizzle_migrations ORDER BY id');
      expect(journal).toHaveLength(readMigrationFiles({ migrationsFolder }).length);
      await migrate(drizzle(sql), { migrationsFolder });
      expect(await sql.unsafe('SELECT * FROM drizzle.__drizzle_migrations ORDER BY id')).toEqual(journal);
      expect(await sql.unsafe('SELECT count(*)::int AS count FROM legacy_medication_history')).toEqual([{ count: 3 }]);
    });
  }, 120_000);

  it.each(['inner operation', 'tenant', 'source identity'] as const)(
    'rejects a covered history reference with mismatched %s', async (mismatch) => {
      await withFixture(async ({ sql, userId, activeId }) => {
        const [original] = await sql.unsafe<History[]>('SELECT * FROM legacy_medication_history WHERE legacy_source_id=$1', [activeId]);
        const [change] = await sql.unsafe<{ payload: { payload: Record<string, unknown> } }[]>(
          'SELECT payload FROM sync_changes WHERE id=$1', [original!.sync_change_id],
        );
        const entryId = randomUUID();
        const foreignUserId = randomUUID();
        if (mismatch === 'tenant') {
          await sql.unsafe("INSERT INTO users (id,email,password_hash) VALUES ($1,'other-history@example.invalid','unused')", [foreignUserId]);
        }
        await expect(sql.begin(async (transaction) => {
          await transaction.unsafe("SELECT set_config('app.current_user_id',$1,true)", [userId]);
          await transaction.unsafe(
            'INSERT INTO legacy_medication_history SELECT (jsonb_populate_record(NULL::legacy_medication_history, ' +
            'to_jsonb(h) || jsonb_build_object(\'history_entry_id\',$2::text,\'source_revision\',2,' +
            '\'coverage_state\',\'pending\',\'sync_change_id\',NULL,\'mapped_entity_type\',NULL,' +
            '\'mapped_entity_id\',NULL,\'mapped_at\',NULL))).* FROM legacy_medication_history h WHERE history_entry_id=$1',
            [original!.history_entry_id, entryId],
          );
          const syncUser = mismatch === 'tenant' ? foreignUserId : userId;
          const sourceId = mismatch === 'source identity' ? randomUUID() : entryId;
          const payload = { ...change!.payload.payload, historyEntryId: sourceId, sourceRevision: '2',
            operation: mismatch === 'inner operation' ? 'tombstone' : 'upsert' };
          await transaction.unsafe("SELECT set_config('app.current_user_id',$1,true)", [syncUser]);
          const [seed] = await transaction.unsafe<{ sequence: string }[]>(
            "SELECT simpastil_seed_sync_change($1,'medicationBridge','legacy_medication_history',$2," +
            "'upsert','legacy_history_entry',$3,2,$4::jsonb)::text AS sequence",
            [syncUser, original!.history_id, sourceId, JSON.stringify(payload)],
          );
          await transaction.unsafe("SELECT set_config('app.current_user_id',$1,true)", [userId]);
          await transaction.unsafe(
            "UPDATE legacy_medication_history SET coverage_state='covered',sync_change_id=" +
            '(SELECT id FROM sync_changes WHERE user_id=$2 AND server_sequence=$3),' +
            "mapped_entity_type='legacy_medication_history',mapped_entity_id=history_id,mapped_at=now() " +
            'WHERE history_entry_id=$1', [entryId, syncUser, seed!.sequence],
          );
        })).rejects.toMatchObject({ code: '23503', message: 'legacy history sync reference does not match its immutable source identity' });
      });
    }, 120_000,
  );
});
