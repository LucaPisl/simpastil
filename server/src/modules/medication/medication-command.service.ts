import { createHash, randomUUID } from 'node:crypto';
import { and, desc, eq, isNull, sql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { TenantTransactionRunner, type TenantTransaction } from '../../db/tenant-transaction.js';
import {
  inventoryEvents,
  medicationCommandReceipts,
  medicationOccurrences,
  occurrenceEvents,
  pills,
  profiles,
} from '../../db/schema.js';
import { appendSyncChange } from './occurrence-materializer.js';
import { appendPillSyncChange } from '../sync/sync-change-writer.js';
import { canonicalJson } from '../sync/sync-payload.js';
import { ConflictError, ErrorCode, ResourceError } from '../shared/errors.js';
import type { InventoryCommand, MedicationCommand } from './medication-command.schema.js';
import { reduceOccurrenceCommand, type OccurrenceState } from './occurrence-reducer.js';
import { lockMedicationLedgerAuthority } from './medication-authority.js';

type CommandResult = Record<string, unknown>;

function fingerprint(command: unknown): string {
  return createHash('sha256').update(canonicalJson(command), 'utf8').digest('hex');
}

async function allocateSequence(tx: TenantTransaction, userId: string): Promise<bigint> {
  const [row] = await tx.execute<{ sequence: string }>(sql`
    SELECT public.next_sync_server_sequence(${userId}::uuid)::text AS sequence
  `);
  if (!row?.sequence) throw new Error('medication stream sequence allocation failed');
  return BigInt(row.sequence);
}

async function readCommandReceipt(
  tx: TenantTransaction,
  userId: string,
  commandId: string,
) {
  const [receipt] = await tx.select().from(medicationCommandReceipts).where(and(
    eq(medicationCommandReceipts.userId, userId),
    eq(medicationCommandReceipts.commandId, commandId),
  ));
  return receipt;
}

function replayReceipt(
  receipt: NonNullable<Awaited<ReturnType<typeof readCommandReceipt>>>,
  inputFingerprint: string,
): CommandResult {
  if (receipt.inputFingerprint !== inputFingerprint) {
    throw new ConflictError('Command ID was already used for different input', receipt.commandId, ErrorCode.CONFLICT_MUTATION_REUSE);
  }
  return receipt.resultMetadata as CommandResult;
}

function stateFromValue(value: string): OccurrenceState {
  if (value === 'pending' || value === 'taken' || value === 'skipped' || value === 'missed') return value;
  throw new Error(`Unexpected occurrence state: ${value}`);
}

/**
 * The app never records a miss sooner than this after the planned time: it is
 * the smallest value of the "record missed doses after" setting.
 */
const MISS_MIN_DELAY_MS = 60_000;

/**
 * How far a client clock may run ahead of the server's before a legitimate
 * miss is refused. It stays well under [MISS_MIN_DELAY_MS], so a dose can never
 * be recorded as missed before its planned time on the server's clock.
 */
const MISS_CLOCK_SKEW_TOLERANCE_MS = 30_000;

/**
 * A miss is an automatic record the app writes after a scheduled dose's
 * planned time plus the person's delay. Only an exact, expected, current
 * scheduled occurrence that is at least the smallest allowed delay past its
 * planned time on the server's clock (less a small skew tolerance) can become
 * missed.
 */
function assertMissAllowed(
  occurrence: Pick<
    typeof medicationOccurrences.$inferSelect,
    'source' | 'expected' | 'provenance' | 'supersededAt' | 'plannedAt'
  >,
  now: Date,
): void {
  if (
    occurrence.source !== 'scheduled'
    || !occurrence.expected
    || occurrence.provenance !== 'exact'
    || occurrence.supersededAt !== null
    || occurrence.plannedAt === null
    || occurrence.plannedAt.getTime() + MISS_MIN_DELAY_MS - MISS_CLOCK_SKEW_TOLERANCE_MS > now.getTime()
  ) {
    throw new ResourceError(
      'Only an exact scheduled dose whose planned time has passed can be recorded as missed',
      422,
      ErrorCode.MISS_NOT_ALLOWED,
    );
  }
}

function asIso(value: Date | null): string | null {
  return value?.toISOString() ?? null;
}

export class MedicationCommandService {
  private readonly transactions: TenantTransactionRunner;

  constructor(db: Db) {
    this.transactions = new TenantTransactionRunner(db);
  }

  execute(userId: string, command: MedicationCommand): Promise<CommandResult> {
    const inputFingerprint = fingerprint(command);
    return this.transactions.run(userId, async (tx) => {
      const ledgerActivated = await lockMedicationLedgerAuthority(tx);
      if (ledgerActivated === null) throw new ResourceError('Medication authority is unavailable', 503);

      // A permanent receipt is the retry authority: return it before looking up
      // the locator, whose occurrence may since have been superseded.
      const prior = await readCommandReceipt(tx, userId, command.commandId);
      if (prior) return replayReceipt(prior, inputFingerprint);
      if (!ledgerActivated) {
        throw new ResourceError('The medication ledger is not active; use the bridge command', 409, ErrorCode.CONFLICT_REVISION);
      }

      const [locator] = await tx.select({
        id: medicationOccurrences.id,
        pillId: medicationOccurrences.pillId,
        occurrenceKey: medicationOccurrences.occurrenceKey,
      }).from(medicationOccurrences).where(and(
        eq(medicationOccurrences.userId, userId),
        eq(medicationOccurrences.id, command.occurrenceId),
      ));
      if (!locator || locator.occurrenceKey !== command.occurrenceKey || !locator.pillId) {
        throw new ConflictError('Occurrence identity is missing or does not match; it was not retargeted', undefined, ErrorCode.CONFLICT_REVISION);
      }

      // Acquire the tenant stream lock before any pill/source-row lock. The
      // pill-stock statement trigger uses this same order during the bridge.
      const eventSequence = await allocateSequence(tx, userId);

      // The stream lock serializes same-tenant command receipt creation. Check
      // again after waiting so concurrent retries cannot apply twice.
      const concurrentReceipt = await readCommandReceipt(tx, userId, command.commandId);
      if (concurrentReceipt) return replayReceipt(concurrentReceipt, inputFingerprint);

      const [ownedPill] = await tx.select({ pill: pills, ownerId: profiles.userId })
        .from(pills)
        .innerJoin(profiles, eq(pills.profileId, profiles.id))
        .where(and(
          eq(pills.id, locator.pillId),
          eq(profiles.userId, userId),
          isNull(pills.deletedAt),
          isNull(profiles.deletedAt),
        ))
        .for('update');
      if (!ownedPill || ownedPill.ownerId !== userId) throw new ResourceError('Medication item not found', 404);

      const [occurrence] = await tx.select().from(medicationOccurrences).where(and(
        eq(medicationOccurrences.id, command.occurrenceId),
        eq(medicationOccurrences.userId, userId),
        eq(medicationOccurrences.occurrenceKey, command.occurrenceKey),
      )).for('update');
      if (!occurrence) throw new ConflictError('Occurrence identity is missing; it was not retargeted', undefined, ErrorCode.CONFLICT_REVISION);
      if (command.action === 'miss') assertMissAllowed(occurrence, new Date());
      if (occurrence.supersededAt) {
        throw new ConflictError('Occurrence was superseded and cannot receive a command', undefined, ErrorCode.CONFLICT_REVISION);
      }
      if (occurrence.provenance !== 'exact' || occurrence.source === 'legacy') {
        throw new ConflictError('Estimated or unknown occurrences require review before action', undefined, ErrorCode.CONFLICT_REVISION);
      }
      if (occurrence.stateVersion !== BigInt(command.baseVersion)) {
        throw new ConflictError('Occurrence has changed; rebase the pending intent on the latest state', undefined, ErrorCode.CONFLICT_STALE_UPDATE);
      }

      const [head] = await tx.select({
        id: occurrenceEvents.id,
        fromState: occurrenceEvents.fromState,
        toState: occurrenceEvents.toState,
        resultVersion: occurrenceEvents.resultVersion,
      }).from(occurrenceEvents).where(and(
        eq(occurrenceEvents.userId, userId),
        eq(occurrenceEvents.occurrenceId, occurrence.id),
      )).orderBy(desc(occurrenceEvents.serverSequence)).limit(1);
      const currentState = head ? stateFromValue(head.toState) : 'pending';
      if ((head?.resultVersion ?? 0n) !== occurrence.stateVersion) {
        throw new Error('Occurrence state version does not match its immutable event history');
      }
      if (command.action === 'miss' && currentState !== 'pending') {
        // Never coerced into a correction: a person or another device already
        // recorded this dose, and the app discards its own unsent miss.
        throw new ConflictError('Occurrence is no longer pending; a miss was not recorded', undefined, ErrorCode.CONFLICT_STALE_UPDATE);
      }

      let referencedEvent: {
        id: string;
        fromState: OccurrenceState;
        toState: OccurrenceState;
        inventoryDelta: number | null;
      } | undefined;
      if (command.reversesEventId) {
        const [reversed] = await tx.select({
          id: occurrenceEvents.id,
          fromState: occurrenceEvents.fromState,
          toState: occurrenceEvents.toState,
        }).from(occurrenceEvents).where(and(
          eq(occurrenceEvents.id, command.reversesEventId),
          eq(occurrenceEvents.userId, userId),
          eq(occurrenceEvents.occurrenceId, occurrence.id),
        ));
        if (!reversed) throw new ConflictError('Referenced event does not belong to this occurrence', undefined, ErrorCode.CONFLICT_REVISION);
        const [reversedInventory] = await tx.select({ delta: inventoryEvents.delta })
          .from(inventoryEvents)
          .where(and(
            eq(inventoryEvents.userId, userId),
            eq(inventoryEvents.occurrenceEventId, reversed.id),
          ))
          .limit(1);
        referencedEvent = {
          id: reversed.id,
          fromState: stateFromValue(reversed.fromState),
          toState: stateFromValue(reversed.toState),
          inventoryDelta: reversedInventory?.delta ?? null,
        };
      }

      const reduction = reduceOccurrenceCommand({
        fromState: currentState,
        action: command.action,
        ...(command.targetState ? { targetState: command.targetState } : {}),
        currentHeadEventId: head?.id ?? null,
        ...(referencedEvent ? { referencedEvent } : {}),
      });
      const resultVersion = occurrence.stateVersion + 1n;
      const recordedAt = new Date();
      const occurrenceEventId = randomUUID();

      const [updatedOccurrence] = await tx.update(medicationOccurrences).set({
        stateVersion: resultVersion,
      }).where(and(
        eq(medicationOccurrences.id, occurrence.id),
        eq(medicationOccurrences.userId, userId),
        eq(medicationOccurrences.stateVersion, occurrence.stateVersion),
      )).returning();
      if (!updatedOccurrence) throw new ConflictError('Occurrence changed while applying the command', undefined, ErrorCode.CONFLICT_STALE_UPDATE);

      const [event] = await tx.insert(occurrenceEvents).values({
        id: occurrenceEventId,
        userId,
        occurrenceId: occurrence.id,
        commandId: command.commandId,
        action: reduction.action,
        fromState: reduction.fromState,
        toState: reduction.toState,
        reversesEventId: reduction.reversesEventId,
        rebasesCommandId: command.rebasesCommandId,
        actualAt: command.actualAt ? new Date(command.actualAt) : null,
        actualTimeKnown: command.actualTimeKnown,
        note: command.note,
        origin: 'native',
        baseVersion: occurrence.stateVersion,
        resultVersion,
        serverSequence: eventSequence,
        recordedAt,
      }).returning();
      if (!event) throw new Error('Occurrence event insert returned no row');

      let inventoryEvent: typeof inventoryEvents.$inferSelect | undefined;
      let resultingPill = ownedPill.pill;
      const trackedStock = ownedPill.pill.currentStock !== null;
      if (reduction.inventoryDelta !== 0 && trackedStock) {
        const nextStock = ownedPill.pill.currentStock! + reduction.inventoryDelta;
        if (!Number.isInteger(nextStock) || nextStock < -2_147_483_648 || nextStock > 2_147_483_647) {
          throw new ResourceError('Inventory result is outside the supported integer range', 409, ErrorCode.CONFLICT_REVISION);
        }
        const inventorySequence = await allocateSequence(tx, userId);
        const [insertedInventoryEvent] = await tx.insert(inventoryEvents).values({
          userId,
          pillId: ownedPill.pill.id,
          commandId: command.commandId,
          kind: reduction.action === 'undo' ? 'dose_reversal' : reduction.action === 'correct' ? 'correction' : 'dose',
          delta: reduction.inventoryDelta,
          occurrenceEventId: event.id,
          reversesInventoryEventId: reduction.action === 'undo' ? (await tx.select({ id: inventoryEvents.id })
            .from(inventoryEvents)
            .where(and(
              eq(inventoryEvents.userId, userId),
              eq(inventoryEvents.occurrenceEventId, command.reversesEventId!),
            )).limit(1))[0]?.id ?? null : null,
          provenance: 'native',
          note: command.note,
          serverSequence: inventorySequence,
          recordedAt,
        }).returning();
        inventoryEvent = insertedInventoryEvent;

        const [updatedPill] = await tx.update(pills).set({
          currentStock: nextStock,
          revision: sql`${pills.revision} + 1`,
          lastMutationId: command.commandId,
          updatedAt: recordedAt,
        }).where(and(
          eq(pills.id, ownedPill.pill.id),
          eq(pills.profileId, ownedPill.pill.profileId),
          eq(pills.currentStock, ownedPill.pill.currentStock!),
        )).returning();
        if (!updatedPill) throw new ConflictError('Inventory changed while applying the command', undefined, ErrorCode.CONFLICT_STALE_UPDATE);
        resultingPill = updatedPill;
      }

      const result: CommandResult = {
        commandId: command.commandId,
        occurrenceId: occurrence.id,
        occurrenceKey: occurrence.occurrenceKey,
        eventId: event.id,
        action: event.action,
        state: event.toState,
        stateVersion: event.resultVersion.toString(),
        inventoryEventId: inventoryEvent?.id ?? null,
        inventoryDelta: trackedStock ? (inventoryEvent?.delta ?? 0) : null,
        currentStock: resultingPill.currentStock,
        // The stock move bumps pills.revision without a stable sync change, so
        // the acknowledgement is the only place the client learns the new base
        // for its next pill or inventory write.
        pillRevision: resultingPill.revision.toString(),
        inventoryTracked: trackedStock,
        recordedAt: event.recordedAt.toISOString(),
      };

      await appendSyncChange(tx, userId, {
        schemaVersion: 2,
        component: 'medication',
        entityType: 'medication_occurrence',
        entityId: updatedOccurrence.id,
        operation: 'upsert',
        sourceIdentity: {
          sourceKind: 'occurrence',
          sourceId: updatedOccurrence.id,
          sourceRevision: (updatedOccurrence.stateVersion + 1n).toString(),
        },
        payload: {
          kind: 'medicationOccurrence',
          id: updatedOccurrence.id,
          pillId: updatedOccurrence.pillId,
          scheduleId: updatedOccurrence.scheduleId,
          occurrenceKey: updatedOccurrence.occurrenceKey,
          source: updatedOccurrence.source,
          scheduleRevision: updatedOccurrence.scheduleRevision?.toString() ?? null,
          plannedLocalDate: updatedOccurrence.plannedLocalDate,
          plannedLocalTime: updatedOccurrence.plannedLocalTime,
          timeZone: updatedOccurrence.timeZone,
          plannedAt: asIso(updatedOccurrence.plannedAt),
          expected: updatedOccurrence.expected,
          snapshotVersion: 1,
          scheduleSnapshot: updatedOccurrence.scheduleSnapshot,
          provenance: updatedOccurrence.provenance,
          supersededAt: asIso(updatedOccurrence.supersededAt),
          supersededByOccurrenceId: updatedOccurrence.supersededByOccurrenceId,
          stateVersion: updatedOccurrence.stateVersion.toString(),
        },
      });
      await appendSyncChange(tx, userId, {
        schemaVersion: 2,
        component: 'medication',
        entityType: 'occurrence_event',
        entityId: event.id,
        operation: 'upsert',
        sourceIdentity: { sourceKind: 'occurrence_event', sourceId: event.id, sourceRevision: event.serverSequence.toString() },
        payload: {
          kind: 'occurrenceEvent',
          id: event.id,
          occurrenceId: event.occurrenceId,
          commandId: event.commandId,
          action: event.action,
          fromState: event.fromState,
          toState: event.toState,
          reversesEventId: event.reversesEventId,
          rebasesCommandId: event.rebasesCommandId,
          actualAt: asIso(event.actualAt),
          actualTimeKnown: event.actualTimeKnown,
          note: event.note,
          origin: event.origin,
          baseVersion: event.baseVersion.toString(),
          resultVersion: event.resultVersion.toString(),
          serverSequence: event.serverSequence.toString(),
          recordedAt: event.recordedAt.toISOString(),
        },
      });
      if (inventoryEvent) {
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
            delta: inventoryEvent.delta,
            occurrenceEventId: inventoryEvent.occurrenceEventId,
            reversesInventoryEventId: inventoryEvent.reversesInventoryEventId,
            provenance: inventoryEvent.provenance,
            note: inventoryEvent.note,
            serverSequence: inventoryEvent.serverSequence.toString(),
            recordedAt: inventoryEvent.recordedAt.toISOString(),
          },
        });
      }
      if (resultingPill.revision !== ownedPill.pill.revision) {
        await appendPillSyncChange(tx, userId, resultingPill);
      }

      await tx.insert(medicationCommandReceipts).values({
        userId,
        commandId: command.commandId,
        inputFingerprint,
        origin: 'native',
        resultMetadata: result,
      });
      return result;
    });
  }

  executeInventory(userId: string, command: InventoryCommand): Promise<CommandResult> {
    const inputFingerprint = fingerprint(command);
    return this.transactions.run(userId, async (tx) => {
      const ledgerActivated = await lockMedicationLedgerAuthority(tx);
      if (ledgerActivated === null) throw new ResourceError('Medication authority is unavailable', 503);
      const prior = await readCommandReceipt(tx, userId, command.commandId);
      if (prior) return replayReceipt(prior, inputFingerprint);
      if (!ledgerActivated) {
        throw new ResourceError('The medication ledger is not active; use the bridge command', 409, ErrorCode.CONFLICT_REVISION);
      }

      // Lock the tenant stream before the pill row; stock guards use the same order.
      const eventSequence = await allocateSequence(tx, userId);
      const concurrentReceipt = await readCommandReceipt(tx, userId, command.commandId);
      if (concurrentReceipt) return replayReceipt(concurrentReceipt, inputFingerprint);
      const [ownedPill] = await tx.select({ pill: pills, ownerId: profiles.userId })
        .from(pills)
        .innerJoin(profiles, eq(pills.profileId, profiles.id))
        .where(and(
          eq(pills.id, command.pillId),
          eq(profiles.userId, userId),
          isNull(pills.deletedAt),
          isNull(profiles.deletedAt),
        ))
        .for('update');
      if (!ownedPill || ownedPill.ownerId !== userId) throw new ResourceError('Medication item not found', 404);
      if (ownedPill.pill.revision !== BigInt(command.baseRevision)) {
        throw new ConflictError('Medication item changed; refresh its revision before inventory correction', command.pillId, ErrorCode.CONFLICT_STALE_UPDATE);
      }

      let delta: number;
      let kind: 'opening' | 'refill' | 'correction';
      let nextStock: number;
      if (command.action === 'start') {
        if (ownedPill.pill.currentStock !== null) {
          throw new ConflictError('Inventory tracking has already been started', command.pillId, ErrorCode.CONFLICT_REVISION);
        }
        const [existingEvent] = await tx.select({ id: inventoryEvents.id }).from(inventoryEvents).where(and(
          eq(inventoryEvents.userId, userId),
          eq(inventoryEvents.pillId, command.pillId),
        )).limit(1);
        if (existingEvent) throw new ConflictError('An inventory ledger already exists for this item', command.pillId, ErrorCode.CONFLICT_REVISION);
        delta = command.initialStock;
        kind = 'opening';
        nextStock = command.initialStock;
      } else {
        if (ownedPill.pill.currentStock === null) {
          throw new ConflictError('Start inventory tracking before applying a relative stock command', command.pillId, ErrorCode.CONFLICT_REVISION);
        }
        nextStock = command.action === 'refill'
          ? ownedPill.pill.currentStock + command.amount
          : command.targetStock;
        delta = nextStock - ownedPill.pill.currentStock;
        kind = command.action === 'refill' ? 'refill' : 'correction';
      }
      if (!Number.isInteger(nextStock) || nextStock < -2_147_483_648 || nextStock > 2_147_483_647) {
        throw new ResourceError('Inventory result is outside the supported integer range', 409, ErrorCode.CONFLICT_REVISION);
      }
      if (delta < -2_147_483_648 || delta > 2_147_483_647) {
        throw new ResourceError('Inventory delta is outside the supported integer range', 409, ErrorCode.CONFLICT_REVISION);
      }

      const recordedAt = new Date();
      let inventoryEvent: typeof inventoryEvents.$inferSelect | undefined;
      if (kind === 'opening' || delta !== 0) {
        const [event] = await tx.insert(inventoryEvents).values({
          userId,
          pillId: command.pillId,
          commandId: command.commandId,
          kind,
          delta,
          occurrenceEventId: null,
          reversesInventoryEventId: null,
          provenance: 'native',
          note: command.note,
          serverSequence: eventSequence,
          recordedAt,
        }).returning();
        inventoryEvent = event;
        if (!event) throw new Error('Inventory event insert returned no row');
      }

      let resultingPill = ownedPill.pill;
      if (ownedPill.pill.currentStock !== nextStock) {
        const [updatedPill] = await tx.update(pills).set({
          currentStock: nextStock,
          revision: sql`${pills.revision} + 1`,
          lastMutationId: command.commandId,
          updatedAt: recordedAt,
        }).where(and(
          eq(pills.id, command.pillId),
          ownedPill.pill.currentStock === null
            ? isNull(pills.currentStock)
            : eq(pills.currentStock, ownedPill.pill.currentStock),
          eq(pills.revision, ownedPill.pill.revision),
        )).returning();
        if (!updatedPill) throw new ConflictError('Inventory changed while applying the command', command.pillId, ErrorCode.CONFLICT_STALE_UPDATE);
        resultingPill = updatedPill;
      }

      const result: CommandResult = {
        commandId: command.commandId,
        pillId: command.pillId,
        action: command.action,
        inventoryEventId: inventoryEvent?.id ?? null,
        inventoryDelta: delta,
        currentStock: resultingPill.currentStock,
        revision: resultingPill.revision.toString(),
        recordedAt: recordedAt.toISOString(),
      };
      if (inventoryEvent) {
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
            delta: inventoryEvent.delta,
            occurrenceEventId: null,
            reversesInventoryEventId: null,
            provenance: inventoryEvent.provenance,
            note: inventoryEvent.note,
            serverSequence: inventoryEvent.serverSequence.toString(),
            recordedAt: inventoryEvent.recordedAt.toISOString(),
          },
        });
      }
      if (resultingPill.revision !== ownedPill.pill.revision) {
        await appendPillSyncChange(tx, userId, resultingPill);
      }
      await tx.insert(medicationCommandReceipts).values({
        userId,
        commandId: command.commandId,
        inputFingerprint,
        origin: 'native',
        resultMetadata: result,
      });
      return result;
    });
  }
}
