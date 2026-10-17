// Drift's check expressions intentionally reference the table's own column getters.
// The analyzer cannot distinguish that DSL pattern from recursive getter calls.
// ignore_for_file: recursive_getters

import 'package:drift/drift.dart';

import 'users_table.dart';

@DataClassName('PendingOperation')
@TableIndex(
  name: 'pending_operations_user_state_created',
  columns: {#userId, #state, #createdAt},
)
class PendingOperations extends Table {
  TextColumn get id => text()();
  TextColumn get userId =>
      text().references(Users, #id, onDelete: KeyAction.cascade)();
  TextColumn get mutationId => text()();
  TextColumn get component => text().check(
    component.isIn(const [
      'account',
      'stable',
      'medicationBridge',
      'medication',
    ]),
  )();
  TextColumn get operationType => text()();
  IntColumn get contractVersion =>
      integer().check(contractVersion.isIn(const [1, 2]))();
  TextColumn get payloadJson => text()();
  TextColumn get dependsOnOperationId => text().nullable()();
  TextColumn get state => text()
      .withDefault(const Constant('queued'))
      .check(
        state.isIn(const [
          'queued',
          'sending',
          'conflict',
          'failedRetryable',
          'blocked',
          'committed',
          'discarded',
        ]),
      )();
  IntColumn get attemptCount => integer()
      .withDefault(const Constant(0))
      .check(attemptCount.isBiggerOrEqualValue(0))();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();
  TextColumn get safeErrorCode => text().nullable()();
  TextColumn get safeCorrelationId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {userId, mutationId},
  ];
}
