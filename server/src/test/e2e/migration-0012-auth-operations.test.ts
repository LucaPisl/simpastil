import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PostgreSqlContainer, type StartedPostgreSqlContainer } from '@testcontainers/postgresql';
import postgres, { type Sql } from 'postgres';
import { readMigrationFiles } from 'drizzle-orm/migrator';
import { drizzle } from 'drizzle-orm/postgres-js';
import { migrate } from 'drizzle-orm/postgres-js/migrator';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const migrationsFolder = join(__dirname, '../../db/migrations');
const pre0012Migrations = [
  '0000_initial.sql',
  '0001_sturdy_thena.sql',
  '0002_prt_rls.sql',
  '0003_petite_proemial_gods.sql',
  '0004_pill_inventory.sql',
  '0005_logging_extensions.sql',
  '0006_server_hardening.sql',
  '0007_rls_enforcement.sql',
  '0008_sync_hardening.sql',
  '0009_api_key_encrypted_storage.sql',
  '0010_rls_nullif_backup_codes.sql',
  '0011_delta_sync_tombstones.sql',
] as const;

const emptyDatabase = 'migration_0012_empty';
const upgradeDatabase = 'migration_0012_upgrade';

function databaseUrl(baseUri: string, database: string, role?: string, password?: string): string {
  const url = new URL(baseUri);
  url.pathname = `/${database}`;
  if (role !== undefined) url.username = role;
  if (password !== undefined) url.password = password;
  return url.toString();
}

async function applyPre0012(sql: Sql): Promise<void> {
  for (const migration of pre0012Migrations) {
    await sql.unsafe(readFileSync(join(migrationsFolder, migration), 'utf8'));
  }
}

async function apply0012(sql: Sql): Promise<void> {
  await sql.unsafe(readFileSync(join(migrationsFolder, '0012_auth_recovery_operations.sql'), 'utf8'));
}

async function seedPriorMigrationJournal(sql: Sql): Promise<void> {
  const priorMigrations = readMigrationFiles({ migrationsFolder }).slice(
    0,
    pre0012Migrations.length,
  );
  await sql.unsafe(`
    CREATE SCHEMA IF NOT EXISTS drizzle;
    CREATE TABLE IF NOT EXISTS drizzle.__drizzle_migrations (
      id SERIAL PRIMARY KEY,
      hash TEXT NOT NULL,
      created_at BIGINT
    )
  `);
  for (const migration of priorMigrations) {
    await sql`
      INSERT INTO drizzle.__drizzle_migrations (hash, created_at)
      VALUES (${migration.hash}, ${migration.folderMillis})
    `;
  }
}

async function applyPendingWithMigrator(sql: Sql): Promise<void> {
  await migrate(drizzle(sql), { migrationsFolder });
}

describe('migration 0012 auth, recovery, outbox, and deployment state', () => {
  let container: StartedPostgreSqlContainer;
  let adminSql: Sql;
  let emptySql: Sql;
  let upgradeSql: Sql;
  let appSql: Sql;
  let outboxSql: Sql;

  beforeAll(async () => {
    container = await new PostgreSqlContainer(
      process.env['TEST_POSTGRES_IMAGE'] ?? 'postgres:16-alpine',
    ).start();
    const baseUri = container.getConnectionUri();
    adminSql = postgres(baseUri, { max: 2 });
    await adminSql.unsafe(`CREATE DATABASE "${emptyDatabase}"`);
    await adminSql.unsafe(`CREATE DATABASE "${upgradeDatabase}"`);

    emptySql = postgres(databaseUrl(baseUri, emptyDatabase), { max: 2 });
    upgradeSql = postgres(databaseUrl(baseUri, upgradeDatabase), { max: 2 });
    await applyPre0012(emptySql);
    await applyPre0012(upgradeSql);

    await emptySql.unsafe(
      `INSERT INTO users (email, password_hash) VALUES ('empty@example.invalid', 'hash')`,
    );
    await upgradeSql.unsafe(
      `INSERT INTO users (email, password_hash) VALUES ('upgrade@example.invalid', 'hash')`,
    );
    await upgradeSql.unsafe(
      `INSERT INTO admin_config (email, password_hash) VALUES ('admin@example.invalid', 'hash')`,
    );

    await seedPriorMigrationJournal(emptySql);
    await seedPriorMigrationJournal(upgradeSql);
    await applyPendingWithMigrator(emptySql);
    await applyPendingWithMigrator(upgradeSql);
    await applyPendingWithMigrator(emptySql);
    await applyPendingWithMigrator(upgradeSql);

    // The SQL remains replay-safe even when a deployment reruns the completed
    // migration outside the journal-backed runner.
    await apply0012(emptySql);
    await apply0012(upgradeSql);
    await apply0012(emptySql);
    await apply0012(upgradeSql);

    await adminSql.unsafe(`ALTER ROLE app_user PASSWORD 'testpass'`);
    await adminSql.unsafe(`ALTER ROLE outbox_user LOGIN PASSWORD 'outboxpass'`);
    await adminSql.unsafe(`GRANT CONNECT ON DATABASE "${emptyDatabase}" TO app_user, outbox_user`);
    await adminSql.unsafe(`GRANT CONNECT ON DATABASE "${upgradeDatabase}" TO app_user, outbox_user`);
    appSql = postgres(databaseUrl(baseUri, emptyDatabase, 'app_user', 'testpass'), { max: 2 });
    outboxSql = postgres(databaseUrl(baseUri, emptyDatabase, 'outbox_user', 'outboxpass'), { max: 2 });
  }, 120_000);

  afterAll(async () => {
    await Promise.all([
      appSql?.end(),
      outboxSql?.end(),
      emptySql?.end(),
      upgradeSql?.end(),
      adminSql?.end(),
    ]);
    await container?.stop();
  }, 60_000);

  it('backfills bootstrap state and initializes security/deployment defaults', async () => {
    const emptyUsers = await emptySql`SELECT session_version FROM users`;
    const upgradeUsers = await upgradeSql`SELECT session_version FROM users`;
    const upgradeAdmins = await upgradeSql`SELECT session_version FROM admin_config`;
    expect(emptyUsers.map((row) => BigInt(String(row.session_version)))).toEqual([1n]);
    expect(upgradeUsers.map((row) => BigInt(String(row.session_version)))).toEqual([1n]);
    expect(upgradeAdmins.map((row) => BigInt(String(row.session_version)))).toEqual([1n]);

    const emptyBootstrap = await emptySql`
      SELECT singleton_key, token_hash, generation, consumed_at
      FROM admin_bootstrap_state
    `;
    const upgradeBootstrap = await upgradeSql`
      SELECT singleton_key, token_hash, generation, consumed_at
      FROM admin_bootstrap_state
    `;
    expect(emptyBootstrap).toHaveLength(1);
    expect(emptyBootstrap[0]).toMatchObject({ singleton_key: true, consumed_at: null });
    expect(BigInt(String(emptyBootstrap[0]?.generation))).toBe(1n);
    expect(emptyBootstrap[0]?.token_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(upgradeBootstrap).toHaveLength(1);
    expect(upgradeBootstrap[0]).toMatchObject({ singleton_key: true });
    expect(BigInt(String(upgradeBootstrap[0]?.generation))).toBe(1n);
    expect(upgradeBootstrap[0]?.consumed_at).toBeTruthy();
    expect(Date.parse(String(upgradeBootstrap[0]?.consumed_at))).not.toBeNaN();
    expect(upgradeBootstrap[0]?.token_hash).toMatch(/^[0-9a-f]{64}$/);

    const manifest = await emptySql`
      SELECT schema_version, contract_version, ledger_activated,
        enforced_minimum_client_build, target_minimum_client_build
      FROM deployment_manifest
    `;
    expect(manifest).toHaveLength(1);
    expect(Number(manifest[0]?.schema_version)).toBeGreaterThanOrEqual(12);
    expect(manifest[0]).toMatchObject({
      ledger_activated: false,
      enforced_minimum_client_build: 1,
      target_minimum_client_build: 2,
    });
    expect(BigInt(String(manifest[0]?.contract_version))).toBe(1n);
  });

  it('enforces token, outbox, singleton, and deployment invariants', async () => {
    await expect(emptySql.unsafe(`
      INSERT INTO admin_bootstrap_state (singleton_key, token_hash, generation, expires_at)
      VALUES (true, repeat('a', 64), 2, now() + interval '30 minutes')
    `)).rejects.toThrow();
    await expect(emptySql.unsafe(`
      INSERT INTO admin_bootstrap_state (singleton_key, token_hash, generation, expires_at)
      VALUES (false, repeat('d', 64), 2, now() + interval '30 minutes')
    `)).rejects.toThrow();
    await expect(emptySql.unsafe(`
      INSERT INTO deployment_manifest (singleton_key)
      VALUES (false)
    `)).rejects.toThrow();

    const [apiKey] = await emptySql.unsafe<{ id: string }[]>(
      `INSERT INTO api_keys (user_id, key_hash, label) VALUES (NULL, repeat('c', 64), 'invite-test') RETURNING id`,
    );
    await emptySql.unsafe(`
      INSERT INTO invitation_tokens (token_hash, recipient_email, api_key_id, expires_at)
      VALUES (repeat('b', 64), 'invite@example.invalid', '${apiKey!.id}', now() + interval '30 minutes')
    `);
    await expect(emptySql.unsafe(`
      INSERT INTO invitation_tokens (token_hash, recipient_email, api_key_id, expires_at)
      VALUES (repeat('b', 64), 'invite-2@example.invalid', '${apiKey!.id}', now() + interval '30 minutes')
    `)).rejects.toThrow();

    await expect(emptySql.unsafe(`
      INSERT INTO outbox_messages (
        message_type, recipient_ref, encrypted_delivery_payload, state,
        attempt_count, next_attempt_at, expires_at
      ) VALUES ('password_reset', 'recipient-ref', 'sealed', 'not-a-state', 0,
        now(), now() + interval '30 minutes')
    `)).rejects.toThrow();
    await expect(emptySql.unsafe(`
      INSERT INTO outbox_messages (
        message_type, recipient_ref, encrypted_delivery_payload, state,
        attempt_count, next_attempt_at, expires_at
      ) VALUES ('password_reset', 'recipient-ref', 'sealed', 'queued', -1,
        now(), now() + interval '30 minutes')
    `)).rejects.toThrow();

    await expect(emptySql.unsafe(`
      UPDATE deployment_manifest SET target_minimum_client_build = 3
    `)).rejects.toThrow();

    await emptySql.unsafe(`
      SELECT set_deployment_authority(1, false, 2, 'minimum_client_build', 'change-0012-up')
    `);
    await emptySql.unsafe(`
      SELECT set_deployment_authority(1, false, 1, 'minimum_client_build', 'change-0012-down')
    `);
    await emptySql.unsafe(`
      SELECT set_deployment_authority(2, true, 1, 'ledger_activation', 'change-0012-activate')
    `);
    const asAuthorityOwner = (statement: string) => emptySql.begin(async (tx) => {
      await tx.unsafe('SET LOCAL ROLE deployment_authority_owner');
      await tx.unsafe(statement);
    });
    await expect(asAuthorityOwner('DELETE FROM deployment_manifest')).rejects.toThrow();
    await expect(asAuthorityOwner('TRUNCATE deployment_manifest')).rejects.toThrow();
    await expect(asAuthorityOwner('TRUNCATE deployment_authority_events')).rejects.toThrow();
    await expect(asAuthorityOwner('DELETE FROM admin_bootstrap_state')).rejects.toThrow();
    await expect(asAuthorityOwner('TRUNCATE admin_bootstrap_state')).rejects.toThrow();
    const authorityEvents = await emptySql`
      SELECT event_type, old_contract_version, new_contract_version,
        old_ledger_activated, new_ledger_activated,
        old_enforced_minimum_client_build, new_enforced_minimum_client_build,
        change_reference
      FROM deployment_authority_events
      ORDER BY created_at, id
    `;
    expect(new Set(authorityEvents.map((event) => event.change_reference))).toEqual(new Set([
      'change-0012-up',
      'change-0012-down',
      'change-0012-activate',
    ]));
    const activationEvent = authorityEvents.find((event) => event.change_reference === 'change-0012-activate');
    expect(activationEvent).toMatchObject({
      old_contract_version: '1',
      new_contract_version: '2',
      old_ledger_activated: false,
      new_ledger_activated: true,
      old_enforced_minimum_client_build: 1,
      new_enforced_minimum_client_build: 1,
    });
    await expect(emptySql.unsafe(`
      SELECT set_deployment_authority(1, true, 1, 'minimum_client_build', 'contract-rollback')
    `)).rejects.toThrow();
    await expect(emptySql.unsafe(`
      INSERT INTO deployment_authority_events (
        event_type, old_contract_version, new_contract_version,
        old_ledger_activated, new_ledger_activated,
        old_enforced_minimum_client_build, new_enforced_minimum_client_build,
        change_reference
      ) VALUES ('ledger_activation', 2, 2, false, true, 1, 1, 'direct-forbidden')
    `)).rejects.toThrow();
    await expect(emptySql.unsafe(`
      UPDATE deployment_manifest SET ledger_activated = false
    `)).rejects.toThrow();
    await expect(emptySql.unsafe(`
      UPDATE deployment_authority_events SET change_reference = 'changed'
    `)).rejects.toThrow();
    await expect(emptySql.unsafe(`
      DELETE FROM deployment_authority_events
    `)).rejects.toThrow();
  });

  it('keeps API and future outbox roles on bounded permissions', async () => {
    await expect(appSql.unsafe(`
      UPDATE admin_bootstrap_state SET token_hash = repeat('e', 64)
    `)).rejects.toThrow();
    await expect(appSql.unsafe(`
      UPDATE admin_bootstrap_state SET generation = generation + 1
    `)).rejects.toThrow();
    await appSql.unsafe(`
      UPDATE admin_bootstrap_state SET consumed_at = now() WHERE consumed_at IS NULL
    `);
    await expect(appSql.unsafe(`
      UPDATE admin_bootstrap_state SET consumed_at = NULL
    `)).rejects.toThrow();

    await appSql.unsafe(`
      INSERT INTO outbox_messages (
        message_type, recipient_ref, encrypted_delivery_payload, state,
        attempt_count, next_attempt_at, expires_at
      ) VALUES ('password_reset', 'recipient-ref', 'sealed', 'queued', 0,
        now(), now() + interval '30 minutes')
    `);
    const inserted = await emptySql`
      SELECT count(*)::int AS count FROM outbox_messages WHERE state = 'queued'
    `;
    expect(inserted[0]?.count).toBe(1);

    await expect(appSql.unsafe(`SELECT encrypted_delivery_payload FROM outbox_messages`)).rejects.toThrow();
    await expect(appSql.unsafe(`UPDATE outbox_messages SET state = 'sending'`)).rejects.toThrow();
    await expect(appSql.unsafe(`UPDATE deployment_manifest SET enforced_minimum_client_build = 2`)).rejects.toThrow();
    await expect(appSql.unsafe(`TRUNCATE deployment_manifest`)).rejects.toThrow();
    await expect(appSql.unsafe(`INSERT INTO deployment_authority_events (event_type, old_contract_version, new_contract_version, old_ledger_activated, new_ledger_activated, old_enforced_minimum_client_build, new_enforced_minimum_client_build, change_reference) VALUES ('ledger_activation', 1, 1, false, true, 1, 1, 'app-forbidden')`)).rejects.toThrow();

    const workerRows = await outboxSql`
      SELECT id, recipient_ref, encrypted_delivery_payload, state
      FROM outbox_messages
    `;
    expect(workerRows).toHaveLength(1);
    await expect(outboxSql.unsafe(`SELECT id FROM users`)).rejects.toThrow();
    for (const table of ['profiles', 'pills', 'schedules', 'dose_logs']) {
      await expect(outboxSql.unsafe(`SELECT * FROM ${table}`)).rejects.toThrow();
    }
    await expect(outboxSql.unsafe(`UPDATE deployment_manifest SET enforced_minimum_client_build = 2`)).rejects.toThrow();
    await expect(outboxSql.unsafe(`TRUNCATE deployment_authority_events`)).rejects.toThrow();
    await expect(outboxSql.unsafe(`SELECT set_deployment_authority(2, true, 1, 'ledger_activation', 'worker-forbidden')`)).rejects.toThrow();
  });

  it('stores only hashed/token-envelope columns for authority and delivery state', async () => {
    const columns = await emptySql`
      SELECT table_name, column_name
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name IN ('admin_bootstrap_state', 'invitation_tokens', 'outbox_messages')
      ORDER BY table_name, ordinal_position
    `;
    const columnNames = columns.map((row) => String(row.column_name));
    expect(columnNames).toContain('token_hash');
    expect(columnNames).toContain('encrypted_delivery_payload');
    expect(columnNames.some((name) => /raw|plaintext|mail_body|api_key_value/i.test(name))).toBe(false);
  });
});
