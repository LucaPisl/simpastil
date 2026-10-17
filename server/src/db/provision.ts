import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { drizzle } from 'drizzle-orm/postgres-js';
import { sql as drizzleSql, type SQL } from 'drizzle-orm';
import postgres, { type Sql } from 'postgres';
import {
  loadDatabaseConfig,
  readRuntimeEnvironment,
  type RuntimeEnvironment,
} from '../config/app-config.js';
import {
  rotateBootstrapProof,
  type BootstrapRotationTransaction,
} from '../modules/admin/bootstrap-rotation.js';
import { activateMedicationLedger } from './activate-ledger.js';
import { setMinimumClientBuild } from './set-minimum-client-build.js';
import { logProcessEvent } from '../lib/process-log.js';

export interface PrivilegedCommandContext {
  sql: Sql;
  environment: RuntimeEnvironment;
  args?: string[];
}

export type PrivilegedSubcommand = (context: PrivilegedCommandContext) => Promise<void>;

/** Later privileged authorities register here; API and worker entrypoints never import it. */
export const privilegedSubcommandRegistry = new Map<string, PrivilegedSubcommand>();

function quoteIdentifier(value: string): string {
  return `"${value.replace(/"/g, '""')}"`;
}

function quoteLiteral(value: string): string {
  if (value.includes('\0')) throw new Error('password contains an unsupported character');
  return `'${value.replace(/'/g, "''")}'`;
}

function requiredSecret(environment: RuntimeEnvironment, name: string): string {
  const value = environment[name];
  if (!value || value.length < 32) {
    throw new Error(`${name} must be configured with at least 32 characters`);
  }
  return value;
}

async function assertSuperuser(sql: Sql): Promise<{ currentUser: string }> {
  const rows = await sql.unsafe<{ currentUser: string; isSuperuser: boolean }[]>(`
    SELECT current_user AS "currentUser", role.rolsuper AS "isSuperuser"
    FROM pg_catalog.pg_roles AS role
    WHERE role.rolname = current_user
  `);
  const row = rows[0];
  if (!row?.isSuperuser) throw new Error('Privileged command requires DATABASE_URL_SUPER');
  return { currentUser: row.currentUser };
}

interface RolePostureRow {
  roleName: string;
  canLogin: boolean;
  isSuperuser: boolean;
  canCreateDatabase: boolean;
  canCreateRole: boolean;
  inheritsRoles: boolean;
  canReplicate: boolean;
  bypassesRls: boolean;
}

async function assertProvisionedRolePosture(sql: Sql): Promise<void> {
  const roles = await sql.unsafe<RolePostureRow[]>(`
    SELECT rolname AS "roleName", rolcanlogin AS "canLogin", rolsuper AS "isSuperuser",
           rolcreatedb AS "canCreateDatabase", rolcreaterole AS "canCreateRole",
           rolinherit AS "inheritsRoles", rolreplication AS "canReplicate",
           rolbypassrls AS "bypassesRls"
    FROM pg_catalog.pg_roles
    WHERE rolname IN ('app_user', 'outbox_user', 'deployment_authority_owner')
  `);
  const expectedLogin = new Map([
    ['app_user', true],
    ['outbox_user', true],
    ['deployment_authority_owner', false],
  ]);
  if (roles.length !== expectedLogin.size || roles.some((role) =>
    role.canLogin !== expectedLogin.get(role.roleName)
    || role.isSuperuser || role.canCreateDatabase || role.canCreateRole
    || role.inheritsRoles || role.canReplicate || role.bypassesRls
  )) {
    throw new Error('Provisioned role posture did not match the least-privilege contract');
  }

  const memberships = await sql.unsafe<{ membershipCount: string }[]>(`
    SELECT count(*)::text AS "membershipCount"
    FROM pg_catalog.pg_auth_members AS membership
    JOIN pg_catalog.pg_roles AS member_role ON member_role.oid = membership.member
    WHERE member_role.rolname IN ('app_user', 'outbox_user', 'deployment_authority_owner')
  `);
  if (memberships[0]?.membershipCount !== '0') {
    throw new Error('Provisioned roles must not inherit or assume another role');
  }
}

async function verifyRuntimePrivileges(sql: Sql): Promise<void> {
  const rows = await sql.unsafe<{
    appCanReadOutbox: boolean;
    appCanReadEnvelope: boolean;
    workerCanReadEnvelope: boolean;
    workerCanUpdateEnvelope: boolean;
    workerCanReadUsers: boolean;
    workerCanReadProfiles: boolean;
    workerCanReadPills: boolean;
    workerCanReadSchedules: boolean;
    workerCanReadDoseLogs: boolean;
    forcedRlsCount: string;
    authorityOwnersMatch: boolean;
  }[]>(`
    SELECT
      has_table_privilege('app_user', 'public.outbox_messages', 'SELECT') AS "appCanReadOutbox",
      has_column_privilege('app_user', 'public.outbox_messages', 'encrypted_delivery_payload', 'SELECT') AS "appCanReadEnvelope",
      has_column_privilege('outbox_user', 'public.outbox_messages', 'encrypted_delivery_payload', 'SELECT') AS "workerCanReadEnvelope",
      has_column_privilege('outbox_user', 'public.outbox_messages', 'encrypted_delivery_payload', 'UPDATE') AS "workerCanUpdateEnvelope",
      has_table_privilege('outbox_user', 'public.users', 'SELECT') AS "workerCanReadUsers",
      has_table_privilege('outbox_user', 'public.profiles', 'SELECT') AS "workerCanReadProfiles",
      has_table_privilege('outbox_user', 'public.pills', 'SELECT') AS "workerCanReadPills",
      has_table_privilege('outbox_user', 'public.schedules', 'SELECT') AS "workerCanReadSchedules",
      has_table_privilege('outbox_user', 'public.dose_logs', 'SELECT') AS "workerCanReadDoseLogs",
      (
        SELECT count(*)::text
        FROM pg_catalog.pg_class AS relation
        JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'public'
          AND relation.relname = ANY(ARRAY[
            'users', 'refresh_tokens', 'profiles', 'pills', 'schedules',
            'dose_logs', 'password_reset_tokens', 'backup_codes', 'outbox_messages'
          ])
          AND relation.relrowsecurity AND relation.relforcerowsecurity
      ) AS "forcedRlsCount",
      (
        (
          SELECT count(*) = 3
          FROM pg_catalog.pg_class AS relation
          JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
          WHERE namespace.nspname = 'public'
            AND relation.relname IN ('admin_bootstrap_state', 'deployment_manifest', 'deployment_authority_events')
            AND pg_catalog.pg_get_userbyid(relation.relowner) = 'deployment_authority_owner'
        )
        AND (
          SELECT count(*) = 5
          FROM pg_catalog.pg_proc AS procedure
          JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
          WHERE namespace.nspname = 'public'
            AND procedure.proname IN (
              'set_deployment_authority', 'protect_admin_bootstrap_state', 'protect_deployment_manifest',
              'prevent_deployment_authority_event_mutation', 'prevent_authority_state_deletion'
            )
            AND pg_catalog.pg_get_userbyid(procedure.proowner) = 'deployment_authority_owner'
        )
      ) AS "authorityOwnersMatch"
  `);
  const row = rows[0];
  if (!row || row.appCanReadOutbox || row.appCanReadEnvelope
    || !row.workerCanReadEnvelope || !row.workerCanUpdateEnvelope
    || row.workerCanReadUsers || row.workerCanReadProfiles || row.workerCanReadPills
    || row.workerCanReadSchedules || row.workerCanReadDoseLogs
    || row.forcedRlsCount !== '9' || !row.authorityOwnersMatch) {
    throw new Error('Restored database grants, forced RLS, or authority ownership did not match policy');
  }
}

async function verifyProvisionedStack({ sql }: PrivilegedCommandContext): Promise<void> {
  await assertProvisionedRolePosture(sql);
  await verifyRuntimePrivileges(sql);
  logProcessEvent('info', 'provision.runtime_posture_verified');
}

async function provisionRoles({ sql, environment }: PrivilegedCommandContext): Promise<void> {
  const appPassword = quoteLiteral(requiredSecret(environment, 'APP_USER_PASSWORD'));
  const outboxPassword = quoteLiteral(requiredSecret(environment, 'OUTBOX_USER_PASSWORD'));
  const { currentUser } = await assertSuperuser(sql);
  const owner = quoteIdentifier(currentUser);

  await sql.begin(async (transaction) => {
    await transaction.unsafe(`
      DO $roles$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'app_user') THEN
          CREATE ROLE app_user NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOLOGIN NOBYPASSRLS;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'outbox_user') THEN
          CREATE ROLE outbox_user NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOLOGIN NOBYPASSRLS;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'deployment_authority_owner') THEN
          CREATE ROLE deployment_authority_owner NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOLOGIN NOBYPASSRLS;
        END IF;
      END
      $roles$
    `);
    await transaction.unsafe(`
      ALTER ROLE app_user WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
        NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD ${appPassword}
    `);
    await transaction.unsafe(`
      ALTER ROLE outbox_user WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
        NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD ${outboxPassword}
    `);
    await transaction.unsafe(`
      ALTER ROLE deployment_authority_owner WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
        NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD NULL
    `);

    const databases = await transaction.unsafe<{ databaseName: string }[]>(`
      SELECT current_database() AS "databaseName"
    `);
    const databaseName = databases[0]?.databaseName;
    if (!databaseName) throw new Error('Current database name is unavailable');
    await transaction.unsafe(`GRANT CONNECT ON DATABASE ${quoteIdentifier(databaseName)} TO app_user, outbox_user`);
    await transaction.unsafe('GRANT USAGE ON SCHEMA public TO app_user, outbox_user');
    await transaction.unsafe('GRANT USAGE ON SCHEMA public TO deployment_authority_owner');
    await transaction.unsafe('REVOKE CREATE ON SCHEMA public FROM PUBLIC, app_user, outbox_user');
    await transaction.unsafe(`
      ALTER DEFAULT PRIVILEGES FOR ROLE ${owner} IN SCHEMA public
      REVOKE ALL ON TABLES FROM app_user, outbox_user
    `);
    await transaction.unsafe(`
      ALTER DEFAULT PRIVILEGES FOR ROLE ${owner} IN SCHEMA public
      REVOKE ALL ON SEQUENCES FROM app_user, outbox_user
    `);
  });

  await assertProvisionedRolePosture(sql);
  logProcessEvent('info', 'provision.runtime_roles_ready');
}

async function rotateBootstrap({ sql }: PrivilegedCommandContext): Promise<void> {
  const database = drizzle(sql);
  const transaction = async <T>(
    callback: (tx: BootstrapRotationTransaction) => Promise<T>,
  ): Promise<T> => database.transaction(async (tx) => {
    // admin_bootstrap_state is writable only by the deployment authority owner;
    // the protect_admin_bootstrap_state trigger stays in force.
    await tx.execute(drizzleSql`SET LOCAL ROLE deployment_authority_owner`);
    return callback({
      execute: async <Row = Record<string, unknown>>(query: unknown): Promise<Row[]> =>
        await tx.execute(query as SQL) as unknown as Row[],
    });
  });

  const proof = await rotateBootstrapProof(transaction);
  process.stdout.write(`${JSON.stringify({ proof: proof.proof, generation: proof.generation, expiresAt: proof.expiresAt.toISOString() })}\n`);
}

privilegedSubcommandRegistry.set('provision', provisionRoles);
privilegedSubcommandRegistry.set('verify', verifyProvisionedStack);
privilegedSubcommandRegistry.set('rotate-bootstrap', rotateBootstrap);
privilegedSubcommandRegistry.set('activate-ledger', activateMedicationLedger);
privilegedSubcommandRegistry.set('set-minimum-client-build', setMinimumClientBuild);

export async function runProvisionCommand(command: string, args: string[] = []): Promise<void> {
  const handler = privilegedSubcommandRegistry.get(command);
  if (!handler) throw new Error('Unknown privileged command');
  const environment = readRuntimeEnvironment();
  const database = loadDatabaseConfig(environment, 'migrate');
  const sql = postgres(database.url, { max: 1, connect_timeout: 10 });
  try {
    await assertSuperuser(sql);
    await handler({ sql, environment, args });
  } finally {
    await sql.end();
  }
}

async function main(): Promise<void> {
  try {
    await runProvisionCommand(process.argv[2] ?? 'provision', process.argv.slice(3));
  } catch {
    logProcessEvent('error', 'provision.command_failed');
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  void main();
}
