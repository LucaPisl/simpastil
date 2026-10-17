import 'dart:convert';

import '../db/database.dart';
import 'schedule_review_target.dart';

/// Proves that a server-backed timezone review describes a retained,
/// synchronized schedule tombstone. This is display classification only; it
/// never resolves or deletes the original issue or schedule evidence.
Future<bool> isRetiredScheduleReview(
  AppDatabase db,
  MigrationIssue issue,
) async {
  if (issue.serverId != issue.id ||
      issue.resolutionState != 'unresolved' ||
      issue.revision != 1 ||
      !const {'schedule', 'schedules'}.contains(issue.entityType) ||
      issue.issueCode != 'schedule_timezone_review_required') {
    return false;
  }

  if (utf8.encode(issue.snapshotJson).length > 16 * 1024) return false;
  final Map<String, dynamic> snapshot;
  try {
    final decoded = jsonDecode(issue.snapshotJson);
    if (decoded is! Map<String, dynamic>) return false;
    snapshot = decoded;
  } on FormatException {
    return false;
  }

  final sourceRevision = snapshot['sourceScheduleRevision'];
  final deletedAt = snapshot['deletedAt'];
  final frequency = snapshot['frequency'];
  final frequencyDays = snapshot['frequencyDays'];
  if (snapshot['scheduleId'] != issue.entityId ||
      sourceRevision is! String ||
      !RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(sourceRevision) ||
      !const {'daily', 'weekly', 'custom', 'prn'}.contains(frequency) ||
      (frequencyDays != null && frequencyDays is! List) ||
      (frequencyDays is List && frequencyDays.any((day) => day is! int)) ||
      snapshot['isActive'] is! bool ||
      snapshot['timeZoneStatus'] != 'legacy_unknown' ||
      snapshot['timeZone'] != null ||
      deletedAt is! String ||
      !_isValidOffsetTimestamp(deletedAt)) {
    return false;
  }
  final bigRevision = BigInt.tryParse(sourceRevision);
  if (bigRevision == null || bigRevision > BigInt.from(9223372036854775807)) {
    return false;
  }
  final revision = bigRevision.toInt();

  final schedule = await db.schedulesDao.getByMappedOrLocalId(issue.entityId);
  if (schedule == null ||
      (schedule.id != issue.entityId && schedule.serverId != issue.entityId) ||
      schedule.serverId != issue.entityId ||
      schedule.revision != revision ||
      schedule.syncStatus != 'synced' ||
      !schedule.isDeleted) {
    return false;
  }

  final pill = await db.pillsDao.getById(schedule.pillId);
  final profile = pill == null
      ? null
      : await db.profilesDao.getById(pill.profileId);
  if (pill == null || profile == null || profile.userId != issue.userId) {
    return false;
  }

  final scheduleIds = {schedule.id, schedule.serverId, issue.entityId};
  for (final operation in await db.pendingOperationsDao.getUnsettledForUser(
    issue.userId,
  )) {
    if (operation.component != 'stable') continue;
    final scheduleOperation = operation.operationType.startsWith('schedule.');
    final Object? payload;
    try {
      payload = jsonDecode(operation.payloadJson);
    } on FormatException {
      // An unparseable schedule mutation cannot be proven unrelated.
      if (scheduleOperation) return false;
      continue;
    }
    if (payload is! Map) {
      if (scheduleOperation) return false;
      continue;
    }
    final entityType = payload['entityType'];
    final entityLocalId = payload['entityLocalId'];
    if ((const {'schedule', 'schedules'}.contains(entityType) &&
            scheduleIds.contains(entityLocalId)) ||
        (scheduleOperation && scheduleIds.contains(entityLocalId))) {
      return false;
    }
  }

  return true;
}

/// Proves that a server-backed timezone review points at a routine this device
/// can no longer reach, so it has nothing left to ask of a person. This is
/// display classification only; it never resolves or deletes the issue.
///
/// Absence only counts once the account's stable work has settled. While a
/// routine create, edit or delete is still queued the routine may simply not
/// have landed yet, and a review that is still answerable must stay visible.
Future<bool> isMissingScheduleReview(
  AppDatabase db,
  MigrationIssue issue, {
  required bool stableProjectionSettled,
}) async {
  if (!stableProjectionSettled ||
      issue.serverId != issue.id ||
      issue.resolutionState != 'unresolved' ||
      issue.revision != 1 ||
      !const {'schedule', 'schedules'}.contains(issue.entityType) ||
      issue.issueCode != 'schedule_timezone_review_required') {
    return false;
  }
  return await scheduleReviewTarget(db, issue.entityId, issue.userId) == null;
}

bool _isValidOffsetTimestamp(String value) {
  if (!RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
  ).hasMatch(value)) {
    return false;
  }
  return DateTime.tryParse(value) != null;
}
