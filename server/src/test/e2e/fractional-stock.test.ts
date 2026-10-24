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
import { InventoryCommandSchema, MedicationCommandSchema } from '../../modules/medication/medication-command.schema.js';
import { BridgePrnCommandService } from '../../modules/medication/bridge-prn-command.service.js';
import { MedicationCommandService, inventoryFingerprints } from '../../modules/medication/medication-command.service.js';

const migrationsFolder = join(dirname(fileURLToPath(import.meta.url)), '../../db/migrations');
const HOUR_MS = 3_600_000;
const amount = (quantity: string, unit: string) => ({ version: 1 as const, state: 'known' as const, quantity, unit });

/**
 * Exact fractional stock against the real ledger: half-tablet takes, undo,
 * correction, review-needed amounts, automatic tablet adoption and the
 * account's minimum client build.
 */
describe('fractional stock commands', () => {
  let scratch: Awaited<ReturnType<typeof createIsolatedDatabase>>;
  let adminSql: Sql;
  let appSql: Sql;
  let service: MedicationCommandService;
  let prn: BridgePrnCommandService;
  const userId = randomUUID();
  let profileId: string;

  beforeAll(async () => {
    scratch = await createIsolatedDatabase('fractional_stock');
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
    prn = new BridgePrnCommandService(drizzle(appSql, { schema }) as unknown as Db);
    profileId = randomUUID();
    await adminSql.unsafe(
      'INSERT INTO users (id, email, password_hash) VALUES ($1, $2, $3)',
      [userId, `${userId}@fractional.invalid`, 'unused-test-hash'],
    );
    await adminSql.begin(async (tx) => {
      await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
      await tx.unsafe('INSERT INTO profiles (id, user_id, name) VALUES ($1, $2, $3)', [profileId, userId, 'Owner']);
    });
    await adminSql.unsafe(
      "SELECT set_deployment_authority(2, true, 1, 'ledger_activation', $1)",
      [`fractional-${userId}`],
    );
  }, 120_000);

  afterAll(async () => {
    await appSql?.end();
    await adminSql?.end();
    await scratch?.drop();
  });

  async function newPill(options: { amountPerUse?: object | null } = {}) {
    const pill = randomUUID();
    const schedule = randomUUID();
    await adminSql.begin(async (tx) => {
      await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
      await tx.unsafe(
        'INSERT INTO pills (id, profile_id, name, amount_per_use) VALUES ($1, $2, $3, $4::jsonb)',
        [pill, profileId, 'Half pill', options.amountPerUse ? JSON.stringify(options.amountPerUse) : null],
      );
      await tx.unsafe(
        `INSERT INTO schedules (id, pill_id, hour, minute, frequency, frequency_days, is_active, time_zone_status, time_zone)
         VALUES ($1, $2, 8, 0, 'daily', NULL, true, 'known', 'Europe/Bucharest')`,
        [schedule, pill],
      );
    });
    return { pill, schedule };
  }

  async function occurrence(pill: string, schedule: string) {
    const id = randomUUID();
    const key = `fractional-${id}`;
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
            version: 1, pillName: 'Half pill', dosage: null, frequency: 'daily', frequencyDays: null,
            hour: 8, minute: 0, timeZone: 'Europe/Bucharest', profileId, profileName: 'Owner',
          })],
      );
    });
    return { id, key };
  }

  const revision = async (pill: string) => (await adminSql.unsafe<{ revision: string }[]>(
    'SELECT revision::text AS revision FROM pills WHERE id = $1', [pill]))[0]!.revision;
  const pillRow = async (pill: string) => (await adminSql.unsafe<{ current_stock: string | null; stock_unit: string | null }[]>(
    'SELECT current_stock::text, stock_unit FROM pills WHERE id = $1', [pill]))[0]!;
  const floorOf = async () => (await adminSql.unsafe<{ minimum_client_build: number }[]>(
    'SELECT minimum_client_build FROM users WHERE id = $1', [userId]))[0]!.minimum_client_build;
  const eventCount = async (pill: string) => (await adminSql.unsafe<{ count: number }[]>(
    'SELECT count(*)::int AS count FROM inventory_events WHERE pill_id = $1', [pill]))[0]!.count;

  async function startStock(pill: string, fields: Record<string, unknown>) {
    return service.executeInventory(userId, InventoryCommandSchema.parse({
      action: 'start', commandId: randomUUID(), pillId: pill, baseRevision: await revision(pill), note: null, ...fields,
    }));
  }

  function takeCommand(seeded: { id: string; key: string }, extra: Record<string, unknown> = {}) {
    return MedicationCommandSchema.parse({
      commandId: randomUUID(), occurrenceId: seeded.id, occurrenceKey: seeded.key, baseVersion: '0',
      action: 'take', rebasesCommandId: null, actualAt: null, actualTimeKnown: false, note: null, ...extra,
    });
  }

  it('starts exact stock in a unit, subtracts half a tablet, and undo gives it back', async () => {
    const { pill, schedule } = await newPill();
    const started = await startStock(pill, { initialQuantity: '10.5', stockUnit: 'tablet' });
    expect(started).toMatchObject({ currentStock: 10, currentStockQuantity: '10.5', stockUnit: 'tablet' });
    expect(await pillRow(pill)).toEqual({ current_stock: '10.500000', stock_unit: 'tablet' });
    expect(await floorOf()).toBeGreaterThanOrEqual(8);

    const seeded = await occurrence(pill, schedule);
    const take = await service.execute(userId, takeCommand(seeded, { administrationAmount: amount('1/2', 'tablet') }));
    expect(take).toMatchObject({
      state: 'taken', stockEffect: 'applied', inventoryQuantityDelta: '-0.5', currentStockQuantity: '10', currentStock: 10,
    });
    expect((await pillRow(pill)).current_stock).toBe('10.000000');

    const undo = await service.execute(userId, MedicationCommandSchema.parse({
      commandId: randomUUID(), occurrenceId: seeded.id, occurrenceKey: seeded.key, baseVersion: String(take['stateVersion']),
      action: 'undo', reversesEventId: take['eventId'], rebasesCommandId: null, actualAt: null, actualTimeKnown: false, note: null,
    }));
    expect(undo).toMatchObject({ state: 'pending', stockEffect: 'applied', inventoryQuantityDelta: '0.5', currentStockQuantity: '10.5' });
  });

  it('lets exact stock go below zero without blocking the dose', async () => {
    const { pill, schedule } = await newPill();
    await startStock(pill, { initialQuantity: '0.25', stockUnit: 'tablet' });
    const take = await service.execute(userId, takeCommand(await occurrence(pill, schedule), {
      administrationAmount: amount('1/2', 'tablet'),
    }));
    expect(take).toMatchObject({ state: 'taken', currentStockQuantity: '-0.25', currentStock: -1 });
  });

  it('records a third of a tablet as taken but sends the stock to review', async () => {
    const { pill, schedule } = await newPill();
    await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
    const before = await eventCount(pill);
    const take = await service.execute(userId, takeCommand(await occurrence(pill, schedule), {
      administrationAmount: amount('1/3', 'tablet'),
    }));
    expect(take).toMatchObject({ state: 'taken', stockEffect: 'needs_review', inventoryEventId: null, currentStockQuantity: '10' });
    expect(await eventCount(pill)).toBe(before);
  });

  describe('stock needs a recount', () => {
    const flag = async (pill: string) => (await adminSql.unsafe<{ f: boolean }[]>(
      'SELECT stock_needs_recount AS f FROM pills WHERE id = $1', [pill]))[0]!.f;
    const pillChanges = async (pill: string) => (await adminSql.unsafe<{ payload: Record<string, unknown> }[]>(
      "SELECT payload FROM sync_changes WHERE entity_type = 'pill' AND entity_id = $1 ORDER BY server_sequence", [pill])).map((r) => r.payload['payload'] as Record<string, unknown>);

    async function flagged() {
      const { pill, schedule } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      const rev = await revision(pill);
      await service.execute(userId, takeCommand(await occurrence(pill, schedule), {
        administrationAmount: amount('1/3', 'tablet'),
      }));
      return { pill, schedule, rev };
    }

    it('marks the pill, bumps its revision and syncs the mark', async () => {
      const { pill, rev } = await flagged();
      expect(await flag(pill)).toBe(true);
      expect(BigInt(await revision(pill))).toBeGreaterThan(BigInt(rev));
      expect((await pillChanges(pill)).at(-1)).toMatchObject({ stockNeedsRecount: true });
    });

    it('leaves an exact take and a plain pill unmarked, and omits the field', async () => {
      const { pill, schedule } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      await service.execute(userId, takeCommand(await occurrence(pill, schedule), {
        administrationAmount: amount('1/2', 'tablet'),
      }));
      expect(await flag(pill)).toBe(false);
      for (const change of await pillChanges(pill)) expect(change).not.toHaveProperty('stockNeedsRecount');
    });

    async function takeThird(pill: string, schedule: string) {
      const seeded = await occurrence(pill, schedule);
      const take = await service.execute(userId, takeCommand(seeded, { administrationAmount: amount('1/3', 'tablet') }));
      return { seeded, take };
    }
    const undoOf = (seeded: { id: string; key: string }, take: Record<string, unknown>) =>
      service.execute(userId, MedicationCommandSchema.parse({
        commandId: randomUUID(), occurrenceId: seeded.id, occurrenceKey: seeded.key, baseVersion: String(take['stateVersion']),
        action: 'undo', reversesEventId: take['eventId'], rebasesCommandId: null, actualAt: null, actualTimeKnown: false, note: null,
      }));

    it('is cleared on every device when the only uncountable dose is undone', async () => {
      const { pill, schedule } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      const { seeded, take } = await takeThird(pill, schedule);
      expect(await flag(pill)).toBe(true);
      const revisionBefore = BigInt(await revision(pill));
      const changesBefore = (await pillChanges(pill)).length;

      await undoOf(seeded, take);

      expect(await flag(pill)).toBe(false);
      expect(BigInt(await revision(pill))).toBeGreaterThan(revisionBefore);
      const changes = await pillChanges(pill);
      expect(changes.length).toBe(changesBefore + 1);
      expect(changes.at(-1)).not.toHaveProperty('stockNeedsRecount');
      expect(changes.at(-1)).toMatchObject({ revision: await revision(pill) });
    });

    it('is cleared when the only uncountable dose is corrected to skipped', async () => {
      const { pill, schedule } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      const { seeded, take } = await takeThird(pill, schedule);
      await service.execute(userId, MedicationCommandSchema.parse({
        commandId: randomUUID(), occurrenceId: seeded.id, occurrenceKey: seeded.key, baseVersion: String(take['stateVersion']),
        action: 'correct', targetState: 'skipped', rebasesCommandId: null, actualAt: null, actualTimeKnown: false, note: null,
      }));
      expect(await flag(pill)).toBe(false);
      expect((await pillChanges(pill)).at(-1)).not.toHaveProperty('stockNeedsRecount');
    });

    it('stays while another uncountable dose is still taken', async () => {
      const { pill, schedule } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      const first = await takeThird(pill, schedule);
      await takeThird(pill, schedule);
      const revisionBefore = await revision(pill);
      await undoOf(first.seeded, first.take);
      expect(await flag(pill)).toBe(true);
      expect(await revision(pill)).toBe(revisionBefore);
    });

    it('is cleared by a count that confirms the same number, without a ledger event', async () => {
      const { pill } = await flagged();
      const before = await eventCount(pill);
      const result = await service.executeInventory(userId, InventoryCommandSchema.parse({
        action: 'correct', commandId: randomUUID(), pillId: pill, baseRevision: await revision(pill),
        targetQuantity: '10', stockUnit: 'tablet', note: null,
      }));
      expect(result).toMatchObject({ currentStockQuantity: '10', inventoryEventId: null });
      expect(await flag(pill)).toBe(false);
      expect(await eventCount(pill)).toBe(before);
      expect((await pillChanges(pill)).at(-1)).not.toHaveProperty('stockNeedsRecount');
    });

    const pause = () => new Promise((resolve) => setTimeout(resolve, 15));
    const sameNumberCount = async (pill: string) => service.executeInventory(userId, InventoryCommandSchema.parse({
      action: 'correct', commandId: randomUUID(), pillId: pill, baseRevision: await revision(pill),
      targetQuantity: '10', stockUnit: 'tablet', note: null,
    }));

    it('lets a count that confirmed the same number settle the doses before it for a later undo', async () => {
      const { pill, schedule } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      await pause();
      await takeThird(pill, schedule); // flagged dose A
      await pause();
      await sameNumberCount(pill);
      expect(await flag(pill)).toBe(false);
      await pause();
      const b = await takeThird(pill, schedule); // flagged dose B
      expect(await flag(pill)).toBe(true);
      await undoOf(b.seeded, b.take);
      // A was counted by the confirmed number, so B was the only open dose.
      expect(await flag(pill)).toBe(false);
    });

    it('keeps the mark on an undo while an earlier flagged dose is still open', async () => {
      const { pill, schedule } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      await pause();
      const a = await takeThird(pill, schedule);
      await pause();
      const b = await takeThird(pill, schedule);
      await undoOf(b.seeded, b.take);
      expect(await flag(pill)).toBe(true);
      await undoOf(a.seeded, a.take);
      expect(await flag(pill)).toBe(false);
    });

    it('records the count time without bumping the pill revision when nothing else changed', async () => {
      const { pill } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      const before = await revision(pill);
      const changes = (await pillChanges(pill)).length;
      await sameNumberCount(pill);
      expect(await revision(pill)).toBe(before);
      expect((await pillChanges(pill)).length).toBe(changes);
      const [row] = await adminSql.unsafe<{ at: Date | null }[]>('SELECT stock_counted_at AS at FROM pills WHERE id = $1', [pill]);
      expect(row!.at).not.toBeNull();
    });

    it('does not move updated_at for a count that changed nothing, but does for a real change', async () => {
      const { pill } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      const updatedAt = async () => Number((await adminSql.unsafe<{ at: string }[]>(
        'SELECT extract(epoch FROM updated_at)::text AS at FROM pills WHERE id = $1', [pill]))[0]!.at);
      const before = await updatedAt();
      await pause();
      await sameNumberCount(pill);
      expect(await updatedAt()).toBe(before);
      await pause();
      await service.executeInventory(userId, InventoryCommandSchema.parse({
        action: 'correct', commandId: randomUUID(), pillId: pill, baseRevision: await revision(pill),
        targetQuantity: '9', stockUnit: 'tablet', note: null,
      }));
      expect(await updatedAt()).toBeGreaterThan(before);
    });

    it('records the time of a start, so a dose recorded before it never reads as open', async () => {
      const { pill } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      const [row] = await adminSql.unsafe<{ at: Date | null }[]>('SELECT stock_counted_at AS at FROM pills WHERE id = $1', [pill]);
      expect(row!.at).not.toBeNull();
    });

    it('falls back to the ledger count when stock_counted_at is empty (a row from before the column)', async () => {
      const { pill, schedule } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      await pause();
      await takeThird(pill, schedule); // flagged dose A
      await pause();
      // A count that changes the number writes a ledger correction event.
      await service.executeInventory(userId, InventoryCommandSchema.parse({
        action: 'correct', commandId: randomUUID(), pillId: pill, baseRevision: await revision(pill),
        targetQuantity: '9', stockUnit: 'tablet', note: null,
      }));
      await adminSql.unsafe('UPDATE pills SET stock_counted_at = NULL WHERE id = $1', [pill]);
      await pause();
      const b = await takeThird(pill, schedule); // flagged dose B
      expect(await flag(pill)).toBe(true);
      await undoOf(b.seeded, b.take);
      // Only the ledger event dates the count now, and it settled dose A.
      expect(await flag(pill)).toBe(false);
    });

    it('replays an undo that cleared the mark without touching the pill again', async () => {
      const { pill, schedule } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      const { seeded, take } = await takeThird(pill, schedule);
      const command = MedicationCommandSchema.parse({
        commandId: randomUUID(), occurrenceId: seeded.id, occurrenceKey: seeded.key, baseVersion: String(take['stateVersion']),
        action: 'undo', reversesEventId: take['eventId'], rebasesCommandId: null, actualAt: null, actualTimeKnown: false, note: null,
      });
      const first = await service.execute(userId, command);
      expect(await flag(pill)).toBe(false);
      const revisionAfter = await revision(pill);
      const changesAfter = (await pillChanges(pill)).length;
      expect(await service.execute(userId, command)).toEqual(first);
      expect(await flag(pill)).toBe(false);
      expect(await revision(pill)).toBe(revisionAfter);
      expect((await pillChanges(pill)).length).toBe(changesAfter);
    });

    it('keeps the mark when a flagged taken dose is corrected to taken again, and clears it for pending', async () => {
      const { pill, schedule } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      const { seeded, take } = await takeThird(pill, schedule);
      const correct = async (targetState: string, base: unknown) => service.execute(userId, MedicationCommandSchema.parse({
        commandId: randomUUID(), occurrenceId: seeded.id, occurrenceKey: seeded.key, baseVersion: String(base),
        action: 'correct', targetState, rebasesCommandId: null, actualAt: null, actualTimeKnown: false, note: null,
        administrationAmount: amount('1/3', 'tablet'),
      }));
      const again = await correct('taken', take['stateVersion']);
      expect(await flag(pill)).toBe(true);
      // A taken dose can never be corrected into a miss.
      await expect(correct('missed', again['stateVersion'])).rejects.toBeDefined();
      expect(await flag(pill)).toBe(true);
      await correct('pending', again['stateVersion']);
      expect(await flag(pill)).toBe(false);
    });

    it('is cleared by a count that changes the number, and kept by a refill', async () => {
      const { pill } = await flagged();
      await service.executeInventory(userId, InventoryCommandSchema.parse({
        action: 'refill', commandId: randomUUID(), pillId: pill, baseRevision: await revision(pill),
        refillQuantity: '1', note: null,
      }));
      expect(await flag(pill)).toBe(true);
      await service.executeInventory(userId, InventoryCommandSchema.parse({
        action: 'correct', commandId: randomUUID(), pillId: pill, baseRevision: await revision(pill),
        targetQuantity: '8', stockUnit: 'tablet', note: null,
      }));
      expect(await flag(pill)).toBe(false);
    });
  });

  it('does not conflict a refill on a stale base revision, but keeps start and correct strict', async () => {
    const { pill } = await newPill();
    await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
    const stale = await revision(pill);
    // Another device changes the pill, so the base revision above is now stale.
    await adminSql.begin(async (tx) => {
      await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
      await tx.unsafe('UPDATE pills SET name = $2, revision = revision + 1, last_mutation_id = $3 WHERE id = $1', [pill, 'Renamed', randomUUID()]);
    });
    expect(await revision(pill)).not.toBe(stale);
    const refilled = await service.executeInventory(userId, InventoryCommandSchema.parse({
      action: 'refill', commandId: randomUUID(), pillId: pill, baseRevision: stale, refillQuantity: '5', note: null,
    }));
    expect(refilled).toMatchObject({ currentStockQuantity: '15' });
    await expect(service.executeInventory(userId, InventoryCommandSchema.parse({
      action: 'correct', commandId: randomUUID(), pillId: pill, baseRevision: stale,
      targetQuantity: '3', stockUnit: 'tablet', note: null,
    }))).rejects.toMatchObject({ code: ErrorCode.CONFLICT_STALE_UPDATE });
  });

  describe('a refill', () => {
    const refillCommand = async (pill: string, extra: Record<string, unknown> = {}) => InventoryCommandSchema.parse({
      action: 'refill', commandId: randomUUID(), pillId: pill, baseRevision: await revision(pill),
      refillQuantity: '5', note: null, ...extra,
    });
    const bumpRevision = (pill: string) => adminSql.begin(async (tx) => {
      await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
      await tx.unsafe('UPDATE pills SET name = $2, revision = revision + 1, last_mutation_id = $3 WHERE id = $1', [pill, 'Renamed', randomUUID()]);
    });

    it('replays as the same command when only its base revision differs, and adds the stock once', async () => {
      const { pill } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      const command = await refillCommand(pill);
      const first = await service.executeInventory(userId, command);
      await bumpRevision(pill);
      const replay = await service.executeInventory(userId, InventoryCommandSchema.parse({ ...command, baseRevision: await revision(pill) }));
      expect(replay).toEqual(first);
      expect((await pillRow(pill)).current_stock).toBe('15.000000');
      expect(await eventCount(pill)).toBe(2);
    });

    it('still refuses a reused command id with another quantity', async () => {
      const { pill } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      const command = await refillCommand(pill);
      await service.executeInventory(userId, command);
      await expect(service.executeInventory(userId, InventoryCommandSchema.parse({ ...command, refillQuantity: '6' })))
        .rejects.toMatchObject({ code: ErrorCode.CONFLICT_MUTATION_REUSE });
    });

    it('still keys the fingerprint of a count and a start on the base revision', () => {
      const count = InventoryCommandSchema.parse({
        action: 'correct', commandId: randomUUID(), pillId: randomUUID(), baseRevision: '3',
        targetQuantity: '8', stockUnit: 'tablet', note: null,
      });
      const other = InventoryCommandSchema.parse({ ...count, baseRevision: '4' });
      expect(inventoryFingerprints(count).inputFingerprint).not.toBe(inventoryFingerprints(other).inputFingerprint);
      const refill = InventoryCommandSchema.parse({
        action: 'refill', commandId: randomUUID(), pillId: randomUUID(), baseRevision: '3', refillQuantity: '1', note: null,
      });
      const refillOther = InventoryCommandSchema.parse({ ...refill, baseRevision: '9' });
      expect(inventoryFingerprints(refill).inputFingerprint).toBe(inventoryFingerprints(refillOther).inputFingerprint);
      // A receipt stored before the base was left out still replays.
      expect(inventoryFingerprints(refill).alsoAccepted).toHaveLength(1);
    });

    it('adds to a pill flagged for a recount and keeps the mark', async () => {
      const { pill, schedule } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      await service.execute(userId, takeCommand(await occurrence(pill, schedule), { administrationAmount: amount('1/3', 'tablet') }));
      const stale = await revision(pill);
      await bumpRevision(pill);
      const result = await service.executeInventory(userId, await refillCommand(pill, { baseRevision: stale, refillQuantity: '2' }));
      expect(result).toMatchObject({ currentStockQuantity: '12' });
      const [row] = await adminSql.unsafe<{ f: boolean }[]>('SELECT stock_needs_recount AS f FROM pills WHERE id = $1', [pill]);
      expect(row!.f).toBe(true);
    });

    it('racing a count lands one way or the other and leaves the stock equal to the ledger', async () => {
      const { pill } = await newPill();
      await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
      const refill = await refillCommand(pill);
      const count = InventoryCommandSchema.parse({
        action: 'correct', commandId: randomUUID(), pillId: pill, baseRevision: await revision(pill),
        targetQuantity: '4', stockUnit: 'tablet', note: null,
      });
      const [a, b] = await Promise.allSettled([
        service.executeInventory(userId, refill),
        service.executeInventory(userId, count),
      ]);
      expect(a.status).toBe('fulfilled');
      // The count either ran first, or lost its base revision to the refill.
      if (b.status === 'rejected') expect(b.reason).toMatchObject({ code: ErrorCode.CONFLICT_STALE_UPDATE });
      const [ledger] = await adminSql.unsafe<{ sum: string }[]>(
        'SELECT sum(delta)::text AS sum FROM inventory_events WHERE pill_id = $1', [pill]);
      expect(Number((await pillRow(pill)).current_stock)).toBe(Number(ledger!.sum));
      expect(Number(ledger!.sum)).toBe(b.status === 'fulfilled' ? 9 : 15);
    });
  });

  it('sends a dose in another unit to review', async () => {
    const { pill, schedule } = await newPill();
    await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
    const take = await service.execute(userId, takeCommand(await occurrence(pill, schedule), {
      administrationAmount: amount('5', 'ml'),
    }));
    expect(take).toMatchObject({ state: 'taken', stockEffect: 'needs_review', currentStockQuantity: '10' });
  });

  it('credits exactly what a taken dose consumed when it is corrected out of taken', async () => {
    const { pill, schedule } = await newPill();
    await startStock(pill, { initialQuantity: '10', stockUnit: 'tablet' });
    const seeded = await occurrence(pill, schedule);
    const take = await service.execute(userId, takeCommand(seeded, { administrationAmount: amount('3/2', 'tablet') }));
    expect(take).toMatchObject({ currentStockQuantity: '8.5' });
    const skip = await service.execute(userId, MedicationCommandSchema.parse({
      commandId: randomUUID(), occurrenceId: seeded.id, occurrenceKey: seeded.key, baseVersion: String(take['stateVersion']),
      action: 'correct', targetState: 'skipped', rebasesCommandId: null, actualAt: null, actualTimeKnown: false, note: null,
    }));
    expect(skip).toMatchObject({ state: 'skipped', stockEffect: 'applied', inventoryQuantityDelta: '1.5', currentStockQuantity: '10' });
  });

  it('replays an identical command and rejects a reused command id with other input', async () => {
    const { pill, schedule } = await newPill();
    await startStock(pill, { initialQuantity: '4', stockUnit: 'tablet' });
    const command = takeCommand(await occurrence(pill, schedule), { administrationAmount: amount('1/2', 'tablet') });
    const first = await service.execute(userId, command);
    expect(await service.execute(userId, command)).toEqual(first);
    expect((await pillRow(pill)).current_stock).toBe('3.500000');
    await expect(service.execute(userId, { ...command, administrationAmount: amount('1', 'tablet') }))
      .rejects.toMatchObject({ code: ErrorCode.CONFLICT_MUTATION_REUSE });
  });

  it('corrects to an exact target and refills by an exact quantity', async () => {
    const { pill } = await newPill();
    await startStock(pill, { initialQuantity: '2', stockUnit: 'tablet' });
    const corrected = await service.executeInventory(userId, InventoryCommandSchema.parse({
      action: 'correct', commandId: randomUUID(), pillId: pill, baseRevision: await revision(pill),
      targetQuantity: '7.25', stockUnit: 'tablet', note: null,
    }));
    expect(corrected).toMatchObject({ currentStockQuantity: '7.25' });
    const refilled = await service.executeInventory(userId, InventoryCommandSchema.parse({
      action: 'refill', commandId: randomUUID(), pillId: pill, baseRevision: await revision(pill),
      refillQuantity: '0.5', note: null,
    }));
    expect(refilled).toMatchObject({ currentStockQuantity: '7.75' });
  });

  describe('automatic unit adoption', () => {
    it('gives a whole tablet count the tablet unit on the first dose of a build that sends amounts', async () => {
      const { pill, schedule } = await newPill({ amountPerUse: amount('1', 'tablet') });
      await startStock(pill, { initialStock: 10 });
      expect(await pillRow(pill)).toEqual({ current_stock: '10.000000', stock_unit: null });

      const take = await service.execute(userId, takeCommand(await occurrence(pill, schedule), {
        administrationAmount: amount('1/2', 'tablet'),
      }));
      expect(take).toMatchObject({ stockEffect: 'applied', stockUnit: 'tablet', currentStockQuantity: '9.5' });
      expect(await pillRow(pill)).toEqual({ current_stock: '9.500000', stock_unit: 'tablet' });
      expect(await floorOf()).toBeGreaterThanOrEqual(8);

      // Idempotent: the unit is already set, so the next dose just subtracts.
      const again = await service.execute(userId, takeCommand(await occurrence(pill, schedule), {
        administrationAmount: amount('1/2', 'tablet'),
      }));
      expect(again).toMatchObject({ currentStockQuantity: '9' });
      expect((await pillRow(pill)).stock_unit).toBe('tablet');
    });

    it('keeps the plain count when an older build sends no amount', async () => {
      const { pill, schedule } = await newPill({ amountPerUse: amount('1', 'tablet') });
      await startStock(pill, { initialStock: 10 });
      const take = await service.execute(userId, takeCommand(await occurrence(pill, schedule)));
      expect(take).toMatchObject({ currentStock: 9 });
      expect(take).not.toHaveProperty('stockUnit');
      expect(await pillRow(pill)).toEqual({ current_stock: '9.000000', stock_unit: null });
    });

    it('does not adopt a unit that is not countable, and still takes one off', async () => {
      const { pill, schedule } = await newPill({ amountPerUse: amount('5', 'ml') });
      await startStock(pill, { initialStock: 10 });
      const take = await service.execute(userId, takeCommand(await occurrence(pill, schedule), {
        administrationAmount: amount('5', 'ml'),
      }));
      expect(take).toMatchObject({ currentStock: 9 });
      expect((await pillRow(pill)).stock_unit).toBeNull();
    });

    it('does not adopt when the dose names another unit than the reviewed amount', async () => {
      const { pill, schedule } = await newPill({ amountPerUse: amount('1', 'tablet') });
      await startStock(pill, { initialStock: 10 });
      await service.execute(userId, takeCommand(await occurrence(pill, schedule), {
        administrationAmount: amount('1', 'capsule'),
      }));
      expect((await pillRow(pill)).stock_unit).toBeNull();
    });
  });

  describe('as-needed doses', () => {
    async function prnPill(amountPerUse: object | null) {
      const pill = randomUUID();
      const schedule = randomUUID();
      await adminSql.begin(async (tx) => {
        await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
        await tx.unsafe(
          'INSERT INTO pills (id, profile_id, name, is_prn, amount_per_use) VALUES ($1, $2, $3, true, $4::jsonb)',
          [pill, profileId, 'PRN pill', amountPerUse ? JSON.stringify(amountPerUse) : null],
        );
        await tx.unsafe(
          `INSERT INTO schedules (id, pill_id, hour, minute, frequency, frequency_days, is_active, time_zone_status, time_zone)
           VALUES ($1, $2, 0, 0, 'prn', NULL, true, 'known', 'Europe/Bucharest')`,
          [schedule, pill],
        );
      });
      return { pill, schedule };
    }
    const prnTake = (pill: string, schedule: string, quantity: string) => {
      const occurrenceId = randomUUID();
      return {
        operation: 'take' as const, commandId: randomUUID(), eventId: randomUUID(), occurrenceId,
        occurrenceKey: `prn:v1:${occurrenceId}`, profileId, pillId: pill, scheduleId: schedule, scheduleRevision: '1',
        plannedLocalDate: '2026-10-16', timeZone: 'Europe/Bucharest', actualAt: null, actualTimeKnown: false,
        amount: amount(quantity, 'tablet'), note: null,
      };
    };

    it('subtracts half a tablet from unit stock and undo gives it back', async () => {
      const { pill, schedule } = await prnPill(null);
      await startStock(pill, { initialQuantity: '3', stockUnit: 'tablet' });
      const take = prnTake(pill, schedule, '1/2');
      const taken = await prn.execute(userId, take, 8);
      expect(taken).toMatchObject({ stockEffect: 'applied', inventoryQuantityDelta: '-0.5', currentStockQuantity: '2.5' });
      const undone = await prn.execute(userId, {
        operation: 'undo' as const, commandId: randomUUID(), eventId: randomUUID(), occurrenceId: take.occurrenceId,
        occurrenceKey: take.occurrenceKey, baseVersion: '1', reversesEventId: take.eventId, note: null,
      }, 8);
      expect(undone).toMatchObject({ stockEffect: 'applied', inventoryQuantityDelta: '0.5', currentStockQuantity: '3' });
    });

    it('clears the recount mark when an as-needed undo removes the only uncountable dose', async () => {
      const { pill, schedule } = await prnPill(null);
      await startStock(pill, { initialQuantity: '3', stockUnit: 'tablet' });
      const take = prnTake(pill, schedule, '1/3');
      await prn.execute(userId, take, 8);
      const flagOf = async () => (await adminSql.unsafe<{ f: boolean }[]>(
        'SELECT stock_needs_recount AS f FROM pills WHERE id = $1', [pill]))[0]!.f;
      expect(await flagOf()).toBe(true);
      await prn.execute(userId, {
        operation: 'undo' as const, commandId: randomUUID(), eventId: randomUUID(), occurrenceId: take.occurrenceId,
        occurrenceKey: take.occurrenceKey, baseVersion: '1', reversesEventId: take.eventId, note: null,
      }, 8);
      expect(await flagOf()).toBe(false);
    });

    it('adopts the tablet unit only for a build that understands units', async () => {
      const { pill, schedule } = await prnPill(amount('1', 'tablet'));
      await startStock(pill, { initialStock: 5 });
      await prn.execute(userId, prnTake(pill, schedule, '1/2'), 7);
      expect(await pillRow(pill)).toEqual({ current_stock: '4.000000', stock_unit: null });
      const taken = await prn.execute(userId, prnTake(pill, schedule, '1/2'), 8);
      expect(taken).toMatchObject({ stockUnit: 'tablet', currentStockQuantity: '3.5' });
    });
  });
});
