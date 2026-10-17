import { createHash } from 'node:crypto';
import { and, eq, sql } from 'drizzle-orm';
import { entityMutationReceipts } from '../../db/schema.js';
import { TenantTransactionRunner, type TenantTransaction } from '../../db/tenant-transaction.js';
import { appendSyncChange } from '../sync/sync-change-writer.js';
import { ApiError } from '../shared/api-error.js';
import {
  AdministrationAmountSchema,
  type AdministrationAmount,
} from '../shared/administration-amount.js';
import { ErrorCode, ResourceError } from '../shared/errors.js';

export type StableEntityType = 'profiles' | 'pills' | 'schedules';
export type StableMutationOperation = 'create' | 'update' | 'delete';
export type SafeMutationEntity = Record<string, unknown>;

export interface MutationEntityVersion<T extends SafeMutationEntity> {
  revision: bigint;
  entity: T;
}

export interface EntityMutationPlan<T extends SafeMutationEntity> {
  userId: string;
  mutationId: string;
  entityType: StableEntityType;
  operation: StableMutationOperation;
  /** Candidate ID used for a create or the exact path ID for update/delete. */
  entityId: string;
  /** Only set when the caller supplied a create ID or the path identifies the entity. */
  expectedEntityId?: string;
  baseRevision?: bigint;
  /** Include parent path IDs and normalized safe request fields. */
  input: unknown;
  write: (tx: TenantTransaction) => Promise<MutationEntityVersion<T> | undefined>;
  readCurrent: (tx: TenantTransaction) => Promise<MutationEntityVersion<T> | undefined>;
}

function canonicalJson(value: unknown): string {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') {
    return JSON.stringify(value);
  }
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new TypeError('Mutation input contains a non-finite number');
    return JSON.stringify(value);
  }
  if (typeof value === 'bigint') return JSON.stringify(value.toString());
  if (value instanceof Date) return JSON.stringify(value.toISOString());
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (typeof value === 'object') {
    const record = value as Record<string, unknown>;
    const keys = Object.keys(record).filter((key) => record[key] !== undefined).sort();
    return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalJson(record[key])}`).join(',')}}`;
  }
  throw new TypeError('Mutation input is not JSON-compatible');
}

function fingerprint(plan: EntityMutationPlan<SafeMutationEntity>): string {
  const canonicalInput = canonicalJson({
    entityType: plan.entityType,
    operation: plan.operation,
    entityId: plan.expectedEntityId ?? null,
    baseRevision: plan.baseRevision?.toString() ?? null,
    input: plan.input,
  });
  return createHash('sha256').update(canonicalInput, 'utf8').digest('hex');
}

function replayEntity<T extends SafeMutationEntity>(metadata: unknown): T {
  if (metadata && typeof metadata === 'object' && !Array.isArray(metadata)) {
    const value = metadata as Record<string, unknown>;
    const entity = value['entity'];
    if (value['version'] === 1 && entity && typeof entity === 'object' && !Array.isArray(entity)) {
      return entity as T;
    }
  }
  throw new ApiError(500, ErrorCode.INTERNAL, 'Stored mutation result is unavailable');
}

export function revisionConflict<T extends SafeMutationEntity>(
  entityType: StableEntityType,
  current: MutationEntityVersion<T>,
): ApiError {
  return new ApiError(409, ErrorCode.CONFLICT_REVISION, 'Resource has changed', {
    retryable: false,
    details: {
      currentRevision: current.revision.toString(),
      currentEntity: { entityType, ...current.entity },
    },
  });
}

function isTombstone<T extends SafeMutationEntity>(current: MutationEntityVersion<T>): boolean {
  const deletedAt = current.entity['deletedAt'];
  return deletedAt !== null && deletedAt !== undefined;
}

function duplicateDetails<T extends SafeMutationEntity>(
  entityType: StableEntityType,
  current: MutationEntityVersion<T>,
): Record<string, unknown> {
  return {
    existingId: current.entity['id'],
    currentEntity: { entityType, ...current.entity },
  };
}

export class EntityMutationService {
  constructor(private readonly transactions: TenantTransactionRunner) {}

  async execute<T extends SafeMutationEntity>(plan: EntityMutationPlan<T>): Promise<T> {
    const inputFingerprint = fingerprint(plan as EntityMutationPlan<SafeMutationEntity>);

    return this.transactions.run(plan.userId, async (tx) => {
      // Serialize requests sharing the tenant-scoped retry key before receipt lookup.
      // Hash collisions only serialize unrelated requests; the unique receipt key remains authoritative.
      await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(
        ${plan.userId}::text || ':' || ${plan.mutationId}::text, 0
      ))`);

      const [receipt] = await tx
        .select()
        .from(entityMutationReceipts)
        .where(and(
          eq(entityMutationReceipts.userId, plan.userId),
          eq(entityMutationReceipts.mutationId, plan.mutationId),
        ));

      if (receipt) {
        const matches = receipt.entityType === plan.entityType
          && receipt.operation === plan.operation
          && receipt.inputFingerprint === inputFingerprint
          && (!plan.expectedEntityId || receipt.entityId === plan.expectedEntityId);
        if (!matches) {
          throw new ApiError(409, ErrorCode.CONFLICT_MUTATION_REUSE, 'Mutation ID was already used for different input', {
            retryable: false,
          });
        }
        return replayEntity<T>(receipt.resultMetadata);
      }

      let outcome = await plan.write(tx);
      let alreadyApplied = false;
      if (!outcome) {
        // readCurrent includes soft-deleted rows so tombstones can be reported.
        const current = await plan.readCurrent(tx);
        if (plan.operation === 'create') {
          throw new ApiError(409, ErrorCode.CONFLICT_DUPLICATE, 'Entity identifier is already in use', {
            retryable: false,
            ...(current ? { details: duplicateDetails(plan.entityType, current) } : {}),
          });
        }
        if (!current) throw new ResourceError('Resource not found', 404);
        if (isTombstone(current)) {
          if (plan.operation === 'update') {
            throw new ApiError(404, ErrorCode.RESOURCE_NOT_FOUND, 'Resource not found', {
              retryable: false,
              details: { currentEntity: { entityType: plan.entityType, ...current.entity } },
            });
          }
          // Deleting what is already deleted reached the desired state: succeed
          // under this mutation ID without a second tombstone in the sync stream.
          outcome = current;
          alreadyApplied = true;
        } else {
          throw revisionConflict(plan.entityType, current);
        }
      }

      if (!alreadyApplied && (plan.entityType === 'profiles' || plan.entityType === 'pills')) {
        await appendSyncChange(tx, plan.userId, stableSyncChange(plan, outcome));
      }

      // The receipt check constraint ties result = base + 1 with base > 0. An
      // idempotent delete of a tombstone documents the transition that created
      // that tombstone. A tombstone left at revision 1 by a pre-0013 delete has
      // no earlier revision to document, so the receipt records 1 -> 2; the
      // returned entity (and replay metadata) is the stored tombstone as is.
      const baseRevision = alreadyApplied
        ? (outcome.revision > 1n ? outcome.revision - 1n : 1n)
        : (plan.baseRevision ?? null);
      await tx.insert(entityMutationReceipts).values({
        userId: plan.userId,
        mutationId: plan.mutationId,
        entityType: plan.entityType,
        entityId: plan.entityId,
        operation: plan.operation,
        baseRevision,
        resultRevision: alreadyApplied && baseRevision !== null ? baseRevision + 1n : outcome.revision,
        inputFingerprint,
        resultMetadata: { version: 1, entity: outcome.entity },
      });
      return outcome.entity;
    });
  }
}

function stableSyncChange<T extends SafeMutationEntity>(
  plan: EntityMutationPlan<T>,
  outcome: MutationEntityVersion<T>,
): unknown {
  const entity = outcome.entity;
  const revision = outcome.revision.toString();
  const id = requiredString(entity, 'id');
  const common = {
    schemaVersion: 2,
    component: 'stable',
    entityId: id,
    sourceIdentity: {
      sourceKind: plan.entityType === 'profiles' ? 'profile' : 'pill',
      sourceId: id,
      sourceRevision: revision,
    },
  };
  const entityType = plan.entityType === 'profiles' ? 'profile' : 'pill';
  if (plan.operation === 'delete') {
    return {
      ...common,
      entityType,
      operation: 'tombstone',
      payload: {
        kind: 'tombstone',
        entityType,
        id,
        revision,
        deletedAt: requiredString(entity, 'deletedAt'),
      },
    };
  }

  const payload = plan.entityType === 'profiles'
    ? {
      kind: 'profile',
      id,
      userId: requiredString(entity, 'userId'),
      name: requiredString(entity, 'name'),
      avatarEmoji: requiredString(entity, 'avatarEmoji'),
      isActive: requiredBoolean(entity, 'isActive'),
      revision,
      deletedAt: null,
      createdAt: requiredString(entity, 'createdAt'),
      updatedAt: requiredString(entity, 'updatedAt'),
    }
    : {
      kind: 'pill',
      id,
      profileId: requiredString(entity, 'profileId'),
      name: requiredString(entity, 'name'),
      dosage: nullableString(entity, 'dosage'),
      notes: nullableString(entity, 'notes'),
      color: nullableString(entity, 'color'),
      currentStock: nullableNumber(entity, 'currentStock'),
      lowStockThreshold: nullableNumber(entity, 'lowStockThreshold'),
      isPrn: requiredBoolean(entity, 'isPrn'),
      amountPerUse: nullableAmount(entity, 'amountPerUse'),
      packageStrength: nullableString(entity, 'packageStrength'),
      form: nullableString(entity, 'form'),
      legacyDosageReviewed: requiredBoolean(entity, 'legacyDosageReviewed'),
      revision,
      deletedAt: null,
      createdAt: requiredString(entity, 'createdAt'),
      updatedAt: requiredString(entity, 'updatedAt'),
    };
  return { ...common, entityType, operation: 'upsert', payload };
}

function requiredString(value: SafeMutationEntity, key: string): string {
  const field = value[key];
  if (typeof field !== 'string') throw new Error(`stable sync field ${key} is unavailable`);
  return field;
}

function nullableString(value: SafeMutationEntity, key: string): string | null {
  const field = value[key];
  if (field === null || field === undefined) return null;
  if (typeof field !== 'string') throw new Error(`stable sync field ${key} is invalid`);
  return field;
}

function requiredBoolean(value: SafeMutationEntity, key: string): boolean {
  const field = value[key];
  if (typeof field !== 'boolean') throw new Error(`stable sync field ${key} is invalid`);
  return field;
}

/// A stored sync payload is re-parsed on every pull, so a malformed amount
/// written once would fail that parse forever. Validate it here with the same
/// schema the pull uses rather than trusting the column.
function nullableAmount(value: SafeMutationEntity, key: string): AdministrationAmount | null {
  const field = value[key];
  if (field === null || field === undefined) return null;
  const parsed = AdministrationAmountSchema.safeParse(field);
  if (!parsed.success) throw new Error(`stable sync field ${key} is invalid`);
  return parsed.data;
}

function nullableNumber(value: SafeMutationEntity, key: string): number | null {
  const field = value[key];
  if (field === null || field === undefined) return null;
  if (typeof field !== 'number' || !Number.isSafeInteger(field)) {
    throw new Error(`stable sync field ${key} is invalid`);
  }
  return field;
}
