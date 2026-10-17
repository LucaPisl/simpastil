import { createHash } from 'node:crypto';
import { and, eq, isNull, sql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { TenantTransactionRunner, type TenantTransaction } from '../../db/tenant-transaction.js';
import {
  doseLogs,
  medicationCommandReceipts,
  medicationHandoffJournal,
  pills,
  preactivationMedicationReceipts,
  profiles,
  schedules,
} from '../../db/schema.js';
import { canonicalJson } from '../sync/sync-payload.js';
import { ConflictError, ErrorCode, ResourceError } from '../shared/errors.js';
import type { BridgeMedicationCommand } from './bridge-medication-command.schema.js';
import { lockMedicationLedgerAuthority } from './medication-authority.js';

type CommandResult = Record<string, unknown>;

function fingerprint(value: unknown): string {
  return createHash('sha256').update(canonicalJson(value), 'utf8').digest('hex');
}

type DoseSourceRow = {
  id: string;
  scheduleId: string;
  scheduledAt: Date;
  takenAt: Date | null;
  status: string;
  deletedAt: Date | null;
};

function truncateToSecond(value: Date): Date {
  return new Date(Math.floor(value.getTime() / 1000) * 1000);
}

function doseSourceFingerprint(row: DoseSourceRow, wholeSeconds = false): string {
  const iso = (value: Date | null): string | null => {
    if (!value) return null;
    return (wholeSeconds ? truncateToSecond(value) : value).toISOString();
  };
  return fingerprint({
    id: row.id,
    scheduleId: row.scheduleId,
    scheduledAt: iso(row.scheduledAt),
    takenAt: iso(row.takenAt),
    status: row.status,
    deletedAt: iso(row.deletedAt),
  });
}

/**
 * Shipped clients read the dose from a store that keeps whole seconds, so they
 * can only produce the second-truncated form of this fingerprint. Both forms
 * are accepted; every other difference is still a stale base.
 */
function doseSourceFingerprintMatches(row: DoseSourceRow, observed: string): boolean {
  return doseSourceFingerprint(row) === observed || doseSourceFingerprint(row, true) === observed;
}

async function allocateSequence(tx: TenantTransaction, userId: string): Promise<void> {
  const [row] = await tx.execute<{ sequence: string }>(sql`
    SELECT public.next_sync_server_sequence(${userId}::uuid)::text AS sequence
  `);
  if (!row?.sequence) throw new Error('medication stream sequence allocation failed');
}

function replayResult(
  receipt: { inputFingerprint: string; resultMetadata: unknown; commandId: string },
  inputFingerprint: string,
): CommandResult {
  if (receipt.inputFingerprint !== inputFingerprint) {
    throw new ConflictError('Command ID was already used for different input', receipt.commandId, ErrorCode.CONFLICT_MUTATION_REUSE);
  }
  return receipt.resultMetadata as CommandResult;
}

async function readPermanentReceipt(tx: TenantTransaction, userId: string, commandId: string) {
  const [row] = await tx.select().from(medicationCommandReceipts).where(and(
    eq(medicationCommandReceipts.userId, userId),
    eq(medicationCommandReceipts.commandId, commandId),
  ));
  return row;
}

async function readBridgeReceipt(tx: TenantTransaction, userId: string, commandId: string) {
  const [row] = await tx.select().from(preactivationMedicationReceipts).where(and(
    eq(preactivationMedicationReceipts.userId, userId),
    eq(preactivationMedicationReceipts.commandId, commandId),
  ));
  return row;
}

export class BridgeMedicationCommandService {
  private readonly transactions: TenantTransactionRunner;

  constructor(db: Db) {
    this.transactions = new TenantTransactionRunner(db);
  }

  execute(userId: string, command: BridgeMedicationCommand): Promise<CommandResult> {
    const inputFingerprint = fingerprint(command);
    return this.transactions.run(userId, async (tx) => {
      const ledgerActivated = await lockMedicationLedgerAuthority(tx);
      if (ledgerActivated === null) throw new ResourceError('Medication authority is unavailable', 503);

      const permanentReceipt = await readPermanentReceipt(tx, userId, command.commandId);
      if (permanentReceipt) return replayResult(permanentReceipt, inputFingerprint);
      const priorBridgeReceipt = await readBridgeReceipt(tx, userId, command.commandId);
      if (priorBridgeReceipt) {
        if (!priorBridgeReceipt.complete || !priorBridgeReceipt.resultMetadata) {
          throw new ConflictError('Bridge command is awaiting reconciliation', command.commandId, ErrorCode.CONFLICT_REVISION);
        }
        return replayResult(priorBridgeReceipt, inputFingerprint);
      }
      if (ledgerActivated) {
        throw new ResourceError('Legacy medication writes are closed after ledger activation', 409, ErrorCode.CONFLICT_REVISION);
      }

      // Match trigger lock order: tenant stream first, then pill and source rows.
      await allocateSequence(tx, userId);
      const concurrentPermanent = await readPermanentReceipt(tx, userId, command.commandId);
      if (concurrentPermanent) return replayResult(concurrentPermanent, inputFingerprint);
      const concurrentBridge = await readBridgeReceipt(tx, userId, command.commandId);
      if (concurrentBridge) {
        if (!concurrentBridge.complete || !concurrentBridge.resultMetadata) {
          throw new ConflictError('Bridge command is awaiting reconciliation', command.commandId, ErrorCode.CONFLICT_REVISION);
        }
        return replayResult(concurrentBridge, inputFingerprint);
      }

      const [ownedPill] = await tx.select({ pill: pills, ownerId: profiles.userId })
        .from(pills)
        .innerJoin(profiles, eq(pills.profileId, profiles.id))
        .where(and(
          eq(pills.id, command.pillId),
          eq(profiles.userId, userId),
          sql`${profiles.deletedAt} IS NULL`,
          sql`${pills.deletedAt} IS NULL`,
        ))
        .for('update');
      if (!ownedPill || ownedPill.ownerId !== userId) throw new ResourceError('Medication item not found', 404);

      const [ownedSchedule] = await tx.select({ id: schedules.id, pillId: schedules.pillId })
        .from(schedules)
        .innerJoin(pills, eq(schedules.pillId, pills.id))
        .innerJoin(profiles, eq(pills.profileId, profiles.id))
        .where(and(
          eq(schedules.id, command.scheduleId),
          eq(schedules.pillId, command.pillId),
          eq(profiles.userId, userId),
          sql`${schedules.deletedAt} IS NULL`,
          sql`${profiles.deletedAt} IS NULL`,
        ));
      if (!ownedSchedule) throw new ResourceError('Schedule not found', 404);

      const [currentDose] = await tx.select().from(doseLogs).where(and(
        eq(doseLogs.id, command.legacyDoseId),
        eq(doseLogs.scheduleId, command.scheduleId),
      )).for('update');
      if (currentDose?.deletedAt) {
        throw new ConflictError('Deleted legacy dose cannot be silently restored', undefined, ErrorCode.CONFLICT_REVISION);
      }
      const isUndo = command.status === 'pending';
      if (!currentDose && (isUndo || !command.allowCreate)) throw new ResourceError('Legacy dose source not found', 404);
      if (!currentDose) {
        const [duplicate] = await tx.select({ id: doseLogs.id }).from(doseLogs).where(and(
          eq(doseLogs.scheduleId, command.scheduleId),
          eq(doseLogs.scheduledAt, new Date(command.scheduledAt)),
          isNull(doseLogs.deletedAt),
        ));
        if (duplicate) throw new ConflictError('A different legacy dose already owns this schedule time', duplicate.id, ErrorCode.CONFLICT_DOSE_LOG);
      } else {
        if (currentDose.scheduledAt.getTime() !== new Date(command.scheduledAt).getTime()) {
          throw new ConflictError('Legacy dose locator does not match its scheduled time', currentDose.id, ErrorCode.CONFLICT_REVISION);
        }
        if (command.observedBaseDoseFingerprint
            && !doseSourceFingerprintMatches(currentDose, command.observedBaseDoseFingerprint)) {
          throw new ConflictError('Legacy dose changed since the observed base', currentDose.id, ErrorCode.CONFLICT_STALE_UPDATE);
        }
      }

      if (command.observedBasePillRevision !== null
          && (ownedPill.pill.revision.toString() !== command.observedBasePillRevision
            || ownedPill.pill.currentStock !== command.observedBaseStock)) {
        throw new ConflictError('Inventory changed since the observed base', command.pillId, ErrorCode.CONFLICT_STALE_UPDATE);
      }

      const beforeState = currentDose?.status === 'taken' ? 'taken' : 'skipped';
      const targetState = isUndo ? 'pending' : command.status === 'taken' ? 'taken' : 'skipped';
      const inventoryDelta = (targetState === 'taken' ? -1 : 0) - (beforeState === 'taken' ? -1 : 0);
      const trackedStock = ownedPill.pill.currentStock !== null;
      const resultingStock = trackedStock
        ? ownedPill.pill.currentStock! + inventoryDelta
        : null;
      if (resultingStock !== null && (!Number.isInteger(resultingStock)
          || resultingStock < -2_147_483_648 || resultingStock > 2_147_483_647)) {
        throw new ResourceError('Inventory result is outside the supported integer range', 409, ErrorCode.CONFLICT_REVISION);
      }
      const expectedSubeffectCount = 1 + (trackedStock && inventoryDelta !== 0 ? 1 : 0);

      const intentMetadata = {
        action: targetState,
        scheduleId: command.scheduleId,
        pillId: command.pillId,
        legacyDoseId: command.legacyDoseId,
        scheduledAt: new Date(command.scheduledAt).toISOString(),
        inventoryDelta: trackedStock ? inventoryDelta : null,
      };
      const now = new Date();
      // Undo is a soft delete: the row keeps its status and taken time and gains
      // deleted_at, which the 0015 trigger publishes as a bridge_dose tombstone.
      const plannedDoseFingerprint = isUndo
        ? doseSourceFingerprint({ ...currentDose!, deletedAt: now })
        : doseSourceFingerprint({
          id: command.legacyDoseId,
          scheduleId: command.scheduleId,
          scheduledAt: new Date(command.scheduledAt),
          takenAt: command.takenAt ? new Date(command.takenAt) : null,
          status: command.status,
          deletedAt: null,
        });
      await tx.insert(preactivationMedicationReceipts).values({
        userId,
        commandId: command.commandId,
        commandBundleId: command.commandBundleId,
        transactionCorrelationId: command.transactionCorrelationId,
        origin: 'bridge',
        inputFingerprint,
        sourceFingerprint: plannedDoseFingerprint,
        intentMetadata,
        plannedAt: targetState === 'taken' ? (command.takenAt ? new Date(command.takenAt) : null) : null,
        dateOnly: command.takenAt === null,
        inventoryDelta: trackedStock ? inventoryDelta : null,
        observedBaseStock: ownedPill.pill.currentStock,
        observedBaseRevision: ownedPill.pill.revision,
        targetStock: resultingStock,
        expectedSubeffectCount,
      });

      await tx.execute(sql`SELECT set_config('app.medication_command_bundle_id', ${command.commandBundleId}, true)`);
      await tx.execute(sql`SELECT set_config('app.transaction_correlation_id', ${command.transactionCorrelationId}, true)`);
      await tx.execute(sql`SELECT set_config('app.medication_command_id', ${command.commandId}, true)`);
      await tx.execute(sql`SELECT set_config('app.medication_command_fingerprint', ${inputFingerprint}, true)`);

      const [dose] = currentDose
        ? await tx.update(doseLogs).set(isUndo ? { deletedAt: now, updatedAt: now } : {
          status: command.status,
          takenAt: command.takenAt ? new Date(command.takenAt) : null,
          ...(command.note !== undefined ? { note: command.note } : {}),
          updatedAt: now,
        }).where(and(
          eq(doseLogs.id, currentDose.id),
          eq(doseLogs.scheduleId, command.scheduleId),
          // The row is already locked FOR UPDATE above. An updated_at compare
          // here would fail on microsecond-precision timestamps the JS Date
          // cannot round-trip (any row created with the database default).
        )).returning()
        : await tx.insert(doseLogs).values({
          id: command.legacyDoseId,
          scheduleId: command.scheduleId,
          scheduledAt: new Date(command.scheduledAt),
          takenAt: command.takenAt ? new Date(command.takenAt) : null,
          status: command.status,
          ...(command.note !== undefined ? { note: command.note } : {}),
        }).returning();
      if (!dose) throw new ConflictError('Legacy dose changed while applying the bridge command', undefined, ErrorCode.CONFLICT_STALE_UPDATE);

      let resultingPill = ownedPill.pill;
      if (trackedStock && inventoryDelta !== 0) {
        const [updatedPill] = await tx.update(pills).set({
          currentStock: resultingStock,
          revision: sql`${pills.revision} + 1`,
          lastMutationId: command.commandId,
          updatedAt: now,
        }).where(and(
          eq(pills.id, command.pillId),
          eq(pills.currentStock, ownedPill.pill.currentStock!),
          eq(pills.revision, ownedPill.pill.revision),
        )).returning();
        if (!updatedPill) throw new ConflictError('Inventory changed while applying the bridge command', command.pillId, ErrorCode.CONFLICT_STALE_UPDATE);
        resultingPill = updatedPill;
      }

      const journalRows = await tx.select({
        sourceKind: medicationHandoffJournal.legacySourceKind,
        sourceId: medicationHandoffJournal.legacySourceId,
        sourceRevision: medicationHandoffJournal.sourceRevision,
      }).from(medicationHandoffJournal).where(and(
        eq(medicationHandoffJournal.userId, userId),
        eq(medicationHandoffJournal.commandBundleId, command.commandBundleId),
      ));
      if (journalRows.length !== expectedSubeffectCount) {
        throw new Error(`Bridge command expected ${expectedSubeffectCount} journaled subeffects, observed ${journalRows.length}`);
      }

      const sourceFingerprint = doseSourceFingerprint(dose);
      if (sourceFingerprint !== plannedDoseFingerprint) {
        throw new Error('Bridge dose fingerprint differs from its preflight snapshot');
      }
      const result: CommandResult = {
        commandId: command.commandId,
        commandBundleId: command.commandBundleId,
        doseLogId: dose.id,
        status: isUndo ? 'pending' : dose.status,
        takenAt: isUndo ? null : dose.takenAt?.toISOString() ?? null,
        currentStock: resultingPill.currentStock,
        pillRevision: resultingPill.revision.toString(),
        inventoryTracked: trackedStock,
        inventoryDelta: trackedStock ? inventoryDelta : null,
        sourceFingerprint,
      };
      const adoptedIds = [...new Set(journalRows.map((row) => row.sourceId))];
      const [completedReceipt] = await tx.update(preactivationMedicationReceipts).set({
        adoptedLegacySourceIds: adoptedIds,
        observedSubeffectCount: journalRows.length,
        reconciliationDisposition: 'applied',
        complete: true,
        resultMetadata: result,
        completedAt: now,
      }).where(and(
        eq(preactivationMedicationReceipts.userId, userId),
        eq(preactivationMedicationReceipts.commandId, command.commandId),
        eq(preactivationMedicationReceipts.complete, false),
      )).returning();
      if (!completedReceipt) throw new Error('Bridge command receipt could not be completed');
      return result;
    });
  }
}
