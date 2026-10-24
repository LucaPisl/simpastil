import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_extras_backfill.dart';

const _ownerId = '20000000-0000-4000-8000-000000000901';
const _profileId = '20000000-0000-4000-8000-000000000903';
const _pillId = '20000000-0000-4000-8000-000000000904';
const _plainId = '20000000-0000-4000-8000-000000000905';
final _at = DateTime.utc(2026, 10, 22, 8);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting();
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: _ownerId,
        email: 'fictional@example.com',
        createdAt: _at,
        updatedAt: _at,
      ),
    );
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _profileId,
        userId: _ownerId,
        name: 'Fictional person',
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_profileId),
        syncStatus: const Value('synced'),
      ),
    );
  });
  tearDown(() async => db.close());

  Future<void> medicine(
    String id, {
    String? expiresOn,
    String syncStatus = 'synced',
  }) => db.pillsDao.upsert(
    PillsCompanion.insert(
      id: id,
      profileId: _profileId,
      name: 'Fakeolol',
      createdAt: _at,
      updatedAt: _at,
      serverId: Value(id),
      revision: const Value(2),
      syncStatus: Value(syncStatus),
      expiresOn: Value(expiresOn),
      prescriberPhone: Value(expiresOn == null ? null : '+40 21 555 0100'),
    ),
  );

  Future<List<PendingOperation>> queue() =>
      db.pendingOperationsDao.getForUser(_ownerId);

  Future<void> run({bool capable = true}) => MedicationExtrasBackfill(
    db: db,
  ).run(userId: _ownerId, medicationDetailsExtra: capable);

  test('a medicine with extras is queued once, with every key', () async {
    await medicine(_pillId, expiresOn: '2027-01-01');
    await medicine(_plainId);

    await run();
    await run();

    final operation = (await queue()).single;
    expect(operation.operationType, 'pill.update');
    final data = (jsonDecode(operation.payloadJson) as Map)['data'] as Map;
    expect(data['expiresOn'], '2027-01-01');
    expect(data['prescriberPhone'], '+40 21 555 0100');
    expect(data.containsKey('prnMaxPer24h'), isTrue);
    expect((await db.pillsDao.getById(_pillId))?.syncStatus, 'pending');
  });

  test('nothing happens against a server without the contract', () async {
    await medicine(_pillId, expiresOn: '2027-01-01');
    await run(capable: false);
    expect(await queue(), isEmpty);

    await run();
    expect(await queue(), hasLength(1));
  });

  test('a medicine with its own unsent edit is left alone', () async {
    await medicine(_pillId, expiresOn: '2027-01-01', syncStatus: 'pending');
    await run();
    expect(await queue(), isEmpty);
  });
}
