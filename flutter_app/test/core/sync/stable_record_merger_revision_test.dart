import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/account_settlement_merger.dart';
import 'package:simpastil/core/sync/stable_record_merger.dart';

const _profile = '10000000-0000-4000-8000-000000000401';
const _pill = '10000000-0000-4000-8000-000000000402';
final _at = DateTime.utc(2026, 10, 12, 8);

Map<String, dynamic> _pillChange(String revision, String name) => {
  'id': _pill,
  'profileId': _profile,
  'revision': revision,
  'name': name,
  'dosage': null,
  'notes': null,
  'color': null,
  'currentStock': 3,
  'lowStockThreshold': null,
  'isPrn': false,
  'deletedAt': null,
  'createdAt': '2026-10-12T08:00:00.000Z',
  'updatedAt': '2026-10-13T08:00:00.000Z',
};

void main() {
  late AppDatabase db;
  late StableRecordMerger merger;

  setUp(() async {
    db = AppDatabase.forTesting();
    merger = StableRecordMerger(db, reviews: AccountSettlementMerger(db));
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: 'u1',
        email: 'u@example.com',
        createdAt: _at,
        updatedAt: _at,
      ),
    );
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _profile,
        userId: 'u1',
        name: 'P',
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_profile),
        syncStatus: const Value('synced'),
      ),
    );
  });
  tearDown(() async => db.close());

  Future<void> seedPill(int revision) => db.pillsDao.upsert(
    PillsCompanion.insert(
      id: _pill,
      profileId: _profile,
      name: 'Old',
      createdAt: _at,
      updatedAt: _at,
      serverId: const Value(_pill),
      revision: Value(revision),
      syncStatus: const Value('synced'),
    ),
  );

  test(
    'a replayed older stable change does not regress an adopted pill revision',
    () async {
      await seedPill(3);
      await merger.mergePill(_pillChange('2', 'Replayed'), {
        _profile: _profile,
      }, {});
      final pill = (await db.pillsDao.getById(_pill))!;
      expect(pill.revision, 3);
      expect(pill.name, 'Replayed');
      expect(pill.syncStatus, 'synced');
    },
  );

  test('a newer stable change still advances the revision', () async {
    await seedPill(3);
    await merger.mergePill(_pillChange('6', 'Newer'), {_profile: _profile}, {});
    expect((await db.pillsDao.getById(_pill))!.revision, 6);
  });
}
