import { readMigrationFiles } from 'drizzle-orm/migrator';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Db } from '../../db/client.js';
import { describeFailure, type SafeCause } from '../../lib/failure-cause.js';
import type { ReadinessReason } from '../../lib/readiness-reason.js';

/** The migrations bundled with this image (src/db/migrations or dist/db/migrations). */
const bundledMigrationsFolder = join(dirname(fileURLToPath(import.meta.url)), '../../db/migrations');

export interface BundledMigrationHead {
  count: number;
  createdAt: number;
  hash: string;
}

export function readBundledMigrationHead(folder = bundledMigrationsFolder): BundledMigrationHead {
  const migrations = readMigrationFiles({ migrationsFolder: folder });
  const head = migrations.at(-1);
  if (head === undefined) throw new Error('no bundled migrations');
  return { count: migrations.length, createdAt: head.folderMillis, hash: head.hash };
}


interface ReadinessRow {
  currentRole: string;
  isSuperuser: boolean;
  bypassesRls: boolean;
  schemaVersion: number | null;
  contractVersion: string | bigint | null;
  targetMinimumClientBuild: number | null;
  releaseId: string | null;
  imageDigest: string | null;
  migrationCompletedAt: Date | string | null;
  appliedCount: string | number | bigint | null;
  appliedCreatedAt: string | number | bigint | null;
  appliedHash: string | null;
}

interface CompatibilityRow {
  bundledHeadApplied: boolean;
  appliedThroughBundled: string | number | bigint;
  appliedCount: string | number | bigint;
  compatibleFromCount: number | null;
}

/** Ready, or the first thing that is wrong, from the closed reason list. */
export type ReadinessResult =
  | { ready: true }
  | { ready: false; reason: ReadinessReason; cause?: SafeCause };

const NOT_READY = (reason: ReadinessReason, cause?: SafeCause): ReadinessResult => (
  cause ? { ready: false, reason, cause } : { ready: false, reason }
);

export class ReadinessService {
  /** The bundled journal cannot change while the process runs; read it once. */
  private cachedBundledHead?: BundledMigrationHead;

  constructor(
    private readonly database: Db,
    private readonly expectedReleaseId?: string,
    private readonly bundledHead: () => BundledMigrationHead = readBundledMigrationHead,
  ) {}

  /** The boolean the probe answers with; exactly `check().ready`. */
  async isReady(): Promise<boolean> {
    return (await this.check()).ready;
  }

  async check(): Promise<ReadinessResult> {
    let bundled: BundledMigrationHead;
    try {
      // Only a successful read is cached: a failing read stays not ready and is retried.
      bundled = this.cachedBundledHead ??= this.bundledHead();
    } catch (error) {
      return NOT_READY('migrations_unreadable', describeFailure(error));
    }
    try {
      const [rows, compatibility] = await this.database.$client.begin(async (transaction) => {
        await transaction.unsafe(`SET LOCAL statement_timeout = '2500ms'`);
        const readiness = await transaction.unsafe<ReadinessRow[]>(`
          SELECT current_user AS "currentRole",
                 role.rolsuper AS "isSuperuser",
                 role.rolbypassrls AS "bypassesRls",
                 manifest.schema_version AS "schemaVersion",
                 manifest.contract_version AS "contractVersion",
                 manifest.target_minimum_client_build AS "targetMinimumClientBuild",
                 manifest.release_id AS "releaseId",
                 manifest.server_image_digest AS "imageDigest",
                 manifest.migration_completed_at AS "migrationCompletedAt",
                 head.migration_count AS "appliedCount",
                 head.head_created_at AS "appliedCreatedAt",
                 head.head_hash AS "appliedHash"
          FROM pg_catalog.pg_roles AS role
          JOIN public.deployment_manifest AS manifest ON manifest.singleton_key IS TRUE
          CROSS JOIN public.read_applied_migration_head() AS head
          WHERE role.rolname = current_user
          LIMIT 1
        `);
        // Only a database ahead of the image needs the compatibility floor.
        const ahead = readiness[0] !== undefined && Number(readiness[0].appliedCount) > bundled.count;
        const floor = ahead
          ? await transaction.unsafe<CompatibilityRow[]>(`
              SELECT bundled_head_applied AS "bundledHeadApplied",
                     applied_through_bundled AS "appliedThroughBundled",
                     applied_count AS "appliedCount",
                     compatible_from_count AS "compatibleFromCount"
              FROM public.read_migration_compatibility($1, $2)
            `, [bundled.hash, bundled.createdAt])
          : [];
        return [readiness, floor] as const;
      });
      const row = rows[0];
      // No row at all means the manifest or the role could not be read.
      if (row === undefined) return NOT_READY('contract_not_ready');
      // Ready at the exact bundled head. A database behind the image
      // (half-applied or skipped migration) is never ready.
      const atBundledHead = Number(row.appliedCount) === bundled.count
        && String(row.appliedCreatedAt) === String(bundled.createdAt)
        && row.appliedHash === bundled.hash;
      // A database ahead of the image (an image rolled back after an upgrade)
      // is ready only when this image's head is applied unchanged and every
      // later migration kept the compatibility floor at or below this image.
      const compatible = compatibility[0];
      const toleratedAhead = !atBundledHead
        && compatible !== undefined
        && compatible.bundledHeadApplied === true
        && Number(compatible.appliedThroughBundled) === bundled.count
        && Number(compatible.appliedCount) > bundled.count
        && compatible.compatibleFromCount !== null
        && compatible.compatibleFromCount <= bundled.count;

      if (!(row.currentRole === 'app_user' && !row.isSuperuser && !row.bypassesRls)) {
        return NOT_READY('runtime_role_unsafe');
      }
      if (!((row.schemaVersion ?? 0) >= 12 && BigInt(row.contractVersion ?? 0) >= 1n)) {
        return NOT_READY('contract_not_ready');
      }
      if (!(atBundledHead || toleratedAhead)) {
        return NOT_READY(Number(row.appliedCount) < bundled.count ? 'migrations_behind' : 'migrations_incompatible');
      }
      const manifestComplete = Number.isInteger(row.targetMinimumClientBuild)
        && (row.targetMinimumClientBuild ?? 0) >= 1
        && typeof row.releaseId === 'string'
        && row.releaseId.length > 0
        && typeof row.imageDigest === 'string'
        && row.imageDigest.length > 0
        && row.migrationCompletedAt !== null;
      if (!manifestComplete) return NOT_READY('contract_not_ready');
      if (this.expectedReleaseId !== undefined && row.releaseId !== this.expectedReleaseId) {
        return NOT_READY('release_mismatch');
      }
      return { ready: true };
    } catch (error) {
      return NOT_READY('database_unreachable', describeFailure(error));
    }
  }
}
