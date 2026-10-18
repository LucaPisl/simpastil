import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import postgres from 'postgres';
import { loadDatabaseConfig, readRuntimeEnvironment } from '../config/app-config.js';
import { logProcessFailure } from '../lib/process-log.js';
import { installProcessGuards } from '../lib/process-guards.js';

interface DeploymentRow {
  releaseId: string;
  serverImageDigest: string;
  schemaVersion: number;
  contractVersion: string;
  ledgerActivated: boolean;
  enforcedMinimumClientBuild: number;
  targetMinimumClientBuild: number;
  migrationCompletedAt: Date;
}

interface MigrationRow {
  hash: string;
  createdAt: string;
}

export async function exportDeploymentManifest(): Promise<void> {
  const environment = readRuntimeEnvironment();
  const database = loadDatabaseConfig(environment, 'migrate');
  const sql = postgres(database.url, { max: 1, connect_timeout: 10 });
  try {
    process.stdout.write(await readDeploymentManifest(sql));
  } finally {
    await sql.end();
  }
}

/** The deployment manifest as the backup bundle stores it, newline-terminated JSON. */
export async function readDeploymentManifest(sql: postgres.Sql): Promise<string> {
  const posture = await sql.unsafe<{ isSuperuser: boolean }[]>(`
    SELECT role.rolsuper AS "isSuperuser"
    FROM pg_catalog.pg_roles AS role
    WHERE role.rolname = current_user
  `);
  if (posture.length !== 1 || posture[0]?.isSuperuser !== true) {
    throw new Error('Manifest export requires DATABASE_URL_SUPER');
  }

  const rows = await sql.unsafe<DeploymentRow[]>(`
    SELECT release_id AS "releaseId",
           server_image_digest AS "serverImageDigest",
           schema_version AS "schemaVersion",
           contract_version::text AS "contractVersion",
           ledger_activated AS "ledgerActivated",
           enforced_minimum_client_build AS "enforcedMinimumClientBuild",
           target_minimum_client_build AS "targetMinimumClientBuild",
           migration_completed_at AS "migrationCompletedAt"
    FROM public.deployment_manifest
    WHERE singleton_key IS TRUE
  `);
  if (rows.length !== 1) throw new Error('Deployment manifest singleton is unavailable');
  const migrationTable = await sql.unsafe<{ present: boolean }[]>(`
    SELECT pg_catalog.to_regclass('drizzle.__drizzle_migrations') IS NOT NULL AS present
  `);
  if (migrationTable[0]?.present !== true) throw new Error('Drizzle migration journal is unavailable');
  const migrationRows = await sql.unsafe<MigrationRow[]>(`
    SELECT hash, created_at::text AS "createdAt"
    FROM drizzle.__drizzle_migrations
    ORDER BY created_at DESC, id DESC
    LIMIT 1
  `);
  const countRows = await sql.unsafe<{ count: string }[]>(`
    SELECT count(*)::text AS count FROM drizzle.__drizzle_migrations
  `);
  const deployment = rows[0];
  const migration = migrationRows[0];
  if (!deployment || !migration || !/^[a-f0-9]{64}$/i.test(migration.hash)) {
    throw new Error('A valid applied migration head is unavailable');
  }
  const appliedAt = new Date(Number(migration.createdAt));
  if (!Number.isFinite(appliedAt.getTime())) throw new Error('Migration journal timestamp is invalid');

  return `${JSON.stringify({
    formatVersion: 1,
    releaseId: deployment.releaseId,
    serverImageDigest: deployment.serverImageDigest,
    schemaVersion: deployment.schemaVersion,
    contractVersion: deployment.contractVersion,
    ledgerActivated: deployment.ledgerActivated,
    enforcedMinimumClientBuild: deployment.enforcedMinimumClientBuild,
    targetMinimumClientBuild: deployment.targetMinimumClientBuild,
    migrationCompletedAt: deployment.migrationCompletedAt.toISOString(),
    migration: {
      schema: 'drizzle',
      appliedCount: Number(countRows[0]?.count ?? 0),
      headHash: migration.hash,
      headAppliedAt: appliedAt.toISOString(),
    },
  }, null, 2)}\n`;
}

async function main(): Promise<void> {
  installProcessGuards('command');
  try {
    await exportDeploymentManifest();
  } catch (error) {
    logProcessFailure('deployment_manifest.export_failed', error);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  void main();
}
