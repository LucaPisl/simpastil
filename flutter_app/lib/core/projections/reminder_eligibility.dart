import 'dart:convert';

import '../db/database.dart';
import '../medication/local_occurrence_snapshot.dart';

/// Whether a pending scheduled dose still belongs to a live routine: its
/// medication and routine are both active and agree with each other, and the
/// frozen snapshot it was materialised from names the same owner, workspace,
/// person and time zone.
///
/// The reconciler plans reminders from the occurrences this accepts, and the
/// Reminders page lists the same ones, so both ask here instead of keeping two
/// copies of the rule.
///
/// [pillsById] holds the active scheduled (not as-needed) medications and
/// [schedulesById] their active routines. A snapshot that cannot be read is
/// never eligible. [workspaceId] is optional, as it is for [snapshotOwns].
bool isEligibleReminderOccurrence(
  MedicationOccurrence occurrence, {
  required Map<String, Pill> pillsById,
  required Map<String, Schedule> schedulesById,
  required String ownerId,
  String? workspaceId,
}) {
  final pill = pillsById[occurrence.pillId];
  final schedule = schedulesById[occurrence.scheduleId];
  if (pill == null || schedule == null || schedule.pillId != pill.id) {
    return false;
  }
  try {
    final snapshot = decodeScheduleSnapshot(
      jsonDecode(occurrence.scheduleSnapshotJson) as Map<String, dynamic>,
    );
    return snapshotOwns(snapshot, ownerId, workspaceId) &&
        snapshot.profileId == pill.profileId &&
        snapshot.timeZone == occurrence.timeZone;
  } on Object {
    return false;
  }
}
