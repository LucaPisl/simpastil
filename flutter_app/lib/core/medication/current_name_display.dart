import 'dart:convert';

import '../db/database.dart';

/// Display-only name resolution for occurrences.
///
/// A scheduled occurrence stores the medication name it was materialized with.
/// That stored snapshot is never rewritten. While a dose is still unrecorded
/// (`pending`) the user should see the medication's current name, so readers
/// substitute it at display time. Recorded doses keep the recorded name.
bool showsCurrentName(String occurrenceState) => occurrenceState == 'pending';

/// Returns [snapshotJson] with `pillName` replaced by [currentName], or the
/// input unchanged when the name already matches, [currentName] is blank, or
/// the JSON is not a snapshot object.
String snapshotJsonWithName(String snapshotJson, String? currentName) {
  if (currentName == null || currentName.trim().isEmpty) return snapshotJson;
  try {
    final decoded = jsonDecode(snapshotJson);
    if (decoded is! Map<String, dynamic> ||
        decoded['pillName'] == currentName) {
      return snapshotJson;
    }
    return jsonEncode({...decoded, 'pillName': currentName});
  } on FormatException {
    return snapshotJson;
  }
}

/// Pending occurrences with the current medication name in their in-memory
/// snapshot; every other occurrence is returned untouched. Nothing is stored.
MedicationOccurrence withCurrentName(
  MedicationOccurrence occurrence,
  Map<String, String> pillNamesById,
) {
  final pillId = occurrence.pillId;
  if (!showsCurrentName(occurrence.state) || pillId == null) return occurrence;
  final json = snapshotJsonWithName(
    occurrence.scheduleSnapshotJson,
    pillNamesById[pillId],
  );
  return identical(json, occurrence.scheduleSnapshotJson)
      ? occurrence
      : occurrence.copyWith(scheduleSnapshotJson: json);
}
