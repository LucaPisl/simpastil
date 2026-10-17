import 'package:drift/drift.dart';

import 'pills_table.dart';
import 'profiles_table.dart';
import 'workspace_tables.dart';

class MedicationDetails extends Table {
  TextColumn get pillId => text().references(Pills, #id)();
  TextColumn get packageStrength => text().nullable()();
  TextColumn get form => text().nullable()();
  TextColumn get amountJson => text()();
  BoolColumn get legacyDosageReviewed =>
      boolean().withDefault(const Constant(false))();
  @override
  Set<Column<Object>> get primaryKey => {pillId};
}

class SetupDrafts extends Table {
  TextColumn get id => text()();
  TextColumn get workspaceId => text().references(CareWorkspaces, #id)();
  TextColumn get authorId => text()();
  TextColumn get purpose => text()();
  TextColumn get step => text()();
  TextColumn get profileId => text().nullable().references(Profiles, #id)();
  TextColumn get medicationId => text().nullable().references(Pills, #id)();
  TextColumn get payloadJson => text()();
  IntColumn get revision => integer().withDefault(const Constant(1))();
  DateTimeColumn get updatedAt => dateTime()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}
