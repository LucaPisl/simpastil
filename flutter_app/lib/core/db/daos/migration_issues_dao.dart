import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/migration_issues_table.dart';

part 'migration_issues_dao.g.dart';

@DriftAccessor(tables: [MigrationIssues])
class MigrationIssuesDao extends DatabaseAccessor<AppDatabase>
    with _$MigrationIssuesDaoMixin {
  MigrationIssuesDao(super.db);

  Future<List<MigrationIssue>> getUnresolved(String userId) =>
      (select(migrationIssues)
            ..where(
              (row) =>
                  row.userId.equals(userId) &
                  row.resolutionState.equals('unresolved'),
            )
            ..orderBy([
              (row) => OrderingTerm.asc(row.createdAt),
              (row) => OrderingTerm.asc(row.id),
            ]))
          .get();

  Stream<List<MigrationIssue>> watchUnresolved(String userId) =>
      (select(migrationIssues)
            ..where(
              (row) =>
                  row.userId.equals(userId) &
                  row.resolutionState.equals('unresolved'),
            )
            ..orderBy([
              (row) => OrderingTerm.asc(row.createdAt),
              (row) => OrderingTerm.asc(row.id),
            ]))
          .watch();

  Future<MigrationIssue?> getById(String id) => (select(
    migrationIssues,
  )..where((row) => row.id.equals(id))).getSingleOrNull();

  Future<void> record(MigrationIssuesCompanion issue) =>
      into(migrationIssues).insert(issue);

  /// Closes review issues whose cause a person has dealt with (for example
  /// by retrying or dismissing the change they describe). The evidence rows
  /// stay; only their resolution state changes.
  Future<int> markResolved(
    Iterable<String> ids, {
    required String resolvedByUserId,
    required DateTime at,
  }) async {
    final list = ids.toList();
    if (list.isEmpty) return 0;
    return (update(migrationIssues)..where(
          (row) => row.id.isIn(list) & row.resolutionState.equals('unresolved'),
        ))
        .write(
          MigrationIssuesCompanion(
            resolutionState: const Value('resolved'),
            resolvedByUserId: Value(resolvedByUserId),
            resolvedAt: Value(at),
            updatedAt: Value(at),
          ),
        );
  }
}
