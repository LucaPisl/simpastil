import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, Value, Variable;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/db/daos/medication_ledger_dao.dart';
import 'package:simpastil/core/projections/projection_reconciler.dart';
import 'package:simpastil/core/projections/reminder_reconcile_runner.dart';
import 'package:simpastil/core/projections/reminder_id_ledger.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
import 'package:simpastil/core/projections/projection_identity.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/projections/projection_registry.dart';
import 'package:simpastil/core/notifications/notification_service.dart';
import 'package:simpastil/core/notifications/reminder_channel.dart';
import 'package:simpastil/core/notifications/reminder_preferences.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/features/profiles/profile_repository.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

const _userId = 'reconciler-user';
const _profileId = '00000000-0000-4000-8000-000000000001';
const _pillId = '00000000-0000-4000-8000-000000000002';
const _scheduleId = '00000000-0000-4000-8000-000000000003';
final _now = DateTime.utc(2026, 9, 24, 6);

class _ObservedGate implements ProjectionEffectsGate {
  final delegate = SerialProjectionEffectsGate();
  void Function()? onRequested;
  @override
  Future<T> run<T>(Future<T> Function() action) {
    onRequested?.call();
    return delegate.run(action);
  }
}

class _OccurrenceSnapshotCounter extends QueryInterceptor {
  int reads = 0;
  int revisionReads = 0;
  int? snapshotsBeforeSecondRevision;
  void Function()? beforeSecondRevisionRead;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    final normalized = statement.toLowerCase();
    if (normalized.contains('from medication_occurrences') &&
        normalized.contains("source='scheduled'") &&
        normalized.contains("provenance='exact'")) {
      reads++;
    }
    if (normalized.contains('from pragma_data_version')) {
      revisionReads++;
      if (revisionReads == 2) {
        snapshotsBeforeSecondRevision = reads;
        beforeSecondRevisionRead?.call();
      }
    }
    return executor.runSelect(statement, args);
  }
}

class _FakeReminderPlatform
    implements
        ReminderNotificationPlatform,
        ActiveReminderNotificationPlatform,
        RetiredChannelNotificationPlatform {
  bool failChannelDeletion = false;
  @override
  Future<void> deleteRetiredChannels() async {
    events.add('deleteRetiredChannels');
    if (failChannelDeletion) throw StateError('synthetic channel failure');
  }

  final requests = <int, PlatformReminderRequest>{};
  final active = <int, PlatformActiveReminder>{};
  @override
  Future<List<PlatformActiveReminder>> activeReminders() async =>
      active.values.toList();
  final scheduled = <ReminderProjection>[];
  final cancelled = <int>[];
  final events = <String>[];
  final scheduleStarted = Completer<void>();
  Completer<void>? scheduleGate;
  bool failNextSchedule = false;
  bool failNextCancel = false;
  final failCancelIds = <int>{};
  Future<void> Function(int)? afterCancel;
  bool exactPermission = true;

  @override
  Future<bool> hasNotificationPermission() async => true;
  @override
  Future<bool> hasExactAlarmPermission() async => exactPermission;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<PlatformReminderRequest>> pendingRequests() async =>
      requests.values.toList();

  @override
  Future<void> schedule(
    ReminderProjection reminder, {
    required AppLocalizations localizations,
  }) async {
    events.add('schedule:${reminder.occurrenceId}');
    if (!scheduleStarted.isCompleted) scheduleStarted.complete();
    final gate = scheduleGate;
    if (gate != null) await gate.future;
    if (failNextSchedule) {
      failNextSchedule = false;
      throw StateError('synthetic schedule failure');
    }
    scheduled.add(reminder);
    requests[reminder.notificationId] = PlatformReminderRequest(
      id: reminder.notificationId,
      title: reminder.title,
      body: reminder.body,
      payload: reminder.payload,
    );
  }

  @override
  Future<void> cancel(int notificationId) async {
    events.add('cancel:$notificationId');
    if (failNextCancel) {
      failNextCancel = false;
      throw StateError('synthetic cancellation failure');
    }
    if (failCancelIds.contains(notificationId)) {
      throw StateError('synthetic cancellation failure');
    }
    cancelled.add(notificationId);
    requests.remove(notificationId);
    active.remove(notificationId);
    await afterCancel?.call(notificationId);
  }

  @override
  Future<void> cancelAll() async {
    events.add('cancelAll');
    cancelled.addAll(requests.keys);
    requests.clear();
    active.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(tz_data.initializeTimeZones);

  late AppDatabase db;
  late SharedPreferences preferences;
  late SessionGenerationRepository generations;
  late _FakeReminderPlatform platform;
  late int generation;
  Directory? fileBackedScratch;

  Future<void> insertOccurrence(
    String id, {
    required int minutesFromNow,
  }) async {
    final snapshot = ScheduleSnapshotV1(
      pillName: id,
      dosage: null,
      frequency: 'daily',
      frequencyDays: null,
      hour: 9,
      minute: 0,
      timeZone: 'UTC',
      profileId: _profileId,
      profileName: 'Profile',
    );
    await db.medicationLedgerDao.upsertOccurrence(
      MedicationOccurrencesCompanion.insert(
        id: id,
        userId: _userId,
        pillId: const Value(_pillId),
        scheduleId: const Value(_scheduleId),
        occurrenceKey: 'scheduled:v1:$id',
        source: 'scheduled',
        scheduleRevision: const Value(1),
        plannedLocalDate: '2026-09-24',
        plannedLocalTime: const Value('06:00'),
        timeZone: 'UTC',
        plannedAt: Value(_now.add(Duration(minutes: minutesFromNow))),
        expected: const Value(true),
        scheduleSnapshotJson: jsonEncode(snapshot.toJson()),
        provenance: 'exact',
        createdAt: _now,
        updatedAt: _now,
      ),
    );
  }

  Future<void> insertCapacityOccurrences(
    int count, {
    int startAtMinute = 100,
  }) async {
    for (var index = 0; index < count; index++) {
      await insertOccurrence(
        'capacity-${index.toString().padLeft(3, '0')}',
        minutesFromNow: startAtMinute + index,
      );
    }
  }

  setUp(() async {
    fileBackedScratch = null;
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    generations = SessionGenerationRepository(preferences);
    generation = await generations.advanceTo(_userId);
    db = AppDatabase.forTesting();
    platform = _FakeReminderPlatform();
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: _userId,
        email: 'reconciler@test.invalid',
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _profileId,
        userId: _userId,
        name: 'Profile',
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: _pillId,
        profileId: _profileId,
        name: 'Medicine',
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    await db.schedulesDao.upsert(
      SchedulesCompanion.insert(
        id: _scheduleId,
        pillId: _pillId,
        hour: 6,
        minute: 20,
        frequency: 'daily',
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    await insertOccurrence('occurrence-a', minutesFromNow: 20);
  });

  tearDown(() async {
    await db.close();
    final scratch = fileBackedScratch;
    if (scratch != null) await scratch.delete(recursive: true);
  });

  Future<void> reopenFileBacked({QueryInterceptor? interceptor}) async {
    final scratch = await Directory.systemTemp.createTemp(
      'simpastil-projection-reconcile-',
    );
    fileBackedScratch = scratch;
    final file = File('${scratch.path}/care.db');
    final quotedPath = file.path.replaceAll("'", "''");
    await db.customStatement("VACUUM INTO '$quotedPath'");
    await db.close();
    final executor = NativeDatabase(file);
    db = AppDatabase(
      interceptor == null ? executor : executor.interceptWith(interceptor),
    );
    await db.customSelect('SELECT 1').get();
  }

  ProjectionReconciler makeReconciler() => ProjectionReconciler(
    database: db,
    preferences: preferences,
    generations: generations,
    platform: platform,
    platformKind: ReminderPlatformKind.android,
    clock: () => _now,
  );

  Future<WorkspaceAccessRepository> protect({
    ProjectionEffectsGate? effectsGate,
  }) async {
    final access = WorkspaceAccessRepository(
      db,
      effectsGate: effectsGate ?? SerialProjectionEffectsGate(),
    );
    const endpoint = 'https://fictional.test/care';
    final transition = await access.configureEndpoint(endpoint);
    await db
        .into(db.credentialSlots)
        .insert(
          CredentialSlotsCompanion.insert(
            id: 'fictional-staged',
            ownerId: _userId,
            endpoint: endpoint,
            state: 'staged',
            createdAt: _now,
          ),
        );
    final authenticated = await access.authenticate(
      ownerId: _userId,
      endpoint: endpoint,
      expectedNetworkEpoch: transition,
      sessionGeneration: generation,
      credentialId: 'fictional-staged',
    );
    await access.confirmOriginalServer(
      workspaceId: authenticated.workspace.id,
      reviewedOriginalEndpoint: endpoint,
      expectedNetworkEpoch: authenticated.network.epoch,
    );
    await db
        .into(db.devicePersonReminders)
        .insertOnConflictUpdate(
          DevicePersonRemindersCompanion.insert(
            profileId: _profileId,
            enabled: const Value(true),
          ),
        );
    return access;
  }

  ProjectionReconciler protectedReconciler(
    WorkspaceAccessRepository access, {
    DateTime Function()? clock,
    ActiveNotificationActionsRefresher? refreshActiveActions,
  }) => ProjectionReconciler(
    database: db,
    preferences: preferences,
    generations: SessionGenerationRepository(preferences, access: access),
    platform: platform,
    platformKind: ReminderPlatformKind.android,
    clock: clock ?? () => _now,
    refreshActiveActions: refreshActiveActions,
  );

  test('a pending reminder uses the medication current name', () async {
    final access = await protect();
    final context = (await access.contextForOwner(_userId))!;
    await (db.update(db.pills)..where((p) => p.id.equals(_pillId))).write(
      const PillsCompanion(name: Value('Renamed')),
    );
    await protectedReconciler(
      access,
    ).reconcile(projectionIdentity: ProjectionIdentity.fromContext(context));
    final reminder = platform.scheduled.single;
    expect('${reminder.title} ${reminder.body}', contains('Renamed'));
    expect(
      '${reminder.title} ${reminder.body}',
      isNot(contains('occurrence-a')),
    );
    // The stored snapshot is history and is not rewritten.
    final row = (await db.medicationLedgerDao.getOccurrenceById(
      'occurrence-a',
    ))!;
    expect(row.scheduleSnapshotJson, contains('"pillName":"occurrence-a"'));
  });

  test(
    'a reminder scheduled on an older channel revision is rescheduled',
    () async {
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      final reconciler = protectedReconciler(access);
      final identity = ProjectionIdentity.fromContext(context);
      await reconciler.reconcile(projectionIdentity: identity);
      expect(platform.scheduled, hasLength(1));
      await reconciler.reconcile(projectionIdentity: identity);
      expect(platform.scheduled, hasLength(1), reason: 'unchanged is reused');

      final registry =
          jsonDecode(
                preferences.getString('notification_projection_registry_v1')!,
              )
              as List;
      for (final entry in registry) {
        expect((entry as Map)['channelRevision'], kReminderChannelRevision);
        entry['channelRevision'] = 0;
      }
      await preferences.setString(
        'notification_projection_registry_v1',
        jsonEncode(registry),
      );
      await reconciler.reconcile(projectionIdentity: identity);
      expect(platform.scheduled, hasLength(2));
    },
  );

  test(
    'retires orphan repeating legacy alarms without saved ID lists',
    () async {
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      const legacyId = 987650;
      final payload = jsonEncode({
        'route': '/home?dose=$_scheduleId',
        'scheduleId': _scheduleId,
        'hour': 9,
        'minute': 0,
        'weekday': null,
        'pillName': 'Synthetic medicine',
      });
      platform.requests[legacyId] = PlatformReminderRequest(
        id: legacyId,
        title: 'Synthetic reminder',
        body: '',
        payload: payload,
      );
      // A dismissed repeating alert is absent from active notifications, but
      // Android still retains the next repeating alarm in its pending cache.
      await preferences.setBool('notification_occurrence_migration_v1', true);
      final reconciler = protectedReconciler(access);
      platform.failNextCancel = true;
      final failed = await reconciler.reconcile(
        projectionIdentity: ProjectionIdentity.fromContext(context),
      );
      expect(failed!.degraded, isTrue);
      expect(platform.requests.containsKey(legacyId), isTrue);
      await reconciler.reconcile(
        projectionIdentity: ProjectionIdentity.fromContext(context),
      );
      expect(platform.requests.containsKey(legacyId), isFalse);
      expect(platform.requests, hasLength(1));
      expect(platform.scheduled, hasLength(1));
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence('occurrence-a'),
        isEmpty,
      );
    },
  );

  test(
    'orphan cleanup requires exact legacy shape and owned schedule',
    () async {
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      final variants = [
        {
          'scheduleId': 'foreign-schedule',
          'route': '/home?dose=foreign-schedule',
        },
        {'projectionId': 'protected-other-grant'},
        {'hour': 24},
        {'weekday': 0},
        {'route': '/other'},
      ];
      for (var i = 0; i < variants.length; i++) {
        platform.requests[987660 + i] = PlatformReminderRequest(
          id: 987660 + i,
          title: 'Synthetic reminder',
          body: '',
          payload: jsonEncode({
            'route': '/home?dose=$_scheduleId',
            'scheduleId': _scheduleId,
            'hour': 9,
            'minute': 0,
            'weekday': null,
            ...variants[i],
          }),
        );
      }
      await protectedReconciler(
        access,
      ).reconcile(projectionIdentity: ProjectionIdentity.fromContext(context));
      for (var i = 0; i < variants.length; i++) {
        expect(platform.requests.containsKey(987660 + i), isTrue);
      }
    },
  );

  test(
    'retires a legacy ID list only when owner and schedule are both gone',
    () async {
      final access = await protect();
      const missingOwner = '20000000-0000-4000-8000-000000000001';
      const missingSchedule = '20000000-0000-4000-8000-000000000002';
      const key = 'notif_ids_$missingOwner';
      const legacyId = 987640;
      const unprovenId = 987641;
      await preferences.setString(key, jsonEncode([legacyId, unprovenId]));
      platform.requests[legacyId] = PlatformReminderRequest(
        id: legacyId,
        title: 'Synthetic old reminder',
        body: '',
        payload: jsonEncode({
          'route': '/home?dose=$missingSchedule',
          'scheduleId': missingSchedule,
          'hour': 9,
          'minute': 0,
          'weekday': null,
        }),
      );
      final reconciler = protectedReconciler(access);
      await reconciler.reconcileAll();
      expect(platform.requests.containsKey(legacyId), isFalse);
      expect(jsonDecode(preferences.getString(key)!), [unprovenId]);
      expect(platform.scheduled, hasLength(1));
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence('occurrence-a'),
        isEmpty,
      );
    },
  );

  Future<void> seedOrphanAlarms(List<int> ids) async {
    const owner = '20000000-0000-4000-8000-000000000001';
    const schedule = '20000000-0000-4000-8000-000000000002';
    await preferences.setString('notif_ids_$owner', jsonEncode(ids));
    for (final id in ids) {
      platform.requests[id] = PlatformReminderRequest(
        id: id,
        title: 'Synthetic old reminder',
        body: '',
        payload: jsonEncode({
          'route': '/home?dose=$schedule',
          'scheduleId': schedule,
          'hour': 9,
          'minute': 0,
          'weekday': null,
        }),
      );
    }
  }

  for (final change in ['care', 'grant', 'cancel failure']) {
    test('orphan retirement preserves unfinished IDs after $change', () async {
      final access = await protect();
      const first = 987630;
      const second = 987631;
      const key = 'notif_ids_20000000-0000-4000-8000-000000000001';
      await seedOrphanAlarms([first, second]);
      if (change == 'cancel failure') {
        platform.failNextCancel = true;
      } else {
        platform.afterCancel = (id) async {
          if (id != first) return;
          if (change == 'grant') {
            await access.revokeNetwork();
          } else {
            await db.customUpdate(
              "UPDATE profiles SET server_id='20000000-0000-4000-8000-000000000001' WHERE id=?",
              variables: [const Variable(_profileId)],
              updates: {db.profiles},
            );
          }
        };
      }
      final reconciler = protectedReconciler(access);
      await reconciler.reconcileAll();
      final retained = change == 'cancel failure' ? first : second;
      final removed = change == 'cancel failure' ? second : first;
      expect(platform.requests.containsKey(retained), isTrue);
      expect(platform.requests.containsKey(removed), isFalse);
      expect(jsonDecode(preferences.getString(key)!), [retained]);
      if (change == 'cancel failure') {
        await reconciler.reconcileAll();
        expect(platform.requests.containsKey(first), isFalse);
        expect(preferences.containsKey(key), isFalse);
      }
    });
  }

  for (final alias in ['parent', 'schedule']) {
    test(
      'orphan retirement retains a foreign tombstone $alias alias',
      () async {
        final access = await protect();
        const oldOwner = '20000000-0000-4000-8000-000000000001';
        const oldSchedule = '20000000-0000-4000-8000-000000000002';
        await db.usersDao.upsert(
          UsersCompanion.insert(
            id: 'other-owner',
            email: 'other@test.invalid',
            createdAt: _now,
            updatedAt: _now,
          ),
        );
        await db.profilesDao.upsert(
          ProfilesCompanion.insert(
            id: 'other-profile',
            userId: 'other-owner',
            name: 'Other',
            serverId: Value(alias == 'parent' ? oldOwner : null),
            isDeleted: const Value(true),
            createdAt: _now,
            updatedAt: _now,
          ),
        );
        await db.pillsDao.upsert(
          PillsCompanion.insert(
            id: 'other-pill',
            profileId: 'other-profile',
            name: 'Other',
            isDeleted: const Value(true),
            createdAt: _now,
            updatedAt: _now,
          ),
        );
        await db.schedulesDao.upsert(
          SchedulesCompanion.insert(
            id: 'other-schedule',
            pillId: 'other-pill',
            hour: 9,
            minute: 0,
            frequency: 'daily',
            serverId: Value(alias == 'schedule' ? oldSchedule : null),
            isDeleted: const Value(true),
            createdAt: _now,
            updatedAt: _now,
          ),
        );
        await seedOrphanAlarms([987620]);
        await protectedReconciler(access).reconcileAll();
        expect(platform.requests.containsKey(987620), isTrue);
        expect(jsonDecode(preferences.getString('notif_ids_$oldOwner')!), [
          987620,
        ]);
        expect(platform.scheduled, hasLength(1));
      },
    );
  }

  for (final deleted in [false, true]) {
    test(
      'retires person-keyed legacy alarms, including deleted=$deleted',
      () async {
        const legacyId = 987654;
        const otherId = 987655;
        final ownKey =
            '${NotificationService.legacyIdsPreferencePrefix}$_profileId';
        const otherKey = 'notif_ids_other-person';
        await preferences.setString(ownKey, jsonEncode([legacyId]));
        await preferences.setString(otherKey, jsonEncode([otherId]));
        for (final id in [legacyId, otherId]) {
          platform.requests[id] = PlatformReminderRequest(
            id: id,
            title: 'Fictional legacy reminder',
            body: 'Fictional medicine',
            payload: jsonEncode({'scheduleId': 'legacy-schedule', 'hour': 9}),
          );
          platform.active[id] = PlatformActiveReminder(
            id: id,
            title: 'Fictional legacy reminder',
            body: 'Fictional medicine',
          );
        }
        if (deleted) await db.profilesDao.softDelete(_profileId);

        await makeReconciler().reconcile(identity: (_userId, generation));

        expect(platform.requests.containsKey(legacyId), isFalse);
        expect(platform.active.containsKey(legacyId), isFalse);
        expect(preferences.containsKey(ownKey), isFalse);
        expect(platform.requests.containsKey(otherId), isTrue);
        expect(platform.active.containsKey(otherId), isTrue);
        expect(preferences.getString(otherKey), jsonEncode([otherId]));
        expect(platform.requests.length, deleted ? 1 : 2);
      },
    );
  }

  test(
    'legacy person registry cannot cancel a different protected grant',
    () async {
      const id = 987654;
      final key = '${NotificationService.legacyIdsPreferencePrefix}$_profileId';
      await preferences.setString(key, jsonEncode([id]));
      platform.requests[id] = PlatformReminderRequest(
        id: id,
        title: 'Other grant reminder',
        body: 'Private',
        payload: jsonEncode({
          'projectionId': 'other-projection',
          'occurrenceId': 'other-occurrence',
          'userId': 'other-owner',
          'sessionGeneration': 1,
        }),
      );

      final report = await makeReconciler().reconcile(
        identity: (_userId, generation),
      );

      expect(platform.requests.containsKey(id), isTrue);
      expect(preferences.getString(key), jsonEncode([id]));
      expect(report!.degraded, isTrue);
    },
  );

  test(
    'upgrades an old pending action presentation without changing its dose identity',
    () async {
      final reconciler = makeReconciler();
      await reconciler.reconcile(identity: (_userId, generation));
      final original = platform.scheduled.single;

      final registry = ProjectionRegistry(preferences).read();
      registry[original.notificationId]!.remove('actionPresentationVersion');
      await ProjectionRegistry(preferences).persist(registry);
      platform.scheduled.clear();

      await reconciler.reconcile(identity: (_userId, generation));

      final upgraded = platform.scheduled.single;
      expect(upgraded.notificationId, original.notificationId);
      expect(upgraded.projectionId, original.projectionId);
      expect(upgraded.payload, original.payload);
      expect(upgraded.scheduledAtUtc, original.scheduledAtUtc);
    },
  );

  for (final change in [
    'none',
    'private',
    'version',
    'completed',
    'missed',
    'privacy',
    'disabled',
    'deleted',
    'visible mismatch',
  ]) {
    test(
      'ordinary reconciliation retains delivered dose only while current: $change',
      () async {
        final access = await protect();
        final context = (await access.contextForOwner(_userId))!;
        if (change == 'private') {
          await ReminderPreferencesRepository(
            database: db,
            access: access,
            context: context,
          ).setFullDetails(false);
        }
        var now = _now;
        final reconciler = protectedReconciler(access, clock: () => now);
        await reconciler.reconcile(
          projectionIdentity: ProjectionIdentity.fromContext(context),
        );
        final original = platform.scheduled.single;
        now = _now.add(const Duration(minutes: 21));
        platform.requests.clear();
        platform.active[original.notificationId] = PlatformActiveReminder(
          id: original.notificationId,
          title: original.title,
          body: change == 'visible mismatch'
              ? 'unrelated content'
              : original.body,
          channelId: 'dose_reminders',
        );
        if (change == 'version') {
          await db.customUpdate(
            "UPDATE medication_occurrences SET state_version=state_version+1 WHERE id='occurrence-a'",
            updates: {db.medicationOccurrences},
          );
        } else if (change == 'completed' || change == 'missed') {
          // A dose recorded as missed stops alerting exactly like a taken one.
          final state = change == 'missed' ? 'missed' : 'taken';
          await db.customUpdate(
            "UPDATE medication_occurrences SET state='$state', state_version=state_version+1 WHERE id='occurrence-a'",
            updates: {db.medicationOccurrences},
          );
        } else if (change == 'privacy') {
          await ReminderPreferencesRepository(
            database: db,
            access: access,
            context: context,
          ).setFullDetails(false);
        } else if (change == 'disabled') {
          await db.customUpdate(
            "UPDATE device_person_reminders SET enabled=0 WHERE profile_id='$_profileId'",
            updates: {db.devicePersonReminders},
          );
        } else if (change == 'deleted') {
          await db.customUpdate(
            "UPDATE profiles SET is_deleted=1 WHERE id='$_profileId'",
            updates: {db.profiles},
          );
        }
        await reconciler.reconcile(
          projectionIdentity: ProjectionIdentity.fromContext(context),
        );
        expect(
          platform.active.containsKey(original.notificationId),
          change == 'none' || change == 'private',
        );
        expect(
          platform.cancelled.contains(original.notificationId),
          change != 'none' && change != 'private',
        );
        expect(platform.scheduled, hasLength(1));
        expect(
          await db.medicationLedgerDao.getEventsForOccurrence('occurrence-a'),
          isEmpty,
        );
        if (change == 'none' || change == 'private') {
          expect(
            platform.active[original.notificationId]!.title,
            original.title,
          );
          expect(
            ProjectionRegistry(
              preferences,
            ).read()[original.notificationId]!['projectionId'],
            original.projectionId,
          );
        }
      },
    );
  }

  test(
    'locked action refresh keeps an eligible active dose during reconcile and retries failure',
    () async {
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      var now = _now;
      final scheduled = protectedReconciler(access, clock: () => now);
      await scheduled.reconcile(
        projectionIdentity: ProjectionIdentity.fromContext(context),
      );
      final original = platform.scheduled.single;
      final registry = ProjectionRegistry(preferences).read();
      registry[original.notificationId]!.remove('actionPresentationVersion');
      await ProjectionRegistry(preferences).persist(registry);

      now = _now.add(const Duration(minutes: 21));
      platform.requests
          .clear(); // Android moved the fired notification to active.
      final capturedEnvelopes = <Map<String, Object?>>[];
      var bridgeAttempts = 0;
      final reconciler = protectedReconciler(
        access,
        clock: () => now,
        refreshActiveActions:
            ({required List<Map<String, Object?>> envelopes}) async {
              bridgeAttempts++;
              capturedEnvelopes.addAll(envelopes);
              if (bridgeAttempts == 1) {
                throw StateError('native refresh unavailable');
              }
              return ActiveNotificationActionRefreshResult(
                activeIds: {original.notificationId},
                refreshedIds: {original.notificationId},
                skippedIds: const {},
                failedIds: const {},
              );
            },
      );

      await reconciler.reconcileAll(refreshActiveActions: true);
      expect(platform.cancelled, isEmpty);
      expect(capturedEnvelopes.single['id'], original.notificationId);
      expect(capturedEnvelopes.single['payload'], original.payload);
      expect(
        ProjectionRegistry(
          preferences,
        ).read()[original.notificationId]!['actionPresentationVersion'],
        isNull,
      );

      await reconciler.reconcileAll(refreshActiveActions: true);
      expect(bridgeAttempts, 2);
      expect(platform.cancelled, isEmpty);
      expect(
        ProjectionRegistry(
          preferences,
        ).read()[original.notificationId]!['actionPresentationVersion'],
        reminderActionPresentationVersion,
      );
    },
  );

  test(
    'retains current active follow-up and snooze notices during action upgrade',
    () async {
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      final identity = ProjectionIdentity.fromContext(context);
      var now = _now;
      await ReminderPreferencesRepository(
        database: db,
        access: access,
        context: context,
      ).setSchedule(_scheduleId, ScheduleReminderChoice(followUpMinutes: [10]));
      final reconciler = protectedReconciler(access, clock: () => now);
      await reconciler.reconcile(projectionIdentity: identity);
      final planned = platform.scheduled.first;
      expect(
        await reconciler.scheduleSnooze(
          identity: (_userId, context.accessEpoch),
          occurrenceId: planned.occurrenceId,
          delay: const Duration(minutes: 15),
          localizations: AppLocalizationsEn(),
          projectionIdentity: identity,
          deliveredStateVersion: planned.stateVersion!,
        ),
        isTrue,
      );
      final originalIds = platform.scheduled
          .map((reminder) => reminder.notificationId)
          .toSet();
      final registry = ProjectionRegistry(preferences).read();
      for (final id in originalIds) {
        registry[id]!.remove('actionPresentationVersion');
      }
      await ProjectionRegistry(preferences).persist(registry);

      now = _now.add(const Duration(minutes: 31));
      platform.requests.clear();
      final captured = <Map<String, Object?>>[];
      final upgrader = protectedReconciler(
        access,
        clock: () => now,
        refreshActiveActions:
            ({required List<Map<String, Object?>> envelopes}) async {
              captured.addAll(envelopes);
              final ids = envelopes.map((item) => item['id'] as int).toSet();
              return ActiveNotificationActionRefreshResult(
                activeIds: ids,
                refreshedIds: ids,
                skippedIds: const {},
                failedIds: const {},
              );
            },
      );

      await upgrader.reconcileAll(refreshActiveActions: true);

      final delivered = captured
          .map(
            (item) =>
                jsonDecode(item['payload']! as String) as Map<String, dynamic>,
          )
          .toList();
      expect(captured.map((item) => item['id']).toSet(), originalIds);
      expect(delivered.any((item) => item['followUpMinutes'] == 10), isTrue);
      final snoozeProjectionId = reminderProjectionId(
        userId: context.ownerUserId,
        sessionGeneration: context.accessEpoch,
        occurrenceId: planned.occurrenceId,
        kind: 'snooze',
        workspaceId: context.workspaceId,
        grantEpoch: context.accessEpoch,
        stateVersion: planned.stateVersion,
      );
      expect(
        captured.map((item) => item['id']),
        contains(notificationIdForProjection(snoozeProjectionId)),
      );
      expect(platform.cancelled, isEmpty);
    },
  );

  test(
    'device eligibility survives viewer selection and ignores legacy active flags',
    () async {
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      await db.customUpdate(
        "UPDATE profiles SET is_active=0 WHERE id='$_profileId'",
        updates: {db.profiles},
      );
      await access.viewPerson(context, null, everyone: true);
      await protectedReconciler(
        access,
      ).reconcile(projectionIdentity: ProjectionIdentity.fromContext(context));
      expect(platform.requests, hasLength(1));
      expect(
        ProjectionIdentity.fromJson(
          jsonDecode(platform.requests.values.single.payload!),
        ),
        ProjectionIdentity.fromContext(context),
      );
      await db.customUpdate(
        "UPDATE device_person_reminders SET enabled=0 WHERE profile_id='$_profileId'",
        updates: {db.devicePersonReminders},
      );
      await protectedReconciler(
        access,
      ).reconcile(projectionIdentity: ProjectionIdentity.fromContext(context));
      expect(platform.requests, isEmpty);
    },
  );

  test('deleting a person retires their pending reminder alarms', () async {
    final access = await protect();
    final context = (await access.contextForOwner(_userId))!;
    final identity = ProjectionIdentity.fromContext(context);
    final reconciler = protectedReconciler(access);
    final initial = await reconciler.reconcile(projectionIdentity: identity);

    expect(initial?.scheduledCount, 1);
    expect(platform.requests, hasLength(1));

    final repository = ProfileRepositoryImpl(
      dao: db.profilesDao,
      pendingOperations: PendingOperationRepository(db),
      userId: _userId,
      access: access,
      context: context,
      reconcileProjections: () async {
        await reconciler.reconcile(projectionIdentity: identity);
      },
    );
    expect(await repository.delete(_profileId), isA<Ok<void>>());

    expect(platform.requests, isEmpty);
    expect(platform.cancelled, hasLength(1));
  });

  test(
    'revocation during a platform effect removes its stale result',
    () async {
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      platform.scheduleGate = Completer<void>();
      final run = protectedReconciler(
        access,
      ).reconcile(projectionIdentity: ProjectionIdentity.fromContext(context));
      await platform.scheduleStarted.future;
      try {
        await access.revokeNetwork().timeout(const Duration(seconds: 1));
        expect(await access.contextForOwner(_userId), isNull);
      } finally {
        platform.scheduleGate!.complete();
      }
      final report = await run;
      expect(report?.degraded, isTrue);
      expect(platform.requests, isEmpty);
    },
  );

  test(
    'an old snooze cannot acquire a reauthenticated grant for the same owner',
    () async {
      final access = await protect();
      final old = (await access.contextForOwner(_userId))!;
      final transition = await access.revokeNetwork();
      const endpoint = 'https://fictional.test/care';
      await db
          .into(db.credentialSlots)
          .insert(
            CredentialSlotsCompanion.insert(
              id: 'fictional-new-staged',
              ownerId: _userId,
              endpoint: endpoint,
              state: 'staged',
              createdAt: _now,
            ),
          );
      await access.authenticate(
        ownerId: _userId,
        endpoint: endpoint,
        expectedNetworkEpoch: transition,
        sessionGeneration: old.sessionGeneration! + 1,
        credentialId: 'fictional-new-staged',
      );
      expect(
        await protectedReconciler(access).scheduleSnooze(
          identity: (_userId, old.sessionGeneration!),
          occurrenceId: 'occurrence-a',
          delay: const Duration(minutes: 15),
          localizations: AppLocalizationsEn(),
        ),
        isFalse,
      );
      expect(platform.requests, isEmpty);
    },
  );

  test(
    'care changed while waiting for the gate cannot publish an obsolete plan',
    () async {
      final gate = _ObservedGate();
      final access = await protect(effectsGate: gate);
      final context = (await access.contextForOwner(_userId))!;
      final entered = Completer<void>();
      final release = Completer<void>();
      final held = gate.run(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final requested = Completer<void>();
      gate.onRequested = () {
        if (!requested.isCompleted) requested.complete();
      };
      final run = protectedReconciler(
        access,
      ).reconcile(projectionIdentity: ProjectionIdentity.fromContext(context));
      await requested.future;
      try {
        await db.customUpdate(
          "UPDATE device_person_reminders SET enabled=0 WHERE profile_id='$_profileId'",
          updates: {db.devicePersonReminders},
        );
      } finally {
        release.complete();
      }
      await held;
      await run;
      expect(platform.scheduled, isEmpty);
      expect(platform.requests, isEmpty);
    },
  );

  test(
    'a dose recorded during scheduling removes the obsolete reminder result',
    () async {
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      platform.scheduleGate = Completer<void>();
      final run = protectedReconciler(
        access,
      ).reconcile(projectionIdentity: ProjectionIdentity.fromContext(context));
      await platform.scheduleStarted.future;
      try {
        await db.customUpdate(
          "UPDATE medication_occurrences SET state='taken', state_version=state_version+1 WHERE id='occurrence-a'",
          updates: {db.medicationOccurrences},
        );
      } finally {
        platform.scheduleGate!.complete();
      }
      await run;
      expect(platform.requests, isEmpty);
    },
  );

  test(
    'a dose committed on another SQLite connection cancels a stale alarm',
    () async {
      await reopenFileBacked();
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      platform.scheduleGate = Completer<void>();
      final run = protectedReconciler(
        access,
      ).reconcile(projectionIdentity: ProjectionIdentity.fromContext(context));
      await platform.scheduleStarted.future;
      final file = File('${fileBackedScratch!.path}/care.db');
      final external = sqlite.sqlite3.open(file.path);
      try {
        external.execute(
          "UPDATE medication_occurrences SET state='taken', state_version=state_version+1 WHERE id='occurrence-a'",
        );
        expect(
          external
              .select(
                "SELECT state FROM medication_occurrences WHERE id='occurrence-a'",
              )
              .single['state'],
          'taken',
        );
      } finally {
        external.close();
        platform.scheduleGate!.complete();
      }

      await run;

      final scheduledId = platform.scheduled.single.notificationId;
      expect(platform.cancelled, contains(scheduledId));
      expect(platform.requests, isNot(contains(scheduledId)));
    },
  );

  test(
    'a care change inside the snapshot revision bracket prevents scheduling',
    () async {
      final counter = _OccurrenceSnapshotCounter();
      await reopenFileBacked(interceptor: counter);
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      counter.reads = 0;
      counter.revisionReads = 0;
      final file = File('${fileBackedScratch!.path}/care.db');
      final external = sqlite.sqlite3.open(file.path);
      counter.beforeSecondRevisionRead = () {
        external.execute(
          "UPDATE medication_occurrences SET state='taken', state_version=state_version+1 WHERE id='occurrence-a'",
        );
      };
      try {
        final report = await protectedReconciler(access).reconcile(
          projectionIdentity: ProjectionIdentity.fromContext(context),
        );

        expect(report?.degraded, isTrue);
        expect(counter.revisionReads, 2);
        expect(counter.snapshotsBeforeSecondRevision, 2);
        expect(
          platform.events.where((event) => event.startsWith('schedule:')),
          isEmpty,
        );
        expect(platform.requests, isEmpty);
        expect(
          external
              .select(
                "SELECT state FROM medication_occurrences WHERE id='occurrence-a'",
              )
              .single['state'],
          'taken',
        );
      } finally {
        external.close();
      }
    },
  );

  test(
    'unchanged multi-alarm reconciliation reuses the validated care snapshot',
    () async {
      await insertOccurrence('occurrence-b', minutesFromNow: 30);
      await insertOccurrence('occurrence-c', minutesFromNow: 40);
      final counter = _OccurrenceSnapshotCounter();
      await reopenFileBacked(interceptor: counter);
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      counter.reads = 0;

      final report = await protectedReconciler(
        access,
      ).reconcile(projectionIdentity: ProjectionIdentity.fromContext(context));

      expect(report?.scheduledCount, 3);
      expect(platform.requests, hasLength(3));
      expect(
        counter.reads,
        lessThanOrEqualTo(2),
        reason:
            'one preparation snapshot and one initial validation should cover the whole unchanged batch',
      );
      expect(counter.reads, greaterThanOrEqualTo(1));
    },
  );

  test('snooze rejects a snapshot naming a different enabled person', () async {
    final access = await protect();
    final context = (await access.contextForOwner(_userId))!;
    await db.profilesDao.upsert(
      (await db.profilesDao.getById(_profileId))!
          .copyWith(id: 'fictional-other-person', name: 'Another person')
          .toCompanion(false),
    );
    await db
        .into(db.devicePersonReminders)
        .insert(
          DevicePersonRemindersCompanion.insert(
            profileId: 'fictional-other-person',
            enabled: const Value(true),
          ),
        );
    final occurrence = (await db.medicationLedgerDao.getOccurrenceById(
      'occurrence-a',
    ))!;
    final snapshot =
        jsonDecode(occurrence.scheduleSnapshotJson) as Map<String, dynamic>;
    snapshot['profileId'] = 'fictional-other-person';
    await db.medicationLedgerDao.upsertOccurrence(
      occurrence
          .copyWith(scheduleSnapshotJson: jsonEncode(snapshot))
          .toCompanion(false),
    );
    expect(
      await protectedReconciler(access).scheduleSnooze(
        identity: (_userId, context.accessEpoch),
        projectionIdentity: ProjectionIdentity.fromContext(context),
        deliveredStateVersion: 0,
        occurrenceId: 'occurrence-a',
        delay: const Duration(minutes: 15),
        localizations: AppLocalizationsEn(),
      ),
      isFalse,
    );
    expect(platform.requests, isEmpty);
  });

  test(
    'late retired-account cleanup preserves another owner and local projections',
    () async {
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      final reconciler = protectedReconciler(access);
      await reconciler.reconcile(
        projectionIdentity: ProjectionIdentity.fromContext(context),
      );
      final accountId = platform.requests.keys.single;
      final local = await access.currentContext();
      final standalone = await access.workspaces.ensureLocal();
      final localContext = (await access.contextForOwner(
        standalone.ownerUserId,
      ))!;
      expect(local.kind, WorkspaceKind.connected);
      final localPayload = {
        ...ProjectionIdentity.fromContext(localContext).toJson(),
        'occurrenceId': 'fictional-local-occurrence',
        'projectionId': 'fictional-local-projection',
        'sessionGeneration': localContext.accessEpoch,
      };
      final newerPayload = {
        'version': 2,
        'workspaceId': 'fictional-newer-workspace',
        'userId': 'fictional-newer-owner',
        'grantEpoch': 7,
        'occurrenceId': 'fictional-newer-occurrence',
        'projectionId': 'fictional-newer-projection',
        'sessionGeneration': 7,
      };
      final registry =
          jsonDecode(
                preferences.getString('notification_projection_registry_v1')!,
              )
              as List;
      for (final item in [(17, localPayload), (18, newerPayload)]) {
        platform.requests[item.$1] = PlatformReminderRequest(
          id: item.$1,
          title: 'Retained',
          body: 'Care',
          payload: jsonEncode(item.$2),
        );
        registry.add({'id': item.$1, 'kind': 'reminder', ...item.$2});
      }
      await preferences.setString(
        'notification_projection_registry_v1',
        jsonEncode(registry),
      );
      await access.revokeNetwork();
      await reconciler.retire(ProjectionIdentity.fromContext(context));
      expect(platform.requests.keys, unorderedEquals([17, 18]));
      expect(platform.cancelled, contains(accountId));
      expect(platform.cancelled, isNot(contains(17)));
      expect(platform.cancelled, isNot(contains(18)));
      final retained =
          jsonDecode(
                preferences.getString('notification_projection_registry_v1')!,
              )
              as List;
      expect(retained.map((item) => item['id']), unorderedEquals([17, 18]));
      await access.requireCurrent(localContext);
    },
  );

  test(
    'startup sweep retires revoked projections and keeps local stock alerts',
    () async {
      final access = await protect();
      final context = await access.currentContext();
      final reconciler = protectedReconciler(access);
      await reconciler.reconcile(
        projectionIdentity: ProjectionIdentity.fromContext(context),
      );
      final retiredIds = platform.requests.keys.toSet();
      final localWorkspace = await access.workspaces.ensureLocal();
      final local = (await access.contextForOwner(localWorkspace.ownerUserId))!;
      final localEntry = <String, Object?>{
        ...ProjectionIdentity.fromContext(local).toJson(),
        'id': 17,
        'projectionId': 'fictional-local-projection',
        'pillId': 'fictional-local-pill',
        'sessionGeneration': local.accessEpoch,
        'kind': 'lowStock',
      };
      final registry =
          jsonDecode(
                preferences.getString('notification_projection_registry_v1')!,
              )
              as List;
      registry.add(localEntry);
      await preferences.setString(
        'notification_projection_registry_v1',
        jsonEncode(registry),
      );
      platform.requests[17] = PlatformReminderRequest(
        id: 17,
        title: 'Local',
        body: '',
        payload: jsonEncode(localEntry),
      );
      await access.revokeNetwork();
      await reconciler.reconcileAll();
      expect(platform.cancelled.toSet(), containsAll(retiredIds));
      expect(platform.cancelled, isNot(contains(17)));
      expect(platform.requests.keys, [17]);
      final remaining =
          jsonDecode(
                preferences.getString('notification_projection_registry_v1')!,
              )
              as List;
      expect(
        remaining.any(
          (entry) => ProjectionIdentity.fromContext(context).owns(entry),
        ),
        isFalse,
      );
      await access.requireCurrent(local);
    },
  );

  test(
    'restart sweep preserves unknown grants and the complete registry',
    () async {
      final access = await protect();
      final context = await access.currentContext();
      final reconciler = protectedReconciler(access);
      await reconciler.reconcile(
        projectionIdentity: ProjectionIdentity.fromContext(context),
      );
      final registry =
          jsonDecode(
                preferences.getString('notification_projection_registry_v1')!,
              )
              as List;
      registry.add({
        'version': 2,
        'workspaceId': 'unknown',
        'userId': 'unknown',
        'grantEpoch': 1,
        'sessionGeneration': 1,
        'kind': 'reminder',
        'id': 17,
        'occurrenceId': 'unknown',
        'projectionId': 'unknown',
      });
      final raw = jsonEncode(registry);
      await preferences.setString('notification_projection_registry_v1', raw);
      await access.revokeNetwork();
      // The unknown grant is skipped and counted instead of aborting the
      // sweep; it and nothing else of the registry is left behind.
      expect(await reconciler.retireUnavailable(), 1);
      expect(platform.cancelled, isNot(contains(17)));
      final kept =
          jsonDecode(
                preferences.getString('notification_projection_registry_v1')!,
              )
              as List;
      expect(kept, hasLength(1));
      expect((kept.single as Map)['userId'], 'unknown');
    },
  );
  test(
    'restart sweep removes a revoked orphan payload without a registry row',
    () async {
      final access = await protect();
      final context = await access.currentContext();
      final reconciler = protectedReconciler(access);
      await reconciler.reconcile(
        projectionIdentity: ProjectionIdentity.fromContext(context),
      );
      final id = platform.requests.keys.single;
      await preferences.setString('notification_projection_registry_v1', '[]');
      await access.revokeNetwork();
      await reconciler.retireUnavailable();
      expect(platform.cancelled, [id]);
      expect(platform.requests, isEmpty);
    },
  );
  test(
    'restart sweep does not cancel another grant occupying a stale registry id',
    () async {
      final access = await protect();
      final context = await access.currentContext();
      final reconciler = protectedReconciler(access);
      await reconciler.reconcile(
        projectionIdentity: ProjectionIdentity.fromContext(context),
      );
      final id = platform.requests.keys.single;
      final localWorkspace = await access.workspaces.ensureLocal();
      final local = (await access.contextForOwner(localWorkspace.ownerUserId))!;
      final payload = {
        ...ProjectionIdentity.fromContext(local).toJson(),
        'projectionId': 'local-projection',
      };
      platform.requests[id] = PlatformReminderRequest(
        id: id,
        title: 'Local',
        body: '',
        payload: jsonEncode(payload),
      );
      await access.revokeNetwork();
      await reconciler.retireUnavailable();
      expect(platform.cancelled, isEmpty);
      expect(platform.requests[id]?.payload, jsonEncode(payload));
      expect(
        jsonDecode(
          preferences.getString('notification_projection_registry_v1')!,
        ),
        isEmpty,
      );
    },
  );

  test(
    'dose reconciliation preserves the same workspace stock alert registry',
    () async {
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      final stock = {
        'id': 17,
        'kind': 'lowStock',
        ...ProjectionIdentity.fromContext(context).toJson(),
        'pillId': _pillId,
        'projectionId': 'fictional-stock-projection',
        'sessionGeneration': context.accessEpoch,
      };
      await preferences.setString(
        'notification_projection_registry_v1',
        jsonEncode([stock]),
      );
      platform.requests[17] = PlatformReminderRequest(
        id: 17,
        title: 'Stock',
        body: 'Care',
        payload: jsonEncode(stock),
      );
      await protectedReconciler(
        access,
      ).reconcile(projectionIdentity: ProjectionIdentity.fromContext(context));
      expect(platform.requests[17], isNotNull);
      final registry =
          jsonDecode(
                preferences.getString('notification_projection_registry_v1')!,
              )
              as List;
      expect(registry.any((entry) => entry['kind'] == 'lowStock'), isTrue);
      expect(platform.cancelled, isNot(contains(17)));
    },
  );

  test(
    'unreadable registry cannot become an empty registry and lose ownership',
    () async {
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      const retained = '{unfinished-registry';
      await preferences.setString(
        'notification_projection_registry_v1',
        retained,
      );
      final report = await protectedReconciler(
        access,
      ).reconcile(projectionIdentity: ProjectionIdentity.fromContext(context));
      expect(report?.degraded, isTrue);
      expect(
        preferences.getString('notification_projection_registry_v1'),
        retained,
      );
      expect(platform.scheduled, isEmpty);
    },
  );

  test(
    'repeated reconciliation reaches desired=actual without new IDs',
    () async {
      final reconciler = makeReconciler();

      final first = await reconciler.reconcile(identity: (_userId, generation));
      final second = await reconciler.reconcile(
        identity: (_userId, generation),
      );

      expect(platform.scheduled, hasLength(1));
      expect(platform.requests, hasLength(1));
      expect(platform.cancelled, isEmpty);
      expect(first?.state, ProjectionReconciliationState.current);
      expect(second?.scheduledCount, 1);
      expect(
        ProjectionReconciler.readStatus(
          preferences,
          _userId,
        )?.sessionGeneration,
        generation,
      );
    },
  );

  test(
    'reconciliation preserves projections belonging to another workspace',
    () async {
      final other = <String, Object?>{
        'id': 17,
        'kind': 'reminder',
        'projectionId': 'other-projection',
        'occurrenceId': 'other-occurrence',
        'userId': 'standalone-owner',
        'sessionGeneration': 1,
        'version': 2,
        'workspaceId': 'standalone-workspace',
        'grantEpoch': 1,
      };
      await preferences.setString(
        'notification_projection_registry_v1',
        jsonEncode([other]),
      );
      platform.requests[17] = PlatformReminderRequest(
        id: 17,
        title: 'Standalone',
        body: 'Care',
        payload: jsonEncode(other),
      );
      await makeReconciler().reconcile(identity: (_userId, generation));
      expect(platform.requests[17], isNotNull);
      expect(platform.cancelled, isNot(contains(17)));
      final registry =
          jsonDecode(
                preferences.getString('notification_projection_registry_v1')!,
              )
              as List;
      expect(
        registry.any((entry) => entry['workspaceId'] == 'standalone-workspace'),
        isTrue,
      );
    },
  );

  test('Android reminder capacity keeps the nearest 450 occurrences', () async {
    await insertCapacityOccurrences(450, startAtMinute: 60);

    final report = await makeReconciler().reconcile(
      identity: (_userId, generation),
    );

    expect(report?.coverageShortened, isTrue);
    expect(report?.availableCount, 451);
    expect(report?.scheduledCount, 450);
    expect(platform.requests, hasLength(450));
    expect(
      platform.scheduled.map((item) => item.occurrenceId),
      contains('capacity-448'),
    );
    expect(
      platform.scheduled.map((item) => item.occurrenceId),
      isNot(contains('capacity-449')),
    );
  });

  test(
    '448 foreign pending alarms leave two slots and stay untouched',
    () async {
      final foreignIds = <int>{};
      for (var index = 0; index < 448; index++) {
        final id = 0x70000000 + index;
        foreignIds.add(id);
        platform.requests[id] = PlatformReminderRequest(
          id: id,
          title: 'Foreign reminder',
          body: 'Unowned',
          payload: 'foreign:$index',
        );
      }
      await insertOccurrence('occurrence-b', minutesFromNow: 30);

      final report = await makeReconciler().reconcile(
        identity: (_userId, generation),
      );

      expect(report?.scheduledCount, 2);
      expect(platform.scheduled, hasLength(2));
      expect(platform.requests, hasLength(450));
      expect(platform.requests.keys, containsAll(foreignIds));
      expect(platform.cancelled, isEmpty);
    },
  );

  test(
    'workspace shares are equal and incumbents shrink before new alarms publish',
    () async {
      await insertCapacityOccurrences(225, startAtMinute: 100);
      final access = await protect();
      final connectedContext = (await access.contextForOwner(_userId))!;
      final reconciler = protectedReconciler(access);
      await reconciler.reconcile(
        projectionIdentity: ProjectionIdentity.fromContext(connectedContext),
      );
      expect(platform.requests, hasLength(226));

      final localWorkspace = await access.workspaces.ensureLocal();
      final localContext = (await access.contextForOwner(
        localWorkspace.ownerUserId,
      ))!;
      final profileRepository = ProfileRepositoryImpl(
        dao: db.profilesDao,
        pendingOperations: PendingOperationRepository(db),
        userId: localContext.ownerUserId,
        access: access,
        context: localContext,
        reconcileProjections: () async {},
      );
      final profile =
          (await profileRepository.create('Local fixture', '👤') as Ok<Profile>)
              .value;
      await profileRepository.setDeviceRemindersEnabled(profile.id, true);

      const localPillId = '00000000-0000-4000-8000-000000000011';
      const localScheduleId = '00000000-0000-4000-8000-000000000012';
      await db.pillsDao.upsert(
        PillsCompanion.insert(
          id: localPillId,
          profileId: profile.id,
          name: 'Local medicine',
          createdAt: _now,
          updatedAt: _now,
        ),
      );
      await db.schedulesDao.upsert(
        SchedulesCompanion.insert(
          id: localScheduleId,
          pillId: localPillId,
          hour: 8,
          minute: 0,
          frequency: 'prn',
          createdAt: _now,
          updatedAt: _now,
        ),
      );
      for (var index = 0; index < 225; index++) {
        final occurrenceId =
            'local-occurrence-${index.toString().padLeft(3, '0')}';
        final snapshot = ScheduleSnapshotV1(
          pillName: 'Local medicine',
          dosage: null,
          frequency: 'daily',
          frequencyDays: null,
          hour: 8,
          minute: 0,
          timeZone: 'UTC',
          profileId: profile.id,
          profileName: 'Local fixture',
        );
        await db.medicationLedgerDao.upsertOccurrence(
          MedicationOccurrencesCompanion.insert(
            id: occurrenceId,
            userId: localContext.ownerUserId,
            pillId: const Value(localPillId),
            scheduleId: const Value(localScheduleId),
            occurrenceKey: 'scheduled:v1:$occurrenceId',
            source: 'scheduled',
            scheduleRevision: const Value(1),
            plannedLocalDate: '2026-09-24',
            plannedLocalTime: const Value('08:00'),
            timeZone: 'UTC',
            plannedAt: Value(_now.add(Duration(minutes: 100 + index))),
            expected: const Value(true),
            scheduleSnapshotJson: jsonEncode(snapshot.toJson()),
            provenance: 'exact',
            createdAt: _now,
            updatedAt: _now,
          ),
        );
      }
      final incumbentIds = platform.requests.keys.toSet();
      platform.events.clear();

      await reconciler.reconcileAll();

      final ownerCounts = <String, int>{};
      for (final request in platform.requests.values) {
        final payload = jsonDecode(request.payload!) as Map<String, dynamic>;
        final owner = payload['userId'] as String;
        ownerCounts[owner] = (ownerCounts[owner] ?? 0) + 1;
      }
      final connectedReport = ProjectionReconciler.readStatus(
        preferences,
        _userId,
      );
      final localReport = ProjectionReconciler.readStatus(
        preferences,
        localContext.ownerUserId,
      );
      final lastIncumbentRetirement = platform.events
          .asMap()
          .entries
          .where((entry) {
            if (!entry.value.startsWith('cancel:')) return false;
            return incumbentIds.contains(
              int.parse(entry.value.substring('cancel:'.length)),
            );
          })
          .map((entry) => entry.key)
          .reduce((left, right) => left > right ? left : right);
      final firstLocalAddition = platform.events.indexWhere(
        (event) => event == 'schedule:local-occurrence-000',
      );

      expect(ownerCounts[_userId], 225);
      expect(ownerCounts[localContext.ownerUserId], 225);
      expect(platform.requests, hasLength(450));
      expect(connectedReport?.scheduledCount, 225);
      expect(connectedReport?.coverageShortened, isTrue);
      expect(localReport?.scheduledCount, 225);
      expect(firstLocalAddition, greaterThan(lastIncumbentRetirement));
    },
  );

  test(
    'retires a displaced future alarm before scheduling a nearer one',
    () async {
      await insertCapacityOccurrences(449, startAtMinute: 100);
      final reconciler = makeReconciler();
      await reconciler.reconcile(identity: (_userId, generation));
      final displaced = platform.scheduled.singleWhere(
        (item) => item.occurrenceId == 'capacity-448',
      );
      await insertOccurrence('capacity-nearest', minutesFromNow: 1);
      platform.events.clear();

      final report = await reconciler.reconcile(
        identity: (_userId, generation),
      );

      final cancellationIndex = platform.events.indexOf(
        'cancel:${displaced.notificationId}',
      );
      final additionIndex = platform.events.indexOf(
        'schedule:capacity-nearest',
      );
      expect(cancellationIndex, greaterThanOrEqualTo(0));
      expect(additionIndex, greaterThan(cancellationIndex));
      expect(platform.cancelled, contains(displaced.notificationId));
      expect(platform.requests, hasLength(450));
      expect(
        platform.scheduled.map((item) => item.occurrenceId),
        contains('capacity-nearest'),
      );
      expect(report?.scheduledCount, 450);
    },
  );

  test(
    'a failed capacity cancellation blocks an over-budget addition',
    () async {
      await insertCapacityOccurrences(449, startAtMinute: 100);
      final reconciler = makeReconciler();
      await reconciler.reconcile(identity: (_userId, generation));
      final displaced = platform.scheduled.singleWhere(
        (item) => item.occurrenceId == 'capacity-448',
      );
      await insertOccurrence('capacity-nearest', minutesFromNow: 1);
      platform.events.clear();
      platform.failNextCancel = true;

      final report = await reconciler.reconcile(
        identity: (_userId, generation),
      );

      expect(report?.degraded, isTrue);
      expect(platform.events, contains('cancel:${displaced.notificationId}'));
      expect(platform.requests, hasLength(450));
      expect(platform.requests.containsKey(displaced.notificationId), isTrue);
      expect(
        platform.scheduled.map((item) => item.occurrenceId),
        isNot(contains('capacity-nearest')),
      );
      expect(platform.cancelled, isNot(contains(displaced.notificationId)));
    },
  );

  test('snooze admission leaves room under the Android alarm limit', () async {
    for (var index = 0; index < 480; index++) {
      final id = 0x70000000 + index;
      platform.requests[id] = PlatformReminderRequest(
        id: id,
        title: 'Foreign alarm',
        body: 'Unowned',
        payload: 'foreign:$index',
      );
    }

    final admitted = await makeReconciler().scheduleSnooze(
      identity: (_userId, generation),
      occurrenceId: 'occurrence-a',
      delay: const Duration(minutes: 15),
      localizations: AppLocalizationsEn(),
    );

    expect(admitted, isFalse);
    expect(platform.scheduled, isEmpty);
    expect(platform.requests, hasLength(480));
    expect(platform.cancelled, isEmpty);
  });

  test(
    'a reminder becoming due during reconciliation remains delivered',
    () async {
      final prior = await makeReconciler().reconcile(
        identity: (_userId, generation),
      );
      expect(prior?.scheduledCount, 1);
      final priorId = platform.requests.keys.single;
      var clockReads = 0;
      DateTime movingClock() {
        clockReads++;
        return clockReads == 1 ? _now : _now.add(const Duration(minutes: 21));
      }

      final report = await ProjectionReconciler(
        database: db,
        preferences: preferences,
        generations: generations,
        platform: platform,
        platformKind: ReminderPlatformKind.android,
        clock: movingClock,
      ).reconcile(identity: (_userId, generation));

      expect(report?.availableCount, 1);
      expect(report?.scheduledCount, 0);
      expect(platform.requests.keys, contains(priorId));
      expect(platform.cancelled, isEmpty);
    },
  );

  test(
    'privacy downgrade retries a failed cancellation of an omitted public alert',
    () async {
      await insertCapacityOccurrences(450, startAtMinute: 60);
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      final identity = ProjectionIdentity.fromContext(context);
      final reconciler = protectedReconciler(access);
      final firstReport = await reconciler.reconcile(
        projectionIdentity: identity,
      );
      expect(firstReport?.coverageShortened, isTrue);
      final omittedRow = await (db.select(
        db.medicationOccurrences,
      )..where((row) => row.id.equals('capacity-449'))).getSingle();
      final omitted = const ReminderProjectionBuilder()
          .build(
            records: [
              MedicationOccurrenceRecord(
                occurrence: omittedRow,
                events: const [],
              ),
            ],
            activeProfileIds: {_profileId},
            userId: _userId,
            sessionGeneration: context.accessEpoch,
            now: _now,
            platform: ReminderPlatformKind.android,
            localizations: AppLocalizationsEn(),
            identity: identity,
            preferences: ReminderPreferences(),
          )
          .reminders
          .single;
      platform.requests[omitted.notificationId] = PlatformReminderRequest(
        id: omitted.notificationId,
        title: omitted.title,
        body: omitted.body,
        payload: omitted.payload,
      );
      final registry = ProjectionRegistry(preferences).read()
        ..[omitted.notificationId] = omitted.toRegistryEntry();
      await ProjectionRegistry(preferences).persist(registry);
      await ReminderPreferencesRepository(
        database: db,
        access: access,
        context: context,
      ).setFullDetails(false);
      platform.failNextCancel = true;
      platform.events.clear();

      final report = await reconciler.reconcile(projectionIdentity: identity);

      expect(report?.degraded, isTrue);
      expect(
        platform.events.where(
          (event) => event == 'cancel:${omitted.notificationId}',
        ),
        hasLength(2),
      );
      expect(platform.requests.containsKey(omitted.notificationId), isFalse);
      expect(platform.requests, hasLength(450));
    },
  );

  test('a failed addition leaves the last safe reminder in place', () async {
    final reconciler = makeReconciler();
    await reconciler.reconcile(identity: (_userId, generation));
    final priorId = platform.requests.keys.single;
    await insertOccurrence('occurrence-b', minutesFromNow: 30);
    platform.failNextSchedule = true;

    final report = await reconciler.reconcile(identity: (_userId, generation));

    expect(platform.requests.keys, contains(priorId));
    expect(platform.cancelled, isEmpty);
    expect(report?.degraded, isTrue);
    expect(report?.failedOperations, 1);
  });

  test(
    'overlapping requests coalesce and stale-generation work is removed',
    () async {
      final reconciler = makeReconciler();
      platform.scheduleGate = Completer<void>();
      final staleRun = reconciler.reconcile(identity: (_userId, generation));
      await platform.scheduleStarted.future;

      await generations.advanceTo(null);
      generation = await generations.advanceTo(_userId);
      final currentRun = reconciler.reconcile(identity: (_userId, generation));
      platform.scheduleGate!.complete();
      await Future.wait([staleRun, currentRun]);

      expect(platform.requests, hasLength(1));
      final payload =
          jsonDecode(platform.requests.values.single.payload!)
              as Map<String, dynamic>;
      expect(payload['sessionGeneration'], generation);
      expect(
        ProjectionReconciler.readStatus(
          preferences,
          _userId,
        )?.sessionGeneration,
        generation,
      );
    },
  );

  test(
    'permission loss reports degraded without cancelling existing state',
    () async {
      final reconciler = makeReconciler();
      await reconciler.reconcile(identity: (_userId, generation));
      final priorId = platform.requests.keys.single;
      platform.exactPermission = false;

      final report = await reconciler.reconcile(
        identity: (_userId, generation),
      );

      expect(report?.degraded, isTrue);
      expect(platform.requests.keys, contains(priorId));
      expect(platform.cancelled, isEmpty);
    },
  );

  test(
    'completion retires its alert even when exact access was revoked',
    () async {
      final reconciler = makeReconciler();
      await reconciler.reconcile(identity: (_userId, generation));
      final priorId = platform.requests.keys.single;
      final occurrenceId = platform.scheduled.single.occurrenceId;
      await (db.update(db.medicationOccurrences)
            ..where((row) => row.id.equals(occurrenceId)))
          .write(const MedicationOccurrencesCompanion(state: Value('taken')));
      platform.exactPermission = false;
      final report = await reconciler.reconcile(
        identity: (_userId, generation),
      );
      expect(report?.degraded, isTrue);
      expect(platform.cancelled, contains(priorId));
      expect(platform.requests, isEmpty);
    },
  );

  group('reminder self-healing', () {
    String legacyPayload(String schedule) => jsonEncode({
      'route': '/home?dose=$schedule',
      'scheduleId': schedule,
      'hour': 9,
      'minute': 0,
      'weekday': null,
    });

    void pending(int id, String? payload) {
      platform.requests[id] = PlatformReminderRequest(
        id: id,
        title: 'Synthetic',
        body: '',
        payload: payload,
      );
    }

    Future<int> settle(ProjectionReconciler reconciler) async {
      final result = await reconciler.reconcileAll();
      expect(result.healthy, isTrue);
      return platform.scheduled.single.notificationId;
    }

    test(
      'a duplicate legacy alarm is cancelled, the desired one stays',
      () async {
        final access = await protect();
        final reconciler = protectedReconciler(access);
        final desired = await settle(reconciler);
        await preferences.setString('notif_ids_$_userId', jsonEncode([987700]));
        pending(987700, legacyPayload(_scheduleId));
        pending(987701, '/home');
        pending(987702, null);

        final result = await protectedReconciler(access).reconcileAll();

        expect(result.audit?.ran, isTrue);
        expect(platform.requests.keys, [desired]);
        expect(platform.cancelled, containsAll([987700, 987701, 987702]));
      },
    );

    test('an unknown pending id is swept once old enough', () async {
      final access = await protect();
      final reconciler = protectedReconciler(access);
      final desired = await settle(reconciler);
      pending(987710, jsonEncode({'projectionId': 'nobody', 'x': 1}));
      await reconciler.reconcileAll();
      expect(platform.requests.keys, [desired]);
      expect(platform.cancelled, contains(987710));
    });

    test(
      'a very recent unknown id is left alone by the grace window',
      () async {
        final access = await protect();
        var now = _now;
        final reconciler = protectedReconciler(access, clock: () => now);
        await settle(reconciler);
        // Another isolate armed this id a moment ago: the ledger knows it.
        final ledger = ReminderIdLedger(preferences);
        await ledger.record([987720], now.subtract(const Duration(seconds: 5)));
        pending(987720, '/home');
        await reconciler.reconcileAll();
        expect(platform.requests.containsKey(987720), isTrue);
        now = now.add(const Duration(minutes: 5));
        await reconciler.reconcileAll();
        expect(platform.requests.containsKey(987720), isFalse);
      },
    );

    test(
      'a signed-out workspace is skipped, does not block the audit and is reported',
      () async {
        final access = await protect();
        final reconciler = protectedReconciler(access);
        await settle(reconciler);
        pending(987730, '/home');
        await access.revokeNetwork();
        final result = await reconciler.reconcileAll();
        expect(result.skippedWorkspaces, 1);
        expect(result.ready, isTrue);
        expect(result.audit?.ran, isTrue);
        expect(result.audit?.skippedWorkspaces, 1);
        expect(platform.requests.containsKey(987730), isFalse);
        final saved = ReminderAuditReport.fromJson(
          jsonDecode(preferences.getString(reminderAuditReportPreferenceKey)!),
        );
        expect(saved?.skippedWorkspaces, 1);
      },
    );

    test('nothing is swept when no workspace can be reached', () async {
      final access = await protect();
      final reconciler = protectedReconciler(access);
      await settle(reconciler);
      pending(987730, '/home');
      await access.revokeNetwork();
      await db.customStatement('UPDATE workspace_grants SET is_granted=0');
      final result = await reconciler.reconcileAll();
      expect(result.ready, isFalse);
      expect(result.audit?.ran, isFalse);
      expect(result.audit?.deferredReason, 'notReady');
      expect(platform.requests.containsKey(987730), isTrue);
    });

    test(
      'one invalid occurrence does not disable the audit or readiness',
      () async {
        final access = await protect();
        final reconciler = protectedReconciler(access);
        await settle(reconciler);
        await insertOccurrence('bad-zone', minutesFromNow: 90);
        await db.customStatement(
          "UPDATE medication_occurrences SET time_zone='Not/AZone', schedule_snapshot_json=replace(schedule_snapshot_json, '\"UTC\"', '\"Not/AZone\"') WHERE id='bad-zone'",
        );
        pending(987740, '/home');
        final result = await reconciler.reconcileAll();
        expect(result.invalidOccurrences, 1);
        expect(result.ready, isTrue);
        expect(result.audit?.ran, isTrue);
        expect(result.audit?.invalidOccurrences, 1);
        expect(platform.requests.containsKey(987740), isFalse);
      },
    );

    test('a stale ledger id is cancelled by number', () async {
      final access = await protect();
      final reconciler = protectedReconciler(access);
      await settle(reconciler);
      await ReminderIdLedger(
        preferences,
      ).record([987740], _now.subtract(const Duration(hours: 1)));
      await reconciler.reconcileAll();
      expect(platform.cancelled, contains(987740));
      expect(ReminderIdLedger(preferences).read().containsKey(987740), isFalse);
    });

    test(
      'active duplicates of one occurrence keep only the desired id',
      () async {
        final access = await protect();
        final reconciler = protectedReconciler(access);
        final desired = await settle(reconciler);
        final registry =
            (jsonDecode(
                      preferences.getString(
                        'notification_projection_registry_v1',
                      )!,
                    )
                    as List)
                .cast<Map<String, Object?>>();
        final entry = Map<String, Object?>.of(
          registry.firstWhere((e) => e['id'] == desired),
        );
        const stray = 987750;
        registry.add({...entry, 'id': stray});
        await preferences.setString(
          'notification_projection_registry_v1',
          jsonEncode(registry),
        );
        final payload = jsonEncode({
          'occurrenceId': entry['occurrenceId'],
          'projectionId': entry['projectionId'],
        });
        for (final id in [desired, stray]) {
          platform.active[id] = PlatformActiveReminder(
            id: id,
            title: 'Shown',
            body: '',
            channelId: currentReminderChannelId(),
            payload: payload,
          );
        }
        await reconciler.reconcileAll();
        expect(platform.active.keys, [desired]);
        expect(platform.cancelled, contains(stray));
      },
    );

    test('the upgrade sweep runs once per build', () async {
      final access = await protect();
      final reconciler = protectedReconciler(access);
      await preferences.setString('notif_ids_$_userId', jsonEncode([987760]));
      final first = await reconciler.reconcileAll(buildKey: '1.0.0+3');
      expect(first.audit?.strict, isTrue);
      expect(preferences.containsKey('notif_ids_$_userId'), isFalse);
      final again = await reconciler.reconcileAll(buildKey: '1.0.0+3');
      expect(again.audit?.strict, isFalse);
      final next = await reconciler.reconcileAll(buildKey: '1.0.0+4');
      expect(next.audit?.strict, isTrue);
    });

    test('retired channels are deleted only after the reschedule', () async {
      final access = await protect();
      await protectedReconciler(access).reconcileAll();
      final events = platform.events;
      final lastSchedule = events.lastIndexWhere(
        (e) => e.startsWith('schedule:'),
      );
      final deletion = events.indexOf('deleteRetiredChannels');
      expect(lastSchedule, isNonNegative);
      expect(deletion, greaterThan(lastSchedule));
    });

    test('channels are kept when the audit could not cancel a stray', () async {
      final access = await protect();
      final reconciler = protectedReconciler(access);
      await settle(reconciler);
      platform.events.clear();
      pending(987731, '/home');
      platform.failCancelIds.add(987731);
      final result = await reconciler.reconcileAll();
      expect(result.audit?.failed, greaterThan(0));
      expect(platform.events, isNot(contains('deleteRetiredChannels')));
    });

    test('a failed channel deletion does not fail the pass', () async {
      final access = await protect();
      platform.failChannelDeletion = true;
      final result = await protectedReconciler(access).reconcileAll();
      expect(result.ready, isTrue);
    });

    test('reset rebuilds exactly the desired set', () async {
      final access = await protect();
      final reconciler = protectedReconciler(access);
      final desired = await settle(reconciler);
      pending(987770, legacyPayload(_scheduleId));
      pending(987771, '/home');
      await preferences.setString('notif_ids_$_userId', jsonEncode([987772]));
      await ReminderIdLedger(
        preferences,
      ).record([987773], _now.subtract(const Duration(days: 3)));
      var stockChecks = 0;

      final result = await reconciler.resetReminders(
        recheckStock: () async => stockChecks++,
      );

      expect(result.succeeded, isTrue);
      expect(stockChecks, 1);
      expect(platform.requests.keys, [desired]);
      expect(platform.events, isNot(contains('cancelAll')));
      // Every id the books remember is cancelled by number before they go.
      expect(platform.cancelled, containsAll([987770, 987771, 987772, 987773]));
      expect(preferences.containsKey('notif_ids_$_userId'), isFalse);
      expect(
        ReminderIdLedger(preferences).read().keys,
        isNot(contains(987773)),
      );
      expect(ReminderIdLedger(preferences).read().keys, contains(desired));
      expect(
        platform.events.lastIndexOf('deleteRetiredChannels'),
        greaterThan(platform.events.lastIndexOf('cancel:987773')),
      );
    });

    test('reset keeps a list whose ids it could not cancel', () async {
      final access = await protect();
      final reconciler = protectedReconciler(access);
      await settle(reconciler);
      await preferences.setString('notif_ids_$_userId', jsonEncode([987774]));
      platform.failCancelIds.add(987774);
      final result = await reconciler.resetReminders();
      expect(result.succeeded, isFalse);
      expect(result.failure, ReminderResetFailure.clear);
      expect(preferences.containsKey('notif_ids_$_userId'), isTrue);
    });

    test('reset leaves a pending snooze armed', () async {
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      final reconciler = protectedReconciler(access);
      await settle(reconciler);
      final planned = platform.scheduled.first;
      expect(
        await reconciler.scheduleSnooze(
          identity: (_userId, context.accessEpoch),
          occurrenceId: planned.occurrenceId,
          delay: const Duration(minutes: 15),
          localizations: AppLocalizationsEn(),
          projectionIdentity: ProjectionIdentity.fromContext(context),
          deliveredStateVersion: planned.stateVersion!,
        ),
        isTrue,
      );
      final snoozeId = platform.requests.keys.singleWhere(
        (id) => id != planned.notificationId,
      );
      platform.cancelled.clear();
      final result = await reconciler.resetReminders();
      expect(result.succeeded, isTrue);
      expect(platform.cancelled, isNot(contains(snoozeId)));
      expect(platform.requests.keys, contains(snoozeId));
      expect(platform.requests.keys, contains(planned.notificationId));
    });

    test('a failed first rebuild is retried through the runner', () async {
      final access = await protect();
      final reconciler = protectedReconciler(access);
      final desired = await settle(reconciler);
      var passes = 0;
      final runner = ReminderReconcileRunner(
        pass: ({locale, refreshActiveActions = false, buildKey}) async {
          passes++;
          return passes == 1
              ? const ReconcileAllResult.failed()
              : reconciler.reconcileAll();
        },
        delay: (_) async {},
      );
      final result = await reconciler.resetReminders(
        rebuild: () => runner.run(),
      );
      expect(result.failure, ReminderResetFailure.rebuild);
      expect(result.restoring, isTrue);
      await pumpEventQueue();
      expect(passes, 2);
      expect(platform.requests.keys, [desired]);
    });

    test(
      'with one workspace ready and one failed, an unowned old alarm survives '
      'the audit until both are ready',
      () async {
        final access = await protect();
        await access.workspaces.ensureLocal();
        final reconciler = protectedReconciler(access);
        final desired = await settle(reconciler);
        pending(987792, '/home');
        // A stale reminder of the connected workspace that cannot be cancelled
        // leaves that workspace failed while the desired alarm stays armed.
        final registry =
            (jsonDecode(
                      preferences.getString(
                        'notification_projection_registry_v1',
                      )!,
                    )
                    as List)
                .cast<Map<String, Object?>>();
        const staleId = 987793;
        registry.add({
          ...registry.single,
          'id': staleId,
          'occurrenceId': 'stale-occurrence',
          'projectionId': 'stale-projection',
        });
        await preferences.setString(
          'notification_projection_registry_v1',
          jsonEncode(registry),
        );
        pending(staleId, jsonEncode(registry.last));
        platform.failNextCancel = true;

        final partial = await protectedReconciler(access).reconcileAll();

        // The local workspace is ready, so the audit runs; the connected one
        // failed, so the alarm that names no owner must not be judged yet.
        expect(partial.healthy, isFalse);
        expect(partial.audit?.ran, isTrue);
        expect(platform.cancelled, isNot(contains(987792)));
        expect(platform.requests.keys, contains(987792));

        final complete = await protectedReconciler(access).reconcileAll();

        expect(complete.healthy, isTrue);
        expect(platform.cancelled, contains(987792));
        expect(platform.requests.keys, [desired]);
      },
    );

    test('a failed rebuild queues the background retry task', () async {
      final access = await protect();
      final reconciler = protectedReconciler(access);
      await settle(reconciler);
      var queued = 0;
      final result = await reconciler.resetReminders(
        rebuild: () async => const ReconcileAllResult.failed(),
        scheduleRetry: () async => queued++,
      );
      expect(result.failure, ReminderResetFailure.rebuild);
      expect(queued, 1);
    });

    test('a healthy rebuild queues no retry task', () async {
      final access = await protect();
      final reconciler = protectedReconciler(access);
      await settle(reconciler);
      var queued = 0;
      final result = await reconciler.resetReminders(
        scheduleRetry: () async => queued++,
      );
      expect(result.succeeded, isTrue);
      expect(queued, 0);
    });

    test('reset refuses an unreadable registry and cancels nothing', () async {
      final access = await protect();
      final context = (await access.contextForOwner(_userId))!;
      final reconciler = protectedReconciler(access);
      await settle(reconciler);
      final planned = platform.scheduled.first;
      expect(
        await reconciler.scheduleSnooze(
          identity: (_userId, context.accessEpoch),
          occurrenceId: planned.occurrenceId,
          delay: const Duration(minutes: 15),
          localizations: AppLocalizationsEn(),
          projectionIdentity: ProjectionIdentity.fromContext(context),
          deliveredStateVersion: planned.stateVersion!,
        ),
        isTrue,
      );
      final armed = {...platform.requests.keys};
      await preferences.setString(
        'notification_projection_registry_v1',
        '{not json',
      );
      platform.cancelled.clear();

      final result = await reconciler.resetReminders();

      expect(result.succeeded, isFalse);
      expect(result.failure, ReminderResetFailure.registry);
      expect(platform.cancelled, isEmpty);
      expect(platform.requests.keys.toSet(), armed);
    });

    test(
      'a signed-out workspace does not stop reset from succeeding',
      () async {
        final access = await protect();
        final reconciler = protectedReconciler(access);
        await settle(reconciler);
        await access.revokeNetwork();
        final result = await reconciler.resetReminders();
        // The signed-out workspace's alarms are retired by the normal pass, not
        // by the reset's own clearing; the reset must not refuse over it.
        expect(result.failure, isNull);
      },
    );

    test(
      'reset reports a missing permission without touching alarms',
      () async {
        final access = await protect();
        final reconciler = protectedReconciler(access);
        await settle(reconciler);
        platform.exactPermission = false;
        final result = await reconciler.resetReminders();
        expect(result.failure, ReminderResetFailure.permission);
        expect(platform.events, isNot(contains('cancelAll')));
        expect(platform.cancelled, isEmpty);
      },
    );

    test(
      'a bad grant in retireUnavailable skips one identity, not all',
      () async {
        final access = await protect();
        await settle(protectedReconciler(access));
        await access.revokeNetwork();
        expect(await protectedReconciler(access).retireUnavailable(), 0);
      },
    );
  });

  group('sticky collision ids', () {
    Future<(String, String)> collidingPair(
      WorkspaceAccessRepository access,
    ) async {
      final reconciler = protectedReconciler(access);
      await reconciler.reconcileAll();
      final entry =
          (jsonDecode(
                    preferences.getString(
                      'notification_projection_registry_v1',
                    )!,
                  )
                  as List)
              .cast<Map<String, Object?>>()
              .single;
      String idOf(String occurrence) => reminderProjectionId(
        userId: entry['userId']! as String,
        sessionGeneration: entry['sessionGeneration']! as int,
        occurrenceId: occurrence,
        kind: 'reminder',
        workspaceId: entry['workspaceId'] as String?,
        grantEpoch: entry['grantEpoch'] as int?,
        stateVersion: entry['stateVersion'] as int?,
      );
      final seen = <int, String>{};
      for (var n = 0; ; n++) {
        final occurrence = 'collide-$n';
        final base = notificationIdForProjection(idOf(occurrence));
        final other = seen[base];
        if (other != null) {
          final a = idOf(other).compareTo(idOf(occurrence)) < 0;
          // (lower projection id, higher projection id)
          return a ? (other, occurrence) : (occurrence, other);
        }
        seen[base] = occurrence;
      }
    }

    Map<String, int> armed() => {
      for (final request in platform.requests.values)
        (jsonDecode(request.payload!) as Map)['occurrenceId'] as String:
            request.id,
    };

    test(
      'a new lower projection does not move the one already armed',
      () async {
        final access = await protect();
        final (lower, higher) = await collidingPair(access);
        await insertOccurrence(higher, minutesFromNow: 30);
        final reconciler = protectedReconciler(access);
        expect((await reconciler.reconcileAll()).healthy, isTrue);
        final held = armed()[higher]!;

        await insertOccurrence(lower, minutesFromNow: 31);
        final result = await reconciler.reconcileAll();

        expect(result.healthy, isTrue);
        expect(armed()[higher], held, reason: 'the armed alarm keeps its id');
        expect(armed().keys, containsAll([higher, lower]));
        expect(armed()[lower], isNot(held));
        expect(platform.requests, hasLength(3));
      },
    );

    test('when the lower projection goes away the other keeps its id', () async {
      final access = await protect();
      final (lower, higher) = await collidingPair(access);
      await insertOccurrence(lower, minutesFromNow: 30);
      await insertOccurrence(higher, minutesFromNow: 31);
      final reconciler = protectedReconciler(access);
      expect((await reconciler.reconcileAll()).healthy, isTrue);
      final held = armed()[higher]!;
      final lowerId = armed()[lower]!;

      await db.customUpdate(
        "UPDATE medication_occurrences SET state='taken', state_version=state_version+1 WHERE id=?",
        variables: [Variable(lower)],
        updates: {db.medicationOccurrences},
      );
      final result = await reconciler.reconcileAll();

      expect(result.healthy, isTrue);
      expect(armed()[higher], held);
      expect(platform.requests.containsKey(lowerId), lowerId == held);
      expect(armed().containsKey(lower), isFalse);
    });

    test(
      'a stale alarm of ours on the base id is retired, then scheduled',
      () async {
        final access = await protect();
        final (lower, _) = await collidingPair(access);
        final reconciler = protectedReconciler(access);
        final entry =
            (jsonDecode(
                      preferences.getString(
                        'notification_projection_registry_v1',
                      )!,
                    )
                    as List)
                .cast<Map<String, Object?>>()
                .single;
        // Plant an own, no longer wanted reminder on the new occurrence's id.
        final probeId = reminderProjectionId(
          userId: entry['userId']! as String,
          sessionGeneration: entry['sessionGeneration']! as int,
          occurrenceId: lower,
          kind: 'reminder',
          workspaceId: entry['workspaceId'] as String?,
          grantEpoch: entry['grantEpoch'] as int?,
          stateVersion: entry['stateVersion'] as int?,
        );
        final id = notificationIdForProjection(probeId);
        final registry =
            (jsonDecode(
                      preferences.getString(
                        'notification_projection_registry_v1',
                      )!,
                    )
                    as List)
                .cast<Map<String, Object?>>();
        registry.add({...entry, 'id': id, 'projectionId': 'stale-projection'});
        await preferences.setString(
          'notification_projection_registry_v1',
          jsonEncode(registry),
        );
        platform.requests[id] = PlatformReminderRequest(
          id: id,
          title: 'old',
          body: '',
          payload: jsonEncode({...entry, 'projectionId': 'stale-projection'}),
        );
        await insertOccurrence(lower, minutesFromNow: 40);
        final result = await reconciler.reconcileAll();
        expect(result.healthy, isTrue);
        expect(armed()[lower], id);
        expect(platform.cancelled, contains(id));
      },
    );
  });
}
