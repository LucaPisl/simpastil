import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/account_settlement_merger.dart';
import 'package:uuid/uuid.dart';

void main() {
  late AppDatabase db;
  late AccountSettlementMerger merger;

  Future<void> record(String kind) => merger.recordReviewIssue(
    'u1',
    {'component': 'stable', 'entityType': 'pill', 'entityId': 'p1'},
    {'kind': kind},
  );

  Future<List<MigrationIssue>> notes() => db.select(db.migrationIssues).get();

  setUp(() {
    db = AppDatabase.forTesting();
    merger = AccountSettlementMerger(db);
  });
  tearDown(() => db.close());

  test(
    'a later item of a different kind for the same entity is recorded',
    () async {
      await record('identityMapping');
      await record('tombstone');
      expect((await notes()).map((n) => n.snapshotJson).toList(), hasLength(2));
    },
  );

  test(
    'replays are idempotent per kind and a dismissed note stays dismissed',
    () async {
      await record('identityMapping');
      final first = (await notes()).single;
      await (db.update(
        db.migrationIssues,
      )..where((i) => i.id.equals(first.id))).write(
        MigrationIssuesCompanion(
          resolutionState: const Value('resolved'),
          resolvedAt: Value(DateTime.utc(2026, 10, 1)),
          resolvedByUserId: const Value('u1'),
        ),
      );
      await record('identityMapping');
      await record('identityMapping');
      final all = await notes();
      expect(all, hasLength(1));
      expect(all.single.resolutionState, 'resolved');
    },
  );

  test('a note written under the old entity-only id still counts as the same '
      'item of that kind', () async {
    await record('identityMapping');
    final current = (await notes()).single;
    // Re-key the row to the pre-fix id shape.
    final legacyId = const Uuid().v5(
      Namespace.url.value,
      'simpastil:sync-review:u1:stable:pill:p1',
    );
    await db.customStatement(
      'UPDATE migration_issues SET id = ? WHERE id = ?',
      [legacyId, current.id],
    );
    await record('identityMapping');
    expect(await notes(), hasLength(1));
    await record('tombstone');
    expect(await notes(), hasLength(2));
  });
}
