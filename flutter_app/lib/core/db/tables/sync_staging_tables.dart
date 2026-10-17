// Drift's check expressions intentionally reference the table's own column getters.
// The analyzer cannot distinguish that DSL pattern from recursive getter calls.
// ignore_for_file: recursive_getters

import 'package:drift/drift.dart';

import 'users_table.dart';

@DataClassName('SyncStagingRun')
@TableIndex(
  name: 'sync_staging_runs_user_component',
  columns: {#userId, #component},
)
class SyncStagingRuns extends Table {
  TextColumn get id => text()();
  TextColumn get userId =>
      text().references(Users, #id, onDelete: KeyAction.cascade)();
  TextColumn get component => text().check(
    component.isIn(const [
      'account',
      'stable',
      'medicationBridge',
      'medication',
    ]),
  )();
  IntColumn get contractVersion =>
      integer().check(contractVersion.isIn(const [1, 2, 3, 4, 5]))();
  TextColumn get afterSequence => text()();
  TextColumn get throughSequence => text()();
  TextColumn get nextCursor => text().nullable()();
  IntColumn get pageCount => integer()
      .withDefault(const Constant(0))
      .check(pageCount.isBiggerOrEqualValue(0))();
  BoolColumn get finalPageReceived =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get startedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('SyncStagingItem')
class SyncStagingItems extends Table {
  TextColumn get runId =>
      text().references(SyncStagingRuns, #id, onDelete: KeyAction.cascade)();
  IntColumn get serverSequence => integer()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get payloadJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {runId, serverSequence};
}
