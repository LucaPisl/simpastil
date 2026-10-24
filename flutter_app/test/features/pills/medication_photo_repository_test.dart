import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_photo_processor.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/features/pills/medication_photo_repository.dart';

const _owner = '10000000-0000-4000-8000-000000000901';
const _otherOwner = '10000000-0000-4000-8000-000000000909';
const _profile = '10000000-0000-4000-8000-000000000902';
const _pill = '10000000-0000-4000-8000-000000000903';
final _at = DateTime.utc(2026, 10, 23, 8);

ProcessedMedicationPhoto _photo(int seed) => ProcessedMedicationPhoto(
  bytes: Uint8List.fromList([0xFF, 0xD8, seed, 0xFF, 0xD9]),
  sha256: '$seed' * 64,
  width: 1,
  height: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late MedicationPhotoRepository repository;

  Future<void> pill({String? serverId}) async {
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: _pill,
        profileId: _profile,
        name: 'Fakeolol',
        createdAt: _at,
        updatedAt: _at,
        serverId: Value(serverId),
        syncStatus: const Value('synced'),
      ),
    );
  }

  Future<MedicationPhoto?> row() => (db.select(
    db.medicationPhotos,
  )..where((t) => t.pillId.equals(_pill))).getSingleOrNull();

  setUp(() async {
    db = AppDatabase.forTesting();
    for (final id in [_owner, _otherOwner]) {
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: id,
          email: '$id@example.com',
          createdAt: _at,
          updatedAt: _at,
        ),
      );
    }
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _profile,
        userId: _owner,
        name: 'P',
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_profile),
        syncStatus: const Value('synced'),
      ),
    );
    repository = MedicationPhotoRepository(
      db: db,
      pendingOperations: PendingOperationRepository(db),
    );
  });
  tearDown(() async => db.close());

  test('saving stores the photo for the next sync to send', () async {
    await pill(serverId: _pill);
    await repository.save(_pill, _photo(1));
    final stored = (await row())!;
    expect(stored.syncStatus, 'pending');
    expect(base64Decode(stored.bytesBase64), _photo(1).bytes);
    expect(MedicationPhotoRepository.view(stored)!.bytes, _photo(1).bytes);
  });

  test(
    'replacing keeps the account revision and chooses the new photo',
    () async {
      await pill(serverId: _pill);
      await repository.save(_pill, _photo(1));
      await (db.update(db.medicationPhotos)).write(
        const MedicationPhotosCompanion(
          syncStatus: Value('synced'),
          revision: Value(4),
        ),
      );
      await repository.save(_pill, _photo(2));
      final stored = (await row())!;
      expect(stored.syncStatus, 'pending');
      expect(stored.revision, 4);
      expect(stored.sha256, _photo(2).sha256);
    },
  );

  test('choosing the same photo again changes nothing', () async {
    await pill(serverId: _pill);
    await repository.save(_pill, _photo(1));
    await (db.update(
      db.medicationPhotos,
    )).write(const MedicationPhotosCompanion(syncStatus: Value('synced')));
    await repository.save(_pill, _photo(1));
    expect((await row())!.syncStatus, 'synced');
  });

  test('removing a photo the account holds marks it for deletion', () async {
    await pill(serverId: _pill);
    await repository.save(_pill, _photo(1));
    await (db.update(db.medicationPhotos)).write(
      const MedicationPhotosCompanion(
        syncStatus: Value('synced'),
        revision: Value(2),
      ),
    );
    await repository.remove(_pill);
    final stored = (await row())!;
    expect(stored.syncStatus, 'removing');
    expect(MedicationPhotoRepository.view(stored), isNull);
  });

  test('removing a photo the account never saw just drops it', () async {
    await pill();
    await repository.save(_pill, _photo(1));
    await repository.remove(_pill);
    expect(await row(), isNull);
  });

  test('deleting the medicine takes its photo with it', () async {
    await pill(serverId: _pill);
    await repository.save(_pill, _photo(1));
    // The protected database runs with foreign keys enforced.
    await db.customStatement('PRAGMA foreign_keys = ON');
    await (db.delete(db.pills)..where((p) => p.id.equals(_pill))).go();
    expect(await row(), isNull);
  });

  test('another account\'s care cannot be changed', () async {
    await pill(serverId: _pill);
    final repo = MedicationPhotoRepository(
      db: db,
      pendingOperations: _OtherOwner(db),
    );
    await expectLater(
      repo.save(_pill, _photo(1)),
      throwsA(isA<WorkspaceAccessFailure>()),
    );
    expect(await row(), isNull);
  });
}

class _OtherOwner extends PendingOperationRepository {
  _OtherOwner(super.db);
  @override
  void requireCareOwner(String ownerId) => throw const WorkspaceAccessFailure(
    WorkspaceAccessFailureCode.wrongPerson,
  );
}
