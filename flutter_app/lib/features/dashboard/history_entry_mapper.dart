import '../../core/db/database.dart';
import '../../core/db/daos/medication_ledger_dao.dart';
import '../../core/medication/care_recording.dart';
import '../../core/medication/current_name_display.dart';
import '../../core/medication/late_dose.dart';
import '../../core/medication/local_occurrence_snapshot.dart';
import '../../core/medication/medication_amount.dart';
import '../../core/medication/recorded_amount.dart';
import '../../core/medication/reviewed_stock.dart';
import '../../core/medication/occurrence_history.dart';
import 'models/history_entry.dart';

HistoryEntry historyEntryFromOccurrenceRecord(
  MedicationOccurrenceRecord record, {
  required DateTime now,
  Map<String, CareEventDetail> detailsByEvent = const {},
  Map<String, String> pillNamesById = const {},
  Map<String, String> pillColorsById = const {},
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
          amount: recordedAmountOf(
            event,
            detailAmountJson: detailsByEvent[event.id]?.amountJson,
          ),
          authorId: detailsByEvent[event.id]?.authorId,
          authorName: careAuthorName(detailsByEvent[event.id], event),
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
    plannedAmount: _plannedAmount(snapshot),
    pillId: occurrence.pillId,
    pillColor: occurrence.pillId == null
        ? null
        : pillColorsById[occurrence.pillId],
    auditEvents: List.unmodifiable(facts),
    takenLate: isTakenLate(occurrence.state, head?.event),
  );
}

MedicationAmount _plannedAmount(Map<String, dynamic>? snapshot) {
  if (snapshot == null) return const MedicationAmount.unknown();
  try {
    final decoded = decodeScheduleSnapshot(snapshot);
    return decoded is LocalOccurrenceSnapshot
        ? decoded.amount
        : const MedicationAmount.unknown();
  } on Object {
    return const MedicationAmount.unknown();
  }
}
