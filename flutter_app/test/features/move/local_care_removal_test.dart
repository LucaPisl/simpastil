import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/features/move/local_care_removal.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test(
    'removes a moved person with their care and keeps everyone else',
    () async {
      final fixture = await CareRecordingFixture.create();
      addTearDown(fixture.db.close);
      final db = fixture.db;
      final context = fixture.workspace.context;
      await fixture.recordMiss();
      final now = DateTime.utc(2026, 10, 22);
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: 'stays',
          userId: context.ownerUserId,
          name: 'Fictional Sam',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.pillsDao.upsert(
        PillsCompanion.insert(
          id: 'stays-pill',
          profileId: 'stays',
          name: 'Fictional kept medication',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await (db.update(
        db.careWorkspaces,
      )..where((w) => w.id.equals(context.workspaceId))).write(
        CareWorkspacesCompanion(selectedProfileId: Value(fixture.person.id)),
      );
      expect(await db.select(db.occurrenceEvents).get(), isNotEmpty);
      expect(await db.select(db.localRoutines).get(), isNotEmpty);

      await removeLocalCare(
        db,
        localWorkspaceId: context.workspaceId,
        localOwnerId: context.ownerUserId,
        profileIds: {fixture.person.id, 'not-on-this-phone'},
      );

      expect((await db.select(db.profiles).get()).map((p) => p.id), ['stays']);
      expect((await db.select(db.pills).get()).map((p) => p.id), [
        'stays-pill',
      ]);
      expect(await db.select(db.medicationOccurrences).get(), isEmpty);
      expect(await db.select(db.occurrenceEvents).get(), isEmpty);
      expect(await db.select(db.localRoutines).get(), isEmpty);
      final workspace = await (db.select(
        db.careWorkspaces,
      )..where((w) => w.id.equals(context.workspaceId))).getSingle();
      expect(workspace.selectedProfileId, isNull);
    },
  );

  test('leaves people of another owner alone', () async {
    final fixture = await CareRecordingFixture.create();
    addTearDown(fixture.db.close);
    final db = fixture.db;

    await removeLocalCare(
      db,
      localWorkspaceId: fixture.workspace.context.workspaceId,
      localOwnerId: 'another-owner',
      profileIds: {fixture.person.id},
    );

    expect(await db.select(db.profiles).get(), hasLength(1));
    expect(await db.select(db.medicationOccurrences).get(), hasLength(1));
  });
}
