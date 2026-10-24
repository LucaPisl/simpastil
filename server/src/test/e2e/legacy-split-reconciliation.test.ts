import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createIsolatedDatabase } from '../helpers/db-helpers.js';
import postgres, { type Sql } from 'postgres';
import { drizzle } from 'drizzle-orm/postgres-js';
import { migrate } from 'drizzle-orm/postgres-js/migrator';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as schema from '../../db/schema.js';
import type { Db } from '../../db/client.js';
import { MedicationCommandService } from '../../modules/medication/medication-command.service.js';
import { LegacySplitReconciliationService } from '../../modules/medication/legacy-split-reconciliation.service.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const migrationsFolder = join(__dirname, '../../db/migrations');

describe('late legacy split reconciliation', () => {
  let scratch: Awaited<ReturnType<typeof createIsolatedDatabase>>;
  let adminSql: Sql;
  let appSql: Sql;
  let appDb: Db;

  beforeAll(async () => {
    scratch = await createIsolatedDatabase('legacy_split');
    adminSql = postgres(scratch.superUri, { max: 4 });
    await migrate(drizzle(adminSql), { migrationsFolder });
    await adminSql.unsafe("ALTER ROLE app_user PASSWORD 'testpass'");
    const databaseName = scratch.name.replaceAll('"', '""');
    await adminSql.unsafe(`GRANT CONNECT ON DATABASE "${databaseName}" TO app_user`);

    const appUrl = new URL(scratch.superUri);
    appUrl.username = 'app_user';
    appUrl.password = 'testpass';
    appSql = postgres(appUrl.toString(), { max: 4 });
    appDb = drizzle(appSql, { schema }) as unknown as Db;
  }, 120_000);

  afterAll(async () => {
    await appSql?.end();
    await adminSql?.end();
    await scratch?.drop();
  });

  it('records and resolves a late residual through the active ledger without broad grants', async () => {
    const userId = randomUUID();
    const profileId = randomUUID();
    const pillId = randomUUID();
    await adminSql.unsafe(
      'INSERT INTO users (id, email, password_hash) VALUES ($1, $2, $3)',
      [userId, `${userId}@late-reconciliation.invalid`, 'unused-test-hash'],
    );
    await adminSql.begin(async (tx) => {
      await tx.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
      await tx.unsafe(
        'INSERT INTO profiles (id, user_id, name) VALUES ($1, $2, $3)',
        [profileId, userId, 'Late reconciliation profile'],
      );
      await tx.unsafe(
        'INSERT INTO pills (id, profile_id, name) VALUES ($1, $2, $3)',
        [pillId, profileId, 'Late reconciliation pill'],
      );
    });
    await adminSql.unsafe(
      "SELECT set_deployment_authority(2, true, 1, 'ledger_activation', $1)",
      [`late-reconciliation-${userId}`],
    );

    const medication = new MedicationCommandService(appDb);
    await medication.executeInventory(userId, {
      action: 'start',
      commandId: randomUUID(),
      pillId,
      baseRevision: '1',
      initialStock: 5,
      note: null,
    });

    const reconciliation = new LegacySplitReconciliationService(appDb);
    const issueId = randomUUID();
    const checkpointCommandId = randomUUID();
    const checkpointBundleId = randomUUID();
    const checkpointCorrelationId = randomUUID();
    const checkpoint = {
      version: 1,
      reason: 'source_missing' as const,
      legacySourceKind: 'pill_stock' as const,
      legacySourceId: pillId,
      sourceFingerprint: 'f'.repeat(64),
      observedBaseRevision: '2',
      observedBaseStock: 5,
      targetStock: 3,
    };
    await expect(reconciliation.execute(userId, {
      operation: 'record',
      issueId,
      commandId: checkpointCommandId,
      commandBundleId: checkpointBundleId,
      transactionCorrelationId: checkpointCorrelationId,
      checkpoint,
    })).resolves.toMatchObject({ issue: { id: issueId }, replayed: false });

    const resolutionCommandId = randomUUID();
    const resolution = {
      operation: 'resolve' as const,
      issueId,
      commandId: resolutionCommandId,
      commandBundleId: randomUUID(),
      transactionCorrelationId: randomUUID(),
      baseIssueRevision: '1',
      resolution: 'apply_residual' as const,
    };
    const result = await reconciliation.execute(userId, resolution);
    expect(result).toMatchObject({
      commandId: resolutionCommandId,
      issueId,
      resolution: 'apply_residual',
      disposition: 'residual_applied',
      targetStock: 3,
    });

    const [stock] = await adminSql.unsafe<{ current_stock: number; revision: string }[]>(
      'SELECT current_stock::int AS current_stock, revision::text AS revision FROM pills WHERE id = $1',
      [pillId],
    );
    const [event] = await adminSql.unsafe<{ kind: string; delta: number; provenance: string }[]>(
      'SELECT kind, delta::int AS delta, provenance FROM inventory_events WHERE user_id = $1 AND command_id = $2',
      [userId, resolutionCommandId],
    );
    const [receipt] = await adminSql.unsafe<{ origin: string; result_metadata: unknown }[]>(
      'SELECT origin, result_metadata FROM medication_command_receipts WHERE user_id = $1 AND command_id = $2',
      [userId, resolutionCommandId],
    );
    const [issue] = await adminSql.unsafe<{ revision: string; state: string }[]>(
      'SELECT revision::text AS revision, state FROM migration_issues WHERE id = $1',
      [issueId],
    );
    expect(stock).toMatchObject({ current_stock: 3, revision: '3' });
    expect(event).toEqual({ kind: 'correction', delta: -2, provenance: 'legacy_handoff' });
    expect(receipt?.origin).toBe('legacy_handoff');
    expect(receipt?.result_metadata).toEqual(result);
    expect(issue).toEqual({ revision: '2', state: 'resolved' });
    const [snapshots] = await adminSql.unsafe<{
      stored_snapshot: unknown;
      published_snapshot: unknown;
    }[]>(`SELECT issue.safe_snapshot AS stored_snapshot,
                 change.payload->'payload'->'safeSnapshot' AS published_snapshot
          FROM migration_issues issue
          JOIN sync_changes change ON change.user_id=issue.user_id
            AND change.entity_type='migration_issue' AND change.entity_id=issue.id
          WHERE issue.id=$1 AND change.payload->'payload'->>'state'='resolved'`, [issueId]);
    expect(snapshots?.stored_snapshot).toEqual(checkpoint);
    expect(snapshots?.published_snapshot).toEqual({
      ...checkpoint,
      settlement: {
        version: 1,
        commandId: resolutionCommandId,
        resolution: 'apply_residual',
        disposition: 'residual_applied',
        issueId,
      },
    });

    await expect(reconciliation.execute(userId, resolution)).resolves.toEqual(result);
    const [eventCount] = await adminSql.unsafe<{ count: number }[]>(
      'SELECT count(*)::int AS count FROM inventory_events WHERE user_id = $1 AND command_id = $2',
      [userId, resolutionCommandId],
    );
    expect(eventCount?.count).toBe(1);

    await expect(appSql.unsafe(
      'SELECT ledger_activated FROM deployment_manifest WHERE singleton_key IS TRUE FOR SHARE',
    )).rejects.toThrow();
    await expect(appSql.unsafe(
      "UPDATE migration_issues SET revision = 2 WHERE id = $1",
      [issueId],
    )).rejects.toThrow();
  }, 60_000);
});
