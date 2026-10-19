import { randomUUID } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PostgreSqlContainer, type StartedPostgreSqlContainer } from '@testcontainers/postgresql';
import { drizzle } from 'drizzle-orm/postgres-js';
import { migrate } from 'drizzle-orm/postgres-js/migrator';
import Fastify from 'fastify';
import postgres, { type Sql } from 'postgres';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import type { Db } from '../../db/client.js';
import * as schema from '../../db/schema.js';
import { runProvisionCommand } from '../../db/provision.js';
import capabilitiesRoutes from '../../modules/capabilities/capabilities.routes.js';
import { MedicationCommandService } from '../../modules/medication/medication-command.service.js';
import { BridgePrnCommandService } from '../../modules/medication/bridge-prn-command.service.js';
import { PillsService } from '../../modules/pills/pills.service.js';
import { SchedulesService } from '../../modules/schedules/schedules.service.js';

const migrationsFolder = join(dirname(fileURLToPath(import.meta.url)), '../../db/migrations');

/**
 * Runs the real `provision.ts activate-ledger` command path as the superuser
 * (DATABASE_URL_SUPER), the way the Compose migration service does, against a
 * disposable database seeded with realistic legacy data.
 */
describe('provision activate-ledger command', () => {
  let container: StartedPostgreSqlContainer;
  let sql: Sql;
  let appSql: Sql;
  const userId = randomUUID();

  async function seedTenant(run: (tx: Sql) => Promise<void>): Promise<void> {
    await sql.begin(async (tx) => {
      await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
      await run(tx as unknown as Sql);
    });
  }

  beforeAll(async () => {
    container = await new PostgreSqlContainer(process.env['TEST_POSTGRES_IMAGE'] ??
      'docker.io/library/postgres:16.15-alpine3.24@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea').start();
    sql = postgres(container.getConnectionUri(), { max: 2 });
    vi.stubEnv('DATABASE_URL_SUPER', container.getConnectionUri());
    vi.stubEnv('APP_USER_PASSWORD', 'a'.repeat(40));
    vi.stubEnv('OUTBOX_USER_PASSWORD', 'b'.repeat(40));
    vi.spyOn(console, 'log').mockImplementation(() => undefined);
    await runProvisionCommand('provision');
    await migrate(drizzle(sql), { migrationsFolder });
    await runProvisionCommand('provision');

    const appUrl = new URL(container.getConnectionUri());
    appUrl.username = 'app_user';
    appUrl.password = 'a'.repeat(40);
    appSql = postgres(appUrl.toString(), { max: 2 });

    // A fresh deployment at head: a legacy dataset written through the legacy
    // tables (the journal triggers capture each write).
    const profileId = randomUUID();
    const tracked = randomUUID();
    const untracked = randomUUID();
    const prnPill = randomUUID();
    const dailySchedule = randomUUID();
    const weeklySchedule = randomUUID();
    const untrackedSchedule = randomUUID();
    await sql.unsafe('INSERT INTO users (id, email, password_hash) VALUES ($1, $2, $3)',
      [userId, `${userId}@ledger.invalid`, 'unused-test-hash']);
    await seedTenant(async (tx) => {
      await tx.unsafe('INSERT INTO profiles (id, user_id, name) VALUES ($1, $2, $3)', [profileId, userId, 'Owner']);
      await tx.unsafe('INSERT INTO pills (id, profile_id, name, dosage, current_stock) VALUES ($1, $2, $3, $4, $5)',
        [tracked, profileId, 'Tracked medicine', '5 mg', 12]);
      await tx.unsafe('INSERT INTO pills (id, profile_id, name, current_stock) VALUES ($1, $2, $3, NULL)',
        [untracked, profileId, 'Untracked medicine']);
      await tx.unsafe('INSERT INTO pills (id, profile_id, name, current_stock) VALUES ($1, $2, $3, 3)',
        [prnPill, profileId, 'As needed']);
      for (const [id, pill, hour, freq, days] of [
        [dailySchedule, tracked, 8, 'daily', null],
        [weeklySchedule, tracked, 20, 'weekly', '{3}'],
        [randomUUID(), untracked, 21, 'custom', '{1,3,5}'],
        [untrackedSchedule, untracked, 9, 'daily', null],
      ] as const) {
        await tx.unsafe(
          `INSERT INTO schedules (id, pill_id, hour, minute, frequency, frequency_days, is_active, time_zone_status, time_zone)
           VALUES ($1, $2, $3, 0, $4, $5, true, 'known', 'Europe/Bucharest')`,
          [id, pill, hour, freq, days],
        );
      }
      const dose = (schedule: string, at: string, status: string, taken: string | null) =>
        tx.unsafe(
          `INSERT INTO dose_logs (id, schedule_id, scheduled_at, taken_at, status, updated_at)
           VALUES ($1, $2, $3, $4, $5, $6)`,
          [randomUUID(), schedule, at, taken, status, at],
        );
      await dose(dailySchedule, '2026-10-01T05:00:00.000Z', 'taken', '2026-10-01T05:02:11.250Z');
      await dose(dailySchedule, '2026-10-02T05:00:00.000Z', 'skipped', null);
      await dose(untrackedSchedule, '2026-10-02T06:00:00.000Z', 'taken', '2026-10-02T06:10:00.000Z');
      // Undone: a taken dose that was then soft deleted.
      const undone = randomUUID();
      await tx.unsafe(
        `INSERT INTO dose_logs (id, schedule_id, scheduled_at, taken_at, status, updated_at)
         VALUES ($1, $2, '2026-10-03T05:00:00.000Z', '2026-10-03T05:01:00.000Z', 'taken', '2026-10-03T05:01:00.000Z')`,
        [undone, dailySchedule]);
      await tx.unsafe('UPDATE dose_logs SET deleted_at = now(), updated_at = now() WHERE id = $1', [undone]);
    });
  }, 240_000);

  afterAll(async () => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
    await appSql?.end();
    await sql?.end();
    await container?.stop();
  });

  async function activate(): Promise<void> {
    vi.stubEnv('LEDGER_CURRENT_BUILD', '2');
    vi.stubEnv('LEDGER_CHANGE_REFERENCE', 'e2e-activation');
    await runProvisionCommand('activate-ledger');
  }

  it('starts with a real, journaled legacy dataset and an inactive ledger', async () => {
    const [journal] = await sql.unsafe<{ count: number }[]>(
      "SELECT count(*)::int AS count FROM medication_handoff_journal WHERE coverage_state <> 'covered'");
    expect(journal?.count).toBeGreaterThan(0);
    const [manifest] = await sql.unsafe<{ ledger_activated: boolean }[]>(
      'SELECT ledger_activated FROM deployment_manifest WHERE singleton_key IS TRUE');
    expect(manifest?.ledger_activated).toBe(false);
  });

  it('activates, stores JSON objects, reports the capability, and refuses a second run', async () => {
    await activate();

    const [manifest] = await sql.unsafe<{ ledger_activated: boolean }[]>(
      'SELECT ledger_activated FROM deployment_manifest WHERE singleton_key IS TRUE');
    expect(manifest?.ledger_activated).toBe(true);

    const snapshots = await sql.unsafe<{ type: string; coverage_state: string }[]>(
      'SELECT jsonb_typeof(source_snapshot) AS type, coverage_state FROM legacy_medication_history');
    expect(snapshots.length).toBeGreaterThan(0);
    expect(snapshots.every((row) => row.type === 'object' && row.coverage_state === 'covered')).toBe(true);

    const changes = await sql.unsafe<{ type: string }[]>(
      'SELECT DISTINCT jsonb_typeof(payload) AS type FROM sync_changes');
    expect(changes).toEqual([{ type: 'object' }]);
    const occurrences = await sql.unsafe<{ type: string }[]>(
      'SELECT DISTINCT jsonb_typeof(schedule_snapshot) AS type FROM medication_occurrences');
    expect(occurrences).toEqual([{ type: 'object' }]);

    const [uncovered] = await sql.unsafe<{ count: number }[]>(
      "SELECT count(*)::int AS count FROM medication_handoff_journal WHERE coverage_state <> 'covered'");
    expect(uncovered?.count).toBe(0);

    const app = Fastify({ logger: false });
    app.register(capabilitiesRoutes, { db: drizzle(appSql, { schema }) as unknown as Db });
    await app.ready();
    const response = await app.inject({ method: 'GET', url: '/capabilities' });
    expect(response.json()).toMatchObject({ medicationLedgerActive: true });
    await app.close();

    // The activation is exclusive: a repeat is refused without further writes.
    const before = await sql.unsafe<{ count: number }[]>('SELECT count(*)::int AS count FROM sync_changes');
    await expect(activate()).rejects.toThrow('medication ledger authority is already active');
    const after = await sql.unsafe<{ count: number }[]>('SELECT count(*)::int AS count FROM sync_changes');
    expect(after).toEqual(before);
  }, 120_000);

  it('lets an activated deployment create untracked and not-yet-tracked pills, start stock, and take doses', async () => {
    const db = drizzle(appSql, { schema }) as unknown as Db;
    const pillsService = new PillsService(db);
    const schedulesService = new SchedulesService(db);
    const medication = new MedicationCommandService(db);
    const [profile] = await sql.unsafe<{ id: string }[]>('SELECT id FROM profiles WHERE user_id = $1', [userId]);
    const profileId = profile!.id;

    // Untracked pill: current_stock stays NULL. This INSERT used to fail with
    // "tracked stock cannot be removed after ledger activation".
    const untracked = await pillsService.createPill(userId, profileId, {
      mutationId: randomUUID(), name: 'Post-activation untracked', isPrn: false,
    });
    expect(untracked).toMatchObject({ currentStock: null });

    // A new pill is created without stock; stock starts through the inventory command.
    const tracked = await pillsService.createPill(userId, profileId, {
      mutationId: randomUUID(), name: 'Post-activation tracked', isPrn: false,
    });
    expect(tracked).toMatchObject({ currentStock: null });
    const trackedId = (tracked as { id: string }).id;
    const untrackedId = (untracked as { id: string }).id;

    const schedule = async (pillId: string) => {
      await schedulesService.createSchedule(userId, pillId, {
        mutationId: randomUUID(), hour: 12, minute: 0, frequency: 'daily', isActive: true,
        timeZone: 'Europe/Bucharest',
      } as Parameters<SchedulesService['createSchedule']>[2]);
      const [occurrence] = await sql.unsafe<{ id: string; occurrence_key: string }[]>(
        `SELECT id, occurrence_key FROM medication_occurrences
         WHERE pill_id = $1 ORDER BY planned_at LIMIT 1`, [pillId]);
      return occurrence!;
    };
    const trackedOccurrence = await schedule(trackedId);
    const untrackedOccurrence = await schedule(untrackedId);

    const started = await medication.executeInventory(userId, {
      action: 'start', commandId: randomUUID(), pillId: trackedId,
      baseRevision: (tracked as { revision: string }).revision, initialStock: 6, note: null,
    });
    expect(started).toBeTruthy();
    const stockOf = async (pillId: string) => (await sql.unsafe<{ current_stock: number | null }[]>(
      'SELECT current_stock FROM pills WHERE id = $1', [pillId]))[0]!.current_stock;
    expect(await stockOf(trackedId)).toBe(6);

    const take = (occurrence: { id: string; occurrence_key: string }) => medication.execute(userId, {
      commandId: randomUUID(), occurrenceId: occurrence.id, occurrenceKey: occurrence.occurrence_key,
      baseVersion: '0', action: 'take', rebasesCommandId: null, actualAt: null, actualTimeKnown: false, note: null,
    });
    const takeResult = await take(trackedOccurrence);
    expect(await stockOf(trackedId)).toBe(5);
    // The acknowledgement carries the pill revision the stock move produced.
    const [revisionRow] = await sql.unsafe<{ revision: string }[]>(
      'SELECT revision::text AS revision FROM pills WHERE id = $1', [trackedId]);
    expect(takeResult).toMatchObject({ pillRevision: revisionRow!.revision, currentStock: 5 });
    await take(untrackedOccurrence);
    expect(await stockOf(untrackedId)).toBeNull();

    // The ledger invariants still hold for tracked pills.
    const mismatch = (stock: number | null, pillId = trackedId) => seedTenant(async (tx) => {
      await tx.unsafe('UPDATE pills SET current_stock = $1 WHERE id = $2', [stock, pillId]);
    });
    await expect(mismatch(null)).rejects.toThrow('tracked stock cannot be removed after ledger activation');
    await expect(mismatch(99)).rejects.toThrow('pill stock must equal its medication inventory ledger projection');
    const noOpening = await pillsService.createPill(userId, profileId, {
      mutationId: randomUUID(), name: 'Never started', isPrn: false,
    });
    await expect(mismatch(3, (noOpening as { id: string }).id))
      .rejects.toThrow('tracked stock requires an opening inventory event');
    await expect(seedTenant(async (tx) => {
      await tx.unsafe('DELETE FROM pills WHERE id = $1', [trackedId]);
    })).rejects.toThrow('tracked stock cannot be removed after ledger activation');

    // Deleting an untracked pill is allowed: the app's soft delete, and a hard DELETE.
    await pillsService.deletePill(userId, profileId, (noOpening as { id: string }).id,
      randomUUID(), (noOpening as { revision: string }).revision);
    const spare = await pillsService.createPill(userId, profileId, {
      mutationId: randomUUID(), name: 'Hard delete me', isPrn: false,
    });
    await seedTenant(async (tx) => {
      await tx.unsafe('DELETE FROM pills WHERE id = $1', [(spare as { id: string }).id]);
    });
  }, 120_000);

  it('records and undoes an exact PRN dose after activation, moving tracked stock', async () => {
    // The server never materializes PRN occurrences, so the PRN command is the
    // only way an as-needed dose reaches the active ledger.
    const db = drizzle(appSql, { schema }) as unknown as Db;
    const pillsService = new PillsService(db);
    const schedulesService = new SchedulesService(db);
    const medication = new MedicationCommandService(db);
    const prn = new BridgePrnCommandService(db);
    const [profile] = await sql.unsafe<{ id: string }[]>('SELECT id FROM profiles WHERE user_id = $1', [userId]);
    const profileId = profile!.id;
    const stockOf = async (pillId: string) => (await sql.unsafe<{ current_stock: number | null }[]>(
      'SELECT current_stock FROM pills WHERE id = $1', [pillId]))[0]!.current_stock;

    const prnItem = async (name: string) => {
      const pill = await pillsService.createPill(userId, profileId, { mutationId: randomUUID(), name, isPrn: true });
      const pillId = (pill as { id: string }).id;
      await schedulesService.createSchedule(userId, pillId, {
        mutationId: randomUUID(), hour: 0, minute: 0, frequency: 'prn', isActive: true,
        timeZone: 'Europe/Bucharest',
      } as Parameters<SchedulesService['createSchedule']>[2]);
      const [schedule] = await sql.unsafe<{ id: string; revision: string }[]>(
        'SELECT id, revision::text AS revision FROM schedules WHERE pill_id = $1', [pillId]);
      return { pill: pill as { id: string; revision: string }, schedule: schedule! };
    };
    const takeCommand = (item: Awaited<ReturnType<typeof prnItem>>) => {
      const occurrenceId = randomUUID();
      return {
        operation: 'take' as const, commandId: randomUUID(), eventId: randomUUID(), occurrenceId,
        occurrenceKey: `prn:v1:${occurrenceId}`, profileId, pillId: item.pill.id,
        scheduleId: item.schedule.id, scheduleRevision: item.schedule.revision,
        plannedLocalDate: '2026-10-16', timeZone: 'Europe/Bucharest',
        actualAt: '2026-10-16T14:21:00.000Z', actualTimeKnown: true,
        amount: { version: 1 as const, state: 'known' as const, quantity: '1', unit: 'tablet' }, note: null,
      };
    };

    const tracked = await prnItem('Tracked as needed');
    await medication.executeInventory(userId, {
      action: 'start', commandId: randomUUID(), pillId: tracked.pill.id,
      baseRevision: tracked.pill.revision, initialStock: 4, note: null,
    });
    const take = takeCommand(tracked);
    const taken = await prn.execute(userId, take);
    expect(taken).toMatchObject({
      occurrenceId: take.occurrenceId, eventId: take.eventId, state: 'taken', stateVersion: '1',
      inventoryDelta: -1, inventoryTracked: true, currentStock: 3,
    });
    expect(await stockOf(tracked.pill.id)).toBe(3);
    // A retry replays the permanent receipt without moving stock again.
    expect(await prn.execute(userId, take)).toEqual(taken);
    expect(await stockOf(tracked.pill.id)).toBe(3);

    const undo = {
      operation: 'undo' as const, commandId: randomUUID(), eventId: randomUUID(),
      occurrenceId: take.occurrenceId, occurrenceKey: take.occurrenceKey,
      baseVersion: '1', reversesEventId: take.eventId, note: null,
    };
    const undone = await prn.execute(userId, undo);
    expect(undone).toMatchObject({ state: 'pending', stateVersion: '2', inventoryDelta: 1, currentStock: 4 });
    expect(await stockOf(tracked.pill.id)).toBe(4);
    const [reversal] = await sql.unsafe<{ kind: string; reverses: string | null; taken: string }[]>(
      `SELECT r.kind, r.reverses_inventory_event_id AS reverses, t.id AS taken
         FROM inventory_events r JOIN inventory_events t ON t.occurrence_event_id = $1
        WHERE r.occurrence_event_id = $2`, [take.eventId, undo.eventId]);
    expect(reversal).toMatchObject({ kind: 'dose_reversal' });
    expect(reversal!.reverses).toBe(reversal!.taken);

    // An untracked PRN item records the dose with no stock effect.
    const untracked = await prnItem('Untracked as needed');
    const untrackedTake = await prn.execute(userId, takeCommand(untracked));
    expect(untrackedTake).toMatchObject({ state: 'taken', inventoryEventId: null, inventoryDelta: null, inventoryTracked: false });
    expect(await stockOf(untracked.pill.id)).toBeNull();
  }, 120_000);
});
