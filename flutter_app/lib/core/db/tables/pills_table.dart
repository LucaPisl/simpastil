import 'package:drift/drift.dart';

import 'profiles_table.dart';

@DataClassName('Pill')
class Pills extends Table {
  @override
  String get tableName => 'pills';

  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(Profiles, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  TextColumn get dosage => text().nullable()(); // e.g. "10mg"
  TextColumn get notes => text().nullable()();
  TextColumn get color => text().nullable()(); // hex e.g. "#FF5733"
  IntColumn get currentStock => integer().nullable()();
  IntColumn get lowStockThreshold => integer().nullable()();
  BoolColumn get isPrn => boolean().withDefault(const Constant(false))();
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
