import { addLocalDays, calculateScheduledOccurrenceSlots, localDateAt } from '../modules/medication/occurrence-materializer.js';
import { serializeSyncChangePayload } from '../modules/sync/sync-payload.js';
import { legacyHistoryRecordFromJournal, inventoryDeltaFromJournal, type LegacyHandoffJournalEvidence } from '../modules/medication/legacy-handoff.js';
import type { PrivilegedCommandContext } from './provision.js';
import type { ScheduleSnapshotV1 } from '../modules/medication/schedule-snapshot.js';
import type { Sql } from 'postgres';

type SqlExecutor = Pick<Sql, 'unsafe'>;

// The raw postgres.js client serializes a parameter by its inferred server type.
// A bare `$n::jsonb` infers jsonb, so a pre-stringified value would be encoded a
// second time and stored as a JSON string. Every JSON parameter here is therefore
// bound as text and cast server-side (`$n::text::jsonb`), so it is encoded once.

interface ManifestRow {
  contractVersion: string;
  ledgerActivated: boolean;
  enforcedMinimumClientBuild: number;
  targetMinimumClientBuild: number;
}

interface JournalRow extends LegacyHandoffJournalEvidence {
  id: string;
  commandBundleId: string;
  subeffectKind: 'dose' | 'inventory';
  subeffectOrdinal: number;
  createdAt: string;
}

interface ScheduleRow {
  id: string;
  userId: string;
  revision: string;
  pillId: string;
  hour: number;
  minute: number;
  frequency: 'daily' | 'weekly' | 'custom' | 'prn';
  frequencyDays: number[] | null;
  isActive: boolean;
  deletedAt: string | null;
  legacyQuarantineIssueId: string | null;
  timeZoneStatus: 'known' | 'legacy_unknown';
  timeZone: string | null;
  materializeFromLocalDate: string | null;
  updatedAt: string;
  pillName: string;
  dosage: string | null;
  profileId: string;
  profileName: string;
}

interface OccurrenceRow {
  id: string;
  occurrenceKey: string;
  stateVersion: string;
  plannedLocalDate: string;
  plannedLocalTime: string;
  plannedAt: string;
  timeZone: string;
  scheduleSnapshot: ScheduleSnapshotV1;
}

async function setTenant(sql: SqlExecutor, userId: string): Promise<void> {
  await sql.unsafe("SELECT set_config('app.current_user_id', $1, true)", [userId]);
}

async function nextSequence(sql: SqlExecutor, userId: string): Promise<string> {
  const rows = await sql.unsafe<{ sequence: string }[]>(
    'SELECT public.next_sync_server_sequence($1::uuid)::text AS sequence', [userId],
  );
  const sequence = rows[0]?.sequence;
  if (!sequence) throw new Error('could not allocate a tenant sync sequence');
  return sequence;
}

async function insertSyncChange(
  sql: SqlExecutor,
  userId: string,
  input: unknown,
  sequence?: string,
): Promise<string> {
  const change = serializeSyncChangePayload(input).value;
  const serverSequence = sequence ?? await nextSequence(sql, userId);
  await sql.unsafe(`
    INSERT INTO public.sync_changes (
      user_id, component, entity_type, entity_id, operation, source_kind,
      source_id, source_revision, server_sequence, payload_schema_version, payload
    ) VALUES ($1::uuid, $2, $3, $4::uuid, $5, $6, $7::uuid, $8::bigint, $9::bigint, 2, $10::text::jsonb)
  `, [
    userId, change.component, change.entityType, change.entityId, change.operation,
    change.sourceIdentity.sourceKind, change.sourceIdentity.sourceId,
    change.sourceIdentity.sourceRevision, serverSequence, JSON.stringify(change),
  ]);
  return serverSequence;
}

function serializeOccurrence(row: OccurrenceRow, schedule: ScheduleRow) {
  return {
    schemaVersion: 2,
    component: 'medication',
    entityType: 'medication_occurrence',
    entityId: row.id,
    operation: 'upsert',
    sourceIdentity: { sourceKind: 'occurrence', sourceId: row.id, sourceRevision: (BigInt(row.stateVersion) + 1n).toString() },
    payload: {
      kind: 'medicationOccurrence',
      id: row.id,
      pillId: schedule.pillId,
      scheduleId: schedule.id,
      occurrenceKey: row.occurrenceKey,
      source: 'scheduled',
      scheduleRevision: schedule.revision,
      plannedLocalDate: row.plannedLocalDate,
      plannedLocalTime: row.plannedLocalTime,
      timeZone: row.timeZone,
      plannedAt: new Date(row.plannedAt).toISOString(),
      expected: true,
      snapshotVersion: 1,
      scheduleSnapshot: row.scheduleSnapshot,
      provenance: 'exact',
      supersededAt: null,
      supersededByOccurrenceId: null,
      stateVersion: row.stateVersion,
    },
  };
}

async function materializeSchedules(sql: SqlExecutor): Promise<void> {
  const rows = await sql.unsafe<ScheduleRow[]>(`
    SELECT s.id, pr.user_id AS "userId", s.revision::text AS revision, s.pill_id AS "pillId",
      s.hour, s.minute, s.frequency, s.frequency_days AS "frequencyDays", s.is_active AS "isActive",
      s.deleted_at AS "deletedAt", s.legacy_quarantine_issue_id AS "legacyQuarantineIssueId",
      s.time_zone_status AS "timeZoneStatus", s.time_zone AS "timeZone",
      s.materialize_from_local_date::text AS "materializeFromLocalDate", s.updated_at AS "updatedAt",
      p.name AS "pillName", p.dosage, pr.id AS "profileId", pr.name AS "profileName"
    FROM public.schedules s
    JOIN public.pills p ON p.id = s.pill_id
    JOIN public.profiles pr ON pr.id = p.profile_id
    WHERE s.deleted_at IS NULL AND p.deleted_at IS NULL AND pr.deleted_at IS NULL
      AND s.is_active AND s.legacy_quarantine_issue_id IS NULL
      AND s.time_zone_status = 'known' AND s.time_zone IS NOT NULL AND s.frequency <> 'prn'
    ORDER BY pr.user_id, s.id
  `);

  for (const schedule of rows) {
    const zone = schedule.timeZone;
    if (!zone) continue;
    await setTenant(sql, schedule.userId);
    const today = localDateAt(new Date(), zone);
    const through = addLocalDays(today, 30);
    const latestRows = await sql.unsafe<{ latest: string | null }[]>(`
      SELECT max(planned_local_date)::text AS latest
      FROM public.medication_occurrences
      WHERE user_id = $1::uuid AND schedule_id = $2::uuid
        AND schedule_revision = $3::bigint AND source = 'scheduled'
    `, [schedule.userId, schedule.id, schedule.revision]);
    const revisionStart = localDateAt(new Date(schedule.updatedAt), zone);
    const startFloor = schedule.materializeFromLocalDate ?? revisionStart;
    const latest = latestRows[0]?.latest;
    const firstMissing = latest ? addLocalDays(latest, 1) : startFloor;
    const from = firstMissing > startFloor ? firstMissing : startFloor;
    if (through < from) continue;

    const slots = calculateScheduledOccurrenceSlots({
      id: schedule.id,
      userId: schedule.userId,
      revision: BigInt(schedule.revision),
      pillId: schedule.pillId,
      hour: schedule.hour,
      minute: schedule.minute,
      frequency: schedule.frequency,
      frequencyDays: schedule.frequencyDays,
      isActive: schedule.isActive,
      deletedAt: schedule.deletedAt ? new Date(schedule.deletedAt) : null,
      legacyQuarantineIssueId: schedule.legacyQuarantineIssueId,
      timeZoneStatus: schedule.timeZoneStatus,
      timeZone: zone,
      materializeFromLocalDate: schedule.materializeFromLocalDate,
      updatedAt: new Date(schedule.updatedAt),
      pillName: schedule.pillName,
      dosage: schedule.dosage,
      profileId: schedule.profileId,
      profileName: schedule.profileName,
    }, schedule.userId, from, through);

    for (const slot of slots) {
      const inserted = await sql.unsafe<OccurrenceRow[]>(`
        INSERT INTO public.medication_occurrences (
          user_id, pill_id, schedule_id, occurrence_key, source, schedule_revision,
          planned_local_date, planned_local_time, time_zone, planned_at, expected,
          snapshot_version, schedule_snapshot, provenance, state_version
        ) VALUES ($1::uuid, $2::uuid, $3::uuid, $4, 'scheduled', $5::bigint,
          $6::date, $7::time, $8, $9::timestamptz, true, 1, $10::text::jsonb, 'exact', 0)
        ON CONFLICT (user_id, occurrence_key) DO NOTHING
        RETURNING id, occurrence_key AS "occurrenceKey", state_version::text AS "stateVersion",
          planned_local_date::text AS "plannedLocalDate", planned_local_time::text AS "plannedLocalTime",
          planned_at AS "plannedAt", time_zone AS "timeZone", schedule_snapshot AS "scheduleSnapshot"
      `, [
        schedule.userId, schedule.pillId, schedule.id, slot.occurrenceKey, schedule.revision,
        slot.plannedLocalDate, slot.plannedLocalTime, slot.timeZone, slot.plannedAt.toISOString(),
        JSON.stringify(slot.scheduleSnapshot),
      ]);
      const occurrence = inserted[0];
      if (occurrence) {
        await insertSyncChange(sql, schedule.userId, serializeOccurrence(occurrence, schedule));
      } else {
        const existing = await sql.unsafe<{
          scheduleId: string | null;
          scheduleRevision: string | null;
          plannedLocalDate: string;
          plannedLocalTime: string | null;
          timeZone: string;
          plannedAt: string | Date | null;
          source: string;
          expected: boolean;
        }[]>(`
          SELECT schedule_id AS "scheduleId", schedule_revision::text AS "scheduleRevision",
            planned_local_date::text AS "plannedLocalDate", planned_local_time::text AS "plannedLocalTime",
            time_zone AS "timeZone", planned_at AS "plannedAt", source, expected
          FROM public.medication_occurrences
          WHERE user_id = $1::uuid AND occurrence_key = $2
        `, [schedule.userId, slot.occurrenceKey]);
        const row = existing[0];
        if (!row || row.source !== 'scheduled' || !row.expected
          || row.scheduleId !== schedule.id || row.scheduleRevision !== schedule.revision
          || row.plannedLocalDate !== slot.plannedLocalDate
          || row.plannedLocalTime?.slice(0, 5) !== slot.plannedLocalTime.slice(0, 5)
          || row.timeZone !== slot.timeZone
          || !row.plannedAt
          || new Date(row.plannedAt).getTime() !== slot.plannedAt.getTime()) {
          throw new Error(`canonical occurrence key ${slot.occurrenceKey} conflicts with stored immutable data`);
        }
      }
    }
  }
}

async function coverJournal(sql: SqlExecutor): Promise<void> {
  const journalRows = await sql.unsafe<JournalRow[]>(`
    SELECT id, user_id AS "userId", legacy_source_kind AS "legacySourceKind",
      legacy_source_id AS "legacySourceId", source_revision::text AS "sourceRevision",
      before_evidence AS "beforeEvidence", after_evidence AS "afterEvidence",
      command_bundle_id AS "commandBundleId", subeffect_kind AS "subeffectKind",
      subeffect_ordinal AS "subeffectOrdinal", created_at AS "createdAt"
    FROM public.medication_handoff_journal
    WHERE coverage_state <> 'covered'
    ORDER BY user_id, journal_sequence
    FOR UPDATE
  `);
  for (const journal of journalRows) {
    await setTenant(sql, journal.userId);
    const scheduleEvidence = journal.afterEvidence?.['scheduleId'] ?? journal.beforeEvidence?.['scheduleId'];
    const parents = journal.legacySourceKind === 'dose_log' && typeof scheduleEvidence === 'string'
      ? {
        schedulePillId: (await sql.unsafe<{ pillId: string }[]>(
          'SELECT pill_id AS "pillId" FROM public.schedules WHERE id = $1::uuid', [scheduleEvidence],
        ))[0]?.pillId ?? null,
      }
      : undefined;
    const converted = legacyHistoryRecordFromJournal(journal, parents);
    const history = converted.history;
    const historyRows = await sql.unsafe<{ historyEntryId: string }[]>(`
      INSERT INTO public.legacy_medication_history (
        history_entry_id, history_id, user_id, source_revision, operation,
        legacy_source_kind, legacy_source_id, pill_id, schedule_id,
        local_date_evidence, local_time_evidence, stored_utc, time_zone_status,
        provenance, state, historical_inventory_delta_evidence, inventory_delta_provenance,
        migration_inventory_effect, inventory_disposition, source_fingerprint,
        entity_revision, source_snapshot, coverage_state
      ) VALUES ($1::uuid, $2::uuid, $3::uuid, $4::bigint, $5,
        $6, $7::uuid, $8::uuid, $9::uuid, NULL, NULL, $10::timestamptz,
        'legacy_unknown', 'legacy_estimated', $11, NULL, 'unknown', 'none', 'effect_unknown',
        $12, 1, $13::text::jsonb, 'pending')
      ON CONFLICT (user_id, legacy_source_kind, legacy_source_id, source_revision)
      DO UPDATE SET history_entry_id = public.legacy_medication_history.history_entry_id
      RETURNING history_entry_id AS "historyEntryId"
    `, [
      history.historyEntryId, history.historyId, journal.userId, history.sourceRevision,
      history.operation, history.legacySourceKind, history.legacySourceId, history.pillId,
      history.scheduleId, history.storedUtc, history.state, history.sourceFingerprint,
      JSON.stringify(converted.sourceSnapshot),
    ]);
    const historyEntryId = historyRows[0]?.historyEntryId;
    if (!historyEntryId) throw new Error('could not preserve a medication handoff journal row');
    let mappingTargetType: 'inventory_event' | 'legacy_medication_history' = 'legacy_medication_history';
    let mappingTargetId = history.historyId;
    let mappingTargetRevision = history.entityRevision;
    const sourceRevision = history.sourceRevision;
    const envelope = history.operation === 'upsert'
      ? {
        schemaVersion: 2,
        component: 'medicationBridge',
        entityType: 'legacy_medication_history',
        entityId: history.historyId,
        operation: 'upsert',
        sourceIdentity: { sourceKind: 'legacy_history_entry', sourceId: history.historyEntryId, sourceRevision },
        payload: history,
      }
      : {
        schemaVersion: 2,
        component: 'medicationBridge',
        entityType: 'legacy_medication_history',
        entityId: history.historyId,
        operation: 'upsert',
        sourceIdentity: { sourceKind: 'legacy_history_entry', sourceId: history.historyEntryId, sourceRevision },
        payload: history,
      };
    const sequence = await insertSyncChange(sql, journal.userId, envelope);
    await sql.unsafe(`
      UPDATE public.legacy_medication_history
      SET coverage_state = 'covered', sync_change_id = (
        SELECT id FROM public.sync_changes WHERE user_id = $1::uuid AND server_sequence = $2::bigint
      ), mapped_entity_type = 'legacy_medication_history', mapped_entity_id = $3::uuid, mapped_at = now()
      WHERE user_id = $1::uuid AND history_entry_id = $4::uuid
    `, [journal.userId, sequence, history.historyId, historyEntryId]);
    await sql.unsafe(`
      UPDATE public.medication_handoff_journal
      SET coverage_state = 'covered', history_entry_id = $2::uuid, mapped_at = now()
      WHERE user_id = $1::uuid AND id = $3::uuid AND coverage_state <> 'covered'
    `, [journal.userId, historyEntryId, journal.id]);

    if (journal.legacySourceKind === 'pill_stock') {
      const delta = inventoryDeltaFromJournal(journal);
      const afterStock = journal.afterEvidence?.['currentStock'];
      if (delta === null && afterStock !== null && afterStock !== undefined) {
        throw new Error(`stock journal ${journal.id} has an unknown post-write balance`);
      }
      const isOpening = journal.beforeEvidence?.['currentStock'] === null
        || journal.beforeEvidence?.['currentStock'] === undefined;
      if (delta !== null && (delta !== 0 || isOpening)) {
        const sequenceForEvent = await nextSequence(sql, journal.userId);
        const eventKind = isOpening ? 'opening' : 'correction';
        const eventRows = await sql.unsafe<{ id: string; recordedAt: string }[]>(`
          INSERT INTO public.inventory_events (
            user_id, pill_id, command_id, kind, delta, provenance, note, server_sequence
          ) VALUES ($1::uuid, $2::uuid, $3::uuid, $4, $5::integer, 'legacy_handoff', NULL, $6::bigint)
          RETURNING id, recorded_at AS "recordedAt"
        `, [journal.userId, history.pillId, journal.commandBundleId, eventKind, delta, sequenceForEvent]);
        const event = eventRows[0];
        if (!event) throw new Error('could not create the stock handoff ledger event');
        mappingTargetType = 'inventory_event';
        mappingTargetId = event.id;
        mappingTargetRevision = sequenceForEvent;
        await insertSyncChange(sql, journal.userId, {
          schemaVersion: 2,
          component: 'medication',
          entityType: 'inventory_event',
          entityId: event.id,
          operation: 'upsert',
          sourceIdentity: { sourceKind: 'inventory_event', sourceId: event.id, sourceRevision: sequenceForEvent },
          payload: {
            kind: 'inventoryEvent',
            id: event.id,
            pillId: history.pillId,
            commandId: journal.commandBundleId,
            eventKind,
            delta,
            occurrenceEventId: null,
            reversesInventoryEventId: null,
            provenance: 'legacy_handoff',
            note: null,
            serverSequence: sequenceForEvent,
            recordedAt: new Date(event.recordedAt).toISOString(),
          },
        }, sequenceForEvent);
      }
    }

    const linkedReceipt = await sql.unsafe<{ commandId: string }[]>(`
      SELECT command_id AS "commandId" FROM public.preactivation_medication_receipts
      WHERE user_id = $1::uuid AND command_bundle_id = $2::uuid
      ORDER BY created_at DESC LIMIT 1
    `, [journal.userId, journal.commandBundleId]);
    await insertSyncChange(sql, journal.userId, {
      schemaVersion: 2,
      component: 'medication',
      entityType: 'identity_mapping',
      entityId: mappingTargetId,
      operation: 'mapping',
      sourceIdentity: {
        sourceKind: 'bridge_mapping',
        sourceId: journal.legacySourceId,
        sourceRevision: history.sourceRevision,
      },
      payload: {
        kind: 'identityMapping',
        mappingRevision: history.sourceRevision,
        legacySourceKind: journal.legacySourceKind,
        legacySourceId: journal.legacySourceId,
        historyId: history.historyId,
        bridgeCommandId: linkedReceipt[0]?.commandId ?? null,
        targetEntityType: mappingTargetType,
        targetEntityId: mappingTargetId,
        targetRevision: mappingTargetRevision,
      },
    });
  }
}

async function promoteCompleteReceipts(sql: SqlExecutor): Promise<void> {
  const incomplete = await sql.unsafe<{ count: string }[]>(`
    SELECT count(*)::text AS count
    FROM public.preactivation_medication_receipts
    WHERE complete IS FALSE OR result_metadata IS NULL
      OR observed_subeffect_count <> expected_subeffect_count
  `);
  if (incomplete[0]?.count !== '0') throw new Error('ledger activation blocked by incomplete bridge receipts');

  const receipts = await sql.unsafe<{ userId: string; commandId: string; inputFingerprint: string; id: string; resultMetadata: unknown; commandBundleId: string }[]>(`
    SELECT user_id AS "userId", command_id AS "commandId", input_fingerprint AS "inputFingerprint",
      id, result_metadata AS "resultMetadata", command_bundle_id AS "commandBundleId"
    FROM public.preactivation_medication_receipts
    WHERE complete IS TRUE
    ORDER BY user_id, created_at, id
    FOR UPDATE
  `);
  for (const receipt of receipts) {
    await setTenant(sql, receipt.userId);
    const bundleRows = await sql.unsafe<{ count: string }[]>(`
      SELECT count(*)::text AS count FROM public.medication_handoff_journal
      WHERE user_id = $1::uuid AND command_bundle_id = $2::uuid
    `, [receipt.userId, receipt.commandBundleId]);
    const expectedRows = await sql.unsafe<{ observed: number }[]>(`
      SELECT observed_subeffect_count AS observed FROM public.preactivation_medication_receipts
      WHERE id = $1::uuid
    `, [receipt.id]);
    if (bundleRows[0]?.count !== String(expectedRows[0]?.observed ?? 0)) {
      throw new Error(`ledger activation blocked by an incomplete command bundle ${receipt.commandBundleId}`);
    }
    await sql.unsafe(`
      INSERT INTO public.medication_command_receipts (
        user_id, command_id, input_fingerprint, origin, result_metadata, preactivation_receipt_id
      ) VALUES ($1::uuid, $2::uuid, $3, 'legacy_handoff', $4::text::jsonb, $5::uuid)
      ON CONFLICT (user_id, command_id) DO NOTHING
    `, [receipt.userId, receipt.commandId, receipt.inputFingerprint, JSON.stringify(receipt.resultMetadata), receipt.id]);
    const promoted = await sql.unsafe<{ inputFingerprint: string }[]>(`
      SELECT input_fingerprint AS "inputFingerprint" FROM public.medication_command_receipts
      WHERE user_id = $1::uuid AND command_id = $2::uuid
    `, [receipt.userId, receipt.commandId]);
    if (promoted[0]?.inputFingerprint !== receipt.inputFingerprint) {
      throw new Error(`bridge command ${receipt.commandId} conflicts with a permanent command receipt`);
    }
  }
}

/**
 * A timezone review on a routine that has since been deleted (the schedule, its
 * pill or its profile is soft deleted) can never be resolved through the repair
 * API, which only accepts live revision-1 schedules, and the 0013 triggers force
 * a legacy_unknown schedule to keep its unresolved issue. Such a review has no
 * occurrences to materialize, so activation closes it: the marker is cleared
 * (the schedule keeps its stored hour/minute and is labelled UTC, which is never
 * used because it is deleted) and the issue becomes resolved revision 2, the
 * only transition the issue guard allows. Reviews on live routines stay
 * blocking. Returns how many reviews were closed.
 */
async function closeDeletedRoutineReviews(sql: SqlExecutor): Promise<number> {
  const reviews = await sql.unsafe<{ issueId: string; scheduleId: string; userId: string }[]>(`
    SELECT issue.id AS "issueId", s.id AS "scheduleId", issue.user_id AS "userId"
    FROM public.migration_issues issue
    JOIN public.schedules s ON s.timezone_review_issue_id = issue.id
    JOIN public.pills p ON p.id = s.pill_id
    JOIN public.profiles pr ON pr.id = p.profile_id
    WHERE issue.state = 'unresolved' AND issue.revision = 1
      AND issue.issue_code = 'schedule_timezone_review_required'
      AND issue.entity_type = 'schedules' AND issue.entity_id = s.id
      AND s.time_zone_status = 'legacy_unknown'
      AND (s.deleted_at IS NOT NULL OR p.deleted_at IS NOT NULL OR pr.deleted_at IS NOT NULL)
    ORDER BY issue.user_id, issue.id
    FOR UPDATE OF s, issue
  `);
  for (const review of reviews) {
    await setTenant(sql, review.userId);
    await sql.unsafe(`
      UPDATE public.schedules
      SET timezone_review_issue_id = NULL, time_zone_status = 'known', time_zone = 'UTC'
      WHERE id = $1::uuid
    `, [review.scheduleId]);
    await sql.unsafe(`
      UPDATE public.migration_issues
      SET state = 'resolved', revision = 2, resolved_by = user_id, resolved_at = now()
      WHERE id = $1::uuid AND state = 'unresolved' AND revision = 1
    `, [review.issueId]);
  }
  return reviews.length;
}

async function assertActivationReady(sql: SqlExecutor): Promise<void> {
  const unresolved = await sql.unsafe<{ count: string }[]>(`
    SELECT count(*)::text AS count FROM public.migration_issues WHERE state = 'unresolved'
  `);
  if (unresolved[0]?.count !== '0') throw new Error('ledger activation blocked by unresolved migration issues');
  const uncovered = await sql.unsafe<{ journal: string; history: string; mappings: string }[]>(`
    SELECT
      (SELECT count(*)::text FROM public.medication_handoff_journal WHERE coverage_state <> 'covered') AS journal,
      (SELECT count(*)::text FROM public.legacy_medication_history WHERE coverage_state <> 'covered') AS history,
      (SELECT count(*)::text FROM public.medication_handoff_journal j
        WHERE NOT EXISTS (SELECT 1 FROM public.sync_changes c
          WHERE c.user_id = j.user_id AND c.source_kind = 'bridge_mapping'
            AND c.source_id = j.legacy_source_id AND c.source_revision = j.source_revision
            AND c.entity_type = 'identity_mapping')) AS mappings
  `);
  if (uncovered[0]?.journal !== '0' || uncovered[0]?.history !== '0' || uncovered[0]?.mappings !== '0') {
    throw new Error('ledger activation blocked by uncovered legacy medication history');
  }
  const stockMismatch = await sql.unsafe<{ count: string }[]>(`
    SELECT count(*)::text AS count
    FROM public.pills p
    JOIN public.profiles pr ON pr.id = p.profile_id
    WHERE p.current_stock IS NOT NULL AND p.deleted_at IS NULL AND pr.deleted_at IS NULL
      AND p.current_stock::bigint <> COALESCE((
        SELECT sum(e.delta)::bigint FROM public.inventory_events e
        WHERE e.user_id = pr.user_id AND e.pill_id = p.id
      ), 0)
  `);
  if (stockMismatch[0]?.count !== '0') throw new Error('ledger activation blocked by an unreconciled stock balance');
}

export async function activateMedicationLedger({ sql, environment }: PrivilegedCommandContext): Promise<void> {
  const build = Number(environment['LEDGER_CURRENT_BUILD']);
  const changeReference = environment['LEDGER_CHANGE_REFERENCE']?.trim();
  if (!Number.isSafeInteger(build) || build < 1 || !changeReference || changeReference.length > 256) {
    throw new Error('set LEDGER_CURRENT_BUILD and LEDGER_CHANGE_REFERENCE before activation');
  }

  await sql.begin(async (transaction) => {
    const manifests = await transaction.unsafe<ManifestRow[]>(`
      SELECT contract_version::text AS "contractVersion", ledger_activated AS "ledgerActivated",
        enforced_minimum_client_build AS "enforcedMinimumClientBuild",
        target_minimum_client_build AS "targetMinimumClientBuild"
      FROM public.deployment_manifest WHERE singleton_key IS TRUE FOR UPDATE
    `);
    const manifest = manifests[0];
    if (!manifest) throw new Error('deployment authority manifest is missing');
    if (manifest.ledgerActivated) throw new Error('medication ledger authority is already active');
    if (build < manifest.targetMinimumClientBuild) throw new Error('current client build is below the activation target');

    const closedReviews = await closeDeletedRoutineReviews(transaction);
    if (closedReviews > 0) {
      console.log(`closed ${closedReviews} timezone review(s) on deleted routines`);
    }
    const unresolved = await transaction.unsafe<{ count: string }[]>(`
      SELECT count(*)::text AS count FROM public.migration_issues WHERE state = 'unresolved'
    `);
    if (unresolved[0]?.count !== '0') throw new Error('ledger activation blocked by unresolved migration issues');

    await coverJournal(transaction);
    await materializeSchedules(transaction);
    await promoteCompleteReceipts(transaction);
    await assertActivationReady(transaction);

    await transaction.unsafe(`
      SELECT public.set_deployment_authority(2, true, $1::integer, 'ledger_activation', $2)
    `, [manifest.enforcedMinimumClientBuild, changeReference]);
  });
}
