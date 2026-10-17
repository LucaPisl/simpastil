// Drift's check expressions intentionally reference the table's own column getters.
// The analyzer cannot distinguish that DSL pattern from recursive getter calls.
// ignore_for_file: recursive_getters

import 'package:drift/drift.dart';

import 'users_table.dart';

@DataClassName('MedicationOccurrence')
@TableIndex(
  name: 'medication_occurrences_user_planned_at',
  columns: {#userId, #plannedAt},
)
class MedicationOccurrences extends Table {
  TextColumn get id => text()();
  TextColumn get userId =>
      text().references(Users, #id, onDelete: KeyAction.cascade)();
  TextColumn get serverId => text().nullable().unique()();
  TextColumn get pillId => text().nullable()();
  TextColumn get scheduleId => text().nullable()();
  TextColumn get occurrenceKey => text()();
  TextColumn get source =>
      text().check(source.isIn(const ['scheduled', 'prn', 'legacy']))();
  IntColumn get scheduleRevision => integer().nullable()();
  TextColumn get plannedLocalDate => text()();
  TextColumn get plannedLocalTime => text().nullable()();
  TextColumn get timeZone => text()();
  DateTimeColumn get plannedAt => dateTime().nullable()();
  BoolColumn get expected => boolean()
      .withDefault(const Constant(false))
      .check(expected.equals(false) | source.isNotValue('prn'))();
  IntColumn get snapshotVersion => integer()
      .withDefault(const Constant(1))
      .check(snapshotVersion.isBiggerThanValue(0))();
  TextColumn get scheduleSnapshotJson => text()();
  TextColumn get provenance =>
      text().check(provenance.isIn(const ['exact', 'legacy_estimated']))();
  TextColumn get state => text()
      .withDefault(const Constant('pending'))
      .check(state.isIn(const ['pending', 'taken', 'skipped', 'missed']))();
  IntColumn get stateVersion => integer()
      .withDefault(const Constant(0))
      .check(stateVersion.isBiggerOrEqualValue(0))();
  IntColumn get serverSequence => integer().nullable()();
  DateTimeColumn get supersededAt => dateTime().nullable()();
  TextColumn get supersededByOccurrenceId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {userId, occurrenceKey},
  ];
}
