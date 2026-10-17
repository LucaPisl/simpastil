/**
 * RLS (Row-Level Security) integration tests.
 *
 * These tests verify that PostgreSQL's RLS policies correctly isolate each
 * user's data. They connect as the least-privilege 'app_user' role (which
 * has RLS enforced) and simulate authenticated requests by setting the
 * 'app.current_user_id' session variable inside a transaction.
 *
 * Required environment variables:
 *   DATABASE_URL_SUPER  — superuser connection (bypasses RLS for test setup)
 *   DATABASE_URL_APP    — app_user connection  (RLS fully enforced)
 *
 * The test database must have the migration and RLS policies applied before
 * running these tests.
 */

import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import postgres from 'postgres';

// ---------------------------------------------------------------------------
// Fixed UUIDs for deterministic test data — easy to spot in pg logs
// ---------------------------------------------------------------------------

const USER_A = '00000000-0000-0000-0000-000000000aa1';
const USER_B = '00000000-0000-0000-0000-000000000bb2';

const PROFILE_A = '00000000-0000-0000-0001-000000000aa1';
const PROFILE_B = '00000000-0000-0000-0001-000000000bb2';

const PILL_A = '00000000-0000-0000-0002-000000000aa1';
const PILL_B = '00000000-0000-0000-0002-000000000bb2';

const SCHEDULE_A = '00000000-0000-0000-0003-000000000aa1';
const SCHEDULE_B = '00000000-0000-0000-0003-000000000bb2';

const DOSE_LOG_A = '00000000-0000-0000-0004-000000000aa1';
const DOSE_LOG_B = '00000000-0000-0000-0004-000000000bb2';

// ---------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------

let superSql: postgres.Sql;  // bypasses RLS — used only for setup/teardown
let appSql: postgres.Sql;    // app_user role — RLS enforced

beforeAll(async () => {
  const superUrl = process.env['DATABASE_URL_SUPER'];
  const appUrl = process.env['DATABASE_URL_APP'];

  if (!superUrl || !appUrl) {
    throw new Error(
      'DATABASE_URL_SUPER and DATABASE_URL_APP must be set to run RLS tests.',
    );
  }

  superSql = postgres(superUrl, { max: 2 });
  appSql = postgres(appUrl, { max: 2 });

  // Seed test data via superuser connection (bypasses RLS).
  await superSql`
    INSERT INTO users (id, email, password_hash) VALUES
      (${USER_A}, 'user-a@rls-test.example', 'argon2id-placeholder-a'),
      (${USER_B}, 'user-b@rls-test.example', 'argon2id-placeholder-b')
    ON CONFLICT (id) DO NOTHING
  `;

  await superSql`
    INSERT INTO profiles (id, user_id, name) VALUES
      (${PROFILE_A}, ${USER_A}, 'Profile A'),
      (${PROFILE_B}, ${USER_B}, 'Profile B')
    ON CONFLICT (id) DO NOTHING
  `;

  await superSql.begin(async (tx) => {
    await tx`SELECT set_config('app.current_user_id', ${USER_A}, true)`;
    await tx`INSERT INTO pills (id, profile_id, name) VALUES (${PILL_A}, ${PROFILE_A}, 'Pill A') ON CONFLICT (id) DO NOTHING`;
  });
  await superSql.begin(async (tx) => {
    await tx`SELECT set_config('app.current_user_id', ${USER_B}, true)`;
    await tx`INSERT INTO pills (id, profile_id, name) VALUES (${PILL_B}, ${PROFILE_B}, 'Pill B') ON CONFLICT (id) DO NOTHING`;
  });

  await superSql.begin(async (tx) => {
    await tx`SELECT set_config('app.current_user_id', ${USER_A}, true)`;
    await tx`INSERT INTO schedules (id, pill_id, hour, minute, frequency, time_zone) VALUES (${SCHEDULE_A}, ${PILL_A}, 8, 0, 'daily', 'UTC') ON CONFLICT (id) DO NOTHING`;
  });
  await superSql.begin(async (tx) => {
    await tx`SELECT set_config('app.current_user_id', ${USER_B}, true)`;
    await tx`INSERT INTO schedules (id, pill_id, hour, minute, frequency, time_zone) VALUES (${SCHEDULE_B}, ${PILL_B}, 9, 0, 'daily', 'UTC') ON CONFLICT (id) DO NOTHING`;
  });

  await superSql.begin(async (tx) => {
    await tx`SELECT set_config('app.current_user_id', ${USER_A}, true)`;
    await tx`INSERT INTO dose_logs (id, schedule_id, scheduled_at, status) VALUES (${DOSE_LOG_A}, ${SCHEDULE_A}, now(), 'taken') ON CONFLICT (id) DO NOTHING`;
  });
  await superSql.begin(async (tx) => {
    await tx`SELECT set_config('app.current_user_id', ${USER_B}, true)`;
    await tx`INSERT INTO dose_logs (id, schedule_id, scheduled_at, status) VALUES (${DOSE_LOG_B}, ${SCHEDULE_B}, now(), 'taken') ON CONFLICT (id) DO NOTHING`;
  });
});

afterAll(async () => {
  // The shared test database is disposable; deleting revisioned fixtures
  // would append immutable sync publications during teardown.
  await superSql.end();
  await appSql.end();
});

// ---------------------------------------------------------------------------
// Helper: run a callback inside a transaction with RLS set to a given user
// ---------------------------------------------------------------------------

function asUser<T>(
  userId: string,
  fn: (sql: postgres.TransactionSql) => Promise<T>,
): Promise<T> {
  return appSql.begin(async (tx) => {
    await tx`SELECT set_config('app.current_user_id', ${userId}, true)`;
    return fn(tx);
  });
}

// ---------------------------------------------------------------------------
// users table
// ---------------------------------------------------------------------------

describe('users — RLS isolation', () => {
  // SELECT on users is intentionally open: the app_user role must be able to
  // SELECT any user row to look up credentials by email during login. RLS on
  // SELECT for users is therefore not applied — the application layer is
  // responsible for only reading the rows it needs.
  it('app_user can select any user row (open SELECT policy — required for login)', async () => {
    const rows = await asUser(USER_B, (tx) => tx`SELECT id FROM users WHERE id = ${USER_A}`);
    expect(rows).toHaveLength(1); // user B can see user A — intentional, trusted app pattern
  });

  it('user A cannot update user B row', async () => {
    await expect(
      asUser(
        USER_A,
        (tx) =>
          tx`UPDATE users SET email = 'hacked@evil.example' WHERE id = ${USER_B}`,
      ),
    ).resolves.toHaveLength(0); // 0 rows updated — RLS silently filters target row
  });
});

// ---------------------------------------------------------------------------
// profiles table
// ---------------------------------------------------------------------------

describe('profiles — RLS isolation', () => {
  it('user A sees only their own profiles', async () => {
    const rows = await asUser(USER_A, (tx) => tx`SELECT id FROM profiles`);
    expect(rows.every((r) => r.id === PROFILE_A)).toBe(true);
    expect(rows.map((r) => r.id)).not.toContain(PROFILE_B);
  });

  it('user B sees only their own profiles', async () => {
    const rows = await asUser(USER_B, (tx) => tx`SELECT id FROM profiles`);
    expect(rows.every((r) => r.id === PROFILE_B)).toBe(true);
    expect(rows.map((r) => r.id)).not.toContain(PROFILE_A);
  });

  it('user A cannot insert a profile owned by user B', async () => {
    await expect(
      asUser(USER_A, (tx) =>
        tx`
          INSERT INTO profiles (user_id, name)
          VALUES (${USER_B}, 'Injected profile')
        `,
      ),
    ).rejects.toThrow(); // violates WITH CHECK policy
  });
});

// ---------------------------------------------------------------------------
// pills table
// ---------------------------------------------------------------------------

describe('pills — RLS isolation (via profile)', () => {
  it('user A sees only their own pills', async () => {
    const rows = await asUser(USER_A, (tx) => tx`SELECT id FROM pills`);
    expect(rows.map((r) => r.id)).toContain(PILL_A);
    expect(rows.map((r) => r.id)).not.toContain(PILL_B);
  });

  it('user B sees only their own pills', async () => {
    const rows = await asUser(USER_B, (tx) => tx`SELECT id FROM pills`);
    expect(rows.map((r) => r.id)).toContain(PILL_B);
    expect(rows.map((r) => r.id)).not.toContain(PILL_A);
  });

  it('user A cannot insert a pill into user B profile', async () => {
    await expect(
      asUser(USER_A, (tx) =>
        tx`INSERT INTO pills (profile_id, name) VALUES (${PROFILE_B}, 'Stolen pill')`,
      ),
    ).rejects.toThrow();
  });

  it('user A cannot delete user B pill', async () => {
    const result = await asUser(
      USER_A,
      (tx) => tx`DELETE FROM pills WHERE id = ${PILL_B}`,
    );
    expect(result).toHaveLength(0); // 0 rows deleted
  });
});

// ---------------------------------------------------------------------------
// schedules table
// ---------------------------------------------------------------------------

describe('schedules — RLS isolation (via pill → profile)', () => {
  it('user A sees only their own schedules', async () => {
    const rows = await asUser(USER_A, (tx) => tx`SELECT id FROM schedules`);
    expect(rows.map((r) => r.id)).toContain(SCHEDULE_A);
    expect(rows.map((r) => r.id)).not.toContain(SCHEDULE_B);
  });

  it('user B cannot read user A schedule by ID', async () => {
    const rows = await asUser(
      USER_B,
      (tx) => tx`SELECT id FROM schedules WHERE id = ${SCHEDULE_A}`,
    );
    expect(rows).toHaveLength(0);
  });

  it('user A cannot insert a schedule for user B pill', async () => {
    await expect(
      asUser(USER_A, (tx) =>
        tx`
          INSERT INTO schedules (pill_id, hour, minute, frequency)
          VALUES (${PILL_B}, 10, 0, 'daily')
        `,
      ),
    ).rejects.toThrow();
  });
});

// ---------------------------------------------------------------------------
// dose_logs table
// ---------------------------------------------------------------------------

describe('dose_logs — RLS isolation (via schedule → pill → profile)', () => {
  it('user A sees only their own dose logs', async () => {
    const rows = await asUser(USER_A, (tx) => tx`SELECT id FROM dose_logs`);
    expect(rows.map((r) => r.id)).toContain(DOSE_LOG_A);
    expect(rows.map((r) => r.id)).not.toContain(DOSE_LOG_B);
  });

  it('user B cannot read user A dose log by ID', async () => {
    const rows = await asUser(
      USER_B,
      (tx) =>
        tx`SELECT id FROM dose_logs WHERE id = ${DOSE_LOG_A}`,
    );
    expect(rows).toHaveLength(0);
  });

  it('user A cannot log a dose against user B schedule', async () => {
    await expect(
      asUser(USER_A, (tx) =>
        tx`
          INSERT INTO dose_logs (schedule_id, scheduled_at, status)
          VALUES (${SCHEDULE_B}, now() + interval '1 hour', 'taken')
        `,
      ),
    ).rejects.toThrow();
  });

  it('user A cannot update user B dose log status', async () => {
    const result = await asUser(
      USER_A,
      (tx) =>
        tx`UPDATE dose_logs SET status = 'skipped' WHERE id = ${DOSE_LOG_B}`,
    );
    expect(result).toHaveLength(0); // 0 rows updated
  });
});

// ---------------------------------------------------------------------------
// Edge case: no current_user_id set → no rows visible
// ---------------------------------------------------------------------------

describe('no current_user_id — empty result set', () => {
  it('queries without setting current_user_id return no rows', async () => {
    // current_setting('app.current_user_id', true) returns '' when unset.
    // NULLIF(..., '')::uuid yields NULL, which never equals any id — RLS
    // blocks all rows and the query returns an empty result set (not an error).
    const rows = await appSql`SELECT id FROM profiles`;
    expect(rows).toHaveLength(0);
  });
});
