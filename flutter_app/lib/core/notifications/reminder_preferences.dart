import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../db/database.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';

class ScheduleReminderChoice {
  ScheduleReminderChoice({
    this.enabled = true,
    List<int> followUpMinutes = const [],
  }) : followUpMinutes = List.unmodifiable(_checkedMinutes(followUpMinutes));
  final bool enabled;
  final List<int> followUpMinutes;
  static List<int> _checkedMinutes(List<int> minutes) {
    if (minutes.any((minute) => minute <= 0)) {
      throw ArgumentError('Follow-ups must be after the planned time');
    }
    return minutes.toSet().toList()..sort();
  }

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'followUpMinutes': followUpMinutes,
  };
}

class ReminderPreferences {
  ReminderPreferences({
    this.fullDetails = true,
    Map<String, ScheduleReminderChoice> schedules = const {},
  }) : schedules = Map.unmodifiable(schedules);
  final bool fullDetails;
  final Map<String, ScheduleReminderChoice> schedules;
  ScheduleReminderChoice choiceFor(String? scheduleId) =>
      schedules[scheduleId] ?? ScheduleReminderChoice();
  Map<String, Object> toJson() => {
    'fullDetails': fullDetails,
    'schedules': {
      for (final id in schedules.keys.toList()..sort())
        id: schedules[id]!.toJson(),
    },
  };
}

class ReminderPreferencesRepository {
  const ReminderPreferencesRepository({
    required this.database,
    required this.access,
    required this.context,
  });
  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final WorkspaceContext context;

  Future<ReminderPreferences> load() => access.withGrant(context, () async {
    final settings =
        await (database.select(database.deviceReminderSettings)
              ..where((row) => row.workspaceId.equals(context.workspaceId)))
            .getSingleOrNull();
    final rows = await (database.select(
      database.deviceScheduleReminders,
    )..where((row) => row.workspaceId.equals(context.workspaceId))).get();
    return ReminderPreferences(
      fullDetails: settings?.fullDetails ?? true,
      schedules: {
        for (final row in rows)
          row.scheduleId: ScheduleReminderChoice(
            enabled: row.enabled,
            followUpMinutes: List<int>.from(
              jsonDecode(row.followUpMinutesJson) as List,
            ),
          ),
      },
    );
  });

  Future<void> setFullDetails(
    bool fullDetails, {
    void Function()? requireInterfaceAccess,
  }) => access.withGrant(context, () async {
    requireInterfaceAccess?.call();
    await database
        .into(database.deviceReminderSettings)
        .insertOnConflictUpdate(
          DeviceReminderSettingsCompanion.insert(
            workspaceId: context.workspaceId,
            fullDetails: Value(fullDetails),
          ),
        );
  });

  Future<void> setSchedule(String scheduleId, ScheduleReminderChoice choice) =>
      access.withGrant(context, () async {
        final schedule = await database.schedulesDao.getById(scheduleId);
        final pill = schedule == null
            ? null
            : await database.pillsDao.getById(schedule.pillId);
        final person = pill == null
            ? null
            : await database.profilesDao.getById(pill.profileId);
        if (schedule == null ||
            schedule.isDeleted ||
            pill == null ||
            pill.isDeleted ||
            person == null ||
            person.isDeleted ||
            person.userId != context.ownerUserId) {
          throw const WorkspaceAccessFailure(
            WorkspaceAccessFailureCode.wrongPerson,
          );
        }
        await database
            .into(database.deviceScheduleReminders)
            .insertOnConflictUpdate(
              DeviceScheduleRemindersCompanion.insert(
                workspaceId: context.workspaceId,
                scheduleId: scheduleId,
                enabled: Value(choice.enabled),
                followUpMinutesJson: Value(jsonEncode(choice.followUpMinutes)),
              ),
            );
      });
}
