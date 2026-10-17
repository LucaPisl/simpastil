import 'dart:convert';
import 'dart:io' show Directory;

import 'package:drift/drift.dart' show Value, Variable;
import 'dart:ui' show Locale;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/notifications/notification_action_handler.dart';
import 'package:simpastil/core/notifications/notification_plugin.dart';
import 'package:simpastil/core/notifications/reminder_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/protection/access_gate.dart';
import 'package:simpastil/core/protection/app_lock_controller.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/projections/projection_reconciler.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/core/storage/preference_keys.dart';
import 'package:simpastil/core/projections/projection_identity.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/core/widget/widget_action_handler.dart';

const _userId = '00000000-0000-4000-8000-000000000001';
const _profileId = '00000000-0000-4000-8000-000000000010';
const _pillId = '00000000-0000-4000-8000-000000000011';
const _scheduleId = '00000000-0000-4000-8000-000000000012';
const _occurrenceId = '00000000-0000-4000-8000-000000000002';
const _generation = 3;
final _plannedAt = DateTime.utc(2026, 6, 11, 5);

class _ReminderPlatform implements ReminderNotificationPlatform {
  final requests = <int, PlatformReminderRequest>{};
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
  Future<void> cancel(int id) async {
    requests.remove(id);
  }

  @override
  Future<void> cancelAll() async {
    requests.clear();
  }

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
}

class _RevokingAccess extends WorkspaceAccessRepository {
  _RevokingAccess(super.database)
    : super(effectsGate: SerialProjectionEffectsGate());
  bool revokeOnResolve = false;
  @override
  Future<WorkspaceContext?> contextForOwner(String ownerId) async {
    final context = await super.contextForOwner(ownerId);
    if (revokeOnResolve) {
      revokeOnResolve = false;
      await revokeNetwork();
    }
    return context;
  }
}

late _RevokingAccess _access;
late WorkspaceContext _context;
int _slotCounter = 0;

String _projectionId({
  int? generation,
  String userId = _userId,
  bool legacy = false,
  int stateVersion = 0,
}) => reminderProjectionId(
  userId: userId,
  sessionGeneration:
      generation ?? (legacy ? _generation : _context.accessEpoch),
  occurrenceId: _occurrenceId,
  kind: 'widget',
  workspaceId: legacy ? null : _context.workspaceId,
  grantEpoch: legacy ? null : (generation ?? _context.accessEpoch),
  stateVersion: legacy ? null : stateVersion,
);

Uri _actionUri({
  String action = 'take',
  int? generation,
  String userId = _userId,
  String? projectionId,
  bool legacy = false,
  int stateVersion = 0,
}) => Uri(
  scheme: 'simpastil',
  host: action,
  queryParameters: {
    'active_user_id': userId,
    'session_generation':
        '${generation ?? (legacy ? _generation : _context.accessEpoch)}',
    'occurrenceId': _occurrenceId,
    'projectionId':
        projectionId ??
        _projectionId(
          generation: generation,
          userId: userId,
          legacy: legacy,
          stateVersion: stateVersion,
        ),
    if (!legacy) ...{
      'version': '2',
      'workspaceId': _context.workspaceId,
      'grantEpoch': '${generation ?? _context.accessEpoch}',
      'stateVersion': '$stateVersion',
    },
  },
);

Future<void> _protect(AppDatabase db) async {
  _access = _RevokingAccess(db);
  const endpoint = 'https://fictional-widget.test/care';
  final transition = await _access.configureEndpoint(endpoint);
  final slot = 'fictional-widget-${++_slotCounter}';
  await db
      .into(db.credentialSlots)
      .insert(
        CredentialSlotsCompanion.insert(
          id: slot,
          ownerId: _userId,
          endpoint: endpoint,
          state: 'staged',
          createdAt: _plannedAt,
        ),
      );
  final authenticated = await _access.authenticate(
    ownerId: _userId,
    endpoint: endpoint,
    expectedNetworkEpoch: transition,
    sessionGeneration: _generation,
    credentialId: slot,
  );
  if (authenticated.workspace.bindingState != 'bound') {
    await _access.confirmOriginalServer(
      workspaceId: authenticated.workspace.id,
      reviewedOriginalEndpoint: endpoint,
      expectedNetworkEpoch: authenticated.network.epoch,
    );
  }
  _context = (await _access.contextForOwner(_userId))!;
  await db
      .into(db.devicePersonReminders)
      .insertOnConflictUpdate(
        DevicePersonRemindersCompanion.insert(
          profileId: _profileId,
          enabled: const Value(true),
        ),
      );
}

Future<AppDatabase> _seededDb({bool protected = true}) async {
  final db = AppDatabase.forTesting();
  final now = DateTime.utc(2026, 6, 1);
  await db.usersDao.upsert(
    UsersCompanion.insert(
      id: _userId,
      email: 'widget@test.invalid',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await db.profilesDao.upsert(
    ProfilesCompanion.insert(
      id: _profileId,
      userId: _userId,
      name: 'Profile',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await db.pillsDao.upsert(
    PillsCompanion.insert(
      id: _pillId,
      profileId: _profileId,
      name: 'Medicine',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await db.schedulesDao.upsert(
    SchedulesCompanion.insert(
      id: _scheduleId,
      pillId: _pillId,
      hour: 8,
      minute: 0,
      frequency: 'daily',
      createdAt: now,
      updatedAt: now,
    ),
  );
  final snapshot = ScheduleSnapshotV1(
    pillName: 'Medicine',
    dosage: '10 mg',
    frequency: 'daily',
    frequencyDays: null,
    hour: 8,
    minute: 0,
    timeZone: 'Europe/Bucharest',
    profileId: _profileId,
    profileName: 'Profile',
  );
  await db.medicationLedgerDao.upsertOccurrence(
    MedicationOccurrencesCompanion.insert(
      id: _occurrenceId,
      userId: _userId,
      pillId: const Value(_pillId),
      scheduleId: const Value(_scheduleId),
      occurrenceKey: 'scheduled:v1:${List.filled(64, 'a').join()}',
      source: 'scheduled',
      scheduleRevision: const Value(1),
      plannedLocalDate: '2026-06-11',
      plannedLocalTime: const Value('08:00:00'),
      timeZone: 'Europe/Bucharest',
      plannedAt: Value(_plannedAt),
      expected: const Value(true),
      scheduleSnapshotJson: jsonEncode(snapshot.toJson()),
      provenance: 'exact',
      createdAt: now,
      updatedAt: now,
    ),
  );
  if (protected) await _protect(db);
  return db;
}

void _setActiveSession({
  String userId = _userId,
  int generation = _generation,
}) {
  SharedPreferences.setMockInitialValues({
    kCurrentUserIdKey: userId,
    kActiveUserIdKey: userId,
    kSessionGenerationKey: generation,
  });
}

class _UnlockedPolicyStorage implements AppLockPolicyStorage {
  @override
  Object? get policyValue => const AppLockPolicy(
    enabled: false,
    revision: 'widget-action-test',
  ).encode();

  @override
  Object? get legacyValue => null;

  @override
  Future<void> reload() async {}

  @override
  Future<bool> write(String value) async => true;
}

late AccessGate _testAccessGate;

Future<void> _dispatchWidgetAction(
  Uri uri, {
  AppDatabase? db,
  WorkspaceAccessRepository? access,
}) => handleWidgetAction(
  uri,
  db: db,
  access: access,
  accessGate: _testAccessGate,
);

class _FlakyReconciler extends Mock implements ProjectionReconciler {
  _FlakyReconciler({required this.failures});
  int failures;
  int attempts = 0;

  @override
  Future<ProjectionReconciliationReport?> reconcile({
    SessionIdentity? identity,
    Locale? locale,
    ProjectionIdentity? projectionIdentity,
  }) async {
    attempts++;
    if (failures > 0) {
      failures--;
      throw const ProjectionEffectsBusy();
    }
    return const ProjectionReconciliationReport(
      userId: 'u',
      sessionGeneration: 1,
      state: ProjectionReconciliationState.current,
      desiredCount: 0,
      scheduledCount: 0,
      failedOperations: 0,
      availableCount: 0,
      invalidOccurrenceCount: 0,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _setActiveSession();
    notificationsPlugin = FlutterLocalNotificationsPlugin();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const storageChannel = MethodChannel('simpastil_storage');
    const notificationChannel = MethodChannel(
      'dexterous.com/flutter/local_notifications',
    );
    const widgetChannel = MethodChannel('home_widget');
    const widgetUpdatesChannel = MethodChannel('home_widget/updates');
    messenger.setMockMethodCallHandler(
      storageChannel,
      (_) async => Directory.systemTemp.path,
    );
    messenger.setMockMethodCallHandler(notificationChannel, (call) async {
      if (call.method == 'pendingNotificationRequests' ||
          call.method == 'getActiveNotifications') {
        return <dynamic>[];
      }
      return true;
    });
    messenger.setMockMethodCallHandler(widgetChannel, (call) async {
      if (call.method == 'getWidgetData') return null;
      return true;
    });
    messenger.setMockMethodCallHandler(widgetUpdatesChannel, (_) async => true);
    addTearDown(() {
      messenger.setMockMethodCallHandler(storageChannel, null);
      messenger.setMockMethodCallHandler(notificationChannel, null);
      messenger.setMockMethodCallHandler(widgetChannel, null);
      messenger.setMockMethodCallHandler(widgetUpdatesChannel, null);
    });
    _testAccessGate = AccessGate(
      AppLockPolicyStore(
        _UnlockedPolicyStorage(),
        gate: SerialProjectionEffectsGate(),
      ),
    );
  });

  test(
    'rejects legacy, malformed, extra, stale, and mismatched actions',
    () async {
      final db = await _seededDb();
      addTearDown(db.close);

      await _dispatchWidgetAction(
        Uri.parse(
          'simpastil://take?scheduleId=$_scheduleId&scheduledAt=${_plannedAt.toIso8601String()}',
        ),
        db: db,
        access: _access,
      );
      await _dispatchWidgetAction(Uri.parse('simpastil://take'), db: db);
      await _dispatchWidgetAction(
        Uri.parse('${_actionUri().toString()}&pillName=Medicine'),
        db: db,
        access: _access,
      );
      await _dispatchWidgetAction(
        _actionUri(generation: _context.accessEpoch - 1),
        db: db,
      );
      await _dispatchWidgetAction(
        _actionUri(projectionId: '00000000-0000-4000-8000-000000000099'),
        db: db,
        access: _access,
      );

      final occurrence = await db.medicationLedgerDao.getOccurrenceById(
        _occurrenceId,
      );
      expect(occurrence?.state, 'pending');
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        isEmpty,
      );
    },
  );

  test('legacy display preferences cannot authorize care recording', () async {
    final db = await _seededDb(protected: false);
    addTearDown(db.close);
    await _dispatchWidgetAction(_actionUri(legacy: true), db: db);
    expect(
      (await db.medicationLedgerDao.getOccurrenceById(_occurrenceId))?.state,
      'pending',
    );
    expect(
      await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
      isEmpty,
    );
  });

  test('valid action uses one stable command across platform replay', () async {
    final db = await _seededDb();
    addTearDown(db.close);
    final uri = _actionUri();

    await _dispatchWidgetAction(uri, db: db, access: _access);
    await _dispatchWidgetAction(uri, db: db, access: _access);

    final events = await db.medicationLedgerDao.getEventsForOccurrence(
      _occurrenceId,
    );
    expect(events, hasLength(1));
    expect(
      events.single.commandId,
      widgetActionCommandId(
        projectionId: _projectionId(),
        occurrenceId: _occurrenceId,
        action: 'take',
      ),
    );
    expect(
      (await db.medicationLedgerDao.getOccurrenceById(_occurrenceId))?.state,
      'taken',
    );
  });

  test(
    'contradictory preference owner cannot override the protected grant',
    () async {
      final db = await _seededDb();
      addTearDown(db.close);
      _setActiveSession(userId: '00000000-0000-4000-8000-000000000099');

      await _dispatchWidgetAction(_actionUri(), db: db, access: _access);

      expect(
        (await db.medicationLedgerDao.getOccurrenceById(_occurrenceId))?.state,
        'taken',
      );
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        hasLength(1),
      );
    },
  );

  test(
    'PRN legacy action remains non-mutating without an exact occurrence',
    () async {
      final db = await _seededDb();
      addTearDown(db.close);

      await _dispatchWidgetAction(
        Uri.parse('simpastil://logprn?scheduleId=$_scheduleId'),
        db: db,
        access: _access,
      );

      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        isEmpty,
      );
    },
  );
  test(
    'retired full grant cannot be adopted by same-owner reauthentication',
    () async {
      final db = await _seededDb();
      addTearDown(db.close);
      final old = _actionUri();
      await _protect(db);
      await _dispatchWidgetAction(old, db: db, access: _access);
      expect(
        (await db.medicationLedgerDao.getOccurrenceById(_occurrenceId))?.state,
        'pending',
      );
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        isEmpty,
      );
    },
  );
  test('disabled person reminders block a current full-grant action', () async {
    final db = await _seededDb();
    addTearDown(db.close);
    await db.customUpdate(
      'UPDATE device_person_reminders SET enabled=0 WHERE profile_id=?',
      variables: const [Variable<String>(_profileId)],
      updates: {db.devicePersonReminders},
    );
    await _dispatchWidgetAction(_actionUri(), db: db, access: _access);
    expect(
      (await db.medicationLedgerDao.getOccurrenceById(_occurrenceId))?.state,
      'pending',
    );
    expect(
      await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
      isEmpty,
    );
  });
  test(
    'viewer and old profile active flag do not control device action eligibility',
    () async {
      final db = await _seededDb();
      addTearDown(db.close);
      await db.customUpdate(
        'UPDATE profiles SET is_active=0 WHERE id=?',
        variables: const [Variable<String>(_profileId)],
        updates: {db.profiles},
      );
      await _access.viewPerson(_context, null, everyone: true);
      await _dispatchWidgetAction(_actionUri(), db: db, access: _access);
      expect(
        (await db.medicationLedgerDao.getOccurrenceById(_occurrenceId))?.state,
        'taken',
      );
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        hasLength(1),
      );
    },
  );
  String reminderPayload({
    bool legacy = false,
    String kind = 'reminder',
    int stateVersion = 0,
  }) => jsonEncode({
    'userId': _userId,
    'sessionGeneration': legacy ? _generation : _context.accessEpoch,
    'occurrenceId': _occurrenceId,
    'projectionId': reminderProjectionId(
      userId: _userId,
      sessionGeneration: legacy ? _generation : _context.accessEpoch,
      occurrenceId: _occurrenceId,
      kind: kind,
      workspaceId: legacy ? null : _context.workspaceId,
      grantEpoch: legacy ? null : _context.accessEpoch,
      stateVersion: legacy ? null : stateVersion,
    ),
    if (!legacy) ...{
      ...ProjectionIdentity.fromContext(_context).toJson(),
      'stateVersion': stateVersion,
    },
  });
  Future<void> reminderAction(
    AppDatabase db,
    String payload, {
    String action = 'taken',
    ProjectionReconciler? projectionReconciler,
    Future<void> Function(Duration)? scheduleRetry,
  }) => dispatchNotificationAction(
    NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      actionId: action,
      payload: payload,
    ),
    plugin: FlutterLocalNotificationsPlugin(),
    database: db,
    access: _access,
    projectionReconciler: projectionReconciler,
    accessGate: _testAccessGate,
    reconcileRetryWait: (_) async {},
    scheduleReconcileRetry: scheduleRetry ?? (_) async {},
  );

  Future<void> warmReminderAction(
    AppDatabase db,
    String payload, {
    String action = 'taken',
  }) => handleNotificationAction(
    NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      actionId: action,
      payload: payload,
    ),
    (_) {},
    database: db,
    access: _access,
  );

  test(
    'warm snooze Taken action updates the mounted dose and replays once',
    () async {
      final db = await _seededDb();
      addTearDown(db.close);
      final query = db.select(db.medicationOccurrences)
        ..where((row) => row.id.equals(_occurrenceId));
      final doseStream = query.watchSingle();
      final initialDose = await doseStream.first;
      expect(initialDose.state, 'pending');
      final takenDose = doseStream.firstWhere((dose) => dose.state == 'taken');
      final payload = reminderPayload(kind: 'snooze');

      await warmReminderAction(db, payload);

      final updatedDose = await takenDose.timeout(const Duration(seconds: 2));
      expect(updatedDose.id, _occurrenceId);
      expect(updatedDose.state, 'taken');

      await warmReminderAction(db, payload);
      final persistedDose = await db.medicationLedgerDao.getOccurrenceById(
        _occurrenceId,
      );
      final events = await db.medicationLedgerDao.getEventsForOccurrence(
        _occurrenceId,
      );
      expect(persistedDose?.id, _occurrenceId);
      expect(persistedDose?.state, 'taken');
      expect(events, hasLength(1));
      expect(events.single.occurrenceId, _occurrenceId);
    },
  );

  test(
    'notification takes an exact protected occurrence once across replay',
    () async {
      final db = await _seededDb();
      addTearDown(db.close);
      final payload = reminderPayload();
      expect(
        parseReminderActionPayload(payload)?.projectionIdentity,
        ProjectionIdentity.fromContext(_context),
      );
      await reminderAction(db, payload);
      await reminderAction(db, payload);
      expect(
        (await db.medicationLedgerDao.getOccurrenceById(_occurrenceId))?.state,
        'taken',
      );
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        hasLength(1),
      );
    },
  );
  test(
    'a failed reminder pass after Taken is retried, then handed to a task',
    () async {
      final db = await _seededDb();
      addTearDown(db.close);
      final reconciler = _FlakyReconciler(failures: 99);
      final handedOff = <Duration>[];
      await reminderAction(
        db,
        reminderPayload(),
        projectionReconciler: reconciler,
        scheduleRetry: (delay) async => handedOff.add(delay),
      );
      expect(
        (await db.medicationLedgerDao.getOccurrenceById(_occurrenceId))?.state,
        'taken',
      );
      expect(reconciler.attempts, 3);
      expect(handedOff, hasLength(1));
    },
  );

  test('a pass that recovers on retry queues no background task', () async {
    final db = await _seededDb();
    addTearDown(db.close);
    final reconciler = _FlakyReconciler(failures: 1);
    final handedOff = <Duration>[];
    await reminderAction(
      db,
      reminderPayload(),
      projectionReconciler: reconciler,
      scheduleRetry: (delay) async => handedOff.add(delay),
    );
    expect(reconciler.attempts, 2);
    expect(handedOff, isEmpty);
  });

  test(
    'schedule alerts disabled still permit the current widget Take',
    () async {
      final db = await _seededDb();
      addTearDown(db.close);
      await ReminderPreferencesRepository(
        database: db,
        access: _access,
        context: _context,
      ).setSchedule(_scheduleId, ScheduleReminderChoice(enabled: false));
      await reminderAction(db, reminderPayload());
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        isEmpty,
      );
      final uri = _actionUri();
      await _dispatchWidgetAction(uri, db: db, access: _access);
      await _dispatchWidgetAction(uri, db: db, access: _access);
      expect(
        (await db.medicationLedgerDao.getOccurrenceById(_occurrenceId))?.state,
        'taken',
      );
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        hasLength(1),
      );
    },
  );
  test(
    'legacy reminder cannot use current display preferences as authority',
    () async {
      final db = await _seededDb();
      addTearDown(db.close);
      await reminderAction(db, reminderPayload(legacy: true));
      expect(
        (await db.medicationLedgerDao.getOccurrenceById(_occurrenceId))?.state,
        'pending',
      );
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        isEmpty,
      );
    },
  );
  test(
    'notification snooze projection can record skip under the same full grant',
    () async {
      final db = await _seededDb();
      addTearDown(db.close);
      await reminderAction(db, reminderPayload(kind: 'snooze'), action: 'skip');
      expect(
        (await db.medicationLedgerDao.getOccurrenceById(_occurrenceId))?.state,
        'skipped',
      );
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        hasLength(1),
      );
    },
  );
  for (final notification in [false, true]) {
    test(
      '${notification ? 'notification' : 'widget'} rechecks grant inside care publication',
      () async {
        final db = await _seededDb();
        addTearDown(db.close);
        final widgetUri = _actionUri();
        final payload = reminderPayload();
        _access.revokeOnResolve = true;
        if (notification) {
          await reminderAction(db, payload);
        } else {
          await _dispatchWidgetAction(widgetUri, db: db, access: _access);
        }
        expect(
          (await db.medicationLedgerDao.getOccurrenceById(
            _occurrenceId,
          ))?.state,
          'pending',
        );
        expect(
          await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
          isEmpty,
        );
      },
    );
  }
  Future<void> undoAcceptedFixture(AppDatabase db) async {
    final before = (await db.medicationLedgerDao.getOccurrenceById(
      _occurrenceId,
    ))!;
    final event = (await db.medicationLedgerDao.getEventsForOccurrence(
      _occurrenceId,
    )).last;
    final acceptedEventId = event.id;
    await (db.update(db.occurrenceEvents)
          ..where((row) => row.id.equals(event.id)))
        .write(OccurrenceEventsCompanion(serverId: Value(acceptedEventId)));
    final inventory = (await db.medicationLedgerDao.getInventoryEventsForPill(
      _pillId,
    )).last;
    await (db.update(db.inventoryEvents)
          ..where((row) => row.id.equals(inventory.id)))
        .write(InventoryEventsCompanion(serverId: Value(inventory.id)));
    await MedicationRepository(db, access: _access, context: _context).apply(
      userId: _userId,
      occurrenceId: _occurrenceId,
      action: MedicationAction.undo,
      actualTimeKnown: false,
      intendedState: MedicationState.pending,
      reversesEventId: acceptedEventId,
      commandIdOverride: projectionCommandIdForKey(
        'fixture-undo:$acceptedEventId',
      ),
    );
    expect(
      (await db.medicationLedgerDao.getOccurrenceById(
        _occurrenceId,
      ))?.stateVersion,
      before.stateVersion + 1,
    );
  }

  for (final notification in [false, true]) {
    test(
      '${notification ? 'notification' : 'widget'} old delivery cannot replay across Undo while a new delivery can act',
      () async {
        final db = await _seededDb();
        addTearDown(db.close);
        await (db.update(db.pills)..where((row) => row.id.equals(_pillId)))
            .write(const PillsCompanion(currentStock: Value(10)));
        final oldWidget = _actionUri();
        final oldReminder = reminderPayload();
        Future<void> deliverOld() => notification
            ? reminderAction(db, oldReminder)
            : _dispatchWidgetAction(oldWidget, db: db, access: _access);
        await deliverOld();
        expect((await db.pillsDao.getById(_pillId))?.currentStock, 9);
        await undoAcceptedFixture(db);
        await deliverOld();
        expect(
          (await db.medicationLedgerDao.getOccurrenceById(
            _occurrenceId,
          ))?.state,
          'pending',
        );
        expect((await db.pillsDao.getById(_pillId))?.currentStock, 10);
        expect(
          await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
          hasLength(2),
        );
        if (notification) {
          await reminderAction(db, reminderPayload(stateVersion: 2));
        } else {
          await _dispatchWidgetAction(
            _actionUri(stateVersion: 2),
            db: db,
            access: _access,
          );
        }
        expect(
          (await db.medicationLedgerDao.getOccurrenceById(
            _occurrenceId,
          ))?.state,
          'taken',
        );
        expect((await db.pillsDao.getById(_pillId))?.currentStock, 9);
        expect(
          await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
          hasLength(3),
        );
      },
    );
  }
  test('old snooze cannot acquire the pending version after Undo', () async {
    final db = await _seededDb();
    addTearDown(db.close);
    await (db.update(db.pills)..where((row) => row.id.equals(_pillId))).write(
      const PillsCompanion(currentStock: Value(10)),
    );
    final old = reminderPayload();
    await reminderAction(db, old);
    await undoAcceptedFixture(db);
    final preferences = await SharedPreferences.getInstance();
    final platform = _ReminderPlatform();
    final reconciler = ProjectionReconciler(
      database: db,
      preferences: preferences,
      generations: SessionGenerationRepository(preferences, access: _access),
      platform: platform,
      platformKind: ReminderPlatformKind.android,
    );
    await reminderAction(
      db,
      old,
      action: 'snooze',
      projectionReconciler: reconciler,
    );
    expect(platform.requests, isEmpty);
    await reminderAction(
      db,
      reminderPayload(stateVersion: 2),
      action: 'snooze',
      projectionReconciler: reconciler,
    );
    expect(platform.requests, hasLength(1));
    final scheduled = parseReminderActionPayload(
      platform.requests.values.single.payload,
    )!;
    expect(scheduled.stateVersion, 2);
    expect(reminderProjectionMatchesAction(scheduled), isTrue);
    final snoozeId = platform.requests.keys.single;
    await reconciler.reconcile(
      projectionIdentity: ProjectionIdentity.fromContext(_context),
    );
    expect(platform.requests.keys, contains(snoozeId));
    expect(
      (await db.medicationLedgerDao.getOccurrenceById(_occurrenceId))?.state,
      'pending',
    );
    expect((await db.pillsDao.getById(_pillId))?.currentStock, 10);
    await _dispatchWidgetAction(
      _actionUri(stateVersion: 2),
      db: db,
      access: _access,
    );
    await undoAcceptedFixture(db);
    expect(
      (await db.medicationLedgerDao.getOccurrenceById(
        _occurrenceId,
      ))?.stateVersion,
      4,
    );
    await reconciler.reconcile(
      projectionIdentity: ProjectionIdentity.fromContext(_context),
    );
    expect(platform.requests.keys, isNot(contains(snoozeId)));
    expect((await db.pillsDao.getById(_pillId))?.currentStock, 10);
  });
}
