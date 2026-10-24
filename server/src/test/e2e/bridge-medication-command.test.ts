import { createHash, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { drizzle } from 'drizzle-orm/postgres-js';
import { migrate } from 'drizzle-orm/postgres-js/migrator';
import postgres, { type Sql } from 'postgres';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createIsolatedDatabase } from '../helpers/db-helpers.js';
import type { Db } from '../../db/client.js';
import * as schema from '../../db/schema.js';
import { canonicalJson } from '../../modules/sync/sync-payload.js';
import { BridgeMedicationCommandService } from '../../modules/medication/bridge-medication-command.service.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const migrationsFolder = join(__dirname, '../../db/migrations');

describe('inactive-ledger medication bridge commands', () => {
  let scratch: Awaited<ReturnType<typeof createIsolatedDatabase>>;
  let adminSql: Sql;
  let appSql: Sql;
  let service: BridgeMedicationCommandService;

  beforeAll(async () => {
    scratch = await createIsolatedDatabase('bridge_command');
    adminSql = postgres(scratch.superUri, { max: 4 });
    await migrate(drizzle(adminSql), { migrationsFolder });
    await adminSql.unsafe("ALTER ROLE app_user PASSWORD 'testpass'");
    const databaseName = scratch.name.replaceAll('"', '""');
    await adminSql.unsafe(`GRANT CONNECT ON DATABASE "${databaseName}" TO app_user`);
    const appUrl = new URL(scratch.superUri);
    appUrl.username = 'app_user';
    appUrl.password = 'testpass';
    appSql = postgres(appUrl.toString(), { max: 4 });
    service = new BridgeMedicationCommandService(
      drizzle(appSql, { schema }) as unknown as Db,
    );
  }, 120_000);

  afterAll(async () => {
    await appSql?.end();
    await adminSql?.end();
    await scratch?.drop();
  });

  for (const initialStock of [4, null]) {
    it(`publishes a migrated scheduled dose with ${initialStock === null ? 'untracked' : 'tracked'} stock as app_user`, async () => {
      const userId = randomUUID();
      const profileId = randomUUID();
      const pillId = randomUUID();
      const scheduleId = randomUUID();
      const doseId = randomUUID();
      const scheduledAt = new Date('2026-10-06T05:30:00.000Z');
      await adminSql.unsafe(
        'INSERT INTO users (id, email, password_hash) VALUES ($1, $2, $3)',
        [userId, `${userId}@bridge.invalid`, 'unused-test-hash'],
      );
      await adminSql.begin(async (tx) => {
        await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
        await tx.unsafe(
          'INSERT INTO profiles (id, user_id, name) VALUES ($1, $2, $3)',
          [profileId, userId, 'Migrated owner'],
        );
        await tx.unsafe(
          'INSERT INTO pills (id, profile_id, name, current_stock) VALUES ($1, $2, $3, $4)',
          [pillId, profileId, 'Migrated medicine', initialStock],
        );
        await tx.unsafe(
          `INSERT INTO schedules
             (id, pill_id, hour, minute, frequency, frequency_days, is_active,
              time_zone_status, time_zone)
           VALUES ($1, $2, 8, 30, 'daily', NULL, true, 'known', 'Europe/Bucharest')`,
          [scheduleId, pillId],
        );
        await tx.unsafe(
          `INSERT INTO dose_logs
             (id, schedule_id, scheduled_at, taken_at, status, updated_at)
           VALUES ($1, $2, $3, NULL, 'missed', $4)`,
          [doseId, scheduleId, scheduledAt.toISOString(), '2026-10-06T05:31:00.123Z'],
        );
      });

      const commandId = randomUUID();
      const commandBundleId = randomUUID();
      const result = await service.execute(userId, {
        commandId,
        commandBundleId,
        transactionCorrelationId: randomUUID(),
        pillId,
        scheduleId,
        legacyDoseId: doseId,
        allowCreate: false,
        scheduledAt: scheduledAt.toISOString(),
        status: 'taken',
        takenAt: '2026-10-06T05:32:00.456Z',
        note: 'Fictional care',
        observedBaseDoseFingerprint: null,
        observedBaseStock: initialStock,
        observedBasePillRevision: initialStock === null ? null : '1',
      });

      expect(result).toMatchObject({
        commandId,
        doseLogId: doseId,
        status: 'taken',
        currentStock: initialStock === null ? null : 3,
        inventoryTracked: initialStock !== null,
        inventoryDelta: initialStock === null ? null : -1,
      });
      const [dose] = await adminSql.unsafe<{
        status: string;
        note: string | null;
        exact_taken_at: boolean;
      }[]>(
        'SELECT status, note, taken_at = $2::timestamptz AS exact_taken_at FROM dose_logs WHERE id=$1',
        [doseId, '2026-10-06T05:32:00.456Z'],
      );
      expect(dose).toMatchObject({
        status: 'taken',
        note: 'Fictional care',
        exact_taken_at: true,
      });
      const [receipt] = await adminSql.unsafe<{
        complete: boolean;
        source_fingerprint: string;
        expected_subeffect_count: number;
        observed_subeffect_count: number;
      }[]>(
        `SELECT complete, source_fingerprint, expected_subeffect_count,
                observed_subeffect_count
         FROM preactivation_medication_receipts
         WHERE user_id=$1 AND command_id=$2`,
        [userId, commandId],
      );
      const expectedSubeffects = initialStock === null ? 1 : 2;
      expect(receipt).toMatchObject({
        complete: true,
        source_fingerprint: expect.stringMatching(/^[a-f0-9]{64}$/),
        expected_subeffect_count: expectedSubeffects,
        observed_subeffect_count: expectedSubeffects,
      });
      const [journal] = await adminSql.unsafe<{ count: number }[]>(
        `SELECT count(*)::int AS count FROM medication_handoff_journal
         WHERE user_id=$1 AND command_bundle_id=$2`,
        [userId, commandBundleId],
      );
      expect(journal?.count).toBe(expectedSubeffects);
    });
  }

  async function seedTracked(stock: number | null, slots: Date[]) {
    const userId = randomUUID();
    const profileId = randomUUID();
    const pillId = randomUUID();
    const scheduleId = randomUUID();
    await adminSql.unsafe(
      'INSERT INTO users (id, email, password_hash) VALUES ($1, $2, $3)',
      [userId, `${userId}@bridge.invalid`, 'unused-test-hash'],
    );
    await adminSql.begin(async (tx) => {
      await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
      await tx.unsafe('INSERT INTO profiles (id, user_id, name) VALUES ($1, $2, $3)', [profileId, userId, 'Owner']);
      await tx.unsafe(
        'INSERT INTO pills (id, profile_id, name, current_stock) VALUES ($1, $2, $3, $4)',
        [pillId, profileId, 'Tracked', stock],
      );
      await tx.unsafe(
        `INSERT INTO schedules
           (id, pill_id, hour, minute, frequency, frequency_days, is_active, time_zone_status, time_zone)
         VALUES ($1, $2, 8, 30, 'daily', NULL, true, 'known', 'Europe/Bucharest')`,
        [scheduleId, pillId],
      );
    });
    void slots;
    return { userId, pillId, scheduleId };
  }

  function command(
    base: { pillId: string; scheduleId: string },
    over: Record<string, unknown>,
  ) {
    return {
      commandId: randomUUID(),
      commandBundleId: randomUUID(),
      transactionCorrelationId: randomUUID(),
      pillId: base.pillId,
      scheduleId: base.scheduleId,
      legacyDoseId: randomUUID(),
      allowCreate: true,
      scheduledAt: '2026-10-07T05:30:00.000Z',
      status: 'taken',
      takenAt: '2026-10-07T05:31:00.000Z',
      observedBaseDoseFingerprint: null,
      observedBaseStock: null,
      observedBasePillRevision: null,
      ...over,
    } as Parameters<BridgeMedicationCommandService['execute']>[1];
  }

  it('take, undo (pending), retake on a tracked pill: stock 4, 3, 4, 3 with a dose tombstone', async () => {
    const base = await seedTracked(4, []);
    const doseA = randomUUID();
    const doseB = randomUUID();
    const take = command(base, { legacyDoseId: doseA });
    const undo = command(base, {
      legacyDoseId: doseA, allowCreate: false, status: 'pending', takenAt: null,
    });
    const retake = command(base, { legacyDoseId: doseB });

    const r1 = await service.execute(base.userId, take);
    expect(r1).toMatchObject({ status: 'taken', currentStock: 3, inventoryDelta: -1, pillRevision: '2' });
    const r2 = await service.execute(base.userId, undo);
    expect(r2).toMatchObject({ status: 'pending', doseLogId: doseA, currentStock: 4, inventoryDelta: 1, pillRevision: '3' });
    const r3 = await service.execute(base.userId, retake);
    expect(r3).toMatchObject({ status: 'taken', doseLogId: doseB, currentStock: 3, inventoryDelta: -1 });

    // Replays return the stored results without side effects.
    expect(await service.execute(base.userId, take)).toEqual(r1);
    expect(await service.execute(base.userId, undo)).toEqual(r2);
    expect(await service.execute(base.userId, retake)).toEqual(r3);

    const rows = await adminSql.unsafe<{ id: string; deleted: boolean }[]>(
      'SELECT id, deleted_at IS NOT NULL AS deleted FROM dose_logs WHERE schedule_id=$1 ORDER BY created_at',
      [base.scheduleId],
    );
    expect(rows).toHaveLength(2);
    expect(rows.find((r) => r.id === doseA)?.deleted).toBe(true);
    expect(rows.find((r) => r.id === doseB)?.deleted).toBe(false);
    const [pill] = await adminSql.unsafe<{ current_stock: number }[]>(
      'SELECT current_stock::int AS current_stock FROM pills WHERE id=$1', [base.pillId]);
    expect(pill?.current_stock).toBe(3);

    const receipts = await adminSql.unsafe<{ expected_subeffect_count: number; observed_subeffect_count: number }[]>(
      `SELECT expected_subeffect_count, observed_subeffect_count FROM preactivation_medication_receipts
       WHERE user_id=$1 ORDER BY completed_at`, [base.userId]);
    expect(receipts).toHaveLength(3);
    for (const receipt of receipts) {
      expect(receipt.observed_subeffect_count).toBe(receipt.expected_subeffect_count);
      expect(receipt.expected_subeffect_count).toBe(2);
    }
    const changes = await adminSql.unsafe<{ entity_type: string; entity_id: string; operation: string }[]>(
      `SELECT entity_type, entity_id, operation FROM sync_changes
       WHERE user_id=$1 AND component='medicationBridge' AND entity_type='bridge_dose'
       ORDER BY server_sequence`, [base.userId]);
    expect(changes.filter((c) => c.entity_id === doseA).map((c) => c.operation))
      .toEqual(['upsert', 'tombstone']);
    expect(changes.filter((c) => c.entity_id === doseB).map((c) => c.operation)).toEqual(['upsert']);
  });

  it('pending adds nothing for a skipped dose and 404s for a missing dose', async () => {
    const base = await seedTracked(4, []);
    const doseId = randomUUID();
    await service.execute(base.userId, command(base, { legacyDoseId: doseId, status: 'skipped', takenAt: null }));
    const undo = await service.execute(base.userId, command(base, {
      legacyDoseId: doseId, allowCreate: false, status: 'pending', takenAt: null,
    }));
    expect(undo).toMatchObject({ status: 'pending', currentStock: 4, inventoryDelta: 0 });
    await expect(service.execute(base.userId, command(base, {
      legacyDoseId: randomUUID(), allowCreate: false, status: 'pending', takenAt: null,
    }))).rejects.toMatchObject({ statusCode: 404 });
  });

  it('keeps refusing to restore a deleted dose by id', async () => {
    const base = await seedTracked(4, []);
    const doseId = randomUUID();
    await service.execute(base.userId, command(base, { legacyDoseId: doseId }));
    await service.execute(base.userId, command(base, {
      legacyDoseId: doseId, allowCreate: false, status: 'pending', takenAt: null,
    }));
    await expect(service.execute(base.userId, command(base, {
      legacyDoseId: doseId, allowCreate: false, status: 'taken',
    }))).rejects.toThrow(/cannot be silently restored/);
  });

  it('applies two sequential takes on different slots with a null observed base', async () => {
    const base = await seedTracked(4, []);
    const a = await service.execute(base.userId, command(base, { scheduledAt: '2026-10-07T05:30:00.000Z' }));
    const b = await service.execute(base.userId, command(base, { scheduledAt: '2026-10-08T05:30:00.000Z' }));
    expect(a).toMatchObject({ currentStock: 3 });
    expect(b).toMatchObject({ currentStock: 2, pillRevision: '3' });
  });
  describe('observedBaseDoseFingerprint precision', () => {
    type DoseRow = { id: string; schedule_id: string; scheduled_at: Date; taken_at: Date | null; status: string };
    const sha = (value: unknown) => createHash('sha256').update(canonicalJson(value), 'utf8').digest('hex');
    const wholeSecond = (d: Date | null) => (d ? new Date(Math.floor(d.getTime() / 1000) * 1000).toISOString() : null);
    const form = (row: DoseRow, iso: (d: Date | null) => string | null) => sha({
      id: row.id,
      scheduleId: row.schedule_id,
      scheduledAt: iso(row.scheduled_at),
      takenAt: iso(row.taken_at),
      status: row.status,
      deletedAt: null,
    });

    it('matches the shared contract fixture', () => {
      const fixture = JSON.parse(readFileSync(
        join(__dirname, '../../../../contracts/fixtures/bridge-dose-fingerprint-v1.json'), 'utf8')) as {
        dose: { id: string; scheduleId: string; scheduledAt: string; takenAt: string; status: string; deletedAt: null };
        wholeSecondFingerprint: string;
        exactFingerprint: string;
      };
      const d = fixture.dose;
      expect(sha({ ...d, scheduledAt: wholeSecond(new Date(d.scheduledAt)), takenAt: wholeSecond(new Date(d.takenAt)) }))
        .toBe(fixture.wholeSecondFingerprint);
      expect(sha(d)).toBe(fixture.exactFingerprint);
    });

    async function takeWithMilliseconds() {
      const base = await seedTracked(4, []);
      const legacyDoseId = randomUUID();
      await service.execute(base.userId, command(base, { legacyDoseId, takenAt: '2026-10-07T05:31:12.456Z' }));
      const [raw] = await adminSql.unsafe<{ id: string; schedule_id: string; scheduled_at: string | Date; taken_at: string | Date; status: string }[]>(
        'SELECT id, schedule_id, scheduled_at, taken_at, status FROM dose_logs WHERE id=$1', [legacyDoseId]);
      const row: DoseRow = {
        id: raw!.id,
        schedule_id: raw!.schedule_id,
        scheduled_at: new Date(raw!.scheduled_at),
        taken_at: new Date(raw!.taken_at),
        status: raw!.status,
      };
      expect(row.taken_at?.getUTCMilliseconds()).toBe(456);
      return { base, legacyDoseId, row };
    }

    it('undo succeeds with the second-truncated fingerprint a shipped client sends', async () => {
      const { base, legacyDoseId, row } = await takeWithMilliseconds();
      const result = await service.execute(base.userId, command(base, {
        legacyDoseId, allowCreate: false, status: 'pending', takenAt: null,
        observedBaseDoseFingerprint: form(row, wholeSecond),
      }));
      expect(result).toMatchObject({ status: 'pending', currentStock: 4 });
    });

    it('undo still succeeds with the exact-millisecond fingerprint', async () => {
      const { base, legacyDoseId, row } = await takeWithMilliseconds();
      const result = await service.execute(base.userId, command(base, {
        legacyDoseId, allowCreate: false, status: 'pending', takenAt: null,
        observedBaseDoseFingerprint: form(row, (d) => d?.toISOString() ?? null),
      }));
      expect(result).toMatchObject({ status: 'pending', currentStock: 4 });
    });

    it('a mismatched fingerprint is still a 409 stale update', async () => {
      const { base, legacyDoseId, row } = await takeWithMilliseconds();
      const other = new Date(row.taken_at!.getTime() + 2000);
      await expect(service.execute(base.userId, command(base, {
        legacyDoseId, allowCreate: false, status: 'pending', takenAt: null,
        observedBaseDoseFingerprint: form({ ...row, taken_at: other }, wholeSecond),
      }))).rejects.toMatchObject({ code: 'CONFLICT_STALE_UPDATE' });
      await expect(service.execute(base.userId, command(base, {
        legacyDoseId, allowCreate: false, status: 'pending', takenAt: null,
        observedBaseDoseFingerprint: 'a'.repeat(64),
      }))).rejects.toMatchObject({ code: 'CONFLICT_STALE_UPDATE' });
    });
  });
});
