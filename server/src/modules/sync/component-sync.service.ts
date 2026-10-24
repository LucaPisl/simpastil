import { and, asc, eq, gt, lte, or, sql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { medicationOccurrences, pills, profiles, schedules, syncChanges } from '../../db/schema.js';
import { TenantTransactionRunner } from '../../db/tenant-transaction.js';
import { ApiError } from '../shared/api-error.js';
import { ErrorCode } from '../shared/errors.js';
import { OccurrenceMaterializer } from '../medication/occurrence-materializer.js';
import { lockMedicationLedgerAuthority } from '../medication/medication-authority.js';
import { SyncChangePayloadV2Schema } from './sync-payload.js';
import { ComponentCursorCodec, componentCursorLimits, supportsContractVersion, type ComponentName } from './component-cursor.js';
import { ComponentSyncResponseSchema, type ComponentSyncResponse } from './sync.schema.js';
import { legacyStockInteger } from '../shared/stock-quantity.js';

export interface ComponentSyncRequest {
  component: ComponentName;
  contractVersion: number;
  cursor?: string;
  afterSequence?: string;
  pageSize?: number;
}

export class ComponentSyncService {
  private readonly transactions: TenantTransactionRunner;
  private readonly materializer: OccurrenceMaterializer;
  private readonly cursors: ComponentCursorCodec;

  constructor(db: Db, cursorSecret: string) {
    this.transactions = new TenantTransactionRunner(db);
    this.materializer = new OccurrenceMaterializer(db);
    this.cursors = new ComponentCursorCodec(cursorSecret);
  }

  async read(userId: string, request: ComponentSyncRequest): Promise<ComponentSyncResponse> {
    if (!supportsContractVersion(request.component, request.contractVersion)) {
      throw new ApiError(409, ErrorCode.CONTRACT_NOT_ACTIVE, 'Requested sync contract is not available for this component', { retryable: false });
    }
    const expectedContract = request.contractVersion;
    const bridgeOccurrenceView = request.component === 'medicationBridge' && expectedContract >= 4;
    const bridgePrnView = request.component === 'medicationBridge' && expectedContract === 5;

    const cursor = request.cursor ? this.cursors.decode(request.cursor, userId) : undefined;
    if (cursor && request.afterSequence !== undefined) {
      throw new ApiError(400, ErrorCode.VALIDATION_ERROR, 'Cursor and checkpoint cannot be combined', { retryable: false });
    }
    if (cursor && (cursor.component !== request.component || cursor.contractVersion !== expectedContract)) {
      throw new ApiError(400, ErrorCode.VALIDATION_ERROR, 'Sync cursor does not match the requested component contract', { retryable: false });
    }
    if (cursor && request.pageSize !== undefined && request.pageSize !== cursor.pageSize) {
      throw new ApiError(400, ErrorCode.VALIDATION_ERROR, 'Page size cannot change during a sync traversal', { retryable: false });
    }
    const pageSize = cursor?.pageSize ?? request.pageSize ?? componentCursorLimits.defaultPageSize;

    return this.transactions.run(userId, async (tx) => {
      if (request.component === 'medication' || request.component === 'medicationBridge') {
        const ledgerActivated = await lockMedicationLedgerAuthority(tx);
        if (ledgerActivated === null) throw new ApiError(503, ErrorCode.INTERNAL, 'Medication sync authority is unavailable');
        if (request.component === 'medicationBridge' && ledgerActivated) {
          throw new ApiError(409, ErrorCode.CONTRACT_NOT_ACTIVE, 'Bridge medication sync is closed after ledger activation', { retryable: false });
        }
        if (request.component === 'medication' && !ledgerActivated) {
          throw new ApiError(409, ErrorCode.CONTRACT_NOT_ACTIVE, 'Active medication sync is not available before ledger activation', { retryable: false });
        }
        if ((request.component === 'medication' || bridgeOccurrenceView) && !cursor) {
          await this.materializer.ensureWindowInTransaction(tx, userId);
        }
      }

      const visibleChange = bridgeOccurrenceView
        ? or(
          eq(syncChanges.component, 'medicationBridge'),
          and(
            eq(syncChanges.component, 'medication'),
            eq(syncChanges.entityType, 'medication_occurrence'),
            bridgePrnView
              ? sql`${syncChanges.payload}->'payload'->>'source' IN ('scheduled', 'prn')`
              : sql`${syncChanges.payload}->'payload'->>'source' = 'scheduled'`,
            sql`${syncChanges.payload}->'payload'->>'provenance' = 'exact'`,
          ),
          ...(bridgePrnView ? [and(
            eq(syncChanges.component, 'medication'),
            eq(syncChanges.entityType, 'occurrence_event'),
            sql`EXISTS (
              SELECT 1 FROM ${medicationOccurrences} AS prn_occurrence
              WHERE prn_occurrence.id = (${syncChanges.payload}->'payload'->>'occurrenceId')::uuid
                AND prn_occurrence.user_id = ${userId}::uuid
                AND prn_occurrence.source = 'prn'
                AND prn_occurrence.provenance = 'exact'
            )`,
          )!] : []),
        )!
        : eq(syncChanges.component, request.component);

      const afterSequence = cursor?.afterSequence ?? request.afterSequence ?? '0';
      const throughSequence = cursor?.throughSequence ?? (await tx.select({
        throughSequence: sql<string>`COALESCE(MAX(${syncChanges.serverSequence}), 0)::text`,
      }).from(syncChanges).where(and(
        eq(syncChanges.userId, userId),
        visibleChange,
      )))[0]?.throughSequence ?? '0';

      if (BigInt(afterSequence) > BigInt(throughSequence)) {
        throw new ApiError(400, ErrorCode.VALIDATION_ERROR, 'Sync cursor sequence range is invalid', { retryable: false });
      }

      const rows = await tx.select({
        serverSequence: syncChanges.serverSequence,
        payloadSchemaVersion: syncChanges.payloadSchemaVersion,
        payload: syncChanges.payload,
      }).from(syncChanges).where(and(
        eq(syncChanges.userId, userId),
        visibleChange,
        gt(syncChanges.serverSequence, BigInt(afterSequence)),
        lte(syncChanges.serverSequence, BigInt(throughSequence)),
      )).orderBy(asc(syncChanges.serverSequence)).limit(pageSize + 1);

      const hasMore = rows.length > pageSize;
      const page = rows.slice(0, pageSize);
      const items = await Promise.all(page.map(async (row) => {
        if (row.payloadSchemaVersion !== 2) {
          throw new ApiError(500, ErrorCode.INTERNAL, 'Stored sync payload is unavailable');
        }
        let payload;
        try {
          payload = SyncChangePayloadV2Schema.parse(row.payload);
        } catch {
          throw new ApiError(500, ErrorCode.INTERNAL, 'Stored sync payload is unavailable');
        }
        if (bridgeOccurrenceView
            && payload.component === 'medication'
            && (payload.payload.kind === 'medicationOccurrence'
              || (bridgePrnView && payload.payload.kind === 'occurrenceEvent'))) {
          payload = SyncChangePayloadV2Schema.parse({ ...payload, component: 'medicationBridge' });
        } else if (payload.component !== request.component) {
          throw new ApiError(500, ErrorCode.INTERNAL, 'Stored sync payload is unavailable');
        }
        if (payload.payload.kind === 'bridgeDose' && payload.payload.parentSchedule !== undefined) {
          throw new ApiError(500, ErrorCode.INTERNAL, 'Stored sync payload is unavailable');
        }
        if (request.component === 'medicationBridge' && expectedContract >= 2 && payload.payload.kind === 'bridgeDose') {
          const [parent] = await tx.select({
            id: schedules.id,
            pillId: schedules.pillId,
            hour: schedules.hour,
            minute: schedules.minute,
            frequency: schedules.frequency,
            frequencyDays: schedules.frequencyDays,
            isActive: schedules.isActive,
            revision: schedules.revision,
            createdAt: schedules.createdAt,
            updatedAt: schedules.updatedAt,
            deletedAt: schedules.deletedAt,
            legacyQuarantineIssueId: schedules.legacyQuarantineIssueId,
            frequencyValid: sql<boolean>`public.schedule_frequency_days_valid(${schedules.frequency}, ${schedules.frequencyDays})`,
            pill: pills,
            profile: profiles,
          }).from(schedules)
            .innerJoin(pills, eq(pills.id, schedules.pillId))
            .innerJoin(profiles, eq(profiles.id, pills.profileId))
            .where(and(eq(schedules.id, payload.payload.scheduleId), eq(profiles.userId, userId)));
          if (!parent) {
            throw new ApiError(500, ErrorCode.INTERNAL, 'Bridge dose parent is unavailable');
          }
          const disposition = parent.deletedAt !== null
            ? 'deleted' as const
            : parent.legacyQuarantineIssueId !== null && !parent.frequencyValid
              ? 'quarantined' as const
              : null;
          if (!parent.frequencyValid && (parent.legacyQuarantineIssueId === null || parent.isActive)) {
            throw new ApiError(500, ErrorCode.INTERNAL, 'Bridge dose parent quarantine is invalid');
          }
          if (disposition !== null) {
            payload = SyncChangePayloadV2Schema.parse({
              ...payload,
              payload: {
                ...payload.payload,
                parentSchedule: {
                  id: parent.id,
                  pillId: parent.pillId,
                  hour: parent.hour,
                  minute: parent.minute,
                  frequency: parent.frequency,
                  frequencyDays: parent.frequencyDays,
                  revision: parent.revision.toString(),
                  createdAt: parent.createdAt.toISOString(),
                  updatedAt: parent.updatedAt.toISOString(),
                  deletedAt: parent.deletedAt?.toISOString() ?? null,
                  disposition,
                },
                ...(expectedContract >= 3 ? {
                  parentProfile: {
                    kind: 'profile', id: parent.profile.id, userId: parent.profile.userId,
                    name: parent.profile.name, avatarEmoji: parent.profile.avatarEmoji,
                    isActive: parent.profile.isActive, revision: parent.profile.revision.toString(),
                    deletedAt: parent.profile.deletedAt?.toISOString() ?? null,
                    createdAt: parent.profile.createdAt.toISOString(), updatedAt: parent.profile.updatedAt.toISOString(),
                  },
                  parentPill: {
                    kind: 'pill', id: parent.pill.id, profileId: parent.pill.profileId,
                    name: parent.pill.name, dosage: parent.pill.dosage, notes: parent.pill.notes,
                    color: parent.pill.color, currentStock: legacyStockInteger(parent.pill.currentStock),
                    lowStockThreshold: parent.pill.lowStockThreshold, isPrn: parent.pill.isPrn,
                    revision: parent.pill.revision.toString(), deletedAt: parent.pill.deletedAt?.toISOString() ?? null,
                    createdAt: parent.pill.createdAt.toISOString(), updatedAt: parent.pill.updatedAt.toISOString(),
                  },
                } : {}),
              },
            });
          }
        }
        return {
          serverSequence: row.serverSequence.toString(),
          change: payload,
        };
      }));
      const nextAfterSequence = page.at(-1)?.serverSequence.toString() ?? afterSequence;
      const nextCursor = hasMore ? this.cursors.encode({
        component: request.component,
        contractVersion: expectedContract,
        afterSequence: nextAfterSequence,
        throughSequence,
        pageSize,
      }, userId) : null;

      const response = {
        component: request.component,
        contractVersion: expectedContract,
        afterSequence,
        throughSequence,
        items,
        nextCursor,
        hasMore,
      };
      const parsed = ComponentSyncResponseSchema.safeParse(response);
      if (!parsed.success) {
        // A server-built page that fails its own schema is a server fault, never
        // a client validation error. Name only the component and offending sequence.
        const [section, index] = parsed.error.issues[0]?.path ?? [];
        const offender = section === 'items' && typeof index === 'number' ? items[index] : undefined;
        throw new ApiError(500, ErrorCode.SYNC_PAYLOAD_INVALID, 'Sync page could not be produced', {
          retryable: false,
          logFields: {
            syncComponent: request.component,
            ...(offender ? { serverSequence: String(offender.serverSequence) } : {}),
          },
        });
      }
      return parsed.data;
    });
  }
}
