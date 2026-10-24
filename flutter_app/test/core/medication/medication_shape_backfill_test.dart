import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_shape_backfill.dart';

const _ownerId = '20000000-0000-4000-8000-000000000801';
const _otherOwnerId = '20000000-0000-4000-8000-000000000802';
const _profileId = '20000000-0000-4000-8000-000000000803';
const _pillId = '20000000-0000-4000-8000-000000000804';
final _at = DateTime.utc(2026, 10, 17, 8);

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

  Future<void> medicine({
    String? shape = 'oval',
    String syncStatus = 'synced',
    int revision = 1,
  }) => db.pillsDao.upsert(
    PillsCompanion.insert(
      id: _pillId,
      profileId: _profileId,
      name: 'Fakeolol',
      dosage: const Value('10 mg'),
      createdAt: _at,
      updatedAt: _at,
      serverId: const Value(_pillId),
      revision: Value(revision),
      syncStatus: Value(syncStatus),
      shape: Value(shape),
    ),
  );

  Future<List<PendingOperation>> queue() =>
      db.pendingOperationsDao.getForUser(_ownerId);

  Future<void> run({bool medicationShapes = true}) => MedicationShapeBackfill(
    db: db,
  ).run(userId: _ownerId, medicationShapes: medicationShapes);

  test('a picked shape the account never received is queued', () async {
    await medicine();

    await run();

    final operation = (await queue()).single;
    expect(operation.operationType, 'pill.update');
    final payload = jsonDecode(operation.payloadJson) as Map;
    expect(payload['entityLocalId'], _pillId);
    final data = payload['data'] as Map<String, Object?>;
    expect(data['shape'], 'oval');
    expect(data['name'], 'Fakeolol');
    expect((await db.pillsDao.getById(_pillId))?.syncStatus, 'pending');
  });

  test('a medicine without a picked shape is left alone', () async {
    await medicine(shape: null);
    await run();
    expect(await queue(), isEmpty);
    expect((await db.pillsDao.getById(_pillId))?.syncStatus, 'synced');
  });

  test('a medicine carrying an unsent edit is left alone', () async {
    await medicine(syncStatus: 'pending');
    await run();
    expect(await queue(), isEmpty);
  });

  test('a medicine the account has never seen is left alone', () async {
    await medicine(syncStatus: 'local', revision: 0);
    await run();
    expect(await queue(), isEmpty);
  });

  test('a server that cannot keep shapes is not sent any', () async {
    await medicine();
    await run(medicationShapes: false);
    expect(await queue(), isEmpty);
  });

  test('the account is handed its shapes once, not on every sync', () async {
    await medicine();
    await run();
    await run();
    expect(await queue(), hasLength(1));
  });

  test('another account being caught up does not skip this one', () async {
    await medicine();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(
      MedicationShapeBackfill.preferenceKey(_otherOwnerId),
      true,
    );
    await run();
    expect(await queue(), hasLength(1));
  });
}
