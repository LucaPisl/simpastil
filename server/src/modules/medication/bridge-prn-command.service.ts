import { createHash } from 'node:crypto';
import { and, desc, eq, isNull, or, sql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { TenantTransactionRunner, type TenantTransaction } from '../../db/tenant-transaction.js';
import {
  inventoryEvents,
  medicationCommandReceipts,
  medicationOccurrences,
  occurrenceEvents,
  pills,
  profiles,
  schedules,
} from '../../db/schema.js';
import { canonicalJson } from '../sync/sync-payload.js';
import { appendSyncChange } from './occurrence-materializer.js';
import { appendPillSyncChange } from '../sync/sync-change-writer.js';
import { lockMedicationLedgerAuthority } from './medication-authority.js';
import { ConflictError, ErrorCode, ResourceError } from '../shared/errors.js';
import type { AdministrationAmount, BridgePrnCommand } from './bridge-prn-command.schema.js';
import { FRACTIONAL_STOCK_MIN_CLIENT_BUILD, inventoryDeltaWire, parseDbStock, readAdministrationAmount } from '../shared/stock-quantity.js';
import { computeStockEffect, type StockEffect } from './stock-effect.js';
import { recordStockEffect, stockReceiptFields, stockUnitToAdopt, type RecordedStock } from './stock-write.js';

type CommandResult = Record<string, unknown>;

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

async function readReceipt(tx: TenantTransaction, userId: string, commandId: string) {
  const [receipt] = await tx.select().from(medicationCommandReceipts).where(and(
    eq(medicationCommandReceipts.userId, userId),
    eq(medicationCommandReceipts.commandId, commandId),
  ));
  return receipt;
}

function replayReceipt(
  receipt: NonNullable<Awaited<ReturnType<typeof readReceipt>>>,
  inputFingerprint: string,
): CommandResult {
  if (receipt.inputFingerprint !== inputFingerprint) {
    throw new ConflictError('Command ID was already used for different input', receipt.commandId, ErrorCode.CONFLICT_MUTATION_REUSE);
  }
  return receipt.resultMetadata as CommandResult;
}

function localDateAt(instant: string, timeZone: string): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone, year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(new Date(instant));
  const value = (type: Intl.DateTimeFormatPartTypes) => parts.find((part) => part.type === type)?.value;
  return `${value('year')}-${value('month')}-${value('day')}`;
}

function occurrencePayload(row: typeof medicationOccurrences.$inferSelect) {
  return {
    kind: 'medicationOccurrence' as const,
    id: row.id,
    pillId: row.pillId,
    scheduleId: row.scheduleId,
    occurrenceKey: row.occurrenceKey,
    source: row.source,
    scheduleRevision: row.scheduleRevision?.toString() ?? null,
    plannedLocalDate: row.plannedLocalDate,
    plannedLocalTime: row.plannedLocalTime,
    timeZone: row.timeZone,
    plannedAt: row.plannedAt?.toISOString() ?? null,
    expected: row.expected,
    snapshotVersion: row.snapshotVersion,
    scheduleSnapshot: row.scheduleSnapshot,
    provenance: row.provenance,
    supersededAt: row.supersededAt?.toISOString() ?? null,
    supersededByOccurrenceId: row.supersededByOccurrenceId,
    stateVersion: row.stateVersion.toString(),
  };
}

function eventPayload(row: typeof occurrenceEvents.$inferSelect) {
  return {
    kind: 'occurrenceEvent' as const,
    id: row.id,
    occurrenceId: row.occurrenceId,
    commandId: row.commandId,
    action: row.action,
    fromState: row.fromState,
    toState: row.toState,
    reversesEventId: row.reversesEventId,
    rebasesCommandId: row.rebasesCommandId,
    actualAt: row.actualAt?.toISOString() ?? null,
    actualTimeKnown: row.actualTimeKnown,
    administrationAmount: row.administrationAmount,
    ...(row.recordedBy ? { recordedBy: row.recordedBy } : {}),
    note: row.note,
    origin: row.origin,
    baseVersion: row.baseVersion.toString(),
    resultVersion: row.resultVersion.toString(),
    serverSequence: row.serverSequence.toString(),
    recordedAt: row.recordedAt.toISOString(),
  };
}

async function publishOccurrence(
  tx: TenantTransaction,
  userId: string,
  occurrence: typeof medicationOccurrences.$inferSelect,
) {
  await appendSyncChange(tx, userId, {
    schemaVersion: 2,
    component: 'medication',
    entityType: 'medication_occurrence',
    entityId: occurrence.id,
    operation: 'upsert',
    sourceIdentity: {
      sourceKind: 'occurrence', sourceId: occurrence.id,
      sourceRevision: (occurrence.stateVersion + 1n).toString(),
    },
    payload: occurrencePayload(occurrence),
  });
}

async function publishInventoryEvent(
  tx: TenantTransaction,
  userId: string,
  event: typeof inventoryEvents.$inferSelect,
  unitStock: boolean,
) {
  await appendSyncChange(tx, userId, {
    schemaVersion: 2,
    component: 'medication',
    entityType: 'inventory_event',
    entityId: event.id,
    operation: 'upsert',
    sourceIdentity: {
      sourceKind: 'inventory_event', sourceId: event.id,
      sourceRevision: event.serverSequence.toString(),
    },
    payload: {
      kind: 'inventoryEvent',
      id: event.id,
      pillId: event.pillId,
      commandId: event.commandId,
      eventKind: event.kind,
      ...inventoryDeltaWire(event.delta, unitStock),
      occurrenceEventId: event.occurrenceEventId,
      reversesInventoryEventId: event.reversesInventoryEventId,
      provenance: event.provenance,
      note: event.note,
      serverSequence: event.serverSequence.toString(),
      recordedAt: event.recordedAt.toISOString(),
    },
  });
}

type StockOutcome = {
  recorded: RecordedStock;
  effect: StockEffect;
};

/**
 * Applies the stock side of an active-ledger PRN take or undo, exactly as the
 * ledger command does for a scheduled dose: an untracked item has no stock
 * effect, and negative stock never blocks a take. A plain count loses one per
 * take; stock counted in a unit loses the amount taken. A plain whole count
 * adopts its tablet or capsule unit only for a build that understands units.
 */
async function applyActiveStock(
  tx: TenantTransaction,
  userId: string,
  pill: typeof pills.$inferSelect,
  input: {
    action: 'take' | 'undo';
    commandAmount: AdministrationAmount | null;
    /** The scaled delta of the inventory event an undo reverses. */
    referencedDelta: bigint | null;
    canAdoptUnit: boolean;
    kind: 'dose' | 'dose_reversal';
    commandId: string;
    occurrenceEventId: string;
    reversesInventoryEventId: string | null;
    note: string | null;
    recordedAt: Date;
  },
): Promise<StockOutcome> {
  const amountPerUse = readAdministrationAmount(pill.amountPerUse);
  const adoptUnit = input.action === 'take' && input.canAdoptUnit
    ? stockUnitToAdopt(pill, input.commandAmount, amountPerUse)
    : null;
  const effect = computeStockEffect({
    tracked: pill.currentStock !== null,
    stockUnit: pill.stockUnit ?? adoptUnit,
    amountPerUse,
    commandAmount: input.commandAmount,
    action: input.action,
    transition: input.action === 'take'
      ? -1
      : input.referencedDelta === null ? 0 : Number(-input.referencedDelta / 1_000_000n),
    referencedDelta: input.referencedDelta,
    linkedNet: 0n,
  });
  const recorded = await recordStockEffect(tx, userId, pill, {
    effect,
    adoptUnit,
    kind: input.kind,
    mayClearRecount: input.action === 'undo',
    commandId: input.commandId,
    occurrenceEventId: input.occurrenceEventId,
    reversesInventoryEventId: input.reversesInventoryEventId,
    note: input.note,
    recordedAt: input.recordedAt,
    allocateSequence: () => allocateSequence(tx, userId),
  });
  return { recorded, effect };
}

async function publishStock(tx: TenantTransaction, userId: string, before: typeof pills.$inferSelect, outcome: StockOutcome) {
  const { inventoryEvent, pill } = outcome.recorded;
  if (inventoryEvent) await publishInventoryEvent(tx, userId, inventoryEvent, pill.stockUnit !== null);
  if (pill.revision !== before.revision) await appendPillSyncChange(tx, userId, pill);
}

function stockResult(outcome: StockOutcome): CommandResult {
  return {
    ...stockReceiptFields(outcome.recorded, outcome.effect),
    // The stock move bumps pills.revision; the acknowledgement carries the new
    // base for the client's next pill or inventory write.
    pillRevision: outcome.recorded.pill.revision.toString(),
    inventoryTracked: outcome.recorded.tracked,
  };
}

async function publishEvent(
  tx: TenantTransaction,
  userId: string,
  event: typeof occurrenceEvents.$inferSelect,
) {
  await appendSyncChange(tx, userId, {
    schemaVersion: 2,
    component: 'medication',
    entityType: 'occurrence_event',
    entityId: event.id,
    operation: 'upsert',
    sourceIdentity: {
      sourceKind: 'occurrence_event', sourceId: event.id,
      sourceRevision: event.serverSequence.toString(),
    },
    payload: eventPayload(event),
  });
}

export class BridgePrnCommandService {
  private readonly transactions: TenantTransactionRunner;

  constructor(db: Db) {
    this.transactions = new TenantTransactionRunner(db);
  }

  execute(userId: string, command: BridgePrnCommand, clientBuild = 1): Promise<CommandResult> {
    const canAdoptUnit = clientBuild >= FRACTIONAL_STOCK_MIN_CLIENT_BUILD;
    const inputFingerprint = fingerprint(command);
    return this.transactions.run(userId, async (tx) => {
      const ledgerActivated = await lockMedicationLedgerAuthority(tx);
      if (ledgerActivated === null) throw new ResourceError('Medication authority is unavailable', 503);
      const prior = await readReceipt(tx, userId, command.commandId);
      if (prior) return replayReceipt(prior, inputFingerprint);
      // After ledger activation the same exact PRN command stays open: the
      // server never materializes PRN occurrences, so this is the only way a
      // PRN dose reaches the ledger. The active path also moves stock.

      const eventSequence = await allocateSequence(tx, userId);
      const concurrent = await readReceipt(tx, userId, command.commandId);
      if (concurrent) return replayReceipt(concurrent, inputFingerprint);

      return command.operation === 'take'
        ? this.take(tx, userId, command, inputFingerprint, eventSequence, ledgerActivated, canAdoptUnit)
        : this.undo(tx, userId, command, inputFingerprint, eventSequence, ledgerActivated);
    });
  }

  private async take(
    tx: TenantTransaction,
    userId: string,
    command: Extract<BridgePrnCommand, { operation: 'take' }>,
    inputFingerprint: string,
    eventSequence: bigint,
    ledgerActivated: boolean,
    canAdoptUnit: boolean,
  ): Promise<CommandResult> {
    if (command.actualAt !== null && localDateAt(command.actualAt, command.timeZone) !== command.plannedLocalDate) {
      throw new ConflictError('Actual time is outside the reviewed care date', command.occurrenceId, ErrorCode.CONFLICT_REVISION);
    }
    const [parent] = await tx.select({
      profile: profiles,
      pill: pills,
      schedule: schedules,
    }).from(schedules)
      .innerJoin(pills, eq(schedules.pillId, pills.id))
      .innerJoin(profiles, eq(pills.profileId, profiles.id))
      .where(and(
        eq(profiles.id, command.profileId),
        eq(profiles.userId, userId),
        eq(pills.id, command.pillId),
        eq(pills.profileId, command.profileId),
        eq(schedules.id, command.scheduleId),
        eq(schedules.pillId, command.pillId),
        isNull(profiles.deletedAt),
        isNull(pills.deletedAt),
        isNull(schedules.deletedAt),
      )).for('update');
    if (!parent) throw new ResourceError('PRN schedule not found', 404);
    if (!parent.pill.isPrn || !parent.schedule.isActive || parent.schedule.frequency !== 'prn') {
      throw new ConflictError('Schedule is not an active PRN authority', command.scheduleId, ErrorCode.CONFLICT_REVISION);
    }
    const [sentinels] = await tx.select({ count: sql<string>`count(*)::text` })
      .from(schedules)
      .where(and(
        eq(schedules.pillId, command.pillId),
        eq(schedules.frequency, 'prn'),
        eq(schedules.isActive, true),
        isNull(schedules.deletedAt),
      ));
    if (sentinels?.count !== '1') {
      throw new ConflictError('Medication must have exactly one active PRN schedule', command.pillId, ErrorCode.CONFLICT_REVISION);
    }
    if (parent.schedule.revision !== BigInt(command.scheduleRevision)) {
      throw new ConflictError('PRN schedule changed since review', command.scheduleId, ErrorCode.CONFLICT_STALE_UPDATE);
    }
    if (parent.schedule.timeZoneStatus !== 'known' || parent.schedule.timeZone !== command.timeZone) {
      throw new ConflictError('PRN timezone does not match the reviewed schedule', command.scheduleId, ErrorCode.CONFLICT_STALE_UPDATE);
    }

    const collision = await tx.select({ id: medicationOccurrences.id }).from(medicationOccurrences).where(and(
      eq(medicationOccurrences.userId, userId),
      or(
        eq(medicationOccurrences.id, command.occurrenceId),
        eq(medicationOccurrences.occurrenceKey, command.occurrenceKey),
      )!,
    )).limit(1);
    if (collision.length) {
      throw new ConflictError('PRN occurrence identity is already in use', command.occurrenceId, ErrorCode.CONFLICT_MUTATION_REUSE);
    }

    const recordedAt = new Date();
    const [inserted] = await tx.insert(medicationOccurrences).values({
      id: command.occurrenceId,
      userId,
      pillId: command.pillId,
      scheduleId: command.scheduleId,
      occurrenceKey: command.occurrenceKey,
      source: 'prn',
      scheduleRevision: parent.schedule.revision,
      plannedLocalDate: command.plannedLocalDate,
      plannedLocalTime: null,
      timeZone: command.timeZone,
      plannedAt: null,
      expected: false,
      snapshotVersion: 1,
      scheduleSnapshot: {
        version: 1,
        pillName: parent.pill.name,
        dosage: parent.pill.dosage,
        frequency: 'prn',
        frequencyDays: null,
        hour: null,
        minute: null,
        timeZone: command.timeZone,
        profileId: parent.profile.id,
        profileName: parent.profile.name,
      },
      provenance: 'exact',
      stateVersion: 0n,
      createdAt: recordedAt,
    }).returning();
    if (!inserted) throw new Error('PRN occurrence insert returned no row');
    const [occurrence] = await tx.update(medicationOccurrences).set({ stateVersion: 1n }).where(and(
      eq(medicationOccurrences.id, command.occurrenceId),
      eq(medicationOccurrences.userId, userId),
      eq(medicationOccurrences.stateVersion, 0n),
    )).returning();
    if (!occurrence) throw new ConflictError('PRN occurrence changed while recording', command.occurrenceId, ErrorCode.CONFLICT_STALE_UPDATE);
    const [event] = await tx.insert(occurrenceEvents).values({
      id: command.eventId,
      userId,
      occurrenceId: command.occurrenceId,
      commandId: command.commandId,
      action: 'take',
      fromState: 'pending',
      toState: 'taken',
      actualAt: command.actualAt ? new Date(command.actualAt) : null,
      actualTimeKnown: command.actualTimeKnown,
      administrationAmount: command.amount,
      ...(command.recordedBy ? { recordedBy: command.recordedBy } : {}),
      note: command.note,
      origin: 'native',
      baseVersion: 0n,
      resultVersion: 1n,
      serverSequence: eventSequence,
      recordedAt,
    }).returning();
    if (!event) throw new Error('PRN occurrence event insert returned no row');
    const stock = ledgerActivated
      ? await applyActiveStock(tx, userId, parent.pill, {
        action: 'take',
        commandAmount: command.amount,
        referencedDelta: null,
        canAdoptUnit,
        kind: 'dose',
        commandId: command.commandId,
        occurrenceEventId: event.id,
        reversesInventoryEventId: null,
        note: command.note,
        recordedAt,
      })
      : null;

    const result: CommandResult = {
      commandId: command.commandId,
      occurrenceId: occurrence.id,
      occurrenceKey: occurrence.occurrenceKey,
      eventId: event.id,
      action: event.action,
      state: event.toState,
      stateVersion: event.resultVersion.toString(),
      amount: event.administrationAmount,
      inventoryEventId: null,
      inventoryDelta: null,
      ...(stock ? stockResult(stock) : {}),
      recordedAt: event.recordedAt.toISOString(),
    };
    await tx.insert(medicationCommandReceipts).values({
      userId,
      commandId: command.commandId,
      inputFingerprint,
      origin: 'native',
      resultMetadata: result,
    });
    await publishOccurrence(tx, userId, occurrence);
    await publishEvent(tx, userId, event);
    if (stock) await publishStock(tx, userId, parent.pill, stock);
    return result;
  }

  private async undo(
    tx: TenantTransaction,
    userId: string,
    command: Extract<BridgePrnCommand, { operation: 'undo' }>,
    inputFingerprint: string,
    eventSequence: bigint,
    ledgerActivated: boolean,
  ): Promise<CommandResult> {
    const [occurrence] = await tx.select().from(medicationOccurrences)
      .innerJoin(pills, eq(medicationOccurrences.pillId, pills.id))
      .innerJoin(profiles, eq(pills.profileId, profiles.id))
      .where(and(
        eq(medicationOccurrences.id, command.occurrenceId),
        eq(medicationOccurrences.userId, userId),
        eq(medicationOccurrences.occurrenceKey, command.occurrenceKey),
        eq(medicationOccurrences.source, 'prn'),
        eq(medicationOccurrences.provenance, 'exact'),
        eq(profiles.userId, userId),
      )).for('update');
    const row = occurrence?.medication_occurrences;
    const pill = occurrence?.pills;
    if (!row) throw new ResourceError('PRN occurrence not found', 404);
    if (row.supersededAt || row.stateVersion !== BigInt(command.baseVersion)) {
      throw new ConflictError('PRN occurrence changed since review', command.occurrenceId, ErrorCode.CONFLICT_STALE_UPDATE);
    }
    const [head] = await tx.select().from(occurrenceEvents).where(and(
      eq(occurrenceEvents.userId, userId),
      eq(occurrenceEvents.occurrenceId, row.id),
    )).orderBy(desc(occurrenceEvents.serverSequence)).limit(1);
    if (!head || head.id !== command.reversesEventId || head.action !== 'take'
        || head.toState !== 'taken' || head.resultVersion !== row.stateVersion) {
      throw new ConflictError('Undo does not reference the current PRN take', command.reversesEventId, ErrorCode.CONFLICT_REVISION);
    }
    const resultVersion = row.stateVersion + 1n;
    const recordedAt = new Date();
    const [updated] = await tx.update(medicationOccurrences).set({ stateVersion: resultVersion }).where(and(
      eq(medicationOccurrences.id, row.id),
      eq(medicationOccurrences.userId, userId),
      eq(medicationOccurrences.stateVersion, row.stateVersion),
    )).returning();
    if (!updated) throw new ConflictError('PRN occurrence changed while undoing', row.id, ErrorCode.CONFLICT_STALE_UPDATE);
    const [event] = await tx.insert(occurrenceEvents).values({
      id: command.eventId,
      userId,
      occurrenceId: row.id,
      commandId: command.commandId,
      action: 'undo',
      fromState: 'taken',
      toState: 'pending',
      reversesEventId: head.id,
      actualAt: null,
      actualTimeKnown: false,
      administrationAmount: null,
      ...(command.recordedBy ? { recordedBy: command.recordedBy } : {}),
      note: command.note,
      origin: 'native',
      baseVersion: row.stateVersion,
      resultVersion,
      serverSequence: eventSequence,
      recordedAt,
    }).returning();
    if (!event) throw new Error('PRN undo event insert returned no row');
    let stock: StockOutcome | null = null;
    if (ledgerActivated) {
      if (!pill || pill.deletedAt) throw new ResourceError('Medication item not found', 404);
      // Reverse exactly what the take moved; a take recorded before activation
      // or while stock was untracked moved nothing and reverses nothing.
      const [taken] = await tx.select().from(inventoryEvents).where(and(
        eq(inventoryEvents.userId, userId),
        eq(inventoryEvents.occurrenceEventId, head.id),
      )).limit(1);
      stock = await applyActiveStock(tx, userId, pill, {
        action: 'undo',
        commandAmount: null,
        referencedDelta: taken ? parseDbStock(taken.delta) : null,
        canAdoptUnit: false,
        kind: 'dose_reversal',
        commandId: command.commandId,
        occurrenceEventId: event.id,
        reversesInventoryEventId: taken?.id ?? null,
        note: command.note,
        recordedAt,
      });
    }
    const result: CommandResult = {
      commandId: command.commandId,
      occurrenceId: updated.id,
      occurrenceKey: updated.occurrenceKey,
      eventId: event.id,
      action: event.action,
      state: event.toState,
      stateVersion: event.resultVersion.toString(),
      amount: null,
      inventoryEventId: null,
      inventoryDelta: null,
      ...(stock ? stockResult(stock) : {}),
      recordedAt: event.recordedAt.toISOString(),
    };
    await tx.insert(medicationCommandReceipts).values({
      userId,
      commandId: command.commandId,
      inputFingerprint,
      origin: 'native',
      resultMetadata: result,
    });
    await publishOccurrence(tx, userId, updated);
    await publishEvent(tx, userId, event);
    if (stock && pill) await publishStock(tx, userId, pill, stock);
    return result;
  }
}
