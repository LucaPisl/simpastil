// Drift's check expressions intentionally reference the table's own column getters.
// The analyzer cannot distinguish that DSL pattern from recursive getter calls.
// ignore_for_file: recursive_getters

import 'package:drift/drift.dart';

import 'medication_occurrences_table.dart';
import 'users_table.dart';

@DataClassName('OccurrenceEvent')
@TableIndex(
  name: 'occurrence_events_user_occurrence_recorded',
  columns: {#userId, #occurrenceId, #recordedAt},
)
class OccurrenceEvents extends Table {
  TextColumn get id => text()();
  TextColumn get serverId => text().nullable().unique()();
  TextColumn get userId =>
      text().references(Users, #id, onDelete: KeyAction.cascade)();
  TextColumn get occurrenceId => text().references(
    MedicationOccurrences,
    #id,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get commandId => text()();
  TextColumn get action => text().check(
    action.isIn(const ['take', 'skip', 'undo', 'correct', 'miss']),
  )();
  TextColumn get fromState => text().check(
    fromState.isIn(const ['pending', 'taken', 'skipped', 'missed']),
  )();
  TextColumn get toState => text().check(
    toState.isIn(const ['pending', 'taken', 'skipped', 'missed']),
  )();
  TextColumn get reversesEventId => text().nullable()();
  TextColumn get rebasesCommandId => text().nullable()();
  DateTimeColumn get actualAt => dateTime().nullable()();
  BoolColumn get actualTimeKnown => boolean()
      .withDefault(const Constant(false))
      .check(actualTimeKnown.equals(false) | actualAt.isNotNull())();
  TextColumn get note => text().nullable()();

  /// Exact shared PRN amount, without inventing a local author attribution.
  TextColumn get administrationAmountJson => text().nullable()();
  TextColumn get origin => text().check(
    origin.isIn(const ['native', 'legacy_backfill', 'legacy_handoff']),
  )();
  IntColumn get baseVersion =>
      integer().check(baseVersion.isBiggerOrEqualValue(0))();
  IntColumn get resultVersion =>
      integer().check(resultVersion.isBiggerThan(baseVersion))();
  IntColumn get serverSequence => integer().nullable()();
  DateTimeColumn get recordedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {userId, commandId},
  ];
}
