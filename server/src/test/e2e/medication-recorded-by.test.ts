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
import { MedicationCommandSchema } from '../../modules/medication/medication-command.schema.js';
import { BridgePrnCommandSchema } from '../../modules/medication/bridge-prn-command.schema.js';
import { BridgePrnCommandService } from '../../modules/medication/bridge-prn-command.service.js';
import { MedicationCommandService } from '../../modules/medication/medication-command.service.js';
import { ComponentSyncService } from '../../modules/sync/component-sync.service.js';

const migrationsFolder = join(dirname(fileURLToPath(import.meta.url)), '../../db/migrations');
const HOUR_MS = 3_600_000;
const unknownAmount = { version: 1 as const, state: 'unknown' as const };
const recordedBy = (name: string | null) => ({ version: 1 as const, name });

/**
 * "Recorded by" travels with a dose: stored on the event, handed back on the
 * pull, absent when the client sent none, and tenant-isolated like every event.
 */
function suite(label: string, ledgerActive: boolean) {
  describe(label, () => {
    let scratch: Awaited<ReturnType<typeof createIsolatedDatabase>>;
    let adminSql: Sql;
    let appSql: Sql;
    let service: MedicationCommandService;
    let prn: BridgePrnCommandService;
    let sync: ComponentSyncService;
    const userId = randomUUID();
    const otherUserId = randomUUID();
    const profileId = randomUUID();

    beforeAll(async () => {
      scratch = await createIsolatedDatabase('recorded_by');
      adminSql = postgres(scratch.superUri, { max: 4 });
      await migrate(drizzle(adminSql), { migrationsFolder });
      await adminSql.unsafe("ALTER ROLE app_user PASSWORD 'testpass'");
      const databaseName = scratch.name.replaceAll('"', '""');
      await adminSql.unsafe(`GRANT CONNECT ON DATABASE "${databaseName}" TO app_user`);
      const appUrl = new URL(scratch.superUri);
      appUrl.username = 'app_user';
      appUrl.password = 'testpass';
      appSql = postgres(appUrl.toString(), { max: 4 });
      const db = drizzle(appSql, { schema }) as unknown as Db;
      service = new MedicationCommandService(db);
      prn = new BridgePrnCommandService(db);
      sync = new ComponentSyncService(db, 'recorded-by-test-cursor-secret-at-least-32-bytes');
      for (const id of [userId, otherUserId]) {
        await adminSql.unsafe('INSERT INTO users (id, email, password_hash) VALUES ($1, $2, $3)', [id, `${id}@recorded.invalid`, 'unused']);
      }
      await adminSql.begin(async (tx) => {
        await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
        await tx.unsafe('INSERT INTO profiles (id, user_id, name) VALUES ($1, $2, $3)', [profileId, userId, 'Owner']);
      });
      if (ledgerActive) {
        await adminSql.unsafe("SELECT set_deployment_authority(2, true, 1, 'ledger_activation', $1)", [`recorded-by-${userId}`]);
      }
    }, 120_000);

    afterAll(async () => {
      await appSql?.end();
      await adminSql?.end();
      await scratch?.drop();
    });

    async function newPill(isPrn: boolean) {
      const pill = randomUUID();
      const schedule = randomUUID();
      await adminSql.begin(async (tx) => {
        await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
        await tx.unsafe('INSERT INTO pills (id, profile_id, name, is_prn) VALUES ($1, $2, $3, $4)', [pill, profileId, 'Fictional', isPrn]);
        await tx.unsafe(
          `INSERT INTO schedules (id, pill_id, hour, minute, frequency, frequency_days, is_active, time_zone_status, time_zone)
           VALUES ($1, $2, $3, 0, $4, NULL, true, 'known', 'Europe/Bucharest')`,
          [schedule, pill, isPrn ? 0 : 8, isPrn ? 'prn' : 'daily'],
        );
      });
      return { pill, schedule };
    }

    async function occurrence(pill: string, schedule: string) {
      const id = randomUUID();
      const key = `recorded-by-${id}`;
      await adminSql.begin(async (tx) => {
        await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
        await tx.unsafe(
          `INSERT INTO medication_occurrences
             (id, user_id, pill_id, schedule_id, occurrence_key, source, schedule_revision,
              planned_local_date, planned_local_time, time_zone, planned_at, expected,
              snapshot_version, schedule_snapshot, provenance)
           VALUES ($1, $2, $3, $4, $5, 'scheduled', 1, '2026-10-01', '08:00:00', 'Europe/Bucharest', $6, true, 1, $7::jsonb, 'exact')`,
          [id, userId, pill, schedule, key, new Date(Date.now() - 2 * HOUR_MS).toISOString(),
            JSON.stringify({
              version: 1, pillName: 'Fictional', dosage: null, frequency: 'daily', frequencyDays: null,
              hour: 8, minute: 0, timeZone: 'Europe/Bucharest', profileId, profileName: 'Owner',
            })],
        );
      });
      return { id, key };
    }

    const take = (seeded: { id: string; key: string }, extra: Record<string, unknown> = {}) => ({
      commandId: randomUUID(), occurrenceId: seeded.id, occurrenceKey: seeded.key, baseVersion: '0',
      action: 'take', rebasesCommandId: null, actualAt: null, actualTimeKnown: false, note: null, ...extra,
    });

    // Every change a device would pull: the ledger view once it is active, the
    // PRN bridge view before.
    async function pulledItems(forUser = userId) {
      const request = ledgerActive
        ? { component: 'medication' as const, contractVersion: 2, pageSize: 200 }
        : { component: 'medicationBridge' as const, contractVersion: 5, pageSize: 200 };
      const view = await sync.read(forUser, request);
      return view.items.map((item) => item.change.payload);
    }

    async function pulledEvent(eventId: string, forUser = userId) {
      const items = await pulledItems(forUser);
      return items.find((payload) => payload.kind === 'occurrenceEvent' && payload.id === eventId);
    }

    const storedName = async (eventId: string) => (await adminSql.unsafe<{ recorded_by: unknown }[]>(
      'SELECT recorded_by FROM occurrence_events WHERE id = $1', [eventId]))[0]!.recorded_by;

    if (ledgerActive) {
      it('stores recordedBy on a take, hands it back on the pull and replays idempotently', async () => {
        const { pill, schedule } = await newPill(false);
        const seeded = await occurrence(pill, schedule);
        const command = MedicationCommandSchema.parse(take(seeded, { recordedBy: recordedBy('Mama') }));
        const result = await service.execute(userId, command);
        const eventId = String(result['eventId']);
        expect(await storedName(eventId)).toEqual(recordedBy('Mama'));
        expect(await pulledEvent(eventId)).toMatchObject({ kind: 'occurrenceEvent', recordedBy: recordedBy('Mama') });
        expect(await service.execute(userId, command)).toEqual(result);
        await expect(service.execute(userId, { ...command, recordedBy: recordedBy('Tata') }))
          .rejects.toMatchObject({ code: ErrorCode.CONFLICT_MUTATION_REUSE });
        const [count] = await adminSql.unsafe<{ count: number }[]>(
          'SELECT count(*)::int AS count FROM occurrence_events WHERE occurrence_id = $1', [seeded.id]);
        expect(count?.count).toBe(1);
      });

      it('keeps a recorded dose with no resolved name distinct from one with no author', async () => {
        const { pill, schedule } = await newPill(false);
        const withNull = await service.execute(userId, MedicationCommandSchema.parse(
          take(await occurrence(pill, schedule), { recordedBy: recordedBy(null) })));
        expect(await pulledEvent(String(withNull['eventId']))).toMatchObject({ recordedBy: { version: 1, name: null } });
      });

      it('accepts a command without recordedBy and pulls the event with no such key', async () => {
        const { pill, schedule } = await newPill(false);
        const result = await service.execute(userId, MedicationCommandSchema.parse(take(await occurrence(pill, schedule))));
        const eventId = String(result['eventId']);
        expect(await storedName(eventId)).toBeNull();
        expect(await pulledEvent(eventId)).not.toHaveProperty('recordedBy');
      });

      it('carries recordedBy on an undo and a correction', async () => {
        const { pill, schedule } = await newPill(false);
        const seeded = await occurrence(pill, schedule);
        const first = await service.execute(userId, MedicationCommandSchema.parse(take(seeded, { recordedBy: recordedBy('Mama') })));
        const undo = await service.execute(userId, MedicationCommandSchema.parse({
          ...take(seeded, { recordedBy: recordedBy('Tata') }), action: 'undo',
          baseVersion: String(first['stateVersion']), reversesEventId: first['eventId'],
        }));
        expect(await pulledEvent(String(undo['eventId']))).toMatchObject({ action: 'undo', recordedBy: recordedBy('Tata') });
        const corrected = await service.execute(userId, MedicationCommandSchema.parse({
          ...take(seeded, { recordedBy: recordedBy('Bunica') }), action: 'correct', targetState: 'skipped',
          baseVersion: String(undo['stateVersion']),
        }));
        expect(await pulledEvent(String(corrected['eventId']))).toMatchObject({ action: 'correct', recordedBy: recordedBy('Bunica') });
      });
    }

    it('stores recordedBy on a PRN take and undo and hands it back on the pull', async () => {
      const { pill, schedule } = await newPill(true);
      const occurrenceId = randomUUID();
      const eventId = randomUUID();
      const command = BridgePrnCommandSchema.parse({
        operation: 'take', commandId: randomUUID(), eventId, occurrenceId, occurrenceKey: `prn:v1:${occurrenceId}`,
        profileId, pillId: pill, scheduleId: schedule, scheduleRevision: '1', plannedLocalDate: '2026-10-06',
        timeZone: 'Europe/Bucharest', actualAt: null, actualTimeKnown: false, amount: unknownAmount, note: null,
        recordedBy: recordedBy('Mama'),
      });
      const result = await prn.execute(userId, command);
      expect(await prn.execute(userId, command)).toEqual(result);
      expect(await storedName(eventId)).toEqual(recordedBy('Mama'));
      expect(await pulledItems()).toEqual(expect.arrayContaining([
        expect.objectContaining({ kind: 'occurrenceEvent', id: eventId, recordedBy: recordedBy('Mama') }),
      ]));
      await expect(prn.execute(userId, { ...command, recordedBy: recordedBy('Tata') }))
        .rejects.toMatchObject({ code: ErrorCode.CONFLICT_MUTATION_REUSE });

      const undoEventId = randomUUID();
      await prn.execute(userId, BridgePrnCommandSchema.parse({
        operation: 'undo', commandId: randomUUID(), eventId: undoEventId, occurrenceId, occurrenceKey: `prn:v1:${occurrenceId}`,
        baseVersion: '1', reversesEventId: eventId, note: null, recordedBy: recordedBy('Tata'),
      }));
      expect(await storedName(undoEventId)).toEqual(recordedBy('Tata'));

      const plainId = randomUUID();
      const plainEvent = randomUUID();
      await prn.execute(userId, BridgePrnCommandSchema.parse({
        operation: 'take', commandId: randomUUID(), eventId: plainEvent, occurrenceId: plainId, occurrenceKey: `prn:v1:${plainId}`,
        profileId, pillId: pill, scheduleId: schedule, scheduleRevision: '1', plannedLocalDate: '2026-10-06',
        timeZone: 'Europe/Bucharest', actualAt: null, actualTimeKnown: false, amount: unknownAmount, note: null,
      }));
      expect(await storedName(plainEvent)).toBeNull();
      const pulled = await pulledEvent(plainEvent);
      expect(pulled).toBeDefined();
      expect(pulled).not.toHaveProperty('recordedBy');
    });

    it('refuses a malformed recordedBy at the schema and at the database boundary', () => {
      const seeded = { id: randomUUID(), key: 'k' };
      for (const bad of [
        { version: 2, name: 'Mama' }, { version: 1 }, { version: 1, name: '' }, { version: 1, name: ' Mama' },
        { version: 1, name: 'x'.repeat(101) }, { version: 1, name: 'Mama', device: 'pixel' },
      ]) {
        expect(MedicationCommandSchema.safeParse(take(seeded, { recordedBy: bad })).success, JSON.stringify(bad)).toBe(false);
      }
      expect(MedicationCommandSchema.safeParse(take(seeded, { action: 'miss', recordedBy: recordedBy('Mama') })).success).toBe(false);
      expect(MedicationCommandSchema.safeParse(take(seeded, { action: 'miss' })).success).toBe(true);
    });

    it.each([
      { version: 2, name: 'Mama' },
      { version: 1 },
      { version: 1, name: 'Mama', extra: true },
      { version: 1, name: '' },
      { version: 1, name: 5 },
    ])('rejects a malformed stored recordedBy %j with a check violation', async (bad) => {
      const { pill, schedule } = await newPill(false);
      const seeded = await occurrence(pill, schedule);
      await expect(adminSql.begin(async (tx) => {
        await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
        await tx.unsafe(
          `INSERT INTO occurrence_events (id, user_id, occurrence_id, command_id, action, from_state, to_state, actual_time_known,
             recorded_by, origin, base_version, result_version, server_sequence)
           VALUES ($1, $2, $3, $4, 'take', 'pending', 'taken', false, $5::jsonb, 'native', 0, 1, 999999)`,
          [randomUUID(), userId, seeded.id, randomUUID(), JSON.stringify(bad)],
        );
      })).rejects.toMatchObject({ constraint_name: 'occurrence_events_recorded_by_check' });
    });

    it('never shows one account a name recorded under another', async () => {
      const { pill, schedule } = await newPill(true);
      const eventId = randomUUID();
      const occurrenceId = randomUUID();
      await prn.execute(userId, BridgePrnCommandSchema.parse({
        operation: 'take', commandId: randomUUID(), eventId, occurrenceId, occurrenceKey: `prn:v1:${occurrenceId}`,
        profileId, pillId: pill, scheduleId: schedule, scheduleRevision: '1', plannedLocalDate: '2026-10-06',
        timeZone: 'Europe/Bucharest', actualAt: null, actualTimeKnown: false, amount: unknownAmount, note: null,
        recordedBy: recordedBy('Mama'),
      }));
      expect(JSON.stringify(await pulledItems(otherUserId))).not.toContain('Mama');
      expect(await pulledEvent(eventId)).toMatchObject({ recordedBy: recordedBy('Mama') });
      const rows = await appSql.begin(async (tx) => {
        await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [otherUserId]);
        return tx.unsafe('SELECT id FROM occurrence_events');
      });
      expect(rows).toHaveLength(0);
    });
  });
}

suite('recorded-by on an active ledger', true);
suite('recorded-by on an inactive ledger', false);
