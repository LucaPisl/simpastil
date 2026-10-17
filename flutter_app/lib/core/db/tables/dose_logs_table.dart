import 'package:drift/drift.dart';

import 'schedules_table.dart';

@DataClassName('DoseLog')
class DoseLogs extends Table {
  @override
  String get tableName => 'dose_logs';

  TextColumn get id => text()();
  TextColumn get scheduleId =>
      text().references(Schedules, #id, onDelete: KeyAction.cascade)();

  /// When the dose was supposed to be taken.
  DateTimeColumn get scheduledAt => dateTime()();

  /// When the dose was actually taken. NULL = not yet taken or missed.
  DateTimeColumn get takenAt => dateTime().nullable()();

  /// Allowed values: 'taken' | 'missed' | 'skipped'
  TextColumn get status => text()();

  TextColumn get note => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  // ── Sync metadata ─────────────────────────────────────────────────────────
  TextColumn get serverId => text().nullable().unique()();
  IntColumn get revision => integer().withDefault(const Constant(1))();
  TextColumn get syncStatus => text().withDefault(const Constant('pending'))();
  IntColumn get lastSyncAt => integer().nullable()();

  /// Soft-delete flag. DoseLogs are rarely deleted but the flag is kept
  /// consistent with other tables for a uniform sync strategy.
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
