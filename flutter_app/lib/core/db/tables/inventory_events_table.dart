// Drift's check expressions intentionally reference the table's own column getters.
// The analyzer cannot distinguish that DSL pattern from recursive getter calls.
// ignore_for_file: recursive_getters

import 'package:drift/drift.dart';

import 'users_table.dart';

@DataClassName('InventoryEvent')
@TableIndex(
  name: 'inventory_events_user_pill_recorded',
  columns: {#userId, #pillId, #recordedAt},
)
class InventoryEvents extends Table {
  TextColumn get id => text()();
  TextColumn get serverId => text().nullable().unique()();
  TextColumn get userId =>
      text().references(Users, #id, onDelete: KeyAction.cascade)();
  TextColumn get pillId => text()();
  TextColumn get commandId => text()();
  TextColumn get kind => text().check(
    kind.isIn(const [
      'opening',
      'dose',
      'dose_reversal',
      'refill',
      'correction',
    ]),
  )();
  IntColumn get delta =>
      integer().check(delta.isNotValue(0) | kind.equals('opening'))();
  TextColumn get occurrenceEventId => text().nullable()();
  TextColumn get reversesInventoryEventId => text().nullable()();
  TextColumn get origin => text().check(
    origin.isIn(const ['native', 'legacy_backfill', 'legacy_handoff']),
  )();
  TextColumn get provenanceJson => text().nullable()();
  IntColumn get serverSequence => integer().nullable()();
  DateTimeColumn get recordedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
