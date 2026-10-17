// Drift's check expressions intentionally reference the table's own column getters.
// The analyzer cannot distinguish that DSL pattern from recursive getter calls.
// ignore_for_file: recursive_getters

import 'package:drift/drift.dart';

import 'pending_operations_table.dart';

@DataClassName('PendingOperationEffect')
class PendingOperationEffects extends Table {
  TextColumn get id => text()();
  TextColumn get operationId =>
      text().references(PendingOperations, #id, onDelete: KeyAction.cascade)();
  IntColumn get ordinal => integer().check(ordinal.isBiggerOrEqualValue(0))();
  TextColumn get kind => text().check(kind.isIn(const ['dose', 'inventory']))();
  TextColumn get legacySourceId => text().nullable()();
  TextColumn get requestFingerprint => text()();
  TextColumn get state => text()
      .withDefault(const Constant('queued'))
      .check(
        state.isIn(const ['queued', 'sending', 'acknowledged', 'uncertain']),
      )();
  TextColumn get safeServerId => text().nullable().withLength(max: 128)();
  TextColumn get safeResultFingerprint =>
      text().nullable().withLength(max: 512)();
  DateTimeColumn get attemptedAt => dateTime().nullable().check(
    attemptedAt.isNotNull() | state.equals('queued'),
  )();
  DateTimeColumn get acknowledgedAt => dateTime().nullable().check(
    acknowledgedAt.isNotNull() | state.isNotValue('acknowledged'),
  )();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {operationId, ordinal},
  ];
}
