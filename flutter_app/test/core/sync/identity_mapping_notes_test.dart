import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/account_settlement_merger.dart';

// Shape taken from a real activation (device pass 7b): one identity_mapping
// per bridge-era history row of a pill with a stock start plus two doses.
const _pillId = 'a4f5b2d9-22e0-4a9b-a06a-46fcb372197a';
const _historyId = '362ff03d-78fd-5586-8026-a2e3a2af859e';

Map<String, dynamic> _change(String historyId) => {
  'component': 'medication',
  'entityType': 'identity_mapping',
  'entityId': historyId,
  'operation': 'mapping',
};

Map<String, dynamic> _payload({
  String sourceKind = 'pill_stock',
  String sourceId = _pillId,
  String historyId = _historyId,
  String targetType = 'inventory_event',
  String targetId = 'e0a1c3a4-0000-4000-8000-000000000001',
}) => {
  'kind': 'identityMapping',
  'mappingRevision': 1,
  'legacySourceKind': sourceKind,
  'legacySourceId': sourceId,
  'historyId': historyId,
  'bridgeCommandId': null,
  'targetEntityType': targetType,
  'targetEntityId': targetId,
  'targetRevision': 1,
};

void main() {
  late AppDatabase db;
  late AccountSettlementMerger merger;

  Future<List<MigrationIssue>> notes() => db.select(db.migrationIssues).get();

  Future<void> addPill() => db
      .into(db.pills)
      .insert(
        PillsCompanion.insert(
          id: _pillId,
          profileId: 'prof',
          name: 'Test',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      );

  setUp(() {
    db = AppDatabase.forTesting();
    merger = AccountSettlementMerger(db);
  });
  tearDown(() => db.close());

  test('a mapping for a known legacy row is applied without a note', () async {
    await addPill();
    await merger.mergeIdentityMapping('u1', _change(_historyId), _payload());
    expect(await notes(), isEmpty);
  });

  test('a mapping nobody knows is kept as an unmapped note', () async {
    await merger.mergeIdentityMapping('u1', _change(_historyId), _payload());
    final n = (await notes()).single;
    expect(jsonDecode(n.snapshotJson)['unmapped'], isTrue);
  });

  test('applying a mapping resolves a note an older build wrote', () async {
    await merger.recordReviewIssue('u1', _change(_historyId), _payload());
    expect(await notes(), hasLength(1));
    await addPill();
    await merger.mergeIdentityMapping('u1', _change(_historyId), _payload());
    expect((await notes()).single.resolutionState, 'resolved');
  });

  test('cleanup resolves old mapping notes but keeps unmapped ones', () async {
    for (final h in [
      _historyId,
      'd56d916f-b943-5d27-a893-88afee6543fa',
      '44fc731a-59eb-532f-9912-c75bf52e71a1',
    ]) {
      await merger.recordReviewIssue('u1', _change(h), _payload(historyId: h));
    }
    await merger.mergeIdentityMapping(
      'u1',
      _change('keep-me'),
      _payload(historyId: 'keep-me'),
    );
    expect(await merger.clearAppliedMappingNotes('u1'), 3);
    final open = (await notes()).where((n) => n.resolutionState != 'resolved');
    expect(open, hasLength(1));
    expect(await merger.clearAppliedMappingNotes('u1'), 0);
  });
}
