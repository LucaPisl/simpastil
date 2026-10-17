// Drift checks intentionally refer to their own column getters.
// ignore_for_file: recursive_getters
import 'package:drift/drift.dart';

import 'workspace_tables.dart';

class ImportReceipts extends Table {
  TextColumn get id => text()();
  TextColumn get workspaceId => text().references(CareWorkspaces, #id)();
  TextColumn get sourceDigest => text()();
  TextColumn get sourceDocumentId => text()();
  DateTimeColumn get sourceCapturedAt => dateTime()();
  TextColumn get mode => text().check(mode.isIn(const ['selected', 'full']))();
  TextColumn get selectedProfileIdsJson => text()();
  TextColumn get identityMapJson => text()();
  DateTimeColumn get appliedAt => dateTime()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Exact incoming/current row bytes are chunked, so preserving a large original
/// row never creates an unexportable oversized JSON cell. No live queue cursor.
class ImportEvidence extends Table {
  TextColumn get receiptId => text().references(ImportReceipts, #id)();
  TextColumn get entityTable => text()();
  TextColumn get entityKey => text()();
  TextColumn get version =>
      text().check(version.isIn(const ['incoming', 'current']))();
  IntColumn get ordinal => integer().check(ordinal.isBiggerOrEqualValue(0))();
  TextColumn get sourceDigest => text()();
  TextColumn get payloadBase64 => text()();
  TextColumn get disposition => text().check(
    disposition.isIn(const [
      'imported',
      'identical',
      'conflict',
      'quarantined',
      'detachedHistory',
    ]),
  )();
  @override
  Set<Column<Object>> get primaryKey => {
    receiptId,
    entityTable,
    entityKey,
    version,
    ordinal,
  };
}

class ImportConflicts extends Table {
  TextColumn get id => text()();
  TextColumn get receiptId => text().references(ImportReceipts, #id)();
  TextColumn get workspaceId => text().references(CareWorkspaces, #id)();
  TextColumn get entityTable => text()();
  TextColumn get entityKey => text()();
  TextColumn get currentDigest => text()();
  TextColumn get incomingDigest => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get resolvedAt => dateTime().nullable()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Device-private intent; never portable authority or a public recovery path.
/// Care commit and preference completion are deliberately distinct facts.
class DeviceRestoreIntents extends Table {
  TextColumn get id => text()();
  TextColumn get receiptId => text().references(ImportReceipts, #id)();
  TextColumn get expectedPreferencesDigest => text()();
  TextColumn get operationsJson => text()();
  TextColumn get completedOperationsJson => text()();
  TextColumn get recoveryGeneration => text()();
  TextColumn get state =>
      text().check(state.isIn(const ['pending', 'conflict', 'completed']))();
  BoolColumn get projectionsCompleted =>
      boolean().withDefault(const Constant(false))();
  TextColumn get retiredProjectionsJson =>
      text().withDefault(const Constant('[]'))();
  DateTimeColumn get createdAt => dateTime()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}
