import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/storage/preference_keys.dart';
import 'package:simpastil/core/widget/widget_snapshot.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';

const kCurrentUserIdForTests = '00000000-0000-4000-8000-000000000001';

Future<void> _seed(
  AppDatabase db, {
  String profileId = 'profile-1',
  bool profileActive = true,
  String pillId = 'pill-1',
  String scheduleId = 'sched-1',
  String pillName = 'Aspirin',
  int hour = 8,
  String state = 'pending',
}) async {
  final createdAt = DateTime.utc(2026, 6, 1);
  await db.usersDao.upsert(
    UsersCompanion.insert(
      id: kCurrentUserIdForTests,
      email: 'widget-snapshot@test.invalid',
      createdAt: createdAt,
      updatedAt: createdAt,
    ),
  );
  await db.profilesDao.upsert(
    ProfilesCompanion(
      id: Value(profileId),
      userId: const Value(kCurrentUserIdForTests),
      name: const Value('Alex'),
      isActive: Value(profileActive),
      createdAt: Value(DateTime(2026)),
      updatedAt: Value(DateTime(2026)),
    ),
  );
  await db.pillsDao.upsert(
    PillsCompanion(
      id: Value(pillId),
      profileId: Value(profileId),
      name: Value(pillName),
      createdAt: Value(DateTime(2026)),
      updatedAt: Value(DateTime(2026)),
    ),
  );
  await db.schedulesDao.upsert(
    SchedulesCompanion(
      id: Value(scheduleId),
      pillId: Value(pillId),
      hour: Value(hour),
      minute: const Value(0),
      frequency: const Value('daily'),
      createdAt: Value(DateTime(2026, 6, 1)),
      updatedAt: Value(DateTime(2026, 6, 1)),
    ),
  );
  final snapshot = ScheduleSnapshotV1(
    pillName: pillName,
    dosage: '10 mg',
    frequency: 'daily',
    frequencyDays: null,
    hour: hour,
    minute: 0,
    timeZone: 'Europe/Bucharest',
    profileId: profileId,
    profileName: 'Alex',
  );
  final occurrenceId = projectionCommandIdForKey(
    'widget-snapshot-fixture-v1:$scheduleId',
  );
  await db.medicationLedgerDao.upsertOccurrence(
    MedicationOccurrencesCompanion.insert(
      id: occurrenceId,
      userId: kCurrentUserIdForTests,
      pillId: Value(pillId),
      scheduleId: Value(scheduleId),
      occurrenceKey: 'scheduled:v1:$scheduleId:$hour',
      source: 'scheduled',
      scheduleRevision: const Value(1),
      plannedLocalDate: '2026-06-11',
      plannedLocalTime: Value('${hour.toString().padLeft(2, '0')}:00:00'),
      timeZone: 'Europe/Bucharest',
      plannedAt: Value(DateTime.utc(2026, 6, 11, hour - 3)),
      expected: const Value(true),
      scheduleSnapshotJson: jsonEncode(snapshot.toJson()),
      provenance: 'exact',
      state: Value(state),
      createdAt: createdAt,
      updatedAt: createdAt,
    ),
  );
  final access = WorkspaceAccessRepository(db);
  var context = await access.contextForOwner(kCurrentUserIdForTests);
  if (context == null) {
    const endpoint = 'https://fictional.test/widget';
    final epoch = await access.configureEndpoint(endpoint);
    await db
        .into(db.credentialSlots)
        .insert(
          CredentialSlotsCompanion.insert(
            id: 'fictional-widget-slot',
            ownerId: kCurrentUserIdForTests,
            endpoint: endpoint,
            state: 'staged',
            createdAt: DateTime.now(),
          ),
        );
    final account = await access.authenticate(
      ownerId: kCurrentUserIdForTests,
      endpoint: endpoint,
      expectedNetworkEpoch: epoch,
      sessionGeneration: 7,
      credentialId: 'fictional-widget-slot',
    );
    context = await access.confirmOriginalServer(
      workspaceId: account.workspace.id,
      reviewedOriginalEndpoint: endpoint,
      expectedNetworkEpoch: account.network.epoch,
    );
  }
  await db
      .into(db.devicePersonReminders)
      .insertOnConflictUpdate(
        DevicePersonRemindersCompanion.insert(
          profileId: profileId,
          enabled: Value(profileActive),
        ),
      );
}

void _setActiveSessionPreferences({Map<String, Object> extra = const {}}) {
  SharedPreferences.setMockInitialValues({
    kCurrentUserIdKey: kCurrentUserIdForTests,
    kActiveUserIdKey: kCurrentUserIdForTests,
    kSessionGenerationKey: 7,
    ...extra,
  });
}

Future<void> _seedTakenPrnOccurrence(
  AppDatabase db, {
  required String occurrenceId,
  required String pillId,
  required int minute,
}) async {
  final now = DateTime.utc(2026, 6, 1);
  await db.medicationLedgerDao.upsertOccurrence(
    MedicationOccurrencesCompanion.insert(
      id: occurrenceId,
      userId: kCurrentUserIdForTests,
      pillId: Value(pillId),
      scheduleId: const Value('prn-sentinel'),
      occurrenceKey: 'prn:v1:$occurrenceId',
      source: 'prn',
      plannedLocalDate: '2026-06-11',
      plannedLocalTime: Value('10:${minute.toString().padLeft(2, '0')}:00'),
      timeZone: 'Europe/Bucharest',
      plannedAt: Value(DateTime.utc(2026, 6, 11, 10, minute)),
      expected: const Value(false),
      scheduleSnapshotJson: jsonEncode(
        ScheduleSnapshotV1(
          pillName: 'Strepsils',
          dosage: null,
          frequency: 'prn',
          frequencyDays: null,
          hour: null,
          minute: null,
          timeZone: 'Europe/Bucharest',
          profileId: 'profile-1',
          profileName: 'Alex',
        ).toJson(),
      ),
      provenance: 'exact',
      state: const Value('taken'),
      createdAt: now,
      updatedAt: now,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Fixed clock: all seeded slots are deterministic relative to this.
  final now = DateTime(2026, 6, 11, 12);

  group('computeWidgetSnapshot', () {
    test(
      'completed scheduled rows carry the captured protected identity',
      () async {
        _setActiveSessionPreferences();
        final prefs = await SharedPreferences.getInstance();
        final db = AppDatabase.forTesting();
        addTearDown(db.close);
        await _seed(db, state: 'taken');
        final snapshot = await computeWidgetSnapshot(
          db: db,
          prefs: prefs,
          now: now,
        );
        final row = (snapshot['doses'] as List).single as Map;
        final identity = snapshot['projectionIdentity'] as Map;
        expect(row['rowKind'], 'scheduled');
        for (final key in ['version', 'workspaceId', 'userId', 'grantEpoch']) {
          expect(row[key], identity[key]);
        }
        expect(row['active_user_id'], identity['userId']);
        expect(row['session_generation'], identity['grantEpoch']);
        expect(row['stateVersion'], 0);
        expect(row['projectionId'], isNull);
        expect(row['status'], 'taken');
      },
    );
    test(
      'standalone widget does not require an authentication mirror',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final db = AppDatabase.forTesting();
        addTearDown(db.close);

        final snapshot = await computeWidgetSnapshot(
          db: db,
          prefs: prefs,
          now: now,
        );
        expect(snapshot['authenticated'], isTrue);
        expect(snapshot['active_user_id'], startsWith('local:'));
        expect(snapshot['doses'], isEmpty);
      },
    );

    test(
      'unbound preference identities do not adopt a connected owner',
      () async {
        _setActiveSessionPreferences();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          kActiveUserIdKey,
          '00000000-0000-4000-8000-000000000099',
        );
        final db = AppDatabase.forTesting();
        addTearDown(db.close);

        final snapshot = await computeWidgetSnapshot(
          db: db,
          prefs: prefs,
          now: now,
        );

        expect(snapshot['authenticated'], isTrue);
        expect(snapshot['active_user_id'], startsWith('local:'));
        expect(snapshot['doses'], isEmpty);
      },
    );

    test('pending doses show the current name, recorded keep theirs', () async {
      _setActiveSessionPreferences();
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      await _seed(db, hour: 20);
      await _seed(
        db,
        pillId: 'pill-2',
        scheduleId: 'sched-2',
        pillName: 'Ibuprofen',
        hour: 8,
        state: 'taken',
      );
      for (final id in ['pill-1', 'pill-2']) {
        await (db.update(db.pills)..where((p) => p.id.equals(id))).write(
          PillsCompanion(name: Value('Renamed $id')),
        );
      }

      final snapshot = await computeWidgetSnapshot(
        db: db,
        prefs: prefs,
        now: now,
      );
      final doses = (snapshot['doses'] as List).cast<Map>();
      expect(doses.first['pill'], 'Ibuprofen'); // taken: as recorded
      expect(doses.last['pill'], 'Renamed pill-1'); // pending: current
    });

    test('builds sorted dose rows with statuses and counts', () async {
      _setActiveSessionPreferences();
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      await _seed(db, hour: 20);
      await _seed(
        db,
        pillId: 'pill-2',
        scheduleId: 'sched-2',
        pillName: 'Ibuprofen',
        hour: 8,
        state: 'taken',
      );

      final snapshot = await computeWidgetSnapshot(
        db: db,
        prefs: prefs,
        now: now,
      );

      expect(snapshot['authenticated'], isTrue);
      expect(snapshot['active_user_id'], kCurrentUserIdForTests);
      expect(
        snapshot['session_generation'],
        (snapshot['projectionIdentity'] as Map)['grantEpoch'],
      );
      expect((snapshot['projectionIdentity'] as Map)['version'], 2);
      expect(snapshot['day'], '2026-06-11');
      expect(snapshot['total'], 2);
      expect(snapshot['taken'], 1);
      final doses = snapshot['doses'] as List;
      expect(doses, hasLength(2));
      expect((doses.first as Map)['pill'], 'Ibuprofen'); // 08:00 before 20:00
      expect((doses.first as Map)['time'], '08:00');
      expect((doses.first as Map)['status'], 'taken');
      expect((doses.last as Map)['status'], 'pending');
      expect((doses.last as Map)['scheduleId'], 'sched-1');
      expect(
        (doses.last as Map)['scheduledAt'],
        DateTime.utc(2026, 6, 11, 17).toIso8601String(),
      );
      expect((doses.last as Map)['occurrenceId'], isNotEmpty);
      expect((doses.last as Map)['projectionId'], isNotEmpty);
    });

    test(
      'private reminder choice emits no care details or action identity',
      () async {
        _setActiveSessionPreferences();
        final prefs = await SharedPreferences.getInstance();
        final db = AppDatabase.forTesting();
        addTearDown(db.close);
        await _seed(db, pillName: 'Fictional Private Medication');
        final access = WorkspaceAccessRepository(db);
        final context = await access.currentContext();
        await db
            .into(db.deviceReminderSettings)
            .insertOnConflictUpdate(
              DeviceReminderSettingsCompanion.insert(
                workspaceId: context.workspaceId,
                fullDetails: const Value(false),
              ),
            );

        final snapshot = await computeWidgetSnapshot(
          db: db,
          prefs: prefs,
          now: now,
        );

        expect(snapshot['private'], isTrue);
        expect(snapshot['doses'], isEmpty);
        expect(snapshot['total'], 0);
        expect(snapshot['taken'], 0);
        final content = jsonEncode(snapshot);
        expect(content, isNot(contains('Fictional Private Medication')));
        expect(content, isNot(contains('sched-1')));
        expect(content, isNot(contains('occurrenceId')));
        expect(content, isNot(contains('"projectionId":')));
      },
    );

    test('only enabled profiles contribute doses', () async {
      _setActiveSessionPreferences();
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      await _seed(db);
      await _seed(
        db,
        profileId: 'profile-2',
        profileActive: false,
        pillId: 'pill-2',
        scheduleId: 'sched-2',
        pillName: 'Hidden Pill',
      );

      final snapshot = await computeWidgetSnapshot(
        db: db,
        prefs: prefs,
        now: now,
      );
      expect(snapshot['total'], 1);
      final doses = snapshot['doses'] as List;
      expect((doses.single as Map)['pill'], 'Aspirin');
    });

    test('prnInWidget adds PRN items without affecting ring counts', () async {
      _setActiveSessionPreferences();
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      await _seed(db, hour: 8);

      // Add a PRN pill + sentinel schedule
      await db.pillsDao.upsert(
        PillsCompanion(
          id: const Value('prn-pill'),
          profileId: const Value('profile-1'),
          name: const Value('Strepsils'),
          isPrn: const Value(true),
          createdAt: Value(DateTime(2026)),
          updatedAt: Value(DateTime(2026)),
        ),
      );
      await db.schedulesDao.upsert(
        SchedulesCompanion(
          id: const Value('prn-sentinel'),
          pillId: const Value('prn-pill'),
          hour: const Value(0),
          minute: const Value(0),
          frequency: const Value('prn'),
          createdAt: Value(DateTime(2026)),
          updatedAt: Value(DateTime(2026)),
        ),
      );
      await _seedTakenPrnOccurrence(
        db,
        occurrenceId: '00000000-0000-4000-8000-000000000021',
        pillId: 'prn-pill',
        minute: 0,
      );
      await _seedTakenPrnOccurrence(
        db,
        occurrenceId: '00000000-0000-4000-8000-000000000022',
        pillId: 'prn-pill',
        minute: 1,
      );

      final snapshot = await computeWidgetSnapshot(
        db: db,
        prefs: prefs,
        now: now,
      );

      // Default: no PRN in widget
      expect(snapshot['total'], 1, reason: 'only scheduled dose counted');
      expect(snapshot['taken'], 0, reason: 'scheduled dose is pending');
      final defaultDoses = snapshot['doses'] as List;
      expect(defaultDoses, hasLength(1));

      // Enable prnInWidget via prefs and recompute
      await prefs.setBool(
        prnInWidgetPreferenceKey(kCurrentUserIdForTests),
        true,
      );
      final withPrn = await computeWidgetSnapshot(
        db: db,
        prefs: prefs,
        now: now,
      );

      expect(withPrn['total'], 1, reason: 'ring total excludes PRN items');
      expect(withPrn['taken'], 0, reason: 'ring taken excludes PRN items');
      final prnDoses = withPrn['doses'] as List;
      expect(prnDoses, hasLength(2)); // 1 scheduled + 1 PRN
      final prnEntry = prnDoses.last as Map;
      expect(prnEntry['isPrn'], isTrue);
      expect(prnEntry['pill'], contains('Strepsils'));
      expect(prnEntry['time'], contains('2×'));
      expect(prnEntry['rowKind'], 'prnSummary');
      final identity = withPrn['projectionIdentity'] as Map;
      for (final key in ['version', 'workspaceId', 'userId', 'grantEpoch']) {
        expect(prnEntry[key], identity[key]);
      }
      expect(prnEntry['active_user_id'], identity['userId']);
      expect(prnEntry['session_generation'], identity['grantEpoch']);
      expect(prnEntry.containsKey('stateVersion'), isFalse);
      expect(prnEntry.containsKey('projectionId'), isFalse);
      expect(prnEntry.containsKey('occurrenceId'), isFalse);
    });

    test(
      'both prnInStats and prnInWidget do not duplicate PRN entries',
      () async {
        _setActiveSessionPreferences(
          extra: {
            prnInStatsPreferenceKey(kCurrentUserIdForTests): true,
            prnInWidgetPreferenceKey(kCurrentUserIdForTests): true,
          },
        );
        final prefs = await SharedPreferences.getInstance();
        final db = AppDatabase.forTesting();
        addTearDown(db.close);
        await _seed(db, hour: 8);

        await db.pillsDao.upsert(
          PillsCompanion(
            id: const Value('prn-pill'),
            profileId: const Value('profile-1'),
            name: const Value('Strepsils'),
            isPrn: const Value(true),
            createdAt: Value(DateTime(2026)),
            updatedAt: Value(DateTime(2026)),
          ),
        );
        await db.schedulesDao.upsert(
          SchedulesCompanion(
            id: const Value('prn-sentinel'),
            pillId: const Value('prn-pill'),
            hour: const Value(0),
            minute: const Value(0),
            frequency: const Value('prn'),
            createdAt: Value(DateTime(2026)),
            updatedAt: Value(DateTime(2026)),
          ),
        );

        final snapshot = await computeWidgetSnapshot(
          db: db,
          prefs: prefs,
          now: now,
        );

        final doses = snapshot['doses'] as List;
        final prnEntries = doses
            .where((d) => (d as Map)['isPrn'] == true)
            .toList();
        expect(
          prnEntries,
          hasLength(1),
          reason:
              'PRN pill must appear exactly once even when both '
              'prnInStats and prnInWidget are true',
        );
      },
    );

    test('the auto-miss setting alone never paints a dose missed', () async {
      _setActiveSessionPreferences(
        extra: {
          'auto_miss_enabled_$kCurrentUserIdForTests': true,
          'auto_miss_delay_minutes_$kCurrentUserIdForTests': 15,
        },
      );
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      await _seed(db, hour: 8); // 08:00 is > 15 min before the fixed noon

      final snapshot = await computeWidgetSnapshot(
        db: db,
        prefs: prefs,
        now: now,
      );
      final doses = snapshot['doses'] as List;
      // Only a recorded `miss` event reads as missed; the sweeper writes it.
      expect((doses.single as Map)['status'], 'pending');
    });

    test('a recorded missed dose shows missed on the widget', () async {
      _setActiveSessionPreferences();
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      await _seed(db, hour: 8, state: 'missed');

      final snapshot = await computeWidgetSnapshot(
        db: db,
        prefs: prefs,
        now: now,
      );
      final doses = snapshot['doses'] as List;
      expect((doses.single as Map)['status'], 'missed');
      expect(snapshot['taken'], 0);
    });
  });

  group('publishWidgetSnapshot', () {
    test('never throws even though the platform channel is absent', () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      await expectLater(publishWidgetSnapshot(db: db), completes);
    });

    test('never throws even when it must open its own database', () async {
      // No db passed: the own-instance open fails in the test environment
      // (no path_provider); both the compute error and the close-after-
      // failed-open rethrow must be swallowed.
      _setActiveSessionPreferences();
      await expectLater(publishWidgetSnapshot(), completes);
    });
  });
}
