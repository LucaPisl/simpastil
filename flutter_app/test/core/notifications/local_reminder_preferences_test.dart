import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/notifications/reminder_preferences.dart';
import 'package:simpastil/core/notifications/reminder_readiness.dart';
import 'package:simpastil/core/protection/app_lock_controller.dart';
import 'package:simpastil/core/projections/projection_registry.dart';
import 'package:simpastil/core/projections/care_projection_coordinator.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/notifications/notification_action_handler.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';
import 'package:simpastil/core/projections/projection_identity.dart';
import 'package:simpastil/core/projections/projection_reconciler.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

import '../../helpers/care_recording_fixture.dart';

class _Phone implements ReminderReadinessPlatform {
  final pending = <int, PlatformReminderRequest>{};
  final scheduled = <ReminderProjection>[];
  bool allowed = true;
  bool exact = true;
  bool failTest = false;
  bool failPermissionRead = false;
  final failOccurrenceIds = <String>{};
  final tests = <ReminderTestNotification>[];
  int accessRequests = 0;
  Future<void> Function()? afterTestSchedule;
  @override
  Future<void> requestReminderAccess() async {
    accessRequests++;
  }

  @override
  Future<void> scheduleTest(
    ReminderTestNotification test, {
    required AppLocalizations localizations,
  }) async {
    if (failTest) throw StateError('fictional native test failure');
    tests.add(test);
    pending[test.id] = PlatformReminderRequest(
      id: test.id,
      title: 'Check',
      body: 'Fictional',
      payload: test.payload,
    );
    await afterTestSchedule?.call();
  }

  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasExactAlarmPermission() async => exact;
  @override
  Future<bool> hasNotificationPermission() async {
    if (failPermissionRead) {
      throw StateError('fictional native permission failure');
    }
    return allowed;
  }

  @override
  Future<List<PlatformReminderRequest>> pendingRequests() async =>
      pending.values.toList();
  @override
  Future<void> cancel(int id) async {
    pending.remove(id);
  }

  @override
  Future<void> cancelAll() async {
    pending.clear();
  }

  @override
  Future<void> schedule(
    ReminderProjection reminder, {
    required AppLocalizations localizations,
  }) async {
    if (failOccurrenceIds.contains(reminder.occurrenceId)) {
      throw StateError('fictional native reminder failure');
    }
    scheduled.add(reminder);
    pending[reminder.notificationId] = PlatformReminderRequest(
      id: reminder.notificationId,
      title: reminder.title,
      body: reminder.body,
      payload: reminder.payload,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tz_data.initializeTimeZones);
  late CareRecordingFixture fixture;
  late _Phone phone;
  late ReminderPreferencesRepository preferences;
  late ProjectionReconciler reconciler;
  final now = DateTime.utc(2026, 9, 30, 8);
  setUp(() async {
    fixture = await CareRecordingFixture.create();
    phone = _Phone();
    final f = fixture.workspace;
    await fixture.db
        .into(fixture.db.devicePersonReminders)
        .insertOnConflictUpdate(
          DevicePersonRemindersCompanion.insert(
            profileId: fixture.person.id,
            enabled: const Value(true),
          ),
        );
    preferences = ReminderPreferencesRepository(
      database: fixture.db,
      access: f.access,
      context: f.context,
    );
    reconciler = ProjectionReconciler(
      database: fixture.db,
      preferences: f.preferences,
      generations: SessionGenerationRepository(f.preferences, access: f.access),
      platform: phone,
      platformKind: ReminderPlatformKind.android,
      clock: () => now,
      access: f.access,
    );
  });
  tearDown(() => fixture.db.close());
  Future<void> refresh() async {
    await reconciler.reconcile(
      projectionIdentity: ProjectionIdentity.fromContext(
        fixture.workspace.context,
      ),
    );
  }

  test(
    'local schedule has one default reminder and explicit exact follow-ups',
    () async {
      await refresh();
      expect(
        phone.scheduled.where((r) => r.occurrenceId == fixture.occurrence.id),
        hasLength(1),
      );
      await preferences.setSchedule(
        fixture.occurrence.scheduleId!,
        ScheduleReminderChoice(followUpMinutes: [30, 15, 15]),
      );
      await refresh();
      final ids = phone.pending.keys.toSet();
      final current = phone.scheduled
          .where((r) => r.occurrenceId == fixture.occurrence.id)
          .toList();
      expect(current.map((r) => r.scheduledAtUtc).toSet(), {
        fixture.occurrence.plannedAt!.toUtc(),
        fixture.occurrence.plannedAt!.toUtc().add(const Duration(minutes: 15)),
        fixture.occurrence.plannedAt!.toUtc().add(const Duration(minutes: 30)),
      });
      final count = phone.scheduled.length;
      await refresh();
      expect(phone.scheduled, hasLength(count));
      expect(phone.pending.keys.toSet(), ids);
      expect(
        await fixture.db.select(fixture.db.pendingOperations).get(),
        isEmpty,
      );
    },
  );
  test(
    'device schedule choice and private labels survive viewing changes',
    () async {
      await preferences.setFullDetails(false);
      await refresh();
      expect(
        phone.pending.values.every(
          (r) =>
              !r.title.contains(fixture.pill.name) &&
              !r.body.contains(fixture.pill.name),
        ),
        isTrue,
      );
      await fixture.workspace.access.viewPerson(
        fixture.workspace.context,
        null,
        everyone: true,
      );
      await refresh();
      expect(phone.pending, isNotEmpty);
      await preferences.setSchedule(
        fixture.occurrence.scheduleId!,
        ScheduleReminderChoice(enabled: false),
      );
      await refresh();
      expect(phone.pending, isEmpty);
      expect((await preferences.load()).fullDetails, isFalse);
    },
  );
  test(
    'stale interface lease cannot publish a reminder privacy choice',
    () async {
      await expectLater(
        preferences.setFullDetails(
          false,
          requireInterfaceAccess: () {
            throw const AppLockRequired();
          },
        ),
        throwsA(isA<AppLockRequired>()),
      );
      expect((await preferences.load()).fullDetails, isTrue);
    },
  );
  test(
    'notification denial does not schedule alerts or block care storage',
    () async {
      phone.allowed = false;
      await refresh();
      expect(phone.pending, isEmpty);
      expect(
        (await fixture.db.pillsDao.getById(fixture.pill.id))?.name,
        fixture.pill.name,
      );
      expect(
        ProjectionReconciler.readStatus(
          fixture.workspace.preferences,
          fixture.workspace.context.ownerUserId,
        )?.degraded,
        isTrue,
      );
    },
  );

  Future<ReminderProjection> snooze() async {
    final identity = ProjectionIdentity.fromContext(fixture.workspace.context);
    expect(
      await reconciler.scheduleSnooze(
        identity: (identity.ownerId, identity.grantEpoch),
        occurrenceId: fixture.occurrence.id,
        delay: const Duration(minutes: 10),
        localizations: AppLocalizationsEn(),
        projectionIdentity: identity,
        deliveredStateVersion: fixture.occurrence.stateVersion,
      ),
      isTrue,
    );
    return phone.scheduled.last;
  }

  test(
    'completed alert retires when an unrelated future alert fails',
    () async {
      await refresh();
      final completedId = phone.scheduled
          .firstWhere((r) => r.occurrenceId == fixture.occurrence.id)
          .notificationId;
      final unrelated = phone.scheduled.firstWhere(
        (r) => r.occurrenceId != fixture.occurrence.id,
      );
      phone.pending.remove(unrelated.notificationId);
      phone.failOccurrenceIds.add(unrelated.occurrenceId);
      final service = CareRecordingService(
        database: fixture.db,
        access: fixture.workspace.access,
        context: fixture.workspace.context,
        clock: () => now,
      );
      await service.commit(
        await service.prepareTakenNow(
          personId: fixture.person.id,
          occurrenceId: fixture.occurrence.id,
          expectedStateVersion: fixture.occurrence.stateVersion,
        ),
      );
      await refresh();
      expect(phone.pending.keys, isNot(contains(completedId)));
      expect(
        ProjectionReconciler.readStatus(
          fixture.workspace.preferences,
          fixture.workspace.context.ownerUserId,
        )?.degraded,
        isTrue,
      );
    },
  );

  test('private choice rebuilds a snooze at its retained instant', () async {
    await refresh();
    final original = await snooze();
    expect(original.title, contains(fixture.pill.name));
    await preferences.setFullDetails(false);
    await refresh();
    final revised = phone.scheduled.lastWhere(
      (r) => r.notificationId == original.notificationId,
    );
    expect(revised.scheduledAtUtc, original.scheduledAtUtc);
    expect(revised.projectionId, original.projectionId);
    expect(revised.allowCareActions, isFalse);
    expect(revised.title, AppLocalizationsEn().core_notifPrivateTitle);
    expect(revised.body, AppLocalizationsEn().core_notifPrivateBody);
    expect(phone.pending[original.notificationId]?.body, revised.body);
  });

  test(
    'private choice cancels exposed primary and snooze after permission loss',
    () async {
      await refresh();
      final original = await snooze();
      expect(phone.pending, isNotEmpty);
      phone.exact = false;
      await preferences.setFullDetails(false);
      await refresh();
      expect(phone.pending, isEmpty);
      expect(phone.pending.keys, isNot(contains(original.notificationId)));
    },
  );

  test(
    'failed private replacement retires the exposed snooze and primary',
    () async {
      await refresh();
      final primaryId = phone.scheduled
          .firstWhere((r) => r.occurrenceId == fixture.occurrence.id)
          .notificationId;
      final original = await snooze();
      await preferences.setFullDetails(false);
      phone.failOccurrenceIds.add(fixture.occurrence.id);
      await refresh();
      expect(phone.pending.keys, isNot(contains(primaryId)));
      expect(phone.pending.keys, isNot(contains(original.notificationId)));
    },
  );

  test(
    'follow-up actions keep the exact target, respect device choices and replay once',
    () async {
      await preferences.setSchedule(
        fixture.occurrence.scheduleId!,
        ScheduleReminderChoice(followUpMinutes: [15]),
      );
      await refresh();
      final reminder = phone.scheduled.firstWhere(
        (r) =>
            r.occurrenceId == fixture.occurrence.id &&
            (jsonDecode(r.payload) as Map)['followUpMinutes'] == 15,
      );
      final payload = parseReminderActionPayload(reminder.payload)!;
      expect(reminderProjectionMatchesAction(payload), isTrue);
      final repository = MedicationRepository(
        fixture.db,
        access: fixture.workspace.access,
        context: fixture.workspace.context,
      );
      Future<MedicationCommand> apply() => repository.applyDeviceAction(
        occurrenceId: payload.occurrenceId,
        projectionId: payload.projectionId,
        kind: followUpReminderKind(payload.followUpMinutes!),
        action: MedicationAction.take,
        deliveredStateVersion: payload.stateVersion,
        now: now,
      );
      await preferences.setSchedule(
        fixture.occurrence.scheduleId!,
        ScheduleReminderChoice(enabled: false, followUpMinutes: [15]),
      );
      await expectLater(apply(), throwsA(isA<MedicationCommandBlocked>()));
      await preferences.setSchedule(
        fixture.occurrence.scheduleId!,
        ScheduleReminderChoice(),
      );
      await expectLater(apply(), throwsA(isA<MedicationCommandBlocked>()));
      await preferences.setSchedule(
        fixture.occurrence.scheduleId!,
        ScheduleReminderChoice(followUpMinutes: [15]),
      );
      final saved = await apply();
      expect((await apply()).commandId, saved.commandId);
      expect(
        await fixture.db.select(fixture.db.occurrenceEvents).get(),
        hasLength(1),
      );
    },
  );

  test(
    'committed Take and Undo refresh phone effects without a save callback',
    () async {
      final ready = Completer<void>();
      final taken = Completer<void>();
      final undone = Completer<void>();
      final coordinator = CareProjectionCoordinator(
        database: fixture.db,
        refresh: () async {
          await refresh();
          final current = (await fixture.db.medicationLedgerDao
              .getOccurrenceById(fixture.occurrence.id))!;
          if (!ready.isCompleted) ready.complete();
          if (current.state == 'taken' && !taken.isCompleted) taken.complete();
          if (current.state == 'pending' &&
              current.stateVersion == 2 &&
              !undone.isCompleted) {
            undone.complete();
          }
        },
      );
      addTearDown(coordinator.close);
      coordinator.start();
      await ready.future.timeout(const Duration(seconds: 5));
      final service = CareRecordingService(
        database: fixture.db,
        access: fixture.workspace.access,
        context: fixture.workspace.context,
        clock: () => now,
      );
      final intent = await service.prepareTakenNow(
        personId: fixture.person.id,
        occurrenceId: fixture.occurrence.id,
        expectedStateVersion: 0,
      );
      final receipt = await service.commit(intent);
      expect(receipt.projection, CareProjectionOutcome.notRequested);
      await taken.future.timeout(const Duration(seconds: 5));
      expect(
        phone.pending.values.where(
          (p) => p.payload!.contains(fixture.occurrence.id),
        ),
        isEmpty,
      );
      await service.commit(await service.prepareUndo(receipt));
      await undone.future.timeout(const Duration(seconds: 5));
      expect(
        phone.pending.values.where(
          (p) => p.payload!.contains(fixture.occurrence.id),
        ),
        hasLength(1),
      );
      await coordinator.close();
    },
  );
  ReminderReadinessService readiness() => ReminderReadinessService(
    database: fixture.db,
    access: fixture.workspace.access,
    context: fixture.workspace.context,
    preferences: ProjectionRegistry(fixture.workspace.preferences),
    platform: phone,
    clock: () => now,
  );
  test(
    'requested, allowed, scheduled and observed delivery remain distinct; restore invalidates evidence',
    () async {
      final service = readiness();
      final initial = await service.inspect();
      expect(initial.permissions.canSchedule, isTrue);
      expect(initial.test, isNull);
      expect(phone.accessRequests, 0);
      final running = service.requestTest(localizations: AppLocalizationsEn());
      final overlap = service.requestTest(localizations: AppLocalizationsEn());
      expect(identical(running, overlap), isTrue);
      final scheduled = await running;
      expect(scheduled.test?.requestedAt, now);
      expect(scheduled.test?.scheduled, isTrue);
      expect(scheduled.deliveryConfirmed, isFalse);
      expect(phone.tests, hasLength(1));
      expect(
        (await service.confirmObserved(
          scheduled.test!.testId,
        )).deliveryConfirmed,
        isTrue,
      );
      await service.invalidateAfterRestore();
      expect((await service.inspect()).test, isNull);
      await expectLater(
        service.confirmObserved(scheduled.test!.testId),
        throwsStateError,
      );
      expect(
        (await fixture.db.pillsDao.getById(fixture.pill.id))?.name,
        fixture.pill.name,
      );
    },
  );
  test(
    'denied, exact unavailable and plugin failure preserve requested facts without success',
    () async {
      final service = readiness();
      phone.allowed = false;
      final denied = await service.requestTest(
        localizations: AppLocalizationsEn(),
      );
      expect(denied.test?.problem, ReminderReadinessProblem.denied);
      expect(denied.test?.scheduled, isFalse);
      expect(phone.tests, isEmpty);
      phone.allowed = true;
      phone.exact = false;
      expect(
        (await service.requestTest(
          localizations: AppLocalizationsEn(),
        )).test?.problem,
        ReminderReadinessProblem.exactUnavailable,
      );
      phone.failPermissionRead = true;
      final unavailable = await service.requestTest(
        localizations: AppLocalizationsEn(),
      );
      expect(unavailable.permissions.notificationsAllowed, isNull);
      expect(
        unavailable.test?.problem,
        ReminderReadinessProblem.platformUnavailable,
      );
      expect(phone.tests, isEmpty);
      phone.failPermissionRead = false;
      phone.exact = true;
      phone.failTest = true;
      final failed = await service.requestTest(
        localizations: AppLocalizationsEn(),
      );
      expect(failed.test?.permissions.canSchedule, isTrue);
      expect(failed.test?.scheduled, isFalse);
      expect(failed.test?.problem, ReminderReadinessProblem.schedulingFailed);
      expect(failed.deliveryConfirmed, isFalse);
    },
  );
  test(
    'a grant revoked during the native check removes the stale effect and cannot report delivery',
    () async {
      phone.afterTestSchedule = () async {
        await (fixture.db.update(fixture.db.workspaceGrants)..where(
              (row) =>
                  row.workspaceId.equals(fixture.workspace.context.workspaceId),
            ))
            .write(const WorkspaceGrantsCompanion(isGranted: Value(false)));
      };
      await expectLater(
        readiness().requestTest(localizations: AppLocalizationsEn()),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(phone.pending, isEmpty);
      final stored =
          (await fixture.db.select(fixture.db.deviceReminderSettings).get())
              .single;
      expect(
        ReminderTestFacts.fromJson(
          jsonDecode(stored.testJson!) as Map<String, dynamic>,
        ).scheduled,
        isFalse,
      );
    },
  );
}
