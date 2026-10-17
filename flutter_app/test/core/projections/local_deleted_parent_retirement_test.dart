import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/projections/projection_identity.dart';
import 'package:simpastil/core/projections/projection_reconciler.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/features/profiles/profile_repository.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

class _ReminderPlatform implements ReminderNotificationPlatform {
  final requests = <int, PlatformReminderRequest>{};
  final cancelled = <int>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasNotificationPermission() async => true;

  @override
  Future<bool> hasExactAlarmPermission() async => true;

  @override
  Future<List<PlatformReminderRequest>> pendingRequests() async =>
      requests.values.toList();

  @override
  Future<void> schedule(
    ReminderProjection projection, {
    required AppLocalizations localizations,
  }) async {
    requests[projection.notificationId] = PlatformReminderRequest(
      id: projection.notificationId,
      title: projection.title,
      body: projection.body,
      payload: projection.payload,
    );
  }

  @override
  Future<void> cancel(int notificationId) async {
    cancelled.add(notificationId);
    requests.remove(notificationId);
  }

  @override
  Future<void> cancelAll() async {
    cancelled.addAll(requests.keys);
    requests.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  test(
    'deleting a local person retires their alerts without removing care rows',
    () async {
      final fixture = await CareRecordingFixture.create(
        routineTimeZone: 'Europe/Bucharest',
        routineHour: 15,
      );
      addTearDown(fixture.db.close);
      final db = fixture.db;
      final access = fixture.workspace.access;
      final context = fixture.workspace.context;
      await db
          .into(db.devicePersonReminders)
          .insertOnConflictUpdate(
            DevicePersonRemindersCompanion.insert(
              profileId: fixture.person.id,
              enabled: const Value(true),
            ),
          );

      const otherPersonId = 'fictional-second-person';
      const otherPillId = 'fictional-second-medication';
      const otherPillName = 'Fictional second medication';
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: otherPersonId,
          userId: context.ownerUserId,
          name: 'Fictional Morgan',
          createdAt: CareRecordingFixture.planned,
          updatedAt: CareRecordingFixture.planned,
        ),
      );
      await db.pillsDao.upsert(
        PillsCompanion.insert(
          id: otherPillId,
          profileId: otherPersonId,
          name: otherPillName,
          createdAt: CareRecordingFixture.planned,
          updatedAt: CareRecordingFixture.planned,
        ),
      );
      await db
          .into(db.devicePersonReminders)
          .insertOnConflictUpdate(
            DevicePersonRemindersCompanion.insert(
              profileId: otherPersonId,
              enabled: const Value(true),
            ),
          );
      final otherRoutine = RoutineRepository(
        database: db,
        access: access,
        context: context,
        clock: () => DateTime.utc(2026, 9, 30, 8),
      );
      final otherReview = await otherRoutine.preview(
        pillId: otherPillId,
        expectedRevision: 0,
        definition: RoutineDefinition(
          kind: RoutineKind.daily,
          timeZone: 'Europe/Bucharest',
          times: [const RoutineTime(slotId: 'afternoon', hour: 16, minute: 0)],
        ),
        effectiveFrom: DateTime.utc(2026, 9, 30, 8),
        fromLocalDate: '2026-09-30',
        throughLocalDate: '2026-09-30',
      );
      await otherRoutine.saveReviewed(otherReview);

      final platform = _ReminderPlatform();
      final identity = ProjectionIdentity.fromContext(context);
      final reconciler = ProjectionReconciler(
        database: db,
        preferences: fixture.workspace.preferences,
        generations: SessionGenerationRepository(
          fixture.workspace.preferences,
          access: access,
        ),
        platform: platform,
        platformKind: ReminderPlatformKind.android,
        clock: () => DateTime.utc(2026, 9, 30, 9),
        effectsGate: SerialProjectionEffectsGate(),
      );

      final initial = await reconciler.reconcile(projectionIdentity: identity);
      expect(initial?.scheduledCount, platform.requests.length);
      final routineIdsBefore = (await db.select(db.localRoutines).get())
          .map((row) => '${row.routineId}/${row.revision}')
          .toSet();
      final scheduleIdsBefore = (await db.select(db.schedules).get())
          .map((row) => row.id)
          .toSet();
      final occurrenceIdsBefore =
          (await db.medicationLedgerDao.getOccurrencesForUser(
            context.ownerUserId,
          )).map((row) => row.id).toSet();
      final scheduledIds = platform.requests.keys.toSet();
      expect(scheduledIds, isNotEmpty);
      final otherTitle = AppLocalizationsEn().core_notifTitle(otherPillName);
      final otherReminderIds = platform.requests.values
          .where((request) => request.title == otherTitle)
          .map((request) => request.id)
          .toSet();
      expect(otherReminderIds, isNotEmpty);
      final deletedPersonReminderIds = scheduledIds.difference(
        otherReminderIds,
      );
      expect(deletedPersonReminderIds, isNotEmpty);

      final delete = ProfileRepositoryImpl(
        dao: db.profilesDao,
        pendingOperations: PendingOperationRepository(db),
        userId: context.ownerUserId,
        context: context,
        access: access,
        reconcileProjections: () async {
          await reconciler.reconcile(projectionIdentity: identity);
        },
      );
      await delete.delete(fixture.person.id);

      expect(platform.requests.keys.toSet(), otherReminderIds);
      expect(platform.cancelled.toSet(), containsAll(deletedPersonReminderIds));
      expect(
        platform.cancelled.toSet().intersection(otherReminderIds),
        isEmpty,
      );
      expect(
        (await db.profilesDao.getById(fixture.person.id))?.isDeleted,
        isTrue,
      );
      expect((await db.pillsDao.getById(fixture.pill.id))?.isDeleted, isFalse);
      expect(
        await db.medicationLedgerDao.getOccurrenceById(fixture.occurrence.id),
        isNotNull,
      );
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(
          fixture.occurrence.id,
        ),
        isEmpty,
      );
      expect(
        (await db.select(db.localRoutines).get())
            .map((row) => '${row.routineId}/${row.revision}')
            .toSet(),
        routineIdsBefore,
      );
      expect(
        (await db.select(db.schedules).get()).map((row) => row.id).toSet(),
        scheduleIdsBefore,
      );
      expect(
        (await db.medicationLedgerDao.getOccurrencesForUser(
          context.ownerUserId,
        )).map((row) => row.id).toSet(),
        occurrenceIdsBefore,
      );
    },
  );
}
