import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:simpastil/core/notifications/reminder_preferences.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/projections/reminder_planning.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';

const _userId = 'planning-user';
const _profileId = '00000000-0000-4000-8000-000000000001';
final _now = DateTime.utc(2026, 9, 24, 6);

ReminderProjection _reminder(
  int id,
  DateTime at, {
  String? projectionId,
  bool allowCareActions = true,
  String title = 'Medicine',
  String body = 'Time',
}) => ReminderProjection(
  notificationId: id,
  projectionId: projectionId ?? 'p$id',
  occurrenceId: 'o$id',
  userId: _userId,
  sessionGeneration: 1,
  scheduledAtUtc: at,
  timeZone: 'UTC',
  title: title,
  body: body,
  payload: '{}',
  allowCareActions: allowCareActions,
);

void main() {
  group('Android budget', () {
    test('share splits the budget by eligible workspaces', () {
      expect(androidReminderBudget, 450);
      expect(androidWorkspaceShare(0), 450);
      expect(androidWorkspaceShare(1), 450);
      expect(androidWorkspaceShare(4), 112);
    });

    test('admission budget subtracts other alarms and never goes negative', () {
      expect(
        androidAdmissionBudget(otherPendingCount: 0, workspaceShare: 450),
        450,
      );
      expect(
        androidAdmissionBudget(otherPendingCount: 100, workspaceShare: 450),
        350,
      );
      expect(
        androidAdmissionBudget(otherPendingCount: 100, workspaceShare: 112),
        112,
      );
      expect(
        androidAdmissionBudget(otherPendingCount: 900, workspaceShare: 450),
        0,
      );
    });

    test('within budget keeps every reminder and reports no shortening', () {
      final desired = {
        1: _reminder(1, _now),
        2: _reminder(2, _now.add(const Duration(minutes: 1))),
      };
      final result = selectWithinAndroidBudget(desired, 2);
      expect(result.shortened, isFalse);
      expect(result.selected.keys, [1, 2]);
    });

    test('over budget keeps the nearest, ties broken by projection ID', () {
      final desired = {
        1: _reminder(1, _now.add(const Duration(minutes: 5))),
        2: _reminder(2, _now, projectionId: 'b'),
        3: _reminder(3, _now, projectionId: 'a'),
        4: _reminder(4, _now.add(const Duration(minutes: 1))),
      };
      final result = selectWithinAndroidBudget(desired, 3);
      expect(result.shortened, isTrue);
      expect(result.selected.keys.toSet(), {3, 2, 4});
      expect(selectWithinAndroidBudget(desired, 0).selected, isEmpty);
    });
  });

  group('privacy retention', () {
    PlatformReminderRequest request(ReminderProjection r) =>
        PlatformReminderRequest(
          id: r.notificationId,
          title: r.title,
          body: r.body,
          payload: r.payload,
        );

    test('a full-detail desired reminder is always retainable', () {
      expect(isPrivacySafeToRetain(_reminder(1, _now), null, null), isTrue);
    });

    test('a private desired reminder needs a matching private effect', () {
      final desired = _reminder(1, _now, allowCareActions: false);
      final stored = {'allowCareActions': false};
      expect(isPrivacySafeToRetain(desired, null, stored), isFalse);
      expect(isPrivacySafeToRetain(desired, request(desired), stored), isTrue);
      expect(
        isPrivacySafeToRetain(desired, request(desired), {
          'allowCareActions': false,
          'publicationPending': true,
        }),
        isFalse,
      );
      expect(
        isPrivacySafeToRetain(desired, request(desired), {
          'allowCareActions': true,
        }),
        isFalse,
      );
      final exposed = _reminder(1, _now, title: 'Aspirin', body: 'Take it');
      expect(isPrivacySafeToRetain(desired, request(exposed), stored), isFalse);
    });

    test('collects only the IDs that are safe to retain', () {
      final safe = _reminder(1, _now, allowCareActions: false);
      final unsafe = _reminder(2, _now, allowCareActions: false);
      final full = _reminder(3, _now);
      final ids = privacySafeReminderIds(
        {1: safe, 2: unsafe, 3: full},
        pendingById: {1: request(safe)},
        registry: {
          1: {'allowCareActions': false},
        },
      );
      expect(ids, {1, 3});
    });
  });

  group('active snoozes', () {
    late AppDatabase db;
    late MedicationOccurrence occurrence;
    final retained = _now.add(const Duration(hours: 1));

    setUp(() async {
      db = AppDatabase.forTesting();
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: _userId,
          email: 'planning@test.invalid',
          createdAt: _now,
          updatedAt: _now,
        ),
      );
      final snapshot = ScheduleSnapshotV1(
        pillName: 'Medicine',
        dosage: '10 mg',
        frequency: 'daily',
        frequencyDays: null,
        hour: 9,
        minute: 30,
        timeZone: 'Europe/Bucharest',
        profileId: _profileId,
        profileName: 'Person',
      );
      await db.medicationLedgerDao.upsertOccurrence(
        MedicationOccurrencesCompanion.insert(
          id: 'occurrence-1',
          userId: _userId,
          occurrenceKey: 'scheduled:v1:1',
          source: 'scheduled',
          scheduleRevision: const Value(1),
          pillId: const Value('pill-1'),
          scheduleId: const Value('schedule-1'),
          plannedLocalDate: '2026-09-24',
          plannedLocalTime: const Value('09:30'),
          timeZone: 'Europe/Bucharest',
          plannedAt: Value(_now),
          expected: const Value(true),
          scheduleSnapshotJson: jsonEncode(snapshot.toJson()),
          provenance: 'exact',
          createdAt: _now,
          updatedAt: _now,
        ),
      );
      occurrence = (await db.medicationLedgerDao.getOccurrencesForUser(
        _userId,
      )).single;
    });

    tearDown(() => db.close());

    String projectionId() => reminderProjectionId(
      userId: _userId,
      sessionGeneration: 1,
      occurrenceId: occurrence.id,
      kind: 'snooze',
    );

    String payload() => jsonEncode({
      'occurrenceId': occurrence.id,
      'projectionId': projectionId(),
      'userId': _userId,
      'sessionGeneration': 1,
    });

    Map<int, Map<String, Object?>> registry() => {
      7: {
        'kind': 'snooze',
        'occurrenceId': occurrence.id,
        'projectionId': projectionId(),
        'userId': _userId,
        'sessionGeneration': 1,
        'scheduledAtUtc': retained.toIso8601String(),
      },
    };

    Map<int, ReminderProjection> plan({
      Map<int, Map<String, Object?>>? entries,
      String? pendingPayload,
      DateTime? now,
      Set<String> profiles = const {_profileId},
      bool owned = true,
      bool fullDetails = true,
    }) => planActiveSnoozes(
      registry: entries ?? registry(),
      pendingById: {
        7: PlatformReminderRequest(
          id: 7,
          title: 't',
          body: 'b',
          payload: pendingPayload ?? payload(),
        ),
      },
      occurrences: [occurrence],
      activeProfileIds: profiles,
      identity: (_userId, 1),
      preferences: ReminderPreferences(fullDetails: fullDetails),
      localizations: AppLocalizationsEn(),
      now: now ?? _now,
      owns: (_) => owned,
    );

    test('retains a valid future snooze with its exact projection', () {
      final result = plan();
      expect(result.keys, [7]);
      expect(result[7]!.projectionId, projectionId());
      expect(result[7]!.payload, payload());
      expect(result[7]!.scheduledAtUtc, retained);
      expect(result[7]!.allowCareActions, isTrue);
      expect(result[7]!.title, contains('Medicine'));
    });

    test('uses the private presentation when details are hidden', () {
      final result = plan(fullDetails: false);
      expect(result[7]!.allowCareActions, isFalse);
      expect(result[7]!.title, isNot(contains('Medicine')));
    });

    test('drops snoozes that are not owned, stale or mismatched', () {
      expect(plan(owned: false), isEmpty);
      expect(plan(now: retained), isEmpty);
      expect(plan(pendingPayload: '{}'), isEmpty);
      expect(plan(profiles: const {}), isEmpty);
      final wrongId = registry()..[7]!['projectionId'] = 'other';
      expect(plan(entries: wrongId), isEmpty);
      final notSnooze = registry()..[7]!['kind'] = 'reminder';
      expect(plan(entries: notSnooze), isEmpty);
      final badTime = registry()..[7]!['scheduledAtUtc'] = 'not-a-time';
      expect(plan(entries: badTime), isEmpty);
    });
  });

  group('review-fix planning', () {
    final now = DateTime.utc(2026, 9, 24, 12);

    test('a publish mark expires, an unmarked legacy one keeps blocking', () {
      expect(
        publicationInFlight({
          'publicationPending': true,
          'publicationPendingAt': now
              .subtract(const Duration(minutes: 1))
              .toIso8601String(),
        }, now),
        isTrue,
      );
      expect(
        publicationInFlight({
          'publicationPending': true,
          'publicationPendingAt': now
              .subtract(const Duration(hours: 1))
              .toIso8601String(),
        }, now),
        isFalse,
      );
      expect(publicationInFlight({'publicationPending': true}, now), isTrue);
      expect(publicationInFlight({}, now), isFalse);
    });

    test('an expired publish mark no longer defers the audit', () {
      final plan = planReminderAudit(
        allWorkspacesReady: true,
        pendingById: const {},
        desiredProjectionIds: const {},
        preservedIds: const {},
        activeIds: const {},
        registry: {
          1: {
            'kind': 'reminder',
            'publicationPending': true,
            'publicationPendingAt': now
                .subtract(const Duration(hours: 1))
                .toIso8601String(),
          },
        },
        ledger: const {},
        now: now,
      );
      expect(plan.deferred, isFalse);
    });

    test('two projections wanted on one id both stay', () {
      PlatformReminderRequest request(String projection) =>
          PlatformReminderRequest(
            id: 5,
            title: '',
            body: '',
            payload: jsonEncode({'projectionId': projection}),
          );
      final plan = planReminderAudit(
        allWorkspacesReady: true,
        pendingById: {5: request('b')},
        desiredProjectionIds: {
          5: {'a', 'b'},
        },
        preservedIds: const {},
        activeIds: const {},
        registry: const {},
        ledger: const {},
        now: now,
      );
      expect(plan.cancel, isEmpty);
    });

    test('an active duplicate group with nothing wanted keeps the newest', () {
      PlatformActiveReminder shown(int id) => PlatformActiveReminder(
        id: id,
        title: '',
        body: '',
        payload: jsonEncode({'occurrenceId': 'o1', 'workspaceId': 'w'}),
      );
      final entry = <String, Object?>{'kind': 'reminder'};
      final cancel = planActiveDedupe(
        active: [shown(1), shown(2), shown(3)],
        registry: {1: entry, 2: entry, 3: entry},
        keepIds: const {},
        isAppChannel: (_) => true,
        ledger: {
          1: now.subtract(const Duration(days: 3)),
          2: now.subtract(const Duration(days: 1)),
          3: now.subtract(const Duration(days: 2)),
        },
        now: now,
      );
      expect(cancel, {1, 3});
    });

    group('retiredChannelsClear', () {
      bool clear({
        Map<int, Map<String, Object?>> registry = const {},
        Set<int> pending = const {},
        List<PlatformActiveReminder> active = const [],
        Set<int> wanted = const {},
      }) => retiredChannelsClear(
        registry: registry,
        pendingIds: pending,
        active: active,
        wantedIds: wanted,
        retiredChannelIds: {'dose_reminders'},
        currentRevision: 2,
      );

      test('is clear when nothing sits on an old revision', () {
        expect(
          clear(
            registry: {
              1: {'kind': 'reminder', 'channelRevision': 2},
            },
            pending: {1},
          ),
          isTrue,
        );
      });

      test('is blocked by a pending alarm recorded on an old revision', () {
        expect(
          clear(
            registry: {
              1: {'kind': 'reminder'},
            },
            pending: {1},
          ),
          isFalse,
        );
      });

      test(
        'is blocked by a wanted delivered reminder on a retired channel',
        () {
          expect(
            clear(
              active: [
                const PlatformActiveReminder(
                  id: 9,
                  title: '',
                  body: '',
                  channelId: 'dose_reminders',
                ),
              ],
              wanted: {9},
            ),
            isFalse,
          );
        },
      );

      test('ignores an unwanted, unregistered delivered stray', () {
        expect(
          clear(
            active: [
              const PlatformActiveReminder(
                id: 9,
                title: '',
                body: '',
                channelId: 'dose_reminders',
              ),
            ],
          ),
          isTrue,
        );
      });
    });
  });

  group('stabilizeReminderIds', () {
    test('a reminder that finds no free id is dropped and reported', () {
      const projectionId = 'abcdef0123456789abcdef0123456789';
      final occupied = {
        for (var probe = 0; probe <= maxNotificationIdProbe; probe++)
          notificationIdForProjection(projectionId, probe: probe),
      };
      var dropped = -1;
      final result = stabilizeReminderIds(
        [_reminder(1, _now, projectionId: projectionId)],
        preferred: const {},
        occupied: occupied,
        onDropped: (count) => dropped = count,
      );
      expect(result, isEmpty);
      expect(dropped, 1);
    });

    test('nothing is reported when every reminder finds an id', () {
      var called = false;
      final result = stabilizeReminderIds(
        [_reminder(1, _now, projectionId: 'abcdef0123456789abcdef0123456789')],
        preferred: const {},
        occupied: const {},
        onDropped: (_) => called = true,
      );
      expect(result, hasLength(1));
      expect(called, isFalse);
    });
  });
}
