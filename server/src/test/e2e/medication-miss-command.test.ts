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

const migrationsFolder = join(dirname(fileURLToPath(import.meta.url)), '../../db/migrations');
const HOUR_MS = 3_600_000;

/**
 * Recorded misses against the real ledger: a disposable database migrated to
 * head, the ledger activated, and the command service running as `app_user`
 * (RLS enforced) like the API does.
 */
describe('recorded miss medication command', () => {
  let scratch: Awaited<ReturnType<typeof createIsolatedDatabase>>;
  let adminSql: Sql;
  let appSql: Sql;
  let service: MedicationCommandService;
  const userId = randomUUID();
  const otherUserId = randomUUID();
  let pillId: string;
  let otherPillId: string;
  let scheduleId: string;
  let otherScheduleId: string;

  beforeAll(async () => {
    scratch = await createIsolatedDatabase('miss_command');
    adminSql = postgres(scratch.superUri, { max: 4 });
    await migrate(drizzle(adminSql), { migrationsFolder });
    await adminSql.unsafe("ALTER ROLE app_user PASSWORD 'testpass'");
    const databaseName = scratch.name.replaceAll('"', '""');
    await adminSql.unsafe(`GRANT CONNECT ON DATABASE "${databaseName}" TO app_user`);
    const appUrl = new URL(scratch.superUri);
    appUrl.username = 'app_user';
    appUrl.password = 'testpass';
    appSql = postgres(appUrl.toString(), { max: 4 });
    service = new MedicationCommandService(drizzle(appSql, { schema }) as unknown as Db);

    const seed = async (owner: string) => {
      const profileId = randomUUID();
      const pill = randomUUID();
      const schedule = randomUUID();
      await adminSql.unsafe(
        'INSERT INTO users (id, email, password_hash) VALUES ($1, $2, $3)',
        [owner, `${owner}@miss.invalid`, 'unused-test-hash'],
      );
      await adminSql.begin(async (tx) => {
        await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [owner]);
        await tx.unsafe('INSERT INTO profiles (id, user_id, name) VALUES ($1, $2, $3)', [profileId, owner, 'Owner']);
        await tx.unsafe('INSERT INTO pills (id, profile_id, name) VALUES ($1, $2, $3)', [pill, profileId, 'Miss pill']);
        await tx.unsafe(
          `INSERT INTO schedules (id, pill_id, hour, minute, frequency, frequency_days, is_active, time_zone_status, time_zone)
           VALUES ($1, $2, 8, 0, 'daily', NULL, true, 'known', 'Europe/Bucharest')`,
          [schedule, pill],
        );
      });
      return { pill, schedule };
    };
    ({ pill: pillId, schedule: scheduleId } = await seed(userId));
    ({ pill: otherPillId, schedule: otherScheduleId } = await seed(otherUserId));
    await adminSql.unsafe(
      "SELECT set_deployment_authority(2, true, 1, 'ledger_activation', $1)",
      [`miss-command-${userId}`],
    );
    // Track stock so the take/undo chain has a measurable inventory effect.
    await service.executeInventory(userId, {
      action: 'start', commandId: randomUUID(), pillId, baseRevision: '1', initialStock: 10, note: null,
    });
  }, 120_000);

  afterAll(async () => {
    await appSql?.end();
    await adminSql?.end();
    await scratch?.drop();
  });

  type Seeded = { id: string; key: string };

  /** Inserts one occurrence directly (superuser, as the materializer would). */
  async function occurrence(options: {
    owner?: string;
    pill?: string;
    schedule?: string;
    source?: 'scheduled' | 'prn';
    plannedAt?: Date | null;
    provenance?: 'exact' | 'legacy_estimated';
    expected?: boolean;
    superseded?: boolean;
  } = {}): Promise<Seeded> {
    const owner = options.owner ?? userId;
    const source = options.source ?? 'scheduled';
    const plannedAt = options.plannedAt === undefined ? new Date(Date.now() - 2 * HOUR_MS) : options.plannedAt;
    const id = randomUUID();
    const key = `miss-test-${id}`;
    const snapshot = JSON.stringify({
      version: 1, pillName: 'Miss pill', dosage: null,
      frequency: source === 'scheduled' ? 'daily' : 'prn', frequencyDays: null,
      hour: source === 'scheduled' ? 8 : null, minute: source === 'scheduled' ? 0 : null,
      timeZone: 'Europe/Bucharest', profileId: randomUUID(), profileName: 'Owner',
    });
    await adminSql.begin(async (tx) => {
      await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [owner]);
      await tx.unsafe(
        `INSERT INTO medication_occurrences
           (id, user_id, pill_id, schedule_id, occurrence_key, source, schedule_revision,
            planned_local_date, planned_local_time, time_zone, planned_at, expected,
            snapshot_version, schedule_snapshot, provenance)
         VALUES ($1, $2, $3, $4, $5, $6, $7, '2026-10-01', $8, 'Europe/Bucharest', $9, $10, 1, $11::jsonb, $12)`,
        [
          id, owner, options.pill ?? (owner === userId ? pillId : otherPillId),
          source === 'scheduled' ? (options.schedule ?? (owner === userId ? scheduleId : otherScheduleId)) : null,
          key, source, source === 'scheduled' ? 1 : null,
          source === 'scheduled' ? '08:00:00' : null,
          plannedAt?.toISOString() ?? null, options.expected ?? source === 'scheduled', snapshot,
          options.provenance ?? 'exact',
        ],
      );
      if (options.superseded) {
        await tx.unsafe('UPDATE medication_occurrences SET superseded_at = now() WHERE id = $1', [id]);
      }
    });
    return { id, key };
  }

  function command(seeded: Seeded, overrides: Partial<Record<string, unknown>> = {}): MedicationCommand {
    return MedicationCommandSchema.parse({
      commandId: randomUUID(),
      occurrenceId: seeded.id,
      occurrenceKey: seeded.key,
      baseVersion: '0',
      action: 'miss',
      rebasesCommandId: null,
      actualAt: null,
      actualTimeKnown: false,
      note: null,
      ...overrides,
    });
  }

  const stock = async () => (await adminSql.unsafe<{ current_stock: number }[]>(
    'SELECT current_stock::int AS current_stock FROM pills WHERE id = $1', [pillId]))[0]!.current_stock;
  const eventCount = async (occurrenceId: string) => (await adminSql.unsafe<{ count: number }[]>(
    'SELECT count(*)::int AS count FROM occurrence_events WHERE occurrence_id = $1', [occurrenceId]))[0]!.count;

  it('records a miss on an elapsed scheduled dose without touching stock', async () => {
    const seeded = await occurrence();
    const before = await stock();
    const missCommand = command(seeded);
    const result = await service.execute(userId, missCommand);

    expect(result).toMatchObject({
      commandId: missCommand.commandId,
      occurrenceId: seeded.id,
      action: 'miss',
      state: 'missed',
      stateVersion: '1',
      inventoryEventId: null,
      inventoryDelta: 0,
      currentStock: before,
    });
    expect(await stock()).toBe(before);
    const [event] = await adminSql.unsafe<{
      action: string; from_state: string; to_state: string; origin: string;
      actual_time_known: boolean; note: string | null;
    }[]>(
      'SELECT action, from_state, to_state, origin, actual_time_known, note FROM occurrence_events WHERE command_id = $1',
      [missCommand.commandId],
    );
    expect(event).toEqual({
      action: 'miss', from_state: 'pending', to_state: 'missed', origin: 'native',
      actual_time_known: false, note: null,
    });
    // The miss reaches every device through the ordinary sync stream.
    const changes = await adminSql.unsafe<{ entity_type: string; state: string | null }[]>(
      `SELECT entity_type, payload->'payload'->>'toState' AS state
         FROM sync_changes
        WHERE user_id = $1
          AND ((entity_type = 'medication_occurrence' AND entity_id = $2)
            OR (entity_type = 'occurrence_event' AND payload->'payload'->>'occurrenceId' = $2::text))
        ORDER BY server_sequence`,
      [userId, seeded.id],
    );
    expect(changes).toEqual(expect.arrayContaining([
      { entity_type: 'medication_occurrence', state: null },
      { entity_type: 'occurrence_event', state: 'missed' },
    ]));
  });

  it('replays the same command id from a second device without a second event', async () => {
    const seeded = await occurrence();
    const missCommand = command(seeded);
    const first = await service.execute(userId, missCommand);
    // Two devices derive the identical command id; the second send is a replay.
    const second = await service.execute(userId, { ...missCommand });
    expect(second).toEqual(first);
    expect(await eventCount(seeded.id)).toBe(1);
    // Reusing the id for different input is still refused.
    await expect(service.execute(userId, { ...missCommand, note: 'different' }))
      .rejects.toMatchObject({ code: ErrorCode.CONFLICT_MUTATION_REUSE });
  });

  it('answers a stale miss on an already recorded dose with 409 and never coerces it', async () => {
    const seeded = await occurrence();
    await service.execute(userId, command(seeded, { action: 'take' }));
    // Wrong base version: the person recorded it first.
    await expect(service.execute(userId, command(seeded)))
      .rejects.toMatchObject({ code: ErrorCode.CONFLICT_STALE_UPDATE });
    // Right base version but the state is no longer pending.
    await expect(service.execute(userId, command(seeded, { baseVersion: '1' })))
      .rejects.toMatchObject({ code: ErrorCode.CONFLICT_STALE_UPDATE });
    expect(await eventCount(seeded.id)).toBe(1);

    const missed = await occurrence();
    await service.execute(userId, command(missed));
    // A different command id for an already missed dose is stale, not a repeat.
    await expect(service.execute(userId, command(missed, { baseVersion: '1' })))
      .rejects.toMatchObject({ code: ErrorCode.CONFLICT_STALE_UPDATE });
    expect(await eventCount(missed.id)).toBe(1);
  });

  it.each([
    ['a future dose', () => occurrence({ plannedAt: new Date(Date.now() + 3 * HOUR_MS) })],
    ['a dose that only just became due', () => occurrence({ plannedAt: new Date(Date.now() - 10_000) })],
    ['an as-needed occurrence', () => occurrence({ source: 'prn', plannedAt: null })],
    ['an estimated legacy dose', () => occurrence({ provenance: 'legacy_estimated' })],
    ['a superseded dose', () => occurrence({ superseded: true })],
  ])('rejects a miss on %s with 422 MISS_NOT_ALLOWED', async (_name, make) => {
    const seeded = await make();
    await expect(service.execute(userId, command(seeded)))
      .rejects.toMatchObject({ statusCode: 422, code: ErrorCode.MISS_NOT_ALLOWED });
    expect(await eventCount(seeded.id)).toBe(0);
  });

  it('accepts a miss once the smallest delay (less the clock tolerance) has passed', async () => {
    const seeded = await occurrence({ plannedAt: new Date(Date.now() - 45_000) });
    await expect(service.execute(userId, command(seeded)))
      .resolves.toMatchObject({ action: 'miss', state: 'missed' });
  });

  it('accepts a late take and restores the unit and the missed state on undo', async () => {
    const seeded = await occurrence();
    const base = await stock();
    await service.execute(userId, command(seeded));
    const lateTake = await service.execute(userId, command(seeded, {
      action: 'take', baseVersion: '1', actualAt: new Date().toISOString(), actualTimeKnown: true,
    }));
    expect(lateTake).toMatchObject({ action: 'correct', state: 'taken', stateVersion: '2', inventoryDelta: -1 });
    expect(await stock()).toBe(base - 1);
    const [lateEvent] = await adminSql.unsafe<{ from_state: string; to_state: string }[]>(
      'SELECT from_state, to_state FROM occurrence_events WHERE id = $1', [lateTake['eventId']]);
    expect(lateEvent).toEqual({ from_state: 'missed', to_state: 'taken' });

    const undoLate = await service.execute(userId, command(seeded, {
      action: 'undo', baseVersion: '2', reversesEventId: lateTake['eventId'],
    }));
    expect(undoLate).toMatchObject({ action: 'undo', state: 'missed', stateVersion: '3', inventoryDelta: 1 });
    expect(await stock()).toBe(base);
  });

  it('undoes a miss back to pending while the miss is the head, and allows a fresh miss afterwards', async () => {
    const seeded = await occurrence();
    const base = await stock();
    const missResult = await service.execute(userId, command(seeded));
    const undoMiss = await service.execute(userId, command(seeded, {
      action: 'undo', baseVersion: '1', reversesEventId: missResult['eventId'],
    }));
    expect(undoMiss).toMatchObject({ action: 'undo', state: 'pending', stateVersion: '2', inventoryDelta: 0 });
    expect(await stock()).toBe(base);
    // The sweeper may record the dose as missed again at the new base version.
    await expect(service.execute(userId, command(seeded, { baseVersion: '2' })))
      .resolves.toMatchObject({ state: 'missed', stateVersion: '3' });
  });

  it('lets a person skip a missed dose with no stock effect', async () => {
    const seeded = await occurrence();
    const base = await stock();
    await service.execute(userId, command(seeded));
    const skipped = await service.execute(userId, command(seeded, { action: 'skip', baseVersion: '1' }));
    expect(skipped).toMatchObject({ action: 'correct', state: 'skipped', inventoryDelta: 0 });
    expect(await stock()).toBe(base);
  });

  it('refuses a correction that targets the missed state at the schema boundary', async () => {
    expect(() => command(occurrenceStub(), { action: 'correct', targetState: 'missed' })).toThrow();
  });

  it('keeps misses tenant-scoped: another user cannot miss this dose', async () => {
    const seeded = await occurrence();
    await expect(service.execute(otherUserId, command(seeded))).rejects.toMatchObject({
      code: ErrorCode.CONFLICT_REVISION,
    });
    expect(await eventCount(seeded.id)).toBe(0);
  });

  it('denies app_user a raw miss event row for another tenant and any update of a recorded miss', async () => {
    const mine = await occurrence();
    const theirs = await occurrence({ owner: otherUserId });
    await service.execute(userId, command(mine));
    const asUser = (owner: string, run: (tx: Sql) => Promise<unknown>) => appSql.begin(async (tx) => {
      await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [owner]);
      await run(tx as unknown as Sql);
    });
    // Tenant A's context cannot append an event to tenant B's occurrence.
    await expect(asUser(userId, (tx) => tx.unsafe(
      `INSERT INTO occurrence_events
         (id, user_id, occurrence_id, command_id, action, from_state, to_state, actual_time_known,
          origin, base_version, result_version, server_sequence)
       VALUES ($1, $2, $3, $4, 'miss', 'pending', 'missed', false, 'native', 0, 1, 987654322)`,
      [randomUUID(), otherUserId, theirs.id, randomUUID()],
    ))).rejects.toThrow();
    // The ledger is append-only: a recorded miss is never rewritten or removed.
    await expect(asUser(userId, (tx) => tx.unsafe(
      "UPDATE occurrence_events SET to_state = 'taken' WHERE occurrence_id = $1", [mine.id],
    ))).rejects.toThrow();
    await expect(asUser(userId, (tx) => tx.unsafe(
      'DELETE FROM occurrence_events WHERE occurrence_id = $1', [mine.id],
    ))).rejects.toThrow();
    expect(await eventCount(mine.id)).toBe(1);
    expect(await eventCount(theirs.id)).toBe(0);
  });

  it('refuses a direct occurrence_events insert of an unknown action or state', async () => {
    const seeded = await occurrence();
    const insert = (action: string, from: string, to: string) => adminSql.begin(async (tx) => {
      await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
      await tx.unsafe(
        `INSERT INTO occurrence_events
           (id, user_id, occurrence_id, command_id, action, from_state, to_state, actual_time_known,
            origin, base_version, result_version, server_sequence)
         VALUES ($1, $2, $3, $4, $5, $6, $7, false, 'native', 0, 1, 987654321)`,
        [randomUUID(), userId, seeded.id, randomUUID(), action, from, to],
      );
    });
    await expect(insert('foo', 'pending', 'missed')).rejects.toThrow(/occurrence_events_action_check/);
    await expect(insert('miss', 'pending', 'foo')).rejects.toThrow(/occurrence_events_to_state_check/);
    await expect(insert('miss', 'foo', 'missed')).rejects.toThrow(/occurrence_events_from_state_check/);
  });

  function occurrenceStub(): Seeded {
    return { id: randomUUID(), key: 'stub' };
  }
});
