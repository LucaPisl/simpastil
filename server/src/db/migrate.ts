/**
 * Standalone migration runner for production deployments.
 *
 * Uses drizzle-orm's built-in migrate() — no drizzle-kit required.
 * Run via the ordered one-shot `migrate` service after role provisioning.
 *
 * Migration files are expected at dist/db/migrations/ (copied from
 * src/db/migrations/ in the Dockerfile, since tsc ignores non-.ts files).
 */
import { migrate } from 'drizzle-orm/postgres-js/migrator';
import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';
import { readFileSync } from 'node:fs';
import { ConfigError, loadDatabaseConfig, readRuntimeEnvironment } from '../config/app-config.js';
import { installProcessGuards } from '../lib/process-guards.js';

// Installed before anything can fail, so a bad setting or an unreachable
// database ends in one explained log line instead of a raw stack trace.
installProcessGuards('migrate');

const databaseConfig = loadDatabaseConfig(readRuntimeEnvironment(), 'migrate');

const sql = postgres(databaseConfig.url, { max: databaseConfig.maxConnections });
const db = drizzle(sql);
// A separate single-connection client holds the session-level advisory lock,
// so the lock and its release always run on the same connection.
const lockSql = postgres(databaseConfig.url, { max: 1 });

const here = dirname(fileURLToPath(import.meta.url));
const migrationsFolder = join(here, 'migrations');
// dist/db/migrate.js and src/db/migrate.ts both sit two levels below package.json.
const imageVersion = (JSON.parse(readFileSync(join(here, '../../package.json'), 'utf8')) as { version: string }).version;

try {
  const posture = await sql.unsafe<{ isSuperuser: boolean }[]>(`
    SELECT role.rolsuper AS "isSuperuser"
    FROM pg_catalog.pg_roles AS role
    WHERE role.rolname = current_user
  `);
  if (posture.length !== 1 || posture[0]?.isSuperuser !== true) {
    throw new ConfigError('DATABASE_URL_SUPER must connect as a PostgreSQL superuser');
  }

  // Two migrate runs against one database (a second Compose project, a manual
  // run) wait for each other instead of racing through the journal.
  await lockSql`SELECT pg_advisory_lock(hashtextextended('simpastil:migrate', 0))`;
  try {
    console.log(`Running migrations from ${migrationsFolder}`);
    await migrate(db, { migrationsFolder });
    await sql`SELECT public.record_server_image(${imageVersion})`;
    console.log(`Migrations complete; server image ${imageVersion} recorded`);
  } finally {
    await lockSql`SELECT pg_advisory_unlock(hashtextextended('simpastil:migrate', 0))`;
  }
} finally {
  await sql.end();
  await lockSql.end();
}
