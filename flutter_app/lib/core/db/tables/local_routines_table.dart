import 'package:drift/drift.dart';
import 'pills_table.dart';
import 'workspace_tables.dart';

/// Append-only reviewed definitions. Intervals end at the next revision boundary.
class LocalRoutines extends Table {
  TextColumn get routineId => text()();
  IntColumn get revision => integer()();
  TextColumn get workspaceId => text().references(CareWorkspaces, #id)();
  TextColumn get authorId => text()();
  TextColumn get pillId => text().references(Pills, #id)();
  IntColumn get effectiveFromMillis => integer()();
  TextColumn get definitionJson => text()();
  DateTimeColumn get createdAt => dateTime()();
  @override
  Set<Column<Object>> get primaryKey => {routineId, revision};
}
