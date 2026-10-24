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
import { BridgePrnCommandService } from '../../modules/medication/bridge-prn-command.service.js';
import { ComponentSyncService } from '../../modules/sync/component-sync.service.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const migrationsFolder = join(__dirname, '../../db/migrations');

describe('inactive-ledger exact PRN commands', () => {
  let scratch: Awaited<ReturnType<typeof createIsolatedDatabase>>;
  let adminSql: Sql;
  let appSql: Sql;
  let service: BridgePrnCommandService;
  let sync: ComponentSyncService;

  beforeAll(async () => {
    scratch = await createIsolatedDatabase('bridge_prn');
    adminSql = postgres(scratch.superUri, { max: 4 });
    await migrate(drizzle(adminSql), { migrationsFolder });
    await adminSql.unsafe("ALTER ROLE app_user PASSWORD 'testpass'");
    const databaseName = scratch.name.replaceAll('"', '""');
    await adminSql.unsafe(`GRANT CONNECT ON DATABASE "${databaseName}" TO app_user`);
    const appUrl = new URL(scratch.superUri);
    appUrl.username = 'app_user';
    appUrl.password = 'testpass';
    appSql = postgres(appUrl.toString(), { max: 4 });
    service = new BridgePrnCommandService(drizzle(appSql, { schema }) as unknown as Db);
    sync = new ComponentSyncService(
      drizzle(appSql, { schema }) as unknown as Db,
      'bridge-prn-test-cursor-secret-at-least-32-bytes',
    );
  }, 120_000);

  afterAll(async () => {
    await appSql?.end();
    await adminSql?.end();
    await scratch?.drop();
  });

  it.each([
    { label: 'unknown amount and time', amount: { version: 1 as const, state: 'unknown' as const }, actualAt: null, actualTimeKnown: false },
    { label: 'reviewed half tablet', amount: { version: 1 as const, state: 'known' as const, quantity: '1/2', unit: 'tablet' }, actualAt: '2026-10-06T08:15:12.345Z', actualTimeKnown: true },
  ])('creates, replays, publishes, and exactly undoes $label without inventory', async ({ amount, actualAt, actualTimeKnown }) => {
    const userId = randomUUID();
    const profileId = randomUUID();
    const pillId = randomUUID();
    const scheduleId = randomUUID();
    await seedPrn({ userId, profileId, pillId, scheduleId, stock: 17 });
    const occurrenceId = randomUUID();
    const eventId = randomUUID();
    const commandId = randomUUID();
    const take = {
      operation: 'take' as const,
      commandId,
      eventId,
      occurrenceId,
      occurrenceKey: `prn:v1:${occurrenceId}`,
      profileId,
      pillId,
      scheduleId,
      scheduleRevision: '1',
      plannedLocalDate: '2026-10-06',
      timeZone: 'Europe/Bucharest',
      actualAt,
      actualTimeKnown,
      amount,
      note: 'Fictional PRN care',
    };
    const result = await service.execute(userId, take);
    expect(result).toMatchObject({ commandId, occurrenceId, eventId, state: 'taken', stateVersion: '1', amount });
    expect(await service.execute(userId, take)).toEqual(result);
    await expect(service.execute(userId, { ...take, note: 'different' })).rejects.toMatchObject({ code: 'CONFLICT_MUTATION_REUSE' });
    for (const contractVersion of [1, 2, 3, 4]) {
      const oldView = await sync.read(userId, { component: 'medicationBridge', contractVersion });
      expect(oldView.items.map((item) => item.change.payload).filter(
        (payload) => payload.kind === 'medicationOccurrence' || payload.kind === 'occurrenceEvent',
      )).toHaveLength(0);
    }
    const prnView = await sync.read(userId, { component: 'medicationBridge', contractVersion: 5 });
    expect(prnView.items.map((item) => item.change.payload)).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: 'medicationOccurrence', id: occurrenceId, source: 'prn' }),
      expect.objectContaining({ kind: 'occurrenceEvent', id: eventId, administrationAmount: amount }),
    ]));
    expect(prnView.items.filter((item) => {
      const payload = item.change.payload;
      return (payload.kind === 'medicationOccurrence' && payload.id === occurrenceId)
        || (payload.kind === 'occurrenceEvent' && payload.occurrenceId === occurrenceId);
    })).toHaveLength(2);

    const [stored] = await adminSql.unsafe<{
      source: string; expected: boolean; state_version: string; administration_amount: unknown;
      event_count: number; inventory_count: number; current_stock: number;
    }[]>(`SELECT o.source, o.expected, o.state_version::text, e.administration_amount,
                  (SELECT count(*)::int FROM occurrence_events x WHERE x.occurrence_id=o.id) AS event_count,
                  (SELECT count(*)::int FROM inventory_events i WHERE i.occurrence_event_id=e.id) AS inventory_count,
                  p.current_stock::int AS current_stock
           FROM medication_occurrences o
           JOIN occurrence_events e ON e.occurrence_id=o.id
           JOIN pills p ON p.id=o.pill_id
           WHERE o.id=$1 AND e.id=$2`, [occurrenceId, eventId]);
    expect(stored).toMatchObject({ source: 'prn', expected: false, state_version: '1', administration_amount: amount, event_count: 1, inventory_count: 0, current_stock: 17 });

    const repeatOccurrenceId = randomUUID();
    const repeat = await service.execute(userId, {
      ...take,
      commandId: randomUUID(),
      eventId: randomUUID(),
      occurrenceId: repeatOccurrenceId,
      occurrenceKey: `prn:v1:${repeatOccurrenceId}`,
    });
    expect(repeat).toMatchObject({ occurrenceId: repeatOccurrenceId, state: 'taken' });
    const [sameDay] = await adminSql.unsafe<{ count: number }[]>(
      `SELECT count(*)::int AS count FROM medication_occurrences
       WHERE user_id=$1 AND schedule_id=$2 AND planned_local_date='2026-10-06' AND source='prn'`,
      [userId, scheduleId],
    );
    expect(sameDay?.count).toBe(2);

    const undoEventId = randomUUID();
    const undoCommandId = randomUUID();
    const undo = {
      operation: 'undo' as const,
      commandId: undoCommandId,
      eventId: undoEventId,
      occurrenceId,
      occurrenceKey: `prn:v1:${occurrenceId}`,
      baseVersion: '1',
      reversesEventId: eventId,
      note: null,
    };
    const undoResult = await service.execute(userId, undo);
    expect(undoResult).toMatchObject({ commandId: undoCommandId, eventId: undoEventId, state: 'pending', stateVersion: '2', amount: null });
    expect(await service.execute(userId, undo)).toEqual(undoResult);
    const delta = await sync.read(userId, {
      component: 'medicationBridge', contractVersion: 5,
      afterSequence: prnView.throughSequence,
    });
    expect(delta.items.map((item) => item.change.payload)).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: 'medicationOccurrence', id: occurrenceId, stateVersion: '2' }),
      expect.objectContaining({ kind: 'occurrenceEvent', id: undoEventId, administrationAmount: null }),
    ]));
    const [after] = await adminSql.unsafe<{ state_version: string; events: number; inventory: number; current_stock: number }[]>(
      `SELECT o.state_version::text, count(DISTINCT e.id)::int AS events,
              count(DISTINCT i.id)::int AS inventory, max(p.current_stock)::int AS current_stock
       FROM medication_occurrences o JOIN occurrence_events e ON e.occurrence_id=o.id
       JOIN pills p ON p.id=o.pill_id LEFT JOIN inventory_events i ON i.occurrence_event_id=e.id
       WHERE o.id=$1 GROUP BY o.state_version`, [occurrenceId],
    );
    expect(after).toEqual({ state_version: '2', events: 2, inventory: 0, current_stock: 17 });
  });

  it('refuses foreign, non-PRN, mismatched, and stale commands without partial care', async () => {
    const ownerId = randomUUID();
    const attackerId = randomUUID();
    const profileId = randomUUID();
    const pillId = randomUUID();
    const scheduleId = randomUUID();
    await seedPrn({ userId: ownerId, profileId, pillId, scheduleId, stock: null });
    await adminSql.unsafe('INSERT INTO users (id, email, password_hash) VALUES ($1,$2,$3)', [attackerId, `${attackerId}@prn.invalid`, 'unused']);
    const occurrenceId = randomUUID();
    const command = {
      operation: 'take' as const, commandId: randomUUID(), eventId: randomUUID(), occurrenceId,
      occurrenceKey: `prn:v1:${occurrenceId}`, profileId, pillId, scheduleId, scheduleRevision: '1',
      plannedLocalDate: '2026-10-06', timeZone: 'Europe/Bucharest', actualAt: null,
      actualTimeKnown: false, amount: { version: 1 as const, state: 'unknown' as const }, note: null,
    };
    await expect(service.execute(attackerId, command)).rejects.toMatchObject({ statusCode: 404 });
    await expect(service.execute(ownerId, { ...command, commandId: randomUUID(), scheduleRevision: '2' })).rejects.toMatchObject({ code: 'CONFLICT_STALE_UPDATE' });
    await adminSql.begin(async (tx) => {
      await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [ownerId]);
      await tx.unsafe(`INSERT INTO schedules
        (id,pill_id,hour,minute,frequency,frequency_days,is_active,time_zone_status,time_zone)
        VALUES ($1,$2,0,0,'prn',NULL,true,'known','Europe/Bucharest')`, [randomUUID(), pillId]);
    });
    await expect(service.execute(ownerId, { ...command, commandId: randomUUID(), eventId: randomUUID() }))
      .rejects.toMatchObject({ code: 'CONFLICT_REVISION' });
    const [counts] = await adminSql.unsafe<{ occurrences: number; events: number; receipts: number }[]>(
      `SELECT (SELECT count(*)::int FROM medication_occurrences WHERE id=$1) AS occurrences,
              (SELECT count(*)::int FROM occurrence_events WHERE occurrence_id=$1) AS events,
              (SELECT count(*)::int FROM medication_command_receipts WHERE command_id=$2) AS receipts`,
      [occurrenceId, command.commandId],
    );
    expect(counts).toEqual({ occurrences: 0, events: 0, receipts: 0 });
  });

  it.each([
    { version: 1, state: 'known', unit: 'tablet' },
    { version: 1, state: 'known', quantity: '' },
    { version: 1, state: 'known', quantity: '1/2' },
    { version: '1', state: 'known', quantity: '1/2', unit: 'tablet' },
  ])('rejects malformed known administration amount at the database boundary: %j', async (amount) => {
    const userId = randomUUID();
    const profileId = randomUUID();
    const pillId = randomUUID();
    const scheduleId = randomUUID();
    const occurrenceId = randomUUID();
    await seedPrn({ userId, profileId, pillId, scheduleId, stock: null });
    await service.execute(userId, {
      operation: 'take',
      commandId: randomUUID(),
      eventId: randomUUID(),
      occurrenceId,
      occurrenceKey: `prn:v1:${occurrenceId}`,
      profileId,
      pillId,
      scheduleId,
      scheduleRevision: '1',
      plannedLocalDate: '2026-10-06',
      timeZone: 'Europe/Bucharest',
      actualAt: null,
      actualTimeKnown: false,
      amount: { version: 1, state: 'unknown' },
      note: null,
    });

    await expect(appSql.begin(async (tx) => {
      await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
      await tx.unsafe(
        `INSERT INTO occurrence_events
          (id,user_id,occurrence_id,command_id,action,from_state,to_state,
           actual_time_known,administration_amount,origin,base_version,result_version,server_sequence)
         VALUES ($1,$2,$3,$4,'take',$5,$5,false,$6::jsonb,'native',1,2,$7)`,
        [randomUUID(), userId, occurrenceId, randomUUID(), 'taken', JSON.stringify(amount), 9_000_000 + Math.floor(Math.random() * 1_000_000)],
      );
    })).rejects.toThrow(/occurrence_events_amount_check/);

    const [stored] = await adminSql.unsafe<{ source: string; provenance: string; expected: boolean; state_version: string; count: number }[]>(
      `SELECT o.source, o.provenance, o.expected, o.state_version::text,
              count(e.id)::int AS count
         FROM medication_occurrences o JOIN occurrence_events e ON e.occurrence_id=o.id
        WHERE o.id=$1 GROUP BY o.source,o.provenance,o.expected,o.state_version`,
      [occurrenceId],
    );
    expect(stored).toEqual({ source: 'prn', provenance: 'exact', expected: false, state_version: '1', count: 1 });
  });

  async function seedPrn(input: { userId: string; profileId: string; pillId: string; scheduleId: string; stock: number | null }) {
    await adminSql.unsafe('INSERT INTO users (id, email, password_hash) VALUES ($1,$2,$3)', [input.userId, `${input.userId}@prn.invalid`, 'unused']);
    await adminSql.begin(async (tx) => {
      await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [input.userId]);
      await tx.unsafe('INSERT INTO profiles (id,user_id,name) VALUES ($1,$2,$3)', [input.profileId, input.userId, 'Fictional owner']);
      await tx.unsafe('INSERT INTO pills (id,profile_id,name,is_prn,current_stock) VALUES ($1,$2,$3,true,$4)', [input.pillId, input.profileId, 'Fictional PRN', input.stock]);
      await tx.unsafe(`INSERT INTO schedules
        (id,pill_id,hour,minute,frequency,frequency_days,is_active,time_zone_status,time_zone)
        VALUES ($1,$2,0,0,'prn',NULL,true,'known','Europe/Bucharest')`, [input.scheduleId, input.pillId]);
    });
  }
});
