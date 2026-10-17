import 'package:drift/drift.dart';
import 'pending_operation_effects_table.dart';
import 'workspace_tables.dart';

/// An authenticated review disposition, never a fabricated delivery receipt.
/// Original operations and effect states remain unchanged for audit.
class EffectSettlements extends Table {
  TextColumn get effectId => text().references(PendingOperationEffects, #id)();
  TextColumn get workspaceId => text().references(CareWorkspaces, #id)();
  TextColumn get userId => text()();
  TextColumn get issueId => text()();
  TextColumn get resolutionCommandId => text()();
  TextColumn get resolution => text()();
  TextColumn get disposition => text()();
  TextColumn get requestFingerprint => text()();
  DateTimeColumn get resolvedAt => dateTime()();
  @override
  Set<Column<Object>> get primaryKey => {effectId};
  @override
  List<Set<Column>> get uniqueKeys => [
    {workspaceId, issueId},
  ];
}
