import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/features/profiles/profile_repository.dart';
import 'package:simpastil/features/setup/setup_repository.dart';

import '../../helpers/protected_workspace_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'schema6 to9 preserves author, viewing/reminder choices and original dosage',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'simpastil-schema6-fictional-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/care.db');
      var db = AppDatabase(NativeDatabase(file));
      final f = await ProtectedWorkspaceFixture.create(database: db);
      final person =
          (await ProfileRepositoryImpl(
                    dao: db.profilesDao,
                    userId: f.context.ownerUserId,
                    pendingOperations: PendingOperationRepository(
                      db,
                      access: f.access,
                      context: f.context,
                    ),
                    access: f.access,
                    context: f.context,
                    reconcileProjections: () async {},
                  ).create('Fictional Alex', 'A')
                  as Ok<Profile>)
              .value;
      await f.access.viewPerson(f.context, person.id);
      // New people start on; an explicit off must survive the upgrade.
      await db
          .update(db.devicePersonReminders)
          .write(const DevicePersonRemindersCompanion(enabled: Value(false)));
      final now = DateTime.now().toUtc();
      await db.pillsDao.upsert(
        PillsCompanion.insert(
          id: 'fictional-legacy-pill',
          profileId: person.id,
          name: 'Fictional old medication',
          dosage: const Value('Old mixed wording'),
          createdAt: now,
          updatedAt: now,
        ),
      );
      // Known v6 fixture: remove every later additive table.
      expect(AppDatabase.supportedSchemaVersion, 18);
      await db.customStatement('DROP TABLE device_restore_intents');
      await db.customStatement('DROP TABLE import_conflicts');
      await db.customStatement('DROP TABLE import_evidence');
      await db.customStatement('DROP TABLE import_receipts');
      await db.customStatement('DROP TABLE device_schedule_reminders');
      await db.customStatement('DROP TABLE device_reminder_settings');
      await db.customStatement('DROP TABLE care_event_details');
      await db.customStatement('DROP TABLE reviewed_stock_balances');
      await db.customStatement('DROP TABLE local_routines');
      await db.customStatement('DROP TABLE setup_drafts');
      await db.customStatement('DROP TABLE medication_details');
      await db.customStatement('DROP TABLE effect_settlements');
      await db.customStatement(
        'ALTER TABLE schedules DROP COLUMN time_zone_status',
      );
      await db.customStatement('ALTER TABLE schedules DROP COLUMN time_zone');
      await db.customStatement(
        'ALTER TABLE occurrence_events DROP COLUMN administration_amount_json',
      );
      await db.customStatement('PRAGMA user_version=6');
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      final access = WorkspaceAccessRepository(
        db,
        effectsGate: SerialProjectionEffectsGate(),
      );
      final context = await access.currentContext();
      expect(context.workspaceId, f.context.workspaceId);
      expect(context.authorId, f.context.authorId);
      expect(
        (await access.workspaces.byId(context.workspaceId))!.selectedProfileId,
        person.id,
      );
      expect(
        (await db.select(db.devicePersonReminders).get()).single.enabled,
        isFalse,
      );
      expect(await db.select(db.setupDrafts).get(), isEmpty);
      expect(await db.select(db.medicationDetails).get(), isEmpty);
      final review = await SetupRepository(
        database: db,
        access: access,
        context: context,
      ).medicationReview('fictional-legacy-pill');
      expect(review.originalDosage, 'Old mixed wording');
      expect(review.legacyDosageReviewed, isFalse);
      expect(review.packageStrength, isNull);
      expect(review.amount.isUnknown, isTrue);
    },
  );
}
