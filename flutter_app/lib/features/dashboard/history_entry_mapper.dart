import 'dart:convert';

import '../../core/db/database.dart';
import '../../core/db/daos/medication_ledger_dao.dart';
import '../../core/medication/care_recording.dart';
import '../../core/medication/current_name_display.dart';
import '../../core/medication/late_dose.dart';
import '../../core/medication/medication_amount.dart';
import '../../core/medication/reviewed_stock.dart';
import '../../core/medication/occurrence_history.dart';
import 'models/history_entry.dart';

HistoryEntry historyEntryFromOccurrenceRecord(
  MedicationOccurrenceRecord record, {
  required DateTime now,
  Map<String, CareEventDetail> detailsByEvent = const {},
  Map<String, String> pillNamesById = const {},
}) {
  // A pending dose shows the medication's current name, like Today and the
  // detail screen; a recorded one keeps the name it was recorded under.
  final occurrence = withCurrentName(record.occurrence, pillNamesById);
  final summary = calculateOccurrenceAdherence(
    records: [
      MedicationOccurrenceRecord(occurrence: occurrence, events: record.events),
    ],
    now: now,
  );
  final item = summary.history.single;
  final snapshot = decodeOccurrenceSnapshot(occurrence.scheduleSnapshotJson);
  final facts = [
    for (final event in record.events)
      if (event.userId == occurrence.userId)
        CareEventFacts(
          event: event,
          amount: detailsByEvent[event.id] == null
              ? const MedicationAmount.unknown()
              : MedicationAmount.fromJson(
                  Map<String, Object?>.from(
                    jsonDecode(detailsByEvent[event.id]!.amountJson) as Map,
                  ),
                ),
          authorId: detailsByEvent[event.id]?.authorId,
          authorName: detailsByEvent[event.id]?.authorName,
          localReversalEventId: detailsByEvent[event.id]?.localReversalEventId,
          stock: detailsByEvent[event.id] == null
              ? CareStockOutcome.notTracked
              : CareStockOutcome.values.byName(
                  detailsByEvent[event.id]!.stockOutcome,
                ),
        ),
  ]..sort((a, b) => a.event.resultVersion.compareTo(b.event.resultVersion));
  final head = facts
      .where((f) => f.event.resultVersion == occurrence.stateVersion)
      .singleOrNull;
  return HistoryEntry(
    doseLogId: occurrence.id,
    occurrenceId: occurrence.id,
    pillName: snapshot?['pillName'] as String? ?? 'Medication history',
    dosage: snapshot?['dosage'] as String?,
    scheduledAt: occurrence.plannedAt,
    takenAt: item.actualTimeKnown ? item.actualAt : null,
    status: item.status,
    occurrenceState: occurrence.state,
    note: item.note,
    profileName: snapshot?['profileName'] as String? ?? 'Unknown profile',
    scheduleId: occurrence.scheduleId ?? '',
    source: occurrence.source,
    provenance: occurrence.provenance,
    actualTimeKnown: item.actualTimeKnown,
    plannedLocalDate: occurrence.plannedLocalDate,
    plannedLocalTime: occurrence.plannedLocalTime,
    personId: snapshot?['profileId'] as String?,
    timeZone: occurrence.timeZone,
    stateVersion: occurrence.stateVersion,
    recordedAt: head?.event.recordedAt,
    authorId: head?.authorId,
    authorName: head?.authorName,
    amount: head?.amount ?? const MedicationAmount.unknown(),
    auditEvents: List.unmodifiable(facts),
    takenLate: isTakenLate(occurrence.state, head?.event),
  );
}
