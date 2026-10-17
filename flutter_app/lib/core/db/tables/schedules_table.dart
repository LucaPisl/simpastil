import 'package:drift/drift.dart';

import 'pills_table.dart';

/// Mirrors the server `schedules` table.
///
/// [frequencyDays] stores ISO weekdays as a JSON-encoded integer list
/// (e.g. "[1,3,5]" for Mon/Wed/Fri). The server uses a native INTEGER[]
/// column; SQLite stores it as TEXT.
@DataClassName('Schedule')
class Schedules extends Table {
  @override
  String get tableName => 'schedules';

  TextColumn get id => text()();
  TextColumn get pillId =>
      text().references(Pills, #id, onDelete: KeyAction.cascade)();
  IntColumn get hour => integer()();
  IntColumn get minute => integer()();

  /// Allowed values: 'daily' | 'weekly' | 'custom' | 'prn'
  TextColumn get frequency => text()();

  /// Explicit reviewed server zone; upgrades do not infer a device zone.
  TextColumn get timeZone => text().nullable()();
  TextColumn get timeZoneStatus =>
      text().withDefault(const Constant('legacy_unknown'))();

  /// JSON-encoded list of ISO weekday integers [1=Mon … 7=Sun].
  /// NULL for 'daily' frequency. Required for 'weekly' and 'custom'.
  TextColumn get frequencyDays => text().nullable()();

  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  // ── Sync metadata ─────────────────────────────────────────────────────────
  TextColumn get serverId => text().nullable().unique()();
  IntColumn get revision => integer().withDefault(const Constant(1))();
  TextColumn get syncStatus => text().withDefault(const Constant('pending'))();
  IntColumn get lastSyncAt => integer().nullable()();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
