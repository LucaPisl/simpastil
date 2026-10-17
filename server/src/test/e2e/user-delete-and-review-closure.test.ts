import { randomUUID } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PostgreSqlContainer, type StartedPostgreSqlContainer } from '@testcontainers/postgresql';
import { drizzle } from 'drizzle-orm/postgres-js';
import { migrate } from 'drizzle-orm/postgres-js/migrator';
import postgres, { type Sql } from 'postgres';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { runProvisionCommand } from '../../db/provision.js';

const migrationsFolder = join(dirname(fileURLToPath(import.meta.url)), '../../db/migrations');

/**
 * Two deployment-blocking defects found while activating stock sync:
 *  - DELETE /admin/users/:id returned 500 on a pre-activation database, because
 *    the cascaded delete of dose_logs/pills ran the handoff journal triggers
 *    for a tenant whose users row was already gone.
 *  - activate-ledger refused forever on a timezone review attached to a
 *    deleted routine, which the repair API cannot resolve.
 */
describe('user deletion and deleted-routine review closure', () => {
  let container: StartedPostgreSqlContainer;
  let sql: Sql;
  let appSql: Sql;

  async function asTenant(client: Sql, userId: string, run: (tx: Sql) => Promise<void>): Promise<void> {
    await client.begin(async (tx) => {
      await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
      await run(tx as unknown as Sql);
    });
  }

  /** A user with a tracked pill, an untracked pill, a schedule and dose logs. */
  async function seedUser(label: string): Promise<{ userId: string; profileId: string; scheduleId: string; pillId: string }> {
    const userId = randomUUID();
    const profileId = randomUUID();
    const pillId = randomUUID();
    const scheduleId = randomUUID();
    await sql.unsafe('INSERT INTO users (id, email, password_hash) VALUES ($1, $2, $3)',
      [userId, `${label}-${userId}@delete.invalid`, 'unused-test-hash']);
    await asTenant(sql, userId, async (tx) => {
      await tx.unsafe('INSERT INTO profiles (id, user_id, name) VALUES ($1, $2, $3)', [profileId, userId, label]);
      await tx.unsafe('INSERT INTO pills (id, profile_id, name, current_stock) VALUES ($1, $2, $3, 9)',
        [pillId, profileId, 'Tracked']);
      await tx.unsafe('INSERT INTO pills (id, profile_id, name, current_stock) VALUES ($1, $2, $3, NULL)',
        [randomUUID(), profileId, 'Untracked']);
      await tx.unsafe(
        `INSERT INTO schedules (id, pill_id, hour, minute, frequency, is_active, time_zone_status, time_zone)
         VALUES ($1, $2, 8, 0, 'daily', true, 'known', 'Europe/Bucharest')`, [scheduleId, pillId]);
      for (const day of ['2026-10-01', '2026-10-02']) {
        await tx.unsafe(
          `INSERT INTO dose_logs (id, schedule_id, scheduled_at, taken_at, status, updated_at)
           VALUES ($1, $2, $3, $3, 'taken', $3)`, [randomUUID(), scheduleId, `${day}T05:00:00.000Z`]);
      }
    });
    return { userId, profileId, scheduleId, pillId };
  }

  /** Exactly what AdminService.deleteUser runs, through the least-privilege runtime role. */
  async function deleteUserAsApp(userId: string): Promise<number> {
    let deleted = 0;
    await asTenant(appSql, userId, async (tx) => {
      deleted = (await tx.unsafe('DELETE FROM users WHERE id = $1 RETURNING id', [userId])).length;
    });
    return deleted;
  }

  const count = async (table: string, userId: string, column = 'user_id') =>
    (await sql.unsafe<{ n: number }[]>(`SELECT count(*)::int AS n FROM ${table} WHERE ${column} = $1`, [userId]))[0]!.n;

  /**
   * Seeds a legacy_unknown schedule with its unresolved timezone review the way
   * migration 0013 left it, optionally with the routine soft deleted afterwards.
   */
  async function seedTimezoneReview(userId: string, scheduleId: string, deletedRoutine: boolean): Promise<string> {
    const issueId = randomUUID();
    await asTenant(sql, userId, async (tx) => {
      await tx.unsafe(
        `INSERT INTO migration_issues (id, user_id, entity_type, entity_id, issue_code, safe_snapshot)
         SELECT $1, $2, 'schedules', s.id, 'schedule_timezone_review_required',
           public.schedule_legacy_source_snapshot(s.id, s.revision, s.frequency, s.frequency_days, s.is_active, s.deleted_at)
         FROM schedules s WHERE s.id = $3`, [issueId, userId, scheduleId]);
      await tx.unsafe(
        `UPDATE schedules SET time_zone_status = 'legacy_unknown', time_zone = NULL, timezone_review_issue_id = $1
         WHERE id = $2`, [issueId, scheduleId]);
      if (deletedRoutine) {
        await tx.unsafe('UPDATE schedules SET deleted_at = now() WHERE id = $1', [scheduleId]);
        await tx.unsafe('UPDATE pills SET deleted_at = now() WHERE id = (SELECT pill_id FROM schedules WHERE id = $1)', [scheduleId]);
      }
    });
    return issueId;
  }

  async function activate(): Promise<void> {
    vi.stubEnv('LEDGER_CURRENT_BUILD', '2');
    vi.stubEnv('LEDGER_CHANGE_REFERENCE', 'e2e-delete-and-review');
    await runProvisionCommand('activate-ledger');
  }

  beforeAll(async () => {
    container = await new PostgreSqlContainer(process.env['TEST_POSTGRES_IMAGE'] ??
      'docker.io/library/postgres:16.15-alpine3.24@sha256:3c5c8892d184f738f4fe282d14ddaa613a38f00f4189d2d94725ebe6f2909ddb').start();
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
  }, 240_000);

  afterAll(async () => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
    await appSql?.end();
    await sql?.end();
    await container?.stop();
  });

  const deletedRoutine = { userId: '', scheduleId: '', issueId: '' };
  const liveReview = { userId: '', scheduleId: '', issueId: '' };
  let keeper: Awaited<ReturnType<typeof seedUser>>;

  it('deletes a user with stocked pills and dose logs before ledger activation', async () => {
    keeper = await seedUser('keeper');
    const doomed = await seedUser('doomed');
    expect(await count('medication_handoff_journal', doomed.userId)).toBeGreaterThan(0);
    expect(await count('sync_stream_counters', doomed.userId)).toBe(1);

    expect(await deleteUserAsApp(doomed.userId)).toBe(1);

    expect(await count('users', doomed.userId, 'id')).toBe(0);
    expect(await count('profiles', doomed.userId)).toBe(0);
    expect(await count('medication_handoff_journal', doomed.userId)).toBe(0);
    expect(await count('sync_stream_counters', doomed.userId)).toBe(0);
    // Another tenant is untouched.
    expect(await count('medication_handoff_journal', keeper.userId)).toBeGreaterThan(0);
    expect(await count('dose_logs', keeper.scheduleId, 'schedule_id')).toBe(2);
  }, 60_000);

  it('still journals and still rejects a legitimate hard delete of an existing tenant\'s dose', async () => {
    const before = await count('medication_handoff_journal', keeper.userId);
    await asTenant(appSql, keeper.userId, async (tx) => {
      await tx.unsafe('DELETE FROM dose_logs WHERE schedule_id = $1', [keeper.scheduleId]);
    });
    expect(await count('medication_handoff_journal', keeper.userId)).toBe(before + 2);
  });

  it('blocks activation on a review for a live routine, and closes one for a deleted routine', async () => {
    const dead = await seedUser('dead-routine');
    deletedRoutine.userId = dead.userId;
    deletedRoutine.scheduleId = dead.scheduleId;
    deletedRoutine.issueId = await seedTimezoneReview(dead.userId, dead.scheduleId, true);
    const live = await seedUser('live-routine');
    liveReview.userId = live.userId;
    liveReview.scheduleId = live.scheduleId;
    liveReview.issueId = await seedTimezoneReview(live.userId, live.scheduleId, false);

    await expect(activate()).rejects.toThrow('ledger activation blocked by unresolved migration issues');
    // The refused activation rolled back, including the closure of the deleted routine's review.
    const [still] = await sql.unsafe<{ state: string }[]>(
      'SELECT state FROM migration_issues WHERE id = $1', [deletedRoutine.issueId]);
    expect(still?.state).toBe('unresolved');

    // Removing the live review's owner lets activation proceed.
    expect(await deleteUserAsApp(liveReview.userId)).toBe(1);
    await activate();

    const [issue] = await sql.unsafe<{ state: string; revision: string; resolved_by: string }[]>(
      'SELECT state, revision::text, resolved_by FROM migration_issues WHERE id = $1', [deletedRoutine.issueId]);
    expect(issue).toMatchObject({ state: 'resolved', revision: '2', resolved_by: deletedRoutine.userId });
    const [schedule] = await sql.unsafe<{ status: string; marker: string | null; deleted: boolean }[]>(
      `SELECT time_zone_status AS status, timezone_review_issue_id AS marker, deleted_at IS NOT NULL AS deleted
       FROM schedules WHERE id = $1`, [deletedRoutine.scheduleId]);
    expect(schedule).toEqual({ status: 'known', marker: null, deleted: true });
    const [manifest] = await sql.unsafe<{ ledger_activated: boolean }[]>(
      'SELECT ledger_activated FROM deployment_manifest WHERE singleton_key IS TRUE');
    expect(manifest?.ledger_activated).toBe(true);
  }, 120_000);

  it('deletes a user after ledger activation too', async () => {
    expect(await count('medication_handoff_journal', keeper.userId)).toBeGreaterThan(0);
    expect(await deleteUserAsApp(keeper.userId)).toBe(1);
    expect(await count('users', keeper.userId, 'id')).toBe(0);
    expect(await count('medication_handoff_journal', keeper.userId)).toBe(0);
    expect(await count('sync_stream_counters', keeper.userId)).toBe(0);
  }, 60_000);
});
