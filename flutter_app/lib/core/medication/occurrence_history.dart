import 'dart:convert';

import '../db/daos/medication_ledger_dao.dart';
import 'adherence_calculator.dart';
import 'local_occurrence_snapshot.dart';

/// Adapts the synced occurrence projection and immutable event rows to the
/// shared read-only adherence/history model.
AdherenceSummary calculateOccurrenceAdherence({
  required Iterable<MedicationOccurrenceRecord> records,
  required DateTime now,
}) {
  final occurrenceList = <AdherenceOccurrence>[];
  final eventList = <AdherenceEvent>[];
  for (final record in records) {
    final occurrence = record.occurrence;
    final snapshot = _decodeSnapshot(occurrence.scheduleSnapshotJson);
    occurrenceList.add(
      AdherenceOccurrence(
        id: occurrence.id,
        source: occurrence.source,
        expected: occurrence.expected,
        plannedAt: occurrence.plannedAt,
        plannedLocalDate: occurrence.plannedLocalDate,
        state: occurrence.state,
        provenance: occurrence.provenance,
        superseded: occurrence.supersededAt != null,
        pillId: occurrence.pillId,
        pillName: snapshot?['pillName'] as String?,
        dosage: snapshot?['dosage'] as String?,
        profileId: snapshot?['profileId'] as String?,
      ),
    );
    eventList.addAll(
      record.events.map(
        (event) => AdherenceEvent(
          occurrenceId: event.occurrenceId,
          resultVersion: event.resultVersion,
          action: event.action,
          toState: event.toState,
          actualAt: event.actualAt,
          actualTimeKnown: event.actualTimeKnown,
          recordedAt: event.recordedAt,
          origin: event.origin,
          note: event.note,
        ),
      ),
    );
  }
  return const AdherenceCalculator().calculate(
    now: now,
    occurrences: occurrenceList,
    events: eventList,
  );
}

Map<String, dynamic>? decodeOccurrenceSnapshot(String json) =>
    _decodeSnapshot(json);

Map<String, dynamic>? _decodeSnapshot(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['version'] == 1) return decoded;
    return decodeScheduleSnapshot(decoded).toJson();
  } on Object {
    return null;
  }
}
