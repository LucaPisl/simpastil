import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/daos/medication_ledger_dao.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

const _userId = 'reminder-user';
const _profileId = '00000000-0000-4000-8000-000000000001';
final _now = DateTime.utc(2026, 9, 24, 6);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(tz_data.initializeTimeZones);

  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting();
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: _userId,
        email: 'reminder@test.invalid',
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _profileId,
        userId: _userId,
        name: 'Private profile name',
        createdAt: _now,
        updatedAt: _now,
      ),
    );
  });

  tearDown(() => db.close());

  Future<List<MedicationOccurrenceRecord>> seed({
    int scheduledCount = 1,
    bool includeInvalidRows = false,
  }) async {
    for (var index = 0; index < scheduledCount; index++) {
      final scheduledAt = _now.add(Duration(minutes: index + 1));
      final snapshot = ScheduleSnapshotV1(
        pillName: 'Medicine $index',
        dosage: '10 mg',
        frequency: 'daily',
        frequencyDays: null,
        hour: 9,
        minute: 30,
        timeZone: 'Europe/Bucharest',
        profileId: _profileId,
        profileName: 'Private profile name',
      );
      await db.medicationLedgerDao.upsertOccurrence(
        MedicationOccurrencesCompanion.insert(
          id: 'occurrence-$index',
          userId: _userId,
          occurrenceKey: 'scheduled:v1:$index',
          source: 'scheduled',
          scheduleRevision: const Value(1),
          plannedLocalDate: '2026-09-24',
          plannedLocalTime: const Value('09:30'),
          timeZone: 'Europe/Bucharest',
          plannedAt: Value(scheduledAt),
          expected: const Value(true),
          scheduleSnapshotJson: jsonEncode(snapshot.toJson()),
          provenance: 'exact',
          createdAt: _now,
          updatedAt: _now,
        ),
      );
    }
    if (includeInvalidRows) {
      await db.medicationLedgerDao.upsertOccurrence(
        MedicationOccurrencesCompanion.insert(
          id: 'occurrence-prn',
          userId: _userId,
          occurrenceKey: 'prn:v1:1',
          source: 'prn',
          plannedLocalDate: '2026-09-24',
          timeZone: 'Europe/Bucharest',
          plannedAt: Value(_now.add(const Duration(minutes: 2))),
          expected: const Value(false),
          scheduleSnapshotJson: '{}',
          provenance: 'exact',
          createdAt: _now,
          updatedAt: _now,
        ),
      );
      await db.medicationLedgerDao.upsertOccurrence(
        MedicationOccurrencesCompanion.insert(
          id: 'occurrence-done',
          userId: _userId,
          occurrenceKey: 'scheduled:v1:done',
          source: 'scheduled',
          plannedLocalDate: '2026-09-24',
          timeZone: 'Europe/Bucharest',
          plannedAt: Value(_now.add(const Duration(minutes: 3))),
          expected: const Value(true),
          scheduleSnapshotJson: '{}',
          provenance: 'exact',
          state: const Value('taken'),
          createdAt: _now,
          updatedAt: _now,
        ),
      );
    }
    return [
      for (final occurrence
          in await db.medicationLedgerDao.getOccurrencesForUser(_userId))
        MedicationOccurrenceRecord(occurrence: occurrence, events: const []),
    ];
  }

  test(
    'uses exact occurrence instant and an identifier-only payload',
    () async {
      final records = await seed();
      final result = const ReminderProjectionBuilder().build(
        records: records,
        activeProfileIds: {_profileId},
        userId: _userId,
        sessionGeneration: 7,
        now: _now,
        platform: ReminderPlatformKind.android,
        localizations: AppLocalizationsEn(),
      );

      expect(result.reminders, hasLength(1));
      expect(
        result.reminders.single.scheduledAtUtc,
        _now.add(const Duration(minutes: 1)),
      );
      final payload =
          jsonDecode(result.reminders.single.payload) as Map<String, dynamic>;
      expect(payload.keys.toSet(), {
        'occurrenceId',
        'projectionId',
        'userId',
        'sessionGeneration',
      });
      expect(result.reminders.single.title, 'Time for Medicine 0');
      expect(result.reminders.single.body, '10 mg, when you’re ready');
    },
  );

  test(
    'iOS schedules the earliest 64 and reports shortened coverage',
    () async {
      final records = await seed(scheduledCount: 70);
      final result = const ReminderProjectionBuilder().build(
        records: records,
        activeProfileIds: {_profileId},
        userId: _userId,
        sessionGeneration: 7,
        now: _now,
        platform: ReminderPlatformKind.ios,
        localizations: AppLocalizationsEn(),
      );

      expect(result.availableCount, 70);
      expect(result.reminders, hasLength(64));
      expect(result.reminders.first.occurrenceId, 'occurrence-0');
      expect(result.reminders.last.occurrenceId, 'occurrence-63');
      expect(result.coverageShortened, isTrue);
    },
  );

  test('excludes PRN, completed, and disabled-profile occurrences', () async {
    final records = await seed(includeInvalidRows: true);
    final result = const ReminderProjectionBuilder().build(
      records: records,
      activeProfileIds: const {},
      userId: _userId,
      sessionGeneration: 7,
      now: _now,
      platform: ReminderPlatformKind.android,
      localizations: AppLocalizationsEn(),
    );

    expect(result.reminders, isEmpty);

    final enabled = const ReminderProjectionBuilder().build(
      records: records,
      activeProfileIds: {_profileId},
      userId: _userId,
      sessionGeneration: 7,
      now: _now,
      platform: ReminderPlatformKind.android,
      localizations: AppLocalizationsEn(),
    );
    expect(enabled.reminders.map((reminder) => reminder.occurrenceId), [
      'occurrence-0',
    ]);
  });

  test(
    'an id collision gets a deterministic probe id and never throws',
    () async {
      // Birthday search over the 30-bit id space for two colliding occurrences.
      final seen = <int, String>{};
      String? first;
      String? second;
      for (var n = 0; first == null; n++) {
        final occurrenceId = 'collide-$n';
        final id = notificationIdForProjection(
          reminderProjectionId(
            userId: _userId,
            sessionGeneration: 7,
            occurrenceId: occurrenceId,
            kind: 'reminder',
          ),
        );
        final other = seen[id];
        if (other != null) {
          first = other;
          second = occurrenceId;
        } else {
          seen[id] = occurrenceId;
        }
      }
      final snapshot = ScheduleSnapshotV1(
        pillName: 'Medicine',
        dosage: null,
        frequency: 'daily',
        frequencyDays: null,
        hour: 9,
        minute: 30,
        timeZone: 'Europe/Bucharest',
        profileId: _profileId,
        profileName: 'Private profile name',
      );
      var minute = 1;
      for (final id in [first, second!]) {
        await db.medicationLedgerDao.upsertOccurrence(
          MedicationOccurrencesCompanion.insert(
            id: id,
            userId: _userId,
            occurrenceKey: 'scheduled:v1:$id',
            source: 'scheduled',
            scheduleRevision: const Value(1),
            plannedLocalDate: '2026-09-24',
            plannedLocalTime: const Value('09:30'),
            timeZone: 'Europe/Bucharest',
            plannedAt: Value(_now.add(Duration(minutes: minute++))),
            expected: const Value(true),
            scheduleSnapshotJson: jsonEncode(snapshot.toJson()),
            provenance: 'exact',
            createdAt: _now,
            updatedAt: _now,
          ),
        );
      }
      final records = await db.medicationLedgerDao.getOccurrencesForUser(
        _userId,
      );
      List<ReminderProjection> build() => const ReminderProjectionBuilder()
          .build(
            records: [
              for (final o in records)
                MedicationOccurrenceRecord(occurrence: o, events: const []),
            ],
            activeProfileIds: {_profileId},
            userId: _userId,
            sessionGeneration: 7,
            now: _now,
            platform: ReminderPlatformKind.android,
            localizations: AppLocalizationsEn(),
          )
          .reminders;

      final reminders = build();
      expect(reminders, hasLength(2));
      expect(reminders.map((r) => r.notificationId).toSet(), hasLength(2));
      for (final reminder in reminders) {
        expect(
          notificationIdMatchesProjection(
            reminder.projectionId,
            reminder.notificationId,
          ),
          isTrue,
        );
      }
      // The assignment is deterministic across builds.
      expect(
        build().map((r) => (r.projectionId, r.notificationId)).toList(),
        reminders.map((r) => (r.projectionId, r.notificationId)).toList(),
      );
    },
  );
}
