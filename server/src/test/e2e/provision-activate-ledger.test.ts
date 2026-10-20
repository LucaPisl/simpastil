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
import { BridgeMedicationCommandService } from '../../modules/medication/bridge-medication-command.service.js';
import { ComponentSyncService } from '../../modules/sync/component-sync.service.js';
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
  /** Doses recorded through the bridge before activation, keyed by what happened to them. */
  const bridgeDoses = {} as Record<'take' | 'skip' | 'corrected' | 'undone' | 'retaken' | 'unmatched', {
    occurrenceId: string | null; legacyDoseId: string; commandIds: string[]; takenAt: string | null;
  }>;

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

    // Doses recorded through the bridge while the ledger was still inactive, on
    // occurrences the server had already materialized (the phone maps them).
    const db = drizzle(appSql, { schema }) as unknown as Db;
    const bridge = new BridgeMedicationCommandService(db);
    await new SchedulesService(db).createSchedule(userId, tracked, {
      mutationId: randomUUID(), hour: 14, minute: 30, frequency: 'daily', isActive: true,
      timeZone: 'Europe/Bucharest',
    } as Parameters<SchedulesService['createSchedule']>[2]);
    const [bridgeSchedule] = await sql.unsafe<{ id: string }[]>(
      'SELECT id FROM schedules WHERE pill_id = $1 AND hour = 14', [tracked]);
    const slots = await sql.unsafe<{ id: string; planned_at: Date | string }[]>(
      `SELECT id, planned_at FROM medication_occurrences WHERE schedule_id = $1 ORDER BY planned_at LIMIT 6`,
      [bridgeSchedule!.id]);
    expect(slots.length).toBeGreaterThanOrEqual(6);
    const record = async (
      key: keyof typeof bridgeDoses, slot: { id: string; planned_at: Date | string } | null,
      commands: { status: 'taken' | 'skipped' | 'pending'; takenAt?: string; create?: boolean; newDose?: boolean }[],
      scheduledAt = new Date(slot!.planned_at).toISOString(),
    ) => {
      let legacyDoseId = randomUUID();
      const commandIds: string[] = [];
      for (const command of commands) {
        // A retake after an undo is a new dose row for the same slot.
        if (command.newDose) legacyDoseId = randomUUID();
        const commandId = randomUUID();
        commandIds.push(commandId);
        await bridge.execute(userId, {
          commandId, commandBundleId: randomUUID(), transactionCorrelationId: randomUUID(),
          pillId: tracked, scheduleId: bridgeSchedule!.id, legacyDoseId,
          allowCreate: command.create ?? false, scheduledAt, status: command.status,
          takenAt: command.takenAt ?? null, observedBaseDoseFingerprint: null,
          observedBaseStock: null, observedBasePillRevision: null,
        });
      }
      bridgeDoses[key] = {
        occurrenceId: slot?.id ?? null, legacyDoseId, commandIds,
        takenAt: commands[0]?.takenAt ?? null,
      };
    };
    await record('take', slots[0]!, [{ status: 'taken', takenAt: '2026-10-19T11:41:07.000Z', create: true }]);
    await record('skip', slots[1]!, [{ status: 'skipped', create: true }]);
    // Taken, then changed to skipped by a second command: two receipts, ambiguous.
    await record('corrected', slots[2]!, [{ status: 'taken', takenAt: '2026-10-19T12:00:00.000Z', create: true }, { status: 'skipped' }]);
    // Taken and undone: the dose log is soft deleted, the occurrence stays pending.
    await record('undone', slots[3]!, [{ status: 'taken', takenAt: '2026-10-19T12:30:00.000Z', create: true }, { status: 'pending' }]);
    // Taken, undone, then taken again: the retake is a new live dose row with
    // its own receipt, but the slot has three receipts and the recording device
    // holds take, undo and take events.
    await record('retaken', slots[4]!, [
      { status: 'taken', takenAt: '2026-10-19T13:00:00.000Z', create: true }, { status: 'pending' },
      { status: 'taken', takenAt: '2026-10-19T13:10:00.000Z', create: true, newDose: true },
    ]);
    // A dose at an instant that is not a materialized slot: no occurrence to move.
    await record('unmatched', null, [{ status: 'taken', takenAt: '2026-10-19T10:00:00.000Z', create: true }],
      '2026-10-19T10:17:00.000Z');
  }, 240_000);

  afterAll(async () => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
    await appSql?.end();
    await sql?.end();
    await container?.stop();
  });

  let activationLog: string[] = [];

  async function activate(): Promise<void> {
    vi.stubEnv('LEDGER_CURRENT_BUILD', '2');
    vi.stubEnv('LEDGER_CHANGE_REFERENCE', 'e2e-activation');
    await runProvisionCommand('activate-ledger');
    activationLog = vi.mocked(console.log).mock.calls.map((call) => String(call[0]));
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

  it('gives bridge-recorded doses their ledger event so every device sees them recorded', async () => {
    const eventsOf = (occurrenceId: string) => sql.unsafe<{
      id: string; command_id: string; action: string; from_state: string; to_state: string;
      origin: string; base_version: string; result_version: string; actual_at: Date | string | null;
      actual_time_known: boolean;
    }[]>(
      `SELECT id, command_id, action, from_state, to_state, origin, base_version::text, result_version::text,
              actual_at, actual_time_known FROM occurrence_events WHERE occurrence_id = $1`, [occurrenceId]);
    const versionOf = async (occurrenceId: string) => (await sql.unsafe<{ state_version: string }[]>(
      'SELECT state_version::text FROM medication_occurrences WHERE id = $1', [occurrenceId]))[0]!.state_version;

    // A matched take: one legacy_handoff event under the bridge command id, version 1.
    const take = bridgeDoses.take;
    const [takeEvent, ...extraTake] = await eventsOf(take.occurrenceId!);
    expect(extraTake).toHaveLength(0);
    expect(takeEvent).toMatchObject({
      command_id: take.commandIds[0], action: 'take', from_state: 'pending', to_state: 'taken',
      origin: 'legacy_handoff', base_version: '0', result_version: '1', actual_time_known: true,
    });
    expect(new Date(takeEvent!.actual_at!).toISOString()).toBe(take.takenAt);
    expect(await versionOf(take.occurrenceId!)).toBe('1');

    // A matched skip.
    const skip = bridgeDoses.skip;
    const [skipEvent, ...extraSkip] = await eventsOf(skip.occurrenceId!);
    expect(extraSkip).toHaveLength(0);
    expect(skipEvent).toMatchObject({
      command_id: skip.commandIds[0], action: 'skip', to_state: 'skipped', origin: 'legacy_handoff',
      result_version: '1', actual_at: null, actual_time_known: false,
    });
    expect(await versionOf(skip.occurrenceId!)).toBe('1');

    // Ambiguous (several receipts for the slot), undone (dose log deleted),
    // undone and retaken, and unmatched stay legacy history.
    for (const key of ['corrected', 'undone', 'retaken'] as const) {
      expect(await eventsOf(bridgeDoses[key].occurrenceId!)).toEqual([]);
      expect(await versionOf(bridgeDoses[key].occurrenceId!)).toBe('0');
    }
    const [anyForUnmatched] = await sql.unsafe<{ count: number }[]>(
      'SELECT count(*)::int AS count FROM occurrence_events WHERE command_id = $1', [bridgeDoses.unmatched.commandIds[0]]);
    expect(anyForUnmatched?.count).toBe(0);
    const [handoffEvents] = await sql.unsafe<{ count: number }[]>(
      "SELECT count(*)::int AS count FROM occurrence_events WHERE origin = 'legacy_handoff'");
    expect(handoffEvents?.count).toBe(2);

    // No inventory event is tied to the backfilled events, and tracked stock still matches its ledger.
    const [tied] = await sql.unsafe<{ count: number }[]>(
      'SELECT count(*)::int AS count FROM inventory_events WHERE occurrence_event_id IN ($1, $2)', [takeEvent!.id, skipEvent!.id]);
    expect(tied?.count).toBe(0);
    const [stockMismatch] = await sql.unsafe<{ count: number }[]>(
      `SELECT count(*)::int AS count FROM pills p WHERE p.current_stock IS NOT NULL AND p.current_stock <>
         COALESCE((SELECT sum(delta) FROM inventory_events e WHERE e.pill_id = p.id), 0)`);
    expect(stockMismatch?.count).toBe(0);

    // The permanent receipt still answers the bridge command id.
    const [receipt] = await sql.unsafe<{ origin: string }[]>(
      'SELECT origin FROM medication_command_receipts WHERE command_id = $1', [take.commandIds[0]]);
    expect(receipt?.origin).toBe('legacy_handoff');

    // The operator sees how many doses were left as legacy history.
    expect(activationLog).toContain('backfilled 2 bridge-recorded dose(s) as ledger events; '
      + '3 left as legacy history only (ambiguous receipts or no single open occurrence)');

    // The other device's first active pull: the occurrence at version 1 and the
    // event that explains it, so its Today reads taken / skipped.
    const sync = new ComponentSyncService(drizzle(appSql, { schema }) as unknown as Db,
      'activate-ledger-test-cursor-secret-at-least-32-bytes');
    const payloads: Record<string, unknown>[] = [];
    let cursor: string | undefined;
    do {
      const page = await sync.read(userId, {
        component: 'medication', contractVersion: 2, pageSize: 200, ...(cursor ? { cursor } : {}),
      });
      payloads.push(...page.items.map((item) => item.change.payload as Record<string, unknown>));
      cursor = page.hasMore ? page.nextCursor! : undefined;
    } while (cursor);
    expect(payloads).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: 'medicationOccurrence', id: take.occurrenceId, stateVersion: '1' }),
      expect.objectContaining({
        kind: 'occurrenceEvent', id: takeEvent!.id, occurrenceId: take.occurrenceId,
        commandId: take.commandIds[0], toState: 'taken', origin: 'legacy_handoff', resultVersion: '1',
      }),
      expect.objectContaining({ kind: 'medicationOccurrence', id: skip.occurrenceId, stateVersion: '1' }),
      expect.objectContaining({ kind: 'occurrenceEvent', id: skipEvent!.id, toState: 'skipped' }),
    ]));
    // The ambiguous occurrence is still delivered only at version 0, with no event.
    const ambiguousId = bridgeDoses.corrected.occurrenceId;
    expect(payloads.filter((p) => p['kind'] === 'medicationOccurrence' && p['id'] === ambiguousId))
      .toEqual([expect.objectContaining({ stateVersion: '0' })]);
    expect(payloads.some((p) => p['kind'] === 'occurrenceEvent' && p['occurrenceId'] === ambiguousId)).toBe(false);

    // Follow-up commands on the backfilled dose. Changing taken to skipped works
    // and returns the pill to stock, since the bridge had already taken it out.
    // A retry of the bridge command id is refused as a different input (the
    // receipt keeps the bridge fingerprint), and an undo is refused because the
    // dose's stock effect lives in the handoff inventory events, not in this one.
    const medication = new MedicationCommandService(drizzle(appSql, { schema }) as unknown as Db);
    const [occurrenceRow] = await sql.unsafe<{ occurrence_key: string; current_stock: number }[]>(
      `SELECT o.occurrence_key, p.current_stock FROM medication_occurrences o
         JOIN pills p ON p.id = o.pill_id WHERE o.id = $1`, [take.occurrenceId]);
    const base = {
      occurrenceId: take.occurrenceId!, occurrenceKey: occurrenceRow!.occurrence_key, baseVersion: '1',
      rebasesCommandId: null, actualAt: null, actualTimeKnown: false, note: null,
    };
    await expect(medication.execute(userId, { ...base, commandId: take.commandIds[0]!, action: 'take' }))
      .rejects.toMatchObject({ code: 'CONFLICT_MUTATION_REUSE' });
    await expect(medication.execute(userId, {
      ...base, commandId: randomUUID(), action: 'undo', reversesEventId: takeEvent!.id,
    })).rejects.toThrow('cannot be undone');
    const corrected = await medication.execute(userId, {
      ...base, commandId: randomUUID(), action: 'correct', targetState: 'skipped',
    });
    expect(corrected).toMatchObject({ state: 'skipped', stateVersion: '2', inventoryDelta: 1 });
    expect(corrected['currentStock']).toBe(occurrenceRow!.current_stock + 1);
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
