import { createHash } from 'node:crypto';
import { canonicalJson } from '../sync/sync-payload.js';
import {
  serializeLegacyEstimatedHistory,
  type LegacyEstimatedHistoryV1,
} from '../sync/legacy-estimated-history.js';

export interface LegacyDoseHistorySource {
  userId: string;
  sourceId: string;
  scheduleId: string;
  pillId: string | null;
  status: 'taken' | 'missed' | 'skipped';
  scheduledAt: Date;
  takenAt: Date | null;
  deletedAt: Date | null;
}

export interface LegacyStockHistorySource {
  userId: string;
  pillId: string;
  currentStock: number | null;
  updatedAt: Date;
}

export interface LegacyHistoryBackfillRecord {
  history: LegacyEstimatedHistoryV1;
  sourceSnapshot: Record<string, unknown>;
}

function deterministicUuid(name: string): string {
  const bytes = createHash('md5').update(name, 'utf8').digest();
  bytes[6] = (bytes[6]! & 0x0f) | 0x50;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function legacyHistoryIds(
  userId: string,
  legacySourceKind: 'dose_log' | 'pill_stock',
  legacySourceId: string,
  sourceRevision: string,
): { historyId: string; historyEntryId: string } {
  const baseIdentity = `legacy-history-v1|${userId.toLowerCase()}|${legacySourceKind}|${legacySourceId.toLowerCase()}`;
  return {
    historyId: deterministicUuid(`${baseIdentity}|history`),
    historyEntryId: deterministicUuid(`${baseIdentity}|entry|${sourceRevision}`),
  };
}

function makeRecord(
  userId: string,
  legacySourceKind: 'dose_log' | 'pill_stock',
  legacySourceId: string,
  sourceRevision: string,
  item: Omit<LegacyEstimatedHistoryV1, 'kind' | 'version' | 'historyId' | 'historyEntryId'
    | 'sourceRevision' | 'operation' | 'legacySourceKind' | 'legacySourceId'
    | 'timeZoneStatus' | 'provenance' | 'historicalInventoryDeltaEvidence'
    | 'inventoryDeltaProvenance' | 'migrationInventoryEffect' | 'inventoryDisposition'
    | 'sourceFingerprint' | 'entityRevision'>,
  sourceSnapshot: Record<string, unknown>,
  operation: 'upsert' | 'tombstone' = 'upsert',
): LegacyHistoryBackfillRecord {
  const fingerprint = createHash('sha256').update(canonicalJson(sourceSnapshot), 'utf8').digest('hex');
  const ids = legacyHistoryIds(userId, legacySourceKind, legacySourceId, sourceRevision);
  const { value } = serializeLegacyEstimatedHistory({
    kind: 'legacyEstimatedHistory',
    version: 1,
    ...ids,
    sourceRevision,
    operation,
    legacySourceKind,
    legacySourceId,
    ...item,
    timeZoneStatus: 'legacy_unknown',
    provenance: 'legacy_estimated',
    historicalInventoryDeltaEvidence: null,
    inventoryDeltaProvenance: 'unknown',
    migrationInventoryEffect: 'none',
    inventoryDisposition: 'effect_unknown',
    sourceFingerprint: fingerprint,
    entityRevision: '1',
  });
  return { history: value, sourceSnapshot };
}

/** Preserve UTC evidence without deriving a historical local date or occurrence. */
export function backfillLegacyDoseHistory(
  source: LegacyDoseHistorySource,
  sourceRevision = '1',
): LegacyHistoryBackfillRecord {
  const storedUtc = source.takenAt ?? source.scheduledAt;
  const sourceSnapshot = {
    deletedAt: source.deletedAt?.toISOString() ?? null,
    id: source.sourceId,
    scheduleId: source.scheduleId,
    scheduledAt: source.scheduledAt.toISOString(),
    status: source.status,
    takenAt: source.takenAt?.toISOString() ?? null,
  };
  return makeRecord(source.userId, 'dose_log', source.sourceId, sourceRevision, {
    pillId: source.pillId,
    scheduleId: source.scheduleId,
    localDateEvidence: null,
    localTimeEvidence: null,
    storedUtc: storedUtc.toISOString(),
    state: source.status,
  }, sourceSnapshot, source.deletedAt ? 'tombstone' : 'upsert');
}

/** A stock snapshot is not a delta and never becomes a historical inventory effect. */
export function backfillLegacyStockHistory(
  source: LegacyStockHistorySource,
  sourceRevision = '1',
): LegacyHistoryBackfillRecord {
  const sourceSnapshot = {
    currentStock: source.currentStock,
    pillId: source.pillId,
    updatedAt: source.updatedAt.toISOString(),
  };
  return makeRecord(source.userId, 'pill_stock', source.pillId, sourceRevision, {
    pillId: source.pillId,
    scheduleId: null,
    localDateEvidence: null,
    localTimeEvidence: null,
    storedUtc: source.updatedAt.toISOString(),
    state: null,
  }, sourceSnapshot);
}
