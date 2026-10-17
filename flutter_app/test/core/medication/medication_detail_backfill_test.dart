import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_detail_backfill.dart';

const _ownerId = '20000000-0000-4000-8000-000000000701';
const _otherOwnerId = '20000000-0000-4000-8000-000000000702';
const _profileId = '20000000-0000-4000-8000-000000000703';
const _pillId = '20000000-0000-4000-8000-000000000704';
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

  /// A medicine the account already knows, plus the reviewed details this
  /// device holds for it.
  Future<void> medicine({
    String id = _pillId,
    String syncStatus = 'synced',
    int revision = 1,
    String? packageStrength = '20 mg',
    String? form,
    MedicationAmount amount = const MedicationAmount.unknown(),
    bool legacyDosageReviewed = false,
  }) async {
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: id,
        profileId: _profileId,
        name: 'Fakeolol',
        dosage: const Value('10 mg'),
        createdAt: _at,
        updatedAt: _at,
        serverId: Value(id),
        revision: Value(revision),
        syncStatus: Value(syncStatus),
      ),
    );
    await db
        .into(db.medicationDetails)
        .insert(
          MedicationDetailsCompanion.insert(
            pillId: id,
            packageStrength: Value(packageStrength),
            form: Value(form),
            amountJson: jsonEncode(amount.toJson()),
            legacyDosageReviewed: Value(legacyDosageReviewed),
          ),
        );
  }

  Future<List<PendingOperation>> queue() =>
      db.pendingOperationsDao.getForUser(_ownerId);

  Future<void> run({bool medicationDetails = true, String? userId}) =>
      MedicationDetailBackfill(
        db: db,
      ).run(userId: userId ?? _ownerId, medicationDetails: medicationDetails);

  test('a review the account never received is queued and left unsent', () async {
    await medicine(
      packageStrength: '20 mg',
      form: 'tablet',
      amount: MedicationAmount.known('2', 'tablet'),
      legacyDosageReviewed: true,
    );

    await run();

    final operation = (await queue()).single;
    expect(operation.operationType, 'pill.update');
    final payload = jsonDecode(operation.payloadJson) as Map;
    expect(payload['entityLocalId'], _pillId);
    expect(payload['parentEntityLocalId'], _profileId);
    final data = payload['data'] as Map<String, Object?>;
    expect(data['packageStrength'], '20 mg');
    expect(data['form'], 'tablet');
    expect(data['legacyDosageReviewed'], true);
    expect((data['amountPerUse'] as Map)['quantity'], '2');
    // The medicine's own fields travel with it, because the server replaces the
    // whole medicine on an update.
    expect(data['name'], 'Fakeolol');
    expect(data['dosage'], '10 mg');
    // Pending is what stops a pull arriving before the flush from answering
    // with the account's own empty details.
    expect((await db.pillsDao.getById(_pillId))?.syncStatus, 'pending');
  });

  test('a medicine with nothing reviewed is left alone', () async {
    await medicine(packageStrength: null);

    await run();

    expect(await queue(), isEmpty);
    expect((await db.pillsDao.getById(_pillId))?.syncStatus, 'synced');
  });

  test('a medicine already carrying an unsent edit is left alone', () async {
    await medicine(syncStatus: 'pending');

    await run();

    expect(await queue(), isEmpty);
  });

  test('a medicine the account has never seen is left alone', () async {
    await medicine(syncStatus: 'local', revision: 0);

    await run();

    expect(await queue(), isEmpty);
  });

  test('a server that cannot keep the details is not sent any', () async {
    await medicine();

    await run(medicationDetails: false);

    expect(await queue(), isEmpty);
    expect((await db.pillsDao.getById(_pillId))?.syncStatus, 'synced');
  });

  test('the account is handed its details once, not on every sync', () async {
    await medicine();

    await run();
    await run();

    expect(await queue(), hasLength(1));
  });

  test('one account being caught up does not skip another', () async {
    await medicine();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(
      MedicationDetailBackfill.preferenceKey(_otherOwnerId),
      true,
    );

    await run();

    expect(await queue(), hasLength(1));
  });
}
