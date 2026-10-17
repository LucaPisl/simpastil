import { createHash } from 'node:crypto';
import { canonicalJson } from '../sync/sync-payload.js';
import {
  serializeLegacyEstimatedHistory,
  type LegacyEstimatedHistoryV1,
} from '../sync/legacy-estimated-history.js';
import { legacyHistoryIds } from './legacy-history-backfill.js';

export interface LegacyHandoffJournalEvidence {
  userId: string;
  legacySourceKind: 'dose_log' | 'pill_stock';
  legacySourceId: string;
  sourceRevision: string;
  beforeEvidence: Record<string, unknown> | null;
  afterEvidence: Record<string, unknown> | null;
}

export interface LegacyHandoffHistoryRecord {
  history: LegacyEstimatedHistoryV1;
  sourceSnapshot: Record<string, unknown>;
}

function evidenceTime(evidence: Record<string, unknown> | null, field: string): string | null {
  const value = evidence?.[field];
  if (value === null || value === undefined) return null;
  const date = value instanceof Date ? value : new Date(String(value));
  return Number.isFinite(date.getTime()) ? date.toISOString() : null;
}

/** Journal evidence is preserved exactly as estimated history; it never invents a local slot. */
export interface LegacyHandoffResolvedParents {
  /**
   * Dose-log journal evidence names only its schedule. The pill (and whether the
   * schedule still exists) is resolved by the caller, which has database access.
   */
  schedulePillId: string | null;
}

export function legacyHistoryRecordFromJournal(
  row: LegacyHandoffJournalEvidence,
  parents?: LegacyHandoffResolvedParents,
): LegacyHandoffHistoryRecord {
  const after = row.afterEvidence;
  const source = after ?? row.beforeEvidence;
  if (!source) throw new TypeError('handoff journal row has no source evidence');

  const deleted = after === null || after['deletedAt'] !== null && after['deletedAt'] !== undefined;
  const evidencedScheduleId = row.legacySourceKind === 'dose_log' && typeof source['scheduleId'] === 'string'
    ? source['scheduleId']
    : null;
  // A schedule with no resolvable pill cannot be referenced by the history row.
  const scheduleId = parents && parents.schedulePillId === null ? null : evidencedScheduleId;
  const pillId = row.legacySourceKind === 'pill_stock'
    ? (typeof source['pillId'] === 'string' ? source['pillId'] : row.legacySourceId)
    : (typeof source['pillId'] === 'string' ? source['pillId'] : parents?.schedulePillId ?? null);
  const scheduledAt = evidenceTime(source, 'scheduledAt');
  const takenAt = evidenceTime(source, 'takenAt');
  const storedUtc = takenAt ?? scheduledAt ?? evidenceTime(source, 'updatedAt');
  const status = source['status'];
  const state = row.legacySourceKind === 'dose_log'
    && (status === 'taken' || status === 'missed' || status === 'skipped') ? status : null;
  if (row.legacySourceKind === 'dose_log' && !state) {
    throw new TypeError('dose handoff evidence has no supported status');
  }
  const sourceSnapshot = {
    afterEvidence: after,
    beforeEvidence: row.beforeEvidence,
    legacySourceId: row.legacySourceId,
    legacySourceKind: row.legacySourceKind,
    sourceRevision: row.sourceRevision,
  };
  const sourceFingerprint = createHash('sha256').update(canonicalJson(sourceSnapshot), 'utf8').digest('hex');
  const ids = legacyHistoryIds(row.userId, row.legacySourceKind, row.legacySourceId, row.sourceRevision);
  const { value } = serializeLegacyEstimatedHistory({
    kind: 'legacyEstimatedHistory',
    version: 1,
    ...ids,
    sourceRevision: row.sourceRevision,
    operation: deleted ? 'tombstone' : 'upsert',
    legacySourceKind: row.legacySourceKind,
    legacySourceId: row.legacySourceId,
    pillId,
    scheduleId,
    localDateEvidence: null,
    localTimeEvidence: null,
    storedUtc,
    timeZoneStatus: 'legacy_unknown',
    provenance: 'legacy_estimated',
    state,
    historicalInventoryDeltaEvidence: null,
    inventoryDeltaProvenance: 'unknown',
    migrationInventoryEffect: 'none',
    inventoryDisposition: 'effect_unknown',
    sourceFingerprint,
    entityRevision: '1',
  });
  return { history: value, sourceSnapshot };
}

export function legacyHistoryFromJournal(row: LegacyHandoffJournalEvidence): LegacyEstimatedHistoryV1 {
  return legacyHistoryRecordFromJournal(row).history;
}

export function inventoryDeltaFromJournal(row: LegacyHandoffJournalEvidence): number | null {
  if (row.legacySourceKind !== 'pill_stock') return null;
  const before = row.beforeEvidence?.['currentStock'];
  const after = row.afterEvidence?.['currentStock'];
  if (after === null || after === undefined || !Number.isSafeInteger(after)) return null;
  if (before === null || before === undefined) return after as number;
  if (!Number.isSafeInteger(before)) return null;
  return (after as number) - (before as number);
}
