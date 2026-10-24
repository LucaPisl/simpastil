import { createHash } from 'node:crypto';
import { and, eq, sql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { TenantTransactionRunner, type TenantTransaction } from '../../db/tenant-transaction.js';
import {
  inventoryEvents,
  medicationCommandReceipts,
  medicationHandoffJournal,
  migrationIssues,
  pills,
  preactivationMedicationReceipts,
  profiles,
} from '../../db/schema.js';
import { appendSyncChange } from './occurrence-materializer.js';
import { appendPillSyncChange } from '../sync/sync-change-writer.js';
import { canonicalJson } from '../sync/sync-payload.js';
import { ConflictError, ErrorCode, ResourceError } from '../shared/errors.js';
import { legacyStockInteger } from '../shared/stock-quantity.js';
import { SplitCheckpointSchema, type LegacySplitReconciliation } from './legacy-split-reconciliation.schema.js';
import { lockMedicationLedgerAuthority } from './medication-authority.js';

const ISSUE_ENTITY_TYPE = 'medication_split';
const ISSUE_CODE = 'legacy_split_checkpoint';
type Result = Record<string, unknown>;

function fingerprint(value: unknown): string {
  return createHash('sha256').update(canonicalJson(value), 'utf8').digest('hex');
}

async function allocateSequence(tx: TenantTransaction, userId: string): Promise<bigint> {
  const [row] = await tx.execute<{ sequence: string }>(sql`
    SELECT public.next_sync_server_sequence(${userId}::uuid)::text AS sequence
  `);
  if (!row?.sequence) throw new Error('medication stream sequence allocation failed');
  return BigInt(row.sequence);
}

function replayResult(
  receipt: { inputFingerprint: string; resultMetadata: unknown; commandId: string },
  inputFingerprint: string,
): Result {
  if (receipt.inputFingerprint !== inputFingerprint) {
    throw new ConflictError('Command ID was already used for different input', receipt.commandId, ErrorCode.CONFLICT_MUTATION_REUSE);
  }
  return receipt.resultMetadata as Result;
}

async function readPermanentReceipt(tx: TenantTransaction, userId: string, commandId: string) {
  const [row] = await tx.select().from(medicationCommandReceipts).where(and(
    eq(medicationCommandReceipts.userId, userId),
    eq(medicationCommandReceipts.commandId, commandId),
  ));
  return row;
}

async function readPreactivationReceipt(tx: TenantTransaction, userId: string, commandId: string) {
  const [row] = await tx.select().from(preactivationMedicationReceipts).where(and(
    eq(preactivationMedicationReceipts.userId, userId),
    eq(preactivationMedicationReceipts.commandId, commandId),
  ));
  return row;
}

function safeIssue(row: typeof migrationIssues.$inferSelect) {
  return {
    kind: 'migrationIssue',
    id: row.id,
    entityType: row.entityType,
    entityId: row.entityId,
    issueCode: row.issueCode,
    safeSnapshot: row.safeSnapshot,
    revision: row.revision.toString(),
    state: row.state,
    resolvedAt: row.resolvedAt?.toISOString() ?? null,
    createdAt: row.createdAt.toISOString(),
  };
}

export class LegacySplitReconciliationService {
  private readonly transactions: TenantTransactionRunner;

  constructor(db: Db) {
    this.transactions = new TenantTransactionRunner(db);
  }

  execute(userId: string, request: LegacySplitReconciliation): Promise<Result> {
    if (request.operation === 'record') return this.record(userId, request);
    return this.resolve(userId, request);
  }

  private record(
    userId: string,
    request: Extract<LegacySplitReconciliation, { operation: 'record' }>,
  ): Promise<Result> {
    return this.transactions.run(userId, async (tx) => {
      const ledgerActivated = await lockMedicationLedgerAuthority(tx);
      if (ledgerActivated === null) throw new ResourceError('Medication authority is unavailable', 503);
      await allocateSequence(tx, userId);
      const [recorded] = await tx.execute<{ id: string; inserted: boolean }>(sql`
        SELECT checkpoint.issue_id AS id, checkpoint.inserted
        FROM public.record_legacy_split_checkpoint_issue(
          ${userId}::uuid, ${request.issueId}::uuid, ${request.commandId}::uuid,
          ${JSON.stringify(request.checkpoint)}::jsonb
        ) AS checkpoint
      `);
      if (!recorded) throw new Error('Split checkpoint issue record returned no row');
      const [issue] = await tx.select().from(migrationIssues).where(and(
        eq(migrationIssues.userId, userId),
        eq(migrationIssues.id, recorded.id),
      ));
      if (!issue) throw new Error('Split checkpoint issue insert returned no row');
      if (issue.id !== request.issueId || issue.entityType !== ISSUE_ENTITY_TYPE
          || issue.entityId !== request.commandId || issue.issueCode !== ISSUE_CODE
          || canonicalJson(issue.safeSnapshot) !== canonicalJson(request.checkpoint)) {
        throw new ConflictError('Issue ID already identifies different review evidence', issue.id, ErrorCode.CONFLICT_MUTATION_REUSE);
      }
      if (!recorded.inserted) return { issue: safeIssue(issue), replayed: true };
      await appendSyncChange(tx, userId, {
        schemaVersion: 2,
        component: 'account',
        entityType: 'migration_issue',
        entityId: issue.id,
        operation: 'upsert',
        sourceIdentity: { sourceKind: 'migration_issue', sourceId: issue.id, sourceRevision: '1' },
        payload: {
          kind: 'migrationIssue',
          id: issue.id,
          entityType: issue.entityType,
          entityId: issue.entityId,
          issueCode: issue.issueCode,
          safeSnapshot: issue.safeSnapshot,
          revision: '1',
          state: 'unresolved',
          resolvedAt: null,
          createdAt: issue.createdAt.toISOString(),
        },
      });
      return { issue: safeIssue(issue), replayed: false };
    });
  }

  private resolve(
    userId: string,
    request: Extract<LegacySplitReconciliation, { operation: 'resolve' }>,
  ): Promise<Result> {
    const inputFingerprint = fingerprint(request);
    return this.transactions.run(userId, async (tx) => {
      const ledgerActivated = await lockMedicationLedgerAuthority(tx);
      if (ledgerActivated === null) throw new ResourceError('Medication authority is unavailable', 503);

      // Promoted receipts are checked before issue/source lookup so activation
      // cannot make an exact retry depend on mutable locators.
      const permanent = await readPermanentReceipt(tx, userId, request.commandId);
      if (permanent) return replayResult(permanent, inputFingerprint);
      const prior = await readPreactivationReceipt(tx, userId, request.commandId);
      if (prior) {
        if (!prior.complete || !prior.resultMetadata) {
          throw new ConflictError('Split reconciliation is incomplete and requires review', request.commandId, ErrorCode.CONFLICT_REVISION);
        }
        return replayResult(prior, inputFingerprint);
      }
      const eventSequence = await allocateSequence(tx, userId);
      const [concurrentPermanent] = await tx.select().from(medicationCommandReceipts).where(and(
        eq(medicationCommandReceipts.userId, userId),
        eq(medicationCommandReceipts.commandId, request.commandId),
      ));
      if (concurrentPermanent) return replayResult(concurrentPermanent, inputFingerprint);
      const [concurrentBridge] = await tx.select().from(preactivationMedicationReceipts).where(and(
        eq(preactivationMedicationReceipts.userId, userId),
        eq(preactivationMedicationReceipts.commandId, request.commandId),
      ));
      if (concurrentBridge) {
        if (!concurrentBridge.complete || !concurrentBridge.resultMetadata) {
          throw new ConflictError('Split reconciliation is incomplete and requires review', request.commandId, ErrorCode.CONFLICT_REVISION);
        }
        return replayResult(concurrentBridge, inputFingerprint);
      }

      const [issue] = await tx.select().from(migrationIssues).where(and(
        eq(migrationIssues.id, request.issueId),
        eq(migrationIssues.userId, userId),
        eq(migrationIssues.entityType, ISSUE_ENTITY_TYPE),
        eq(migrationIssues.issueCode, ISSUE_CODE),
      ));
      if (!issue) throw new ResourceError('Medication review issue not found', 404);
      if (issue.state !== 'unresolved' || issue.revision !== BigInt(request.baseIssueRevision)) {
        throw new ConflictError('Medication review issue was already resolved or changed', issue.id, ErrorCode.CONFLICT_STALE_UPDATE);
      }
      const checkpoint = SplitCheckpointSchema.parse(issue.safeSnapshot);
      const now = new Date();
      let expectedSubeffectCount = 0;
      let observedBaseStock: number | null = null;
      let observedBaseRevision: bigint | null = null;
      let targetStock: number | null = null;
      let inventoryDelta: number | null = null;
      let residualInventoryEventId: string | null = null;
      let adoptedLegacySourceIds: string[] = [];

      const bundleRowsBefore = await tx.select({
        sourceId: medicationHandoffJournal.legacySourceId,
        sourceKind: medicationHandoffJournal.legacySourceKind,
      }).from(medicationHandoffJournal).where(and(
        eq(medicationHandoffJournal.userId, userId),
        eq(medicationHandoffJournal.commandBundleId, request.commandBundleId),
      ));
      const existingBundleReceipts = await tx.select({ id: preactivationMedicationReceipts.id })
        .from(preactivationMedicationReceipts).where(and(
          eq(preactivationMedicationReceipts.userId, userId),
          eq(preactivationMedicationReceipts.commandBundleId, request.commandBundleId),
        ));
      if (existingBundleReceipts.length) {
        throw new ConflictError('Command bundle already has a reconciliation receipt', request.commandBundleId, ErrorCode.CONFLICT_REVISION);
      }

      if (request.resolution === 'adopt') {
        if (!checkpoint.sourceFingerprint || !checkpoint.legacySourceKind || !checkpoint.legacySourceId) {
          throw new ConflictError('Checkpoint lacks exact source identity and fingerprint evidence', issue.id, ErrorCode.CONFLICT_REVISION);
        }
        const sourceRows = await tx.select({
          id: medicationHandoffJournal.id,
          sourceId: medicationHandoffJournal.legacySourceId,
          sourceKind: medicationHandoffJournal.legacySourceKind,
          commandBundleId: medicationHandoffJournal.commandBundleId,
          transactionCorrelationId: medicationHandoffJournal.transactionCorrelationId,
          commandFingerprint: medicationHandoffJournal.commandFingerprint,
          afterEvidence: medicationHandoffJournal.afterEvidence,
        }).from(medicationHandoffJournal).where(and(
          eq(medicationHandoffJournal.userId, userId),
          eq(medicationHandoffJournal.legacySourceKind, checkpoint.legacySourceKind),
          eq(medicationHandoffJournal.legacySourceId, checkpoint.legacySourceId),
        ));
        const exactRows = sourceRows.filter((row) => row.commandFingerprint === checkpoint.sourceFingerprint
          || (row.afterEvidence !== null
            && fingerprint(row.afterEvidence) === checkpoint.sourceFingerprint));
        if (exactRows.length !== 1 || exactRows[0]!.commandBundleId !== request.commandBundleId
            || exactRows[0]!.transactionCorrelationId !== request.transactionCorrelationId
            || bundleRowsBefore.length === 0 || bundleRowsBefore.length > 128) {
          throw new ConflictError('Source evidence is absent or ambiguous; it remains unresolved', issue.id, ErrorCode.CONFLICT_REVISION);
        }
        expectedSubeffectCount = bundleRowsBefore.length;
        adoptedLegacySourceIds = [...new Set(bundleRowsBefore.map((row) => row.sourceId))];
      } else if (request.resolution === 'keep_server_state') {
        if (bundleRowsBefore.length > 128) {
          throw new ConflictError('Command bundle exceeds the safe reconciliation bound', issue.id, ErrorCode.CONFLICT_REVISION);
        }
        expectedSubeffectCount = bundleRowsBefore.length;
        adoptedLegacySourceIds = [...new Set(bundleRowsBefore.map((row) => row.sourceId))];
      } else if (request.resolution === 'apply_residual') {
        if (checkpoint.reason !== 'source_missing' || checkpoint.legacySourceKind !== 'pill_stock'
            || !checkpoint.legacySourceId || checkpoint.observedBaseRevision === null
            || checkpoint.observedBaseStock === null || checkpoint.targetStock === null
            || !checkpoint.sourceFingerprint) {
          throw new ConflictError('Residual requires an exact missing stock effect and a complete observed base', issue.id, ErrorCode.CONFLICT_REVISION);
        }
        const priorSourceRows = await tx.select({
          commandFingerprint: medicationHandoffJournal.commandFingerprint,
          afterEvidence: medicationHandoffJournal.afterEvidence,
        })
          .from(medicationHandoffJournal)
          .where(and(
            eq(medicationHandoffJournal.userId, userId),
            eq(medicationHandoffJournal.legacySourceKind, 'pill_stock'),
            eq(medicationHandoffJournal.legacySourceId, checkpoint.legacySourceId),
          ));
        const possiblePrior = priorSourceRows.some((row) => row.commandFingerprint === checkpoint.sourceFingerprint
          || (row.afterEvidence !== null
            && fingerprint(row.afterEvidence) === checkpoint.sourceFingerprint));
        if (possiblePrior) {
          throw new ConflictError('The source effect is not exactly absent; residual was not applied', issue.id, ErrorCode.CONFLICT_REVISION);
        }
        if (bundleRowsBefore.length) {
          throw new ConflictError('Residual requires a fresh command bundle with no prior journaled effects', issue.id, ErrorCode.CONFLICT_REVISION);
        }
        const [ownedPill] = await tx.select({ pill: pills, ownerId: profiles.userId })
          .from(pills)
          .innerJoin(profiles, eq(pills.profileId, profiles.id))
          .where(and(
            eq(pills.id, checkpoint.legacySourceId),
            eq(profiles.userId, userId),
            sql`${pills.deletedAt} IS NULL`,
            sql`${profiles.deletedAt} IS NULL`,
          ))
          .for('update');
        if (!ownedPill || ownedPill.ownerId !== userId) throw new ResourceError('Medication item not found', 404);
        if (legacyStockInteger(ownedPill.pill.currentStock) !== checkpoint.observedBaseStock
            || ownedPill.pill.revision !== BigInt(checkpoint.observedBaseRevision)) {
          throw new ConflictError('Stock no longer matches the observed base; residual was not applied', checkpoint.legacySourceId, ErrorCode.CONFLICT_STALE_UPDATE);
        }
        inventoryDelta = checkpoint.targetStock - checkpoint.observedBaseStock;
        if (inventoryDelta === 0) {
          throw new ConflictError('Equal stock is not evidence that a missing effect was applied', issue.id, ErrorCode.CONFLICT_REVISION);
        }
        if (inventoryDelta < -2_147_483_648 || inventoryDelta > 2_147_483_647) {
          throw new ResourceError('Residual inventory delta is outside the supported integer range', 409, ErrorCode.CONFLICT_REVISION);
        }
        const projected = legacyStockInteger(ownedPill.pill.currentStock)! + inventoryDelta;
        if (!Number.isInteger(projected) || projected < -2_147_483_648 || projected > 2_147_483_647) {
          throw new ResourceError('Inventory result is outside the supported integer range', 409, ErrorCode.CONFLICT_REVISION);
        }
        observedBaseStock = legacyStockInteger(ownedPill.pill.currentStock);
        observedBaseRevision = ownedPill.pill.revision;
        targetStock = projected;
        expectedSubeffectCount = 1;
      }

      const receiptInput = {
        userId,
        commandId: request.commandId,
        commandBundleId: request.commandBundleId,
        transactionCorrelationId: request.transactionCorrelationId,
        origin: 'legacy_split_reconciliation' as const,
        inputFingerprint,
        sourceFingerprint: checkpoint.sourceFingerprint,
        intentMetadata: {
          issueId: issue.id,
          resolution: request.resolution,
          legacySourceKind: checkpoint.legacySourceKind,
          legacySourceId: checkpoint.legacySourceId,
        },
        inventoryDelta,
        observedBaseStock,
        observedBaseRevision,
        targetStock,
        adoptedLegacySourceIds,
        expectedSubeffectCount,
      };
      await tx.insert(preactivationMedicationReceipts).values(receiptInput);

      if (request.resolution === 'apply_residual') {
        if (ledgerActivated) {
          const [inventoryEvent] = await tx.insert(inventoryEvents).values({
            userId,
            pillId: checkpoint.legacySourceId!,
            commandId: request.commandId,
            kind: 'correction',
            delta: String(inventoryDelta!),
            occurrenceEventId: null,
            reversesInventoryEventId: null,
            provenance: 'legacy_handoff',
            note: 'Late legacy split reconciliation residual',
            serverSequence: eventSequence,
            recordedAt: now,
          }).returning();
          if (!inventoryEvent) throw new Error('Residual inventory event insert returned no row');
          residualInventoryEventId = inventoryEvent.id;
        }
        await tx.execute(sql`SELECT set_config('app.medication_command_bundle_id', ${request.commandBundleId}, true)`);
        await tx.execute(sql`SELECT set_config('app.transaction_correlation_id', ${request.transactionCorrelationId}, true)`);
        await tx.execute(sql`SELECT set_config('app.medication_command_id', ${request.commandId}, true)`);
        await tx.execute(sql`SELECT set_config('app.medication_command_fingerprint', ${inputFingerprint}, true)`);
        const [updatedPill] = await tx.update(pills).set({
          currentStock: targetStock === null ? null : String(targetStock),
          revision: sql`${pills.revision} + 1`,
          lastMutationId: request.commandId,
          updatedAt: now,
        }).where(and(
          eq(pills.id, checkpoint.legacySourceId!),
          eq(pills.currentStock, String(observedBaseStock!)),
          eq(pills.revision, observedBaseRevision!),
        )).returning();
        if (!updatedPill) throw new ConflictError('Stock changed during residual application', checkpoint.legacySourceId!, ErrorCode.CONFLICT_STALE_UPDATE);
        if (ledgerActivated) {
          if (!residualInventoryEventId) throw new Error('Active residual inventory event is missing');
          const [inventoryEvent] = await tx.select().from(inventoryEvents).where(and(
            eq(inventoryEvents.id, residualInventoryEventId),
            eq(inventoryEvents.userId, userId),
          ));
          if (!inventoryEvent) throw new Error('Active residual inventory event could not be read back');
          await appendSyncChange(tx, userId, {
            schemaVersion: 2,
            component: 'medication',
            entityType: 'inventory_event',
            entityId: inventoryEvent.id,
            operation: 'upsert',
            sourceIdentity: {
              sourceKind: 'inventory_event',
              sourceId: inventoryEvent.id,
              sourceRevision: inventoryEvent.serverSequence.toString(),
            },
            payload: {
              kind: 'inventoryEvent',
              id: inventoryEvent.id,
              pillId: inventoryEvent.pillId,
              commandId: inventoryEvent.commandId,
              eventKind: inventoryEvent.kind,
              delta: Number(inventoryEvent.delta),
              occurrenceEventId: null,
              reversesInventoryEventId: null,
              provenance: inventoryEvent.provenance,
              note: inventoryEvent.note,
              serverSequence: inventoryEvent.serverSequence.toString(),
              recordedAt: inventoryEvent.recordedAt.toISOString(),
            },
          });
          await appendPillSyncChange(tx, userId, updatedPill);
        } else {
          const journalRows = await tx.select({
            sourceId: medicationHandoffJournal.legacySourceId,
            sourceRevision: medicationHandoffJournal.sourceRevision,
          }).from(medicationHandoffJournal).where(and(
            eq(medicationHandoffJournal.userId, userId),
            eq(medicationHandoffJournal.commandBundleId, request.commandBundleId),
            eq(medicationHandoffJournal.commandId, request.commandId),
            eq(medicationHandoffJournal.legacySourceKind, 'pill_stock'),
            eq(medicationHandoffJournal.legacySourceId, checkpoint.legacySourceId!),
          ));
          if (journalRows.length !== 1) throw new Error('Residual stock write did not produce exactly one journal row');
        }
        adoptedLegacySourceIds = [checkpoint.legacySourceId!];
      }

      const disposition = request.resolution === 'adopt' ? 'adopted'
        : request.resolution === 'apply_residual' ? 'residual_applied' : 'kept_server_state';
      const result: Result = {
        commandId: request.commandId,
        issueId: issue.id,
        resolution: request.resolution,
        disposition,
        sourceIds: adoptedLegacySourceIds,
        targetStock,
      };
      const [receipt] = await tx.update(preactivationMedicationReceipts).set({
        adoptedLegacySourceIds,
        observedSubeffectCount: expectedSubeffectCount,
        reconciliationDisposition: disposition,
        complete: true,
        resultMetadata: result,
        completedAt: now,
      }).where(and(
        eq(preactivationMedicationReceipts.userId, userId),
        eq(preactivationMedicationReceipts.commandId, request.commandId),
        eq(preactivationMedicationReceipts.complete, false),
      )).returning();
      if (!receipt) throw new Error('Split reconciliation receipt could not be completed');

      if (ledgerActivated) {
        await tx.insert(medicationCommandReceipts).values({
          userId,
          commandId: request.commandId,
          inputFingerprint,
          origin: 'legacy_handoff',
          resultMetadata: result,
          preactivationReceiptId: receipt.id,
        });
      }

      const [resolvedIssueId] = await tx.execute<{ id: string | null }>(sql`
        SELECT public.resolve_legacy_split_checkpoint_issue(
          ${userId}::uuid, ${issue.id}::uuid, ${issue.entityId}::uuid,
          ${BigInt(request.baseIssueRevision)}::bigint
        )::text AS id
      `);
      const [resolvedIssue] = resolvedIssueId?.id
        ? await tx.select().from(migrationIssues).where(and(
            eq(migrationIssues.id, resolvedIssueId.id),
            eq(migrationIssues.userId, userId),
          ))
        : [];
      if (!resolvedIssue) throw new ConflictError('Medication issue changed during resolution', issue.id, ErrorCode.CONFLICT_STALE_UPDATE);
      await appendSyncChange(tx, userId, {
        schemaVersion: 2,
        component: 'account',
        entityType: 'migration_issue',
        entityId: resolvedIssue.id,
        operation: 'upsert',
        sourceIdentity: {
          sourceKind: 'migration_issue',
          sourceId: resolvedIssue.id,
          sourceRevision: resolvedIssue.revision.toString(),
        },
        payload: {
          kind: 'migrationIssue',
          id: resolvedIssue.id,
          entityType: resolvedIssue.entityType,
          entityId: resolvedIssue.entityId,
          issueCode: resolvedIssue.issueCode,
          safeSnapshot: {
            ...SplitCheckpointSchema.parse(resolvedIssue.safeSnapshot),
            settlement: {
              version: 1,
              commandId: request.commandId,
              resolution: request.resolution,
              disposition,
              issueId: issue.id,
            },
          },
          revision: resolvedIssue.revision.toString(),
          state: 'resolved',
          resolvedAt: resolvedIssue.resolvedAt?.toISOString() ?? now.toISOString(),
          createdAt: resolvedIssue.createdAt.toISOString(),
        },
      });
      return result;
    });
  }
}
