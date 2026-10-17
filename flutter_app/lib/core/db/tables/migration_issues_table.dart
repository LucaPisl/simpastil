// Drift's check expressions intentionally reference the table's own column getters.
// The analyzer cannot distinguish that DSL pattern from recursive getter calls.
// ignore_for_file: recursive_getters

import 'package:drift/drift.dart';

import 'users_table.dart';

@DataClassName('MigrationIssue')
@TableIndex(
  name: 'migration_issues_user_state_created',
  columns: {#userId, #resolutionState, #createdAt},
)
class MigrationIssues extends Table {
  TextColumn get id => text()();
  TextColumn get userId =>
      text().references(Users, #id, onDelete: KeyAction.cascade)();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get issueCode => text()();
  TextColumn get snapshotJson => text()();
  TextColumn get serverId => text().nullable()();
  IntColumn get revision => integer()
      .withDefault(const Constant(1))
      .check(revision.isBiggerThanValue(0))();
  TextColumn get resolutionState => text()
      .withDefault(const Constant('unresolved'))
      .check(resolutionState.isIn(const ['unresolved', 'resolved']))();
  TextColumn get resolvedByUserId => text().nullable()();
  DateTimeColumn get resolvedAt => dateTime().nullable().check(
    (resolvedAt.isNull() & resolutionState.equals('unresolved')) |
        (resolvedAt.isNotNull() & resolutionState.equals('resolved')),
  )();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
