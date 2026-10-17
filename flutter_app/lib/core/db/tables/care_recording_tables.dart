import 'package:drift/drift.dart';
import 'occurrence_events_table.dart';
import 'pills_table.dart';
import 'workspace_tables.dart';

/// Append-only additional facts for newly authored care. Historical attribution is not guessed.
class CareEventDetails extends Table {
  TextColumn get eventId => text().references(OccurrenceEvents, #id)();
  TextColumn get workspaceId => text().references(CareWorkspaces, #id)();
  TextColumn get commandId => text()();
  TextColumn get authorId => text().references(WorkspaceAuthors, #id)();
  TextColumn get authorName => text().nullable()();
  TextColumn get amountJson => text()();
  TextColumn get commandJson => text()();
  TextColumn get requestFingerprint => text()();
  TextColumn get localReversalEventId => text().nullable()();
  TextColumn get stockOutcome => text()();
  TextColumn get stockEffectJson => text().nullable()();
  @override
  Set<Column<Object>> get primaryKey => {eventId};
  @override
  List<Set<Column>> get uniqueKeys => [
    {workspaceId, commandId},
  ];
}

/// Optional physical stock reviewed independently of the preserved legacy count.
class ReviewedStockBalances extends Table {
  TextColumn get workspaceId => text().references(CareWorkspaces, #id)();
  TextColumn get pillId => text().references(Pills, #id)();
  TextColumn get authorId => text().references(WorkspaceAuthors, #id)();
  TextColumn get quantityJson => text()();
  IntColumn get reviewRevision => integer()();
  IntColumn get revision => integer()();
  DateTimeColumn get updatedAt => dateTime()();
  @override
  Set<Column<Object>> get primaryKey => {workspaceId, pillId};
}
