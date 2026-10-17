import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/features/pills/pill_repository.dart';
import 'package:simpastil/features/profiles/profile_repository.dart';

import '../../helpers/protected_workspace_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'a local person can save a name-only medication without a routine or network queue',
    () async {
      final fixture = await ProtectedWorkspaceFixture.create();
      addTearDown(fixture.db.close);
      final pending = PendingOperationRepository(
        fixture.db,
        access: fixture.access,
        context: fixture.context,
      );
      final people = ProfileRepositoryImpl(
        dao: fixture.db.profilesDao,
        pendingOperations: pending,
        userId: fixture.context.ownerUserId,
        access: fixture.access,
        context: fixture.context,
        reconcileProjections: () async {},
      );
      final person =
          (await people.create('Fictional Alex', 'A') as Ok<Profile>).value;
      final medication = PillRepositoryImpl(
        db: fixture.db,
        dao: fixture.db.pillsDao,
        profilesDao: fixture.db.profilesDao,
        schedulesDao: fixture.db.schedulesDao,
        pendingOperations: pending,
        reconcileProjections: () async =>
            throw StateError('Optional reminders unavailable'),
      );
      final result = await medication.create(
        profileId: person.id,
        name: 'Fictional medicine',
      );
      expect(result, isA<Ok<Pill>>());
      final pill = (result as Ok<Pill>).value;
      expect(pill.profileId, person.id);
      expect(pill.dosage, isNull);
      expect(pill.currentStock, isNull);
      expect(pill.syncStatus, 'local');
      expect(await fixture.db.schedulesDao.getByPillId(pill.id), isEmpty);
      expect(
        await fixture.db.pendingOperationsDao.getForUser(
          fixture.context.ownerUserId,
        ),
        isEmpty,
      );
      expect(await fixture.access.currentNetworkCapability(), isNull);
    },
  );
}
