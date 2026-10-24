import 'dart:convert';

import '../db/database.dart';
import '../medication/schedule_window.dart';

/// A reviewed, revisioned request whose exact bytes can survive response loss.
/// This exception never makes ordinary stable or medication mutations replayable.
class ScheduleRepairIntent {
  const ScheduleRepairIntent._(this.pillId, this.scheduleId, this.request);
  final String pillId;
  final String scheduleId;
  final Map<String, dynamic> request;
  String get path => '/pills/$pillId/schedules/$scheduleId/repair';

  static ScheduleRepairIntent? fromOperation(PendingOperation operation) {
    if (operation.component != 'stable' ||
        operation.contractVersion != 2 ||
        operation.operationType != 'schedule.repair') {
      return null;
    }
    try {
      final payload = jsonDecode(operation.payloadJson);
      if (payload is! Map ||
          payload['entityType'] != 'schedule' ||
          payload['action'] != 'repair' ||
          payload['parentEntityType'] != 'pill') {
        return null;
      }
      final repair = payload['reviewedRepair'];
      if (repair is! Map || repair['version'] != 1) return null;
      final pillId = repair['pillServerId'];
      final scheduleId = repair['scheduleServerId'];
      final request = repair['request'];
      if (!_uuid(pillId) ||
          !_uuid(scheduleId) ||
          !_uuid(repair['issueId']) ||
          repair['issueRevision'] != 1 ||
          request is! Map<String, dynamic> ||
          request['mutationId'] != operation.mutationId ||
          !_uuid(operation.mutationId) ||
          request['baseRevision'] != '1' ||
          request['effectiveFromLocalDate'] is! String ||
          !RegExp(
            r'^\d{4}-\d{2}-\d{2}$',
          ).hasMatch(request['effectiveFromLocalDate'] as String) ||
          !validDocument(request['schedule'])) {
        return null;
      }
      return ScheduleRepairIntent._(
        pillId as String,
        scheduleId as String,
        request,
      );
    } on FormatException {
      return null;
    }
  }

  static bool _uuid(Object? value) =>
      value is String &&
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        caseSensitive: false,
      ).hasMatch(value);

  static bool validDocument(Object? value) {
    if (value is! Map ||
        value['hour'] is! int ||
        value['minute'] is! int ||
        (value['hour'] as int) < 0 ||
        (value['hour'] as int) > 23 ||
        (value['minute'] as int) < 0 ||
        (value['minute'] as int) > 59 ||
        value['isActive'] is! bool ||
        value['timeZone'] is! String ||
        (value['timeZone'] as String).isEmpty ||
        (value['timeZone'] as String).length > 128) {
      return false;
    }
    final days = value['frequencyDays'];
    final frequency = value['frequency'];
    final ScheduleWindow window;
    try {
      window = ScheduleWindow.fromJson(value);
    } on TypeError {
      return false;
    }
    if (frequency is! String || !window.isValidFor(frequency)) return false;
    if (frequency == 'interval') return days == null;
    if (value['frequency'] == 'daily' || value['frequency'] == 'prn') {
      return days == null;
    }
    if (!const {'weekly', 'custom'}.contains(value['frequency']) ||
        days is! List ||
        days.isEmpty ||
        days.any((d) => d is! int || d < 1 || d > 7) ||
        days.toSet().length != days.length) {
      return false;
    }
    return value['frequency'] != 'weekly' || days.length == 1;
  }

  bool matchesReceipt(Object? value) {
    if (value is! Map ||
        value['id'] != scheduleId ||
        value['pillId'] != pillId ||
        value['revision'] != '2' ||
        value['deletedAt'] != null ||
        value['timeZoneStatus'] != 'known' ||
        value['materializeFromLocalDate'] !=
            request['effectiveFromLocalDate']) {
      return false;
    }
    final document = request['schedule'] as Map;
    return [
      'hour',
      'minute',
      'frequency',
      'frequencyDays',
      'isActive',
      'timeZone',
      // The interval and window fields are compared only when the reviewed
      // document carries them; an ordinary repair keeps its exact old check.
      for (final key in const [
        'everyDays',
        'anchorDate',
        'startDate',
        'endDate',
      ])
        if (document.containsKey(key)) key,
    ].every((key) => jsonEncode(value[key]) == jsonEncode(document[key]));
  }
}

/// Only a definitively rejected, still-current edit can become a repair.
/// A second edit, unknown delivery or a mismatching projection stays fenced.
Future<PendingOperation?> rejectedScheduleUpdateForReview(
  AppDatabase db,
  Schedule schedule,
  String ownerId,
) async {
  final target = <PendingOperation>[];
  for (final operation in await db.pendingOperationsDao.getForUser(ownerId)) {
    if (operation.state == 'committed' || operation.state == 'discarded') {
      continue;
    }
    try {
      final payload = jsonDecode(operation.payloadJson);
      if (payload is Map &&
          payload['entityType'] == 'schedule' &&
          payload['entityLocalId'] == schedule.id) {
        target.add(operation);
      }
    } on FormatException {
      /* Malformed evidence cannot qualify. */
    }
  }
  if (target.length != 1) return null;
  final operation = target.single;
  if (operation.component != 'stable' ||
      operation.contractVersion != 2 ||
      operation.operationType != 'schedule.update' ||
      operation.state != 'conflict' ||
      operation.safeErrorCode != 'SCHEDULE_TIMEZONE_REVIEW_REQUIRED' ||
      (await db.pendingOperationsDao.getEffects(operation.id)).isNotEmpty) {
    return null;
  }
  final payload = jsonDecode(operation.payloadJson) as Map;
  final data = payload['data'];
  if (payload['action'] != 'update' ||
      payload['parentEntityType'] != 'pill' ||
      payload['parentEntityLocalId'] != schedule.pillId ||
      data is! Map ||
      data.keys.any(
        (k) => !const {
          'hour',
          'minute',
          'frequency',
          'frequencyDays',
          'isActive',
          'timeZone',
        }.contains(k),
      )) {
    return null;
  }
  final current = <String, Object?>{
    'hour': schedule.hour,
    'minute': schedule.minute,
    'frequency': schedule.frequency,
    'frequencyDays': schedule.frequencyDays == null
        ? null
        : jsonDecode(schedule.frequencyDays!),
    'isActive': schedule.isActive,
  };
  if (!current.keys.every(
    (key) => jsonEncode(data[key]) == jsonEncode(current[key]),
  )) {
    return null;
  }
  return operation;
}
