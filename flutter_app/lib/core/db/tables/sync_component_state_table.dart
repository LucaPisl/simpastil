// Drift's check expressions intentionally reference the table's own column getters.
// The analyzer cannot distinguish that DSL pattern from recursive getter calls.
// ignore_for_file: recursive_getters

import 'package:drift/drift.dart';

import 'users_table.dart';

@DataClassName('SyncComponentState')
class SyncComponentStates extends Table {
  TextColumn get userId =>
      text().references(Users, #id, onDelete: KeyAction.cascade)();
  TextColumn get component => text().check(
    component.isIn(const [
      'account',
      'accountSettings',
      'stable',
      'medicationBridge',
      'medication',
    ]),
  )();
  IntColumn get contractVersion =>
      integer().check(contractVersion.isIn(const [1, 2, 3, 4, 5]))();
  TextColumn get lastCompletedCursor => text().nullable()();
  DateTimeColumn get lastFullSuccessAt => dateTime().nullable()();
  TextColumn get currentState => text()
      .withDefault(const Constant('idle'))
      .check(
        currentState.isIn(const ['idle', 'running', 'partial', 'failed']),
      )();
  TextColumn get diagnosticMetadataJson => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {userId, component};
}
