import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:timezone/timezone.dart' as tz;
import '../../core/medication/occurrence_materializer.dart';
import '../../core/db/database.dart';
import '../../core/errors/app_error.dart';
import '../../core/workspace/workspace_access_repository.dart';
import '../../core/workspace/workspace_context.dart';
import 'schedule_repository.dart';
import '../../core/sync/retired_schedule_review.dart';
import '../../core/sync/schedule_repair_intent.dart';

class LegacyRoutineReviewItem {
  const LegacyRoutineReviewItem({
    required this.schedule,
    required this.issue,
    required this.pillName,
    required this.personName,
    required this.frequencyDays,
    required this.nextDoseAt,
    this.rejectedOperation,
  });
  final PendingOperation? rejectedOperation;
  final Schedule schedule;
  final MigrationIssue issue;
  final String pillName;
  final String personName;
  final List<int>? frequencyDays;
  final DateTime? nextDoseAt;
}

class LegacyRoutineReviewPreview {
  LegacyRoutineReviewPreview._(
    this._origin, {
    required this.items,
    required this.timeZone,
    required this.effectiveFromLocalDate,
    required this.invalidCount,
    required this.unavailableCount,
  });
  final Object _origin;
  final List<LegacyRoutineReviewItem> items;
  final String timeZone;
  final DateTime effectiveFromLocalDate;
  final int invalidCount;
  final int unavailableCount;
  final _accepted = <String>{};
}

class LegacyRoutineReviewResult {
  const LegacyRoutineReviewResult({
    required this.acceptedCount,
    required this.totalCount,
    this.error,
  });
  final int acceptedCount;
  final int totalCount;
  final AppError? error;
  bool get isComplete => error == null && acceptedCount == totalCount;
}

class LegacyRoutineReviewRepository {
  LegacyRoutineReviewRepository({
    required this.database,
    required this.access,
    required this.context,
    required this.schedules,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final WorkspaceContext context;
  final ScheduleRepository schedules;
  final DateTime Function() _clock;
  Future<LegacyRoutineReviewPreview> preview({
    required String timeZone,
    required DateTime effectiveFromLocalDate,
  }) => access.withGrant(context, () async {
    if (context.isLocal) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.unresolvedOrigin,
      );
    }
    tz.getLocation(timeZone);
    final boundary = DateTime(
      effectiveFromLocalDate.year,
      effectiveFromLocalDate.month,
      effectiveFromLocalDate.day,
    );
    final selection = await _collect(timeZone, boundary);
    return LegacyRoutineReviewPreview._(
      this,
      items: List.unmodifiable(selection.items),
      timeZone: timeZone,
      effectiveFromLocalDate: boundary,
      invalidCount: selection.invalid,
      unavailableCount: selection.unavailable,
    );
  });

  Future<LegacyRoutineReviewResult> apply(
    LegacyRoutineReviewPreview review,
  ) async {
    if (!identical(review._origin, this)) {
      throw const WorkspaceAccessFailure(WorkspaceAccessFailureCode.staleGrant);
    }
    LegacyRoutineReviewResult result([AppError? error]) =>
        LegacyRoutineReviewResult(
          acceptedCount: review._accepted.length,
          totalCount: review.items.length,
          error: error,
        );
    final remaining = review.items
        .where((item) => !review._accepted.contains(item.issue.id))
        .toList();
    final unchanged = await access.withGrant(context, () async {
      final current = await _collect(
        review.timeZone,
        review.effectiveFromLocalDate,
      );
      final byIssue = {for (final item in current.items) item.issue.id: item};
      final operations = await database.pendingOperationsDao.getForUser(
        context.ownerUserId,
      );
      for (final item in remaining) {
        final frozen = await _matchingRepair(review, item, operations);
        if (frozen != null) {
          // The exact request was already approved before its first send.
          // State transitions and background acknowledgement are not new intent.
          if (frozen.state == 'committed') review._accepted.add(item.issue.id);
          continue;
        }
        final now = byIssue[item.issue.id];
        if (now == null ||
            now.schedule != item.schedule ||
            now.rejectedOperation != item.rejectedOperation ||
            now.issue != item.issue ||
            now.pillName != item.pillName ||
            now.personName != item.personName) {
          return false;
        }
      }
      return true;
    });
    if (!unchanged) return result(const ConflictError());
    for (final item in remaining) {
      if (review._accepted.contains(item.issue.id)) continue;
      // Revalidate authority before every request, including a retry after pull.
      await access.requireCurrent(context);
      final response = await schedules.repair(
        localId: item.schedule.id,
        issueId: item.issue.id,
        expectedIssueRevision: item.issue.revision,
        hour: item.schedule.hour,
        minute: item.schedule.minute,
        frequency: item.schedule.frequency,
        frequencyDays: item.frequencyDays,
        isActive: item.schedule.isActive,
        effectiveFromLocalDate: review.effectiveFromLocalDate,
        timeZone: review.timeZone,
      );
      if (response is Err<Schedule>) return result(response.error);
      review._accepted.add(item.issue.id);
    }
    return result();
  }

  Future<PendingOperation?> _matchingRepair(
    LegacyRoutineReviewPreview review,
    LegacyRoutineReviewItem item,
    List<PendingOperation> operations,
  ) async {
    final pill = await database.pillsDao.getById(item.schedule.pillId);
    final date = review.effectiveFromLocalDate.toIso8601String().substring(
      0,
      10,
    );
    for (final operation in operations) {
      final intent = ScheduleRepairIntent.fromOperation(operation);
      if (intent == null) continue;
      final payload = jsonDecode(operation.payloadJson) as Map;
      final envelope = payload['reviewedRepair'] as Map;
      if (payload['entityLocalId'] != item.schedule.id ||
          payload['parentEntityLocalId'] != item.schedule.pillId ||
          envelope['issueId'] != item.issue.id ||
          envelope['issueRevision'] != item.issue.revision ||
          intent.scheduleId != (item.schedule.serverId ?? item.schedule.id) ||
          intent.pillId != (pill?.serverId ?? pill?.id) ||
          intent.request['effectiveFromLocalDate'] != date) {
        continue;
      }
      if (const DeepCollectionEquality().equals(intent.request['schedule'], {
        'hour': item.schedule.hour,
        'minute': item.schedule.minute,
        'frequency': item.schedule.frequency,
        'frequencyDays': item.frequencyDays,
        'isActive': item.schedule.isActive,
        'timeZone': review.timeZone,
      })) {
        return operation;
      }
    }
    return null;
  }

  Future<({List<LegacyRoutineReviewItem> items, int invalid, int unavailable})>
  _collect(String zone, DateTime boundary) async {
    final issues = await database.migrationIssuesDao.getUnresolved(
      context.ownerUserId,
    );
    final items = <LegacyRoutineReviewItem>[];
    var invalid = 0;
    var unavailable = 0;
    // A routine still queued for the server may simply not have landed yet, so
    // absence only classifies a review once stable work has settled.
    final stableProjectionSettled =
        !(await database.pendingOperationsDao.getUnsettledForUser(
          context.ownerUserId,
        )).any((operation) => operation.component == 'stable');
    for (final issue in issues.where(
      (issue) => issue.issueCode == 'schedule_timezone_review_required',
    )) {
      if (await isRetiredScheduleReview(database, issue)) continue;
      // Counting a review this device cannot reach would send a person to an
      // individual review that has nothing to open.
      if (await isMissingScheduleReview(
        database,
        issue,
        stableProjectionSettled: stableProjectionSettled,
      )) {
        continue;
      }
      final schedule = await database.schedulesDao.getByMappedOrLocalId(
        issue.entityId,
      );
      if (issue.serverId != issue.id ||
          issue.revision != 1 ||
          !const {'schedule', 'schedules'}.contains(issue.entityType) ||
          schedule == null ||
          schedule.isDeleted) {
        unavailable++;
        continue;
      }
      final rawDays = schedule.frequencyDays;
      List<int>? days;
      try {
        if (rawDays != null) {
          days = (jsonDecode(rawDays) as List).cast<int>().toList();
        }
      } catch (_) {
        invalid++;
        continue;
      }
      final validDays =
          days != null &&
          days.isNotEmpty &&
          days.every((day) => day >= 1 && day <= 7) &&
          days.toSet().length == days.length;
      final valid = switch (schedule.frequency) {
        'daily' => rawDays == null,
        'weekly' => validDays && days.length == 1,
        'custom' => validDays,
        _ => false,
      };
      final quarantined = issues.any(
        (other) =>
            other.issueCode == 'invalid_schedule_frequency_days' &&
            (other.entityId == schedule.id ||
                other.entityId == schedule.serverId),
      );
      if (!valid ||
          quarantined ||
          schedule.hour < 0 ||
          schedule.hour > 23 ||
          schedule.minute < 0 ||
          schedule.minute > 59) {
        invalid++;
        continue;
      }
      final pill = await database.pillsDao.getById(schedule.pillId);
      final person = pill == null
          ? null
          : await database.profilesDao.getById(pill.profileId);
      final rejected = await rejectedScheduleUpdateForReview(
        database,
        schedule,
        context.ownerUserId,
      );
      if (schedule.revision != 1 ||
          (schedule.syncStatus != 'synced' && rejected == null) ||
          pill == null ||
          pill.isDeleted ||
          pill.syncStatus != 'synced' ||
          person == null ||
          person.isDeleted ||
          person.userId != context.ownerUserId ||
          (rejected == null &&
              await database.pendingOperationsDao.hasUncommittedEntity(
                userId: context.ownerUserId,
                component: 'stable',
                entityType: 'schedule',
                entityLocalId: schedule.id,
              ))) {
        unavailable++;
        continue;
      }
      DateTime? next;
      final location = tz.getLocation(zone);
      final now = tz.TZDateTime.from(_clock(), location);
      for (var offset = 0; schedule.isActive && offset < 8; offset++) {
        final date = DateTime.utc(
          boundary.year,
          boundary.month,
          boundary.day + offset,
        );
        if (schedule.frequency != 'daily' && !days!.contains(date.weekday)) {
          continue;
        }
        final instant = OccurrenceMaterializer.resolveReviewedLocalTime(
          localDate: date.toIso8601String().substring(0, 10),
          hour: schedule.hour,
          minute: schedule.minute,
          timeZone: zone,
        );
        if (!instant.isBefore(now)) {
          next = instant;
          break;
        }
      }
      items.add(
        LegacyRoutineReviewItem(
          schedule: schedule,
          rejectedOperation: rejected,
          issue: issue,
          pillName: pill.name,
          personName: person.name,
          frequencyDays: days == null ? null : List.unmodifiable(days),
          nextDoseAt: next,
        ),
      );
    }
    return (items: items, invalid: invalid, unavailable: unavailable);
  }
}
