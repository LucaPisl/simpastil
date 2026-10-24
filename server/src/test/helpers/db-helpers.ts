import postgres from 'postgres';
import { drizzle } from 'drizzle-orm/postgres-js';
import * as schema from '../../db/schema.js';
import { apiKeys } from '../../db/schema.js';
import { sql as drizzleSql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { randomBytes } from 'node:crypto';
import { sha256Hex } from '../../lib/crypto.js';

/**
 * Creates two Drizzle instances for integration tests:
 *   superDb — superuser connection (bypasses RLS). Use for assertions + TRUNCATE.
 *   appDb   — app_user connection (RLS enforced).  Pass to buildApp().
 */
export function createDbs(): { superDb: Db; appDb: Db; cleanup: () => Promise<void> } {
  const superUrl = process.env['TEST_DATABASE_URL_SUPER']!;
  const appUrl   = process.env['TEST_DATABASE_URL_APP']!;

  const superSql = postgres(superUrl, { max: 5 });
  const appSql   = postgres(appUrl,   { max: 5 });

  return {
    superDb: drizzle(superSql, { schema }) as Db,
    appDb:   drizzle(appSql,   { schema }) as Db,
    cleanup: async () => {
      await superSql.end();
      await appSql.end();
    },
  };
}

/** Wipes all user data between tests. Fast alternative to transaction rollback. */
async function reportStalledTruncate(): Promise<void> {
  const superUrl = process.env['TEST_DATABASE_URL_SUPER'];
  if (!superUrl) {
    console.warn('[test cleanup diagnostic] database URL unavailable');
    return;
  }

  const observer = postgres(superUrl, {
    max: 1,
    connect_timeout: 2,
    connection: { statement_timeout: 1500 },
  });
  try {
    const rows = await observer.unsafe(`
      SELECT
        pid,
        state,
        floor(extract(epoch FROM clock_timestamp() - query_start) * 1000)::int AS query_age_ms,
        floor(extract(epoch FROM clock_timestamp() - xact_start) * 1000)::int AS transaction_age_ms,
        wait_event_type,
        wait_event,
        pg_blocking_pids(pid) AS blocking_pids
      FROM pg_stat_activity
      WHERE datname = current_database()
        AND pid <> pg_backend_pid()
        AND state = 'active'
        AND query ILIKE 'TRUNCATE users,%'
      ORDER BY query_start NULLS LAST
    `);
    console.warn(
      '[test cleanup diagnostic] TRUNCATE still active after 5s',
      JSON.stringify(rows.length === 0 ? { matchingTruncates: 0 } : rows),
    );
  } finally {
    await observer.end({ timeout: 1 });
  }
}

export async function truncateAll(superDb: Db): Promise<void> {
  const diagnosticTimer = setTimeout(() => {
    void reportStalledTruncate().catch(() => {
      console.warn('[test cleanup diagnostic] observer unavailable');
    });
  }, 5_000);
  try {
    await superDb.execute(
      drizzleSql`TRUNCATE users, refresh_tokens, profiles, pills, schedules, dose_logs, api_keys, admin_config, admin_refresh_tokens, password_reset_tokens, audit_logs, backup_codes, invitation_tokens, outbox_messages, email_change_tokens, deleted_account_markers RESTART IDENTITY CASCADE`,
    );
    // The settings row is seeded by the migration, so reset it instead of truncating.
    await superDb.execute(
      drizzleSql`UPDATE server_settings SET password_reset_mode = NULL, reset_link_lifetime_minutes = 60, updated_at = now()`,
    );
  } finally {
    clearTimeout(diagnosticTimer);
  }
}

/** Wait until an application transaction is blocked on a FOR UPDATE query. */
export async function waitForBlockedQuery(
  superDb: Db,
  queryFragment: string,
  minimumCount = 1,
): Promise<void> {
  const deadline = Date.now() + 5_000;
  const pattern = `%${queryFragment}%`;
  while (Date.now() < deadline) {
    const rows = await superDb.execute<{ count: number }>(drizzleSql`
      SELECT count(*)::int AS count
      FROM pg_stat_activity
      WHERE state = 'active'
        AND wait_event_type = 'Lock'
        AND query ILIKE ${pattern}
        AND query ILIKE '%FOR UPDATE%'
    `);
    if ((rows[0]?.count ?? 0) >= minimumCount) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`Timed out waiting for ${minimumCount} blocked query matching ${queryFragment}`);
}

/**
 * Rotate the disposable bootstrap proof through the same owner-only path that
 * the operator command will use. The raw proof is returned only to the test;
 * production code persists its hash and never exposes it through the API.
 */
export async function prepareBootstrapProof(
  superDb: Db,
  options: { expiresAt?: Date } = {},
): Promise<string> {
  const proof = randomBytes(32).toString('hex');
  const expiresAt = options.expiresAt ?? new Date(Date.now() + 30 * 60 * 1000);
  const expiresAtIso = expiresAt.toISOString();
  await superDb.transaction(async (tx) => {
    await tx.execute(drizzleSql`SET LOCAL ROLE deployment_authority_owner`);
    await tx.execute(drizzleSql`
      UPDATE admin_bootstrap_state
      SET token_hash = ${sha256Hex(proof)},
          generation = generation + 1,
          expires_at = ${expiresAtIso}::timestamptz,
          consumed_at = NULL
    `);
  });
  return proof;
}

async function generateKey(): Promise<{ rawKey: string; keyHash: string }> {
  const { createHash, randomBytes } = await import('node:crypto');
  const rawKey = randomBytes(32).toString('hex');
  const keyHash = createHash('sha256').update(rawKey).digest('hex');
  return { rawKey, keyHash };
}

/**
 * Creates a raw API key + stores its hash in api_keys for the given userId.
 * Returns the raw key string for use in X-Api-Key headers.
 */
export async function createApiKey(
  superDb: Db,
  userId: string,
  label = 'test-key',
): Promise<string> {
  const { rawKey, keyHash } = await generateKey();
  await superDb.insert(apiKeys).values({ userId, keyHash, label });
  return rawKey;
}

/**
 * Creates an unclaimed API key (userId = null). Returns raw key.
 */
export async function createUnclaimedKey(
  superDb: Db,
  label = 'unclaimed-test-key',
): Promise<string> {
  const { rawKey, keyHash } = await generateKey();
  await superDb.insert(apiKeys).values({ userId: null, keyHash, label });
  return rawKey;
}

/**
 * A scratch database inside the shared test cluster (global-setup), for e2e
 * files that must migrate their own empty schema but do not need a fresh
 * cluster. Cheaper than a private container (about 5 s each). Roles are
 * cluster-wide, so a file using this must not alter role passwords other than
 * app_user's 'testpass'. Files that assert role creation from empty, or that
 * run the provisioning command (it sets new role passwords), keep their own
 * container.
 */
export async function createIsolatedDatabase(
  prefix: string,
): Promise<{ name: string; superUri: string; drop: () => Promise<void> }> {
  const clusterUrl = process.env['TEST_DATABASE_URL_SUPER']!;
  const name = `${prefix}_${randomBytes(4).toString('hex')}`.replace(/[^a-z0-9_]/gi, '_').toLowerCase();
  const admin = postgres(clusterUrl, { max: 1 });
  try {
    await admin.unsafe(`CREATE DATABASE "${name}"`);
  } finally {
    await admin.end();
  }
  const url = new URL(clusterUrl);
  url.pathname = `/${name}`;
  return {
    name,
    superUri: url.toString(),
    drop: async () => {
      const dropper = postgres(clusterUrl, { max: 1 });
      try {
        await dropper.unsafe(`DROP DATABASE IF EXISTS "${name}" WITH (FORCE)`);
      } finally {
        await dropper.end();
      }
    },
  };
}
