import { randomUUID } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { drizzle } from 'drizzle-orm/postgres-js';
import { migrate } from 'drizzle-orm/postgres-js/migrator';
import postgres, { type Sql } from 'postgres';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createIsolatedDatabase } from '../helpers/db-helpers.js';
import type { Db } from '../../db/client.js';
import * as schema from '../../db/schema.js';
import { ErrorCode } from '../../modules/shared/errors.js';
import { MedicationCommandSchema, type MedicationCommand } from '../../modules/medication/medication-command.schema.js';
import { MedicationCommandService } from '../../modules/medication/medication-command.service.js';
import { MovedHistoryRequestSchema } from '../../modules/medication/moved-history.schema.js';
import { MovedHistoryService } from '../../modules/medication/moved-history.service.js';
import { addLocalDays, localDateAt } from '../../modules/medication/occurrence-materializer.js';
import { SCHEDULE_WINDOWS_MIN_CLIENT_BUILD } from '../../modules/schedules/schedule-windows.js';

const migrationsFolder = join(dirname(fileURLToPath(import.meta.url)), '../../db/migrations');
const ZONE = 'Europe/Bucharest';
const DAILY = { frequency: 'daily' as const, frequencyDays: null, everyDays: null, anchorDate: null, startDate: null, endDate: null };

/**
 * Moved history against the real ledger: a disposable database migrated to head,
 * the ledger activated, and the services running as `app_user` (RLS enforced).
 */
describe('moved history', () => {
  let scratch: Awaited<ReturnType<typeof createIsolatedDatabase>>;
  let adminSql: Sql;
  let appSql: Sql;
  let moved: MovedHistoryService;
  let commands: MedicationCommandService;
  const userId = randomUUID();
  const otherUserId = randomUUID();
  let scheduleId: string;
  let otherScheduleId: string;
  let prnScheduleId: string;
  const today = localDateAt(new Date(), ZONE);

  beforeAll(async () => {
    scratch = await createIsolatedDatabase('moved_history');
    adminSql = postgres(scratch.superUri, { max: 4 });
    await migrate(drizzle(adminSql), { migrationsFolder });
    await adminSql.unsafe("ALTER ROLE app_user PASSWORD 'testpass'");
    const databaseName = scratch.name.replaceAll('"', '""');
    await adminSql.unsafe(`GRANT CONNECT ON DATABASE "${databaseName}" TO app_user`);
    const appUrl = new URL(scratch.superUri);
    appUrl.username = 'app_user';
    appUrl.password = 'testpass';
    appSql = postgres(appUrl.toString(), { max: 4 });
    const appDb = drizzle(appSql, { schema }) as unknown as Db;
    moved = new MovedHistoryService(appDb);
    commands = new MedicationCommandService(appDb);

    const seed = async (owner: string, withPrn: boolean) => {
      const profileId = randomUUID();
      const pill = randomUUID();
      const schedule = randomUUID();
      const prnPill = randomUUID();
      const prnSchedule = randomUUID();
      await adminSql.unsafe(
        'INSERT INTO users (id, email, password_hash) VALUES ($1, $2, $3)',
        [owner, `${owner}@moved.invalid`, 'unused-test-hash'],
      );
      await adminSql.begin(async (tx) => {
        await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [owner]);
        await tx.unsafe('INSERT INTO profiles (id, user_id, name) VALUES ($1, $2, $3)', [profileId, owner, 'Owner']);
        await tx.unsafe('INSERT INTO pills (id, profile_id, name) VALUES ($1, $2, $3)', [pill, profileId, 'Moved pill']);
        // Midnight, so today's own occurrence is always already due.
        await tx.unsafe(
          `INSERT INTO schedules (id, pill_id, hour, minute, frequency, frequency_days, is_active, time_zone_status, time_zone)
           VALUES ($1, $2, 0, 0, 'daily', NULL, true, 'known', $3)`,
          [schedule, pill, ZONE],
        );
        if (withPrn) {
          await tx.unsafe('INSERT INTO pills (id, profile_id, name, is_prn) VALUES ($1, $2, $3, true)', [prnPill, profileId, 'Prn pill']);
          await tx.unsafe(
            `INSERT INTO schedules (id, pill_id, hour, minute, frequency, frequency_days, is_active, time_zone_status, time_zone)
             VALUES ($1, $2, 0, 0, 'prn', NULL, true, 'known', $3)`,
            [prnSchedule, prnPill, ZONE],
          );
        }
      });
      return { schedule, prnSchedule };
    };
    ({ schedule: scheduleId, prnSchedule: prnScheduleId } = await seed(userId, true));
    ({ schedule: otherScheduleId } = await seed(otherUserId, false));
    await adminSql.unsafe(
      "SELECT set_deployment_authority(2, true, 1, 'ledger_activation', $1)",
      [`moved-history-${userId}`],
    );
  }, 120_000);

  afterAll(async () => {
    await appSql?.end();
    await adminSql?.end();
    await scratch?.drop();
  });

  function item(daysAgo: number, overrides: Record<string, unknown> = {}) {
    return {
      occurrenceId: randomUUID(),
      plannedLocalDate: addLocalDays(today, -daysAgo),
      plannedLocalTime: '08:00',
      timeZone: ZONE,
      routine: { ...DAILY },
      ...overrides,
    };
  }

  const request = (items: unknown[], schedule: string = scheduleId) =>
    MovedHistoryRequestSchema.parse({ scheduleId: schedule, items });

  const minimumBuild = async (owner: string) => (await adminSql.unsafe<{ minimum_client_build: number }[]>(
    'SELECT minimum_client_build FROM users WHERE id = $1', [owner]))[0]!.minimum_client_build;
  const occurrenceChanges = async (id: string) => Number((await adminSql.unsafe<{ count: string }[]>(
    `SELECT count(*) FROM sync_changes WHERE user_id = $1 AND entity_type = 'medication_occurrence' AND entity_id = $2`,
    [userId, id]))[0]!.count);

  it('creates past scheduled occurrences, publishes them once, and replays idempotently', async () => {
    const items = [item(3), item(2), item(1)];
    const first = await moved.execute(userId, request(items));
    expect(first.items.map((row) => row.occurrenceId)).toEqual(items.map((row) => row.occurrenceId));
    expect(first.items.every((row) => row.created && row.stateVersion === '0')).toBe(true);
    expect(first.items.every((row) => row.occurrenceKey.startsWith('scheduled:v1:'))).toBe(true);

    const [stored] = await adminSql.unsafe<{
      source: string; expected: boolean; provenance: string; snapshot_version: number;
      schedule_revision: string; planned_at: string | Date; schedule_snapshot: { version: number; hour: number; frequency: string };
    }[]>('SELECT source, expected, provenance, snapshot_version, schedule_revision::text, planned_at, schedule_snapshot FROM medication_occurrences WHERE id = $1', [items[0]!.occurrenceId]);
    expect(stored).toMatchObject({ source: 'scheduled', expected: true, provenance: 'exact', snapshot_version: 1, schedule_revision: '1' });
    expect(stored!.schedule_snapshot).toMatchObject({ version: 1, frequency: 'daily', hour: 8 });
    expect(new Date(stored!.planned_at).getTime()).toBeLessThan(Date.now());
    expect(await occurrenceChanges(items[0]!.occurrenceId)).toBe(1);

    const replay = await moved.execute(userId, request(items));
    expect(replay.items.map((row) => ({ ...row, created: undefined })))
      .toEqual(first.items.map((row) => ({ ...row, created: undefined })));
    expect(replay.items.every((row) => !row.created)).toBe(true);
    expect(await occurrenceChanges(items[0]!.occurrenceId)).toBe(1);
    // A daily, undated routine never raises the account's build floor.
    expect(await minimumBuild(userId)).toBe(1);
  });

  it('dedupes a moved dose against the occurrence the materializer already produced today', async () => {
    const todays = item(0, { plannedLocalTime: '00:00' });
    const result = await moved.execute(userId, request([todays]));
    expect(result.items).toHaveLength(1);
    const [row] = result.items;
    expect(row!.created).toBe(false);
    expect(row!.occurrenceId).not.toBe(todays.occurrenceId);
    const matches = await adminSql.unsafe<{ id: string }[]>(
      `SELECT id FROM medication_occurrences WHERE user_id = $1 AND schedule_id = $2 AND planned_local_date = $3 AND planned_local_time = '00:00:00'`,
      [userId, scheduleId, today],
    );
    expect(matches.map((m) => m.id)).toEqual([row!.occurrenceId]);
  });

  it('answers 409 when an occurrence id is already used by a different dose', async () => {
    const first = item(5);
    await moved.execute(userId, request([first]));
    const clash = { ...item(6), occurrenceId: first.occurrenceId };
    await expect(moved.execute(userId, request([clash]))).rejects.toMatchObject({
      name: 'ConflictError', code: ErrorCode.CONFLICT_MUTATION_REUSE,
    });
    // Nothing from the failed request survived (one transaction).
    const rows = await adminSql.unsafe<{ count: string }[]>(
      'SELECT count(*) FROM medication_occurrences WHERE user_id = $1 AND planned_local_date = $2 AND schedule_id = $3',
      [userId, clash.plannedLocalDate, scheduleId]);
    expect(Number(rows[0]!.count)).toBe(0);
    const [again] = (await moved.execute(userId, request([first]))).items;
    expect(again).toMatchObject({ occurrenceId: first.occurrenceId, created: false });
  });

  it('rejects a dose planned in the future with 400 and stores nothing', async () => {
    const future = item(-3);
    const fine = item(7);
    await expect(moved.execute(userId, request([fine, future]))).rejects.toMatchObject({ statusCode: 400 });
    const rows = await adminSql.unsafe<{ id: string }[]>(
      'SELECT id FROM medication_occurrences WHERE id = ANY($1::uuid[])', [[fine.occurrenceId, future.occurrenceId]]);
    expect(rows).toEqual([]);
  });

  it('does not accept another account\'s schedule, a PRN schedule, or an invalid routine', async () => {
    await expect(moved.execute(userId, request([item(1)], otherScheduleId))).rejects.toMatchObject({ statusCode: 404 });
    await expect(moved.execute(userId, request([item(1)], randomUUID()))).rejects.toMatchObject({ statusCode: 404 });
    await expect(moved.execute(userId, request([item(1)], prnScheduleId))).rejects.toMatchObject({
      name: 'ConflictError',
    });
    expect(() => request([item(1, { routine: { ...DAILY, frequency: 'prn' } })])).toThrow();
    expect(() => request([item(1, { routine: { ...DAILY, frequency: 'interval' } })])).toThrow();
    expect(() => request([item(1, { routine: { ...DAILY, startDate: '2026-02-30' } })])).toThrow();
    expect(() => request([])).toThrow();
    expect(() => request(Array.from({ length: 201 }, () => item(1)))).toThrow();
  });

  it('writes snapshot 3 for an interval or dated routine and raises the account build floor', async () => {
    const interval = item(9, {
      routine: { ...DAILY, frequency: 'interval', everyDays: 3, anchorDate: addLocalDays(today, -30) },
    });
    const dated = item(10, { routine: { ...DAILY, startDate: addLocalDays(today, -40), endDate: addLocalDays(today, 5) } });
    expect(await minimumBuild(otherUserId)).toBe(1);
    await moved.execute(userId, request([interval, dated]));
    const rows = await adminSql.unsafe<{ id: string; snapshot_version: number; schedule_snapshot: Record<string, unknown> }[]>(
      'SELECT id, snapshot_version, schedule_snapshot FROM medication_occurrences WHERE id = ANY($1::uuid[])',
      [[interval.occurrenceId, dated.occurrenceId]]);
    expect(rows).toHaveLength(2);
    for (const row of rows) {
      expect(row.snapshot_version).toBe(3);
      expect(row.schedule_snapshot['version']).toBe(3);
    }
    expect(rows.find((row) => row.id === interval.occurrenceId)!.schedule_snapshot).toMatchObject({
      frequency: 'interval', everyDays: 3, anchorDate: addLocalDays(today, -30), startDate: null, endDate: null,
    });
    expect(await minimumBuild(userId)).toBe(SCHEDULE_WINDOWS_MIN_CLIENT_BUILD);
    // Another account is untouched.
    expect(await minimumBuild(otherUserId)).toBe(1);
  });

  describe('recording the moved history with the normal commands', () => {
    function command(row: { occurrenceId: string; occurrenceKey: string }, overrides: Record<string, unknown>): MedicationCommand {
      return MedicationCommandSchema.parse({
        commandId: randomUUID(),
        occurrenceId: row.occurrenceId,
        occurrenceKey: row.occurrenceKey,
        baseVersion: '0',
        action: 'take',
        rebasesCommandId: null,
        actualAt: null,
        actualTimeKnown: false,
        note: null,
        ...overrides,
      });
    }

    it('takes a moved dose with its original past actualAt', async () => {
      const [row] = (await moved.execute(userId, request([item(12)]))).items;
      const actualAt = new Date(Date.now() - 12 * 24 * 3_600_000).toISOString();
      const result = await commands.execute(userId, command(row!, { action: 'take', actualAt, actualTimeKnown: true }));
      expect(result).toMatchObject({ action: 'take', state: 'taken', stateVersion: '1' });
      const [event] = await adminSql.unsafe<{ actual_at: string | Date }[]>(
        'SELECT actual_at FROM occurrence_events WHERE occurrence_id = $1', [row!.occurrenceId]);
      expect(new Date(event!.actual_at).toISOString()).toBe(actualAt);
    });

    it('skips a moved dose', async () => {
      const [row] = (await moved.execute(userId, request([item(13)]))).items;
      const result = await commands.execute(userId, command(row!, { action: 'skip' }));
      expect(result).toMatchObject({ action: 'skip', state: 'skipped', stateVersion: '1' });
    });

    it('records a miss on a moved dose and then corrects it from missed', async () => {
      const [row] = (await moved.execute(userId, request([item(14)]))).items;
      const missed = await commands.execute(userId, command(row!, { action: 'miss' }));
      expect(missed).toMatchObject({ action: 'miss', state: 'missed', stateVersion: '1' });
      const actualAt = new Date(Date.now() - 14 * 24 * 3_600_000 + 3_600_000).toISOString();
      const corrected = await commands.execute(userId, command(row!, {
        action: 'correct', targetState: 'taken', baseVersion: '1', actualAt, actualTimeKnown: true,
      }));
      expect(corrected).toMatchObject({ action: 'correct', state: 'taken', stateVersion: '2' });
      const events = await adminSql.unsafe<{ action: string; from_state: string; to_state: string }[]>(
        'SELECT action, from_state, to_state FROM occurrence_events WHERE occurrence_id = $1 ORDER BY server_sequence',
        [row!.occurrenceId]);
      expect(events).toEqual([
        { action: 'miss', from_state: 'pending', to_state: 'missed' },
        { action: 'correct', from_state: 'missed', to_state: 'taken' },
      ]);
    });
  });
});
