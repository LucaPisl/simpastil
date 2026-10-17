// ignore_for_file: recursive_getters
import 'package:drift/drift.dart';

import 'schedules_table.dart';
import 'workspace_tables.dart';

/// Device choices stay in protected care storage and never enter sync queues.
class DeviceReminderSettings extends Table {
  TextColumn get workspaceId => text().references(CareWorkspaces, #id)();
  BoolColumn get fullDetails => boolean().withDefault(const Constant(true))();
  IntColumn get readinessEpoch => integer().withDefault(const Constant(1))();
  TextColumn get testJson => text().nullable()();
  @override
  Set<Column<Object>> get primaryKey => {workspaceId};
}

class DeviceScheduleReminders extends Table {
  TextColumn get workspaceId => text().references(CareWorkspaces, #id)();
  TextColumn get scheduleId => text().references(Schedules, #id)();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  TextColumn get followUpMinutesJson =>
      text().withDefault(const Constant('[]'))();
  @override
  Set<Column<Object>> get primaryKey => {workspaceId, scheduleId};
}
