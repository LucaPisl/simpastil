import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/notifications/next_reminders.dart';
import 'package:simpastil/core/notifications/reminder_preferences.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

import '../../helpers/care_recording_fixture.dart';
import '../../helpers/planned_dose_fixture.dart';

const _userId = 'next-user';
const _alex = '00000000-0000-4000-8000-0000000000a1';
const _sam = '00000000-0000-4000-8000-0000000000b2';
final _now = DateTime.utc(2026, 9, 24, 6);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tz_data.initializeTimeZones);

  group('planNextReminders', () {
    late AppDatabase db;
    final l = AppLocalizationsEn();

    setUp(() async {
      db = AppDatabase.forTesting();
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: _userId,
          email: 'next@test.invalid',
          createdAt: _now,
          updatedAt: _now,
        ),
      );
    });
    tearDown(() => db.close());

    /// Stores one planned dose and returns the stored row.
    Future<MedicationOccurrence> dose(
      String id, {
      required DateTime at,
      String pill = 'Fictional vitamin',
      String? dosage = '10 mg',
      String profileId = _alex,
      String profileName = 'Alex',
      String? scheduleId = 'schedule-1',
      String source = 'scheduled',
      String state = 'pending',
    }) => storePlannedDose(
      db,
      userId: _userId,
      id: id,
      at: at,
      now: _now,
      pill: pill,
      dosage: dosage,
      profileId: profileId,
      profileName: profileName,
      scheduleId: scheduleId,
      source: source,
      state: state,
    );

    NextRemindersPlan plan(
      List<MedicationOccurrence> occurrences, {
      Set<String> people = const {_alex, _sam},
      ReminderPreferences? preferences,
      int limit = 4,
      DateTime? now,
    }) => planNextReminders(
      NextRemindersSource(
        userId: _userId,
        identity: null,
        activeProfileIds: people,
        occurrences: occurrences,
        preferences: preferences ?? ReminderPreferences(),
      ),
      now: now ?? _now,
      localizations: l,
      limit: limit,
    );

    test(
      'lists the nearest doses first, whatever order they come in',
      () async {
        final late = await dose(
          'late',
          at: DateTime.utc(2026, 9, 24, 21),
          pill: 'Evening pill',
        );
        final soon = await dose(
          'soon',
          at: DateTime.utc(2026, 9, 24, 9),
          pill: 'Morning pill',
        );
        final tomorrow = await dose(
          'tomorrow',
          at: DateTime.utc(2026, 9, 25, 9),
          pill: 'Next day pill',
        );
        final result = plan([tomorrow, late, soon]);
        expect(result.upcoming.map((r) => r.occurrenceId), [
          'soon',
          'late',
          'tomorrow',
        ]);
        expect(result.first?.pillName, 'Morning pill');
        expect(result.first?.dosage, '10 mg');
        expect(result.first?.profileName, 'Alex');
        expect(result.first?.at, DateTime.utc(2026, 9, 24, 9).toLocal());
        expect(result.availableCount, 3);
        // Two people are switched on, so a list would name whose dose it is.
        expect(result.peopleCount, 2);
      },
    );

    test('stops at the limit but still counts what is planned', () async {
      final doses = [
        for (var hour = 7; hour < 13; hour++)
          await dose('dose-$hour', at: DateTime.utc(2026, 9, 24, hour)),
      ];
      final result = plan(doses, limit: 4);
      expect(result.upcoming, hasLength(4));
      expect(result.availableCount, 6);
      expect(result.upcoming.last.occurrenceId, 'dose-10');
      expect(plan(doses, limit: 2).upcoming, hasLength(2));
    });

    test('leaves out doses that are already due or past', () async {
      final past = await dose('past', at: DateTime.utc(2026, 9, 24, 5));
      final exactlyNow = await dose('now', at: _now);
      final ahead = await dose('ahead', at: DateTime.utc(2026, 9, 24, 7));
      expect(
        plan([past, exactlyNow, ahead]).upcoming.map((r) => r.occurrenceId),
        ['ahead'],
      );
    });

    test('leaves out taken, skipped and as needed doses', () async {
      final taken = await dose(
        'taken',
        at: DateTime.utc(2026, 9, 24, 8),
        state: 'taken',
      );
      final skipped = await dose(
        'skipped',
        at: DateTime.utc(2026, 9, 24, 9),
        state: 'skipped',
      );
      final prn = await dose(
        'prn',
        at: DateTime.utc(2026, 9, 24, 10),
        source: 'prn',
        scheduleId: null,
      );
      final pending = await dose('pending', at: DateTime.utc(2026, 9, 24, 11));
      final result = plan([taken, skipped, prn, pending]);
      expect(result.upcoming.map((r) => r.occurrenceId), ['pending']);
    });

    test('respects a schedule switched off on this device', () async {
      final off = await dose(
        'off',
        at: DateTime.utc(2026, 9, 24, 8),
        scheduleId: 'schedule-off',
      );
      final on = await dose(
        'on',
        at: DateTime.utc(2026, 9, 24, 9),
        scheduleId: 'schedule-on',
      );
      final result = plan(
        [off, on],
        preferences: ReminderPreferences(
          schedules: {'schedule-off': ScheduleReminderChoice(enabled: false)},
        ),
      );
      expect(result.upcoming.map((r) => r.occurrenceId), ['on']);
      expect(result.availableCount, 1);
    });

    test('respects people switched off for reminders on this device', () async {
      final alex = await dose('alex', at: DateTime.utc(2026, 9, 24, 8));
      final sam = await dose(
        'sam',
        at: DateTime.utc(2026, 9, 24, 9),
        profileId: _sam,
        profileName: 'Sam',
        scheduleId: 'schedule-2',
      );
      expect(
        plan([alex, sam], people: const {_sam}).upcoming.single.profileName,
        'Sam',
      );
      final nobody = plan([alex, sam], people: const {});
      expect(nobody.upcoming, isEmpty);
      expect(nobody.peopleCount, 0);
      expect(plan([alex, sam], people: const {_sam}).peopleCount, 1);
    });

    test('lists a dose once even when follow-ups are chosen', () async {
      final first = await dose('first', at: DateTime.utc(2026, 9, 24, 8));
      final result = plan(
        [first],
        preferences: ReminderPreferences(
          schedules: {
            'schedule-1': ScheduleReminderChoice(followUpMinutes: [15, 30]),
          },
        ),
      );
      expect(result.upcoming, hasLength(1));
      expect(result.availableCount, 1);
      expect(result.first?.at, DateTime.utc(2026, 9, 24, 8).toLocal());
    });

    test('does not list the follow-ups of a dose already reminded', () async {
      // The dose itself has already been reminded, so only its follow-ups
      // are ahead; they repeat the dose and are not listed again.
      final started = await dose(
        'started',
        at: DateTime.utc(2026, 9, 24, 5, 50),
      );
      final result = plan(
        [started],
        preferences: ReminderPreferences(
          schedules: {
            'schedule-1': ScheduleReminderChoice(followUpMinutes: [30]),
          },
        ),
      );
      expect(result.upcoming, isEmpty);
      expect(result.availableCount, 0);
    });

    test('keeps to the thirty day horizon the device schedules', () async {
      final inside = await dose(
        'inside',
        at: _now.add(const Duration(days: 29)),
      );
      final outside = await dose(
        'outside',
        at: _now.add(const Duration(days: 31)),
      );
      expect(plan([inside, outside]).upcoming.map((r) => r.occurrenceId), [
        'inside',
      ]);
    });

    test(
      'full details name the medicine, the amount and the actions',
      () async {
        final item = await dose('full', at: DateTime.utc(2026, 9, 24, 8));
        final result = plan([item]);
        expect(result.fullDetails, isTrue);
        expect(
          result.first?.copy.title,
          l.core_notifTitle('Fictional vitamin'),
        );
        expect(result.first?.copy.body, l.r6_notifDoseBody('10 mg'));
      },
    );

    test(
      'private copy keeps the medicine and the amount off the notification',
      () async {
        final item = await dose('private', at: DateTime.utc(2026, 9, 24, 8));
        final result = plan([
          item,
        ], preferences: ReminderPreferences(fullDetails: false));
        expect(result.fullDetails, isFalse);
        expect(result.first?.copy.title, l.core_notifPrivateTitle);
        expect(result.first?.copy.body, l.core_notifPrivateBody);
        expect(result.first?.copy.title, isNot(contains('Fictional vitamin')));
        expect(result.first?.copy.body, isNot(contains('10 mg')));
        // The list on the page still names the dose: only the notification
        // is private.
        expect(result.first?.pillName, 'Fictional vitamin');
      },
    );

    test('a dose with no amount has no dosage', () async {
      final item = await dose(
        'bare',
        at: DateTime.utc(2026, 9, 24, 8),
        dosage: null,
      );
      final result = plan([item]);
      expect(result.first?.dosage, isNull);
      expect(result.first?.copy.body, l.r6_notifNoDoseBody);
    });

    test('an unreadable dose is skipped, not guessed', () async {
      final good = await dose('good', at: DateTime.utc(2026, 9, 24, 8));
      await db.medicationLedgerDao.upsertOccurrence(
        MedicationOccurrencesCompanion.insert(
          id: 'broken',
          userId: _userId,
          scheduleId: const Value('schedule-1'),
          occurrenceKey: 'scheduled:v1:broken',
          source: 'scheduled',
          plannedLocalDate: '2026-09-24',
          timeZone: 'UTC',
          plannedAt: Value(DateTime.utc(2026, 9, 24, 7)),
          expected: const Value(true),
          scheduleSnapshotJson: '{}',
          provenance: 'exact',
          createdAt: _now,
          updatedAt: _now,
        ),
      );
      final broken = (await db.medicationLedgerDao.getOccurrencesForUser(
        _userId,
      )).firstWhere((row) => row.id == 'broken');
      expect(plan([broken, good]).upcoming.map((r) => r.occurrenceId), [
        'good',
      ]);
    });

    test('nothing planned gives an empty plan', () {
      final result = plan(const []);
      expect(result.upcoming, isEmpty);
      expect(result.first, isNull);
      expect(result.availableCount, 0);
    });
  });

  group('NextRemindersRepository', () {
    late CareRecordingFixture fixture;
    late NextRemindersRepository repository;
    final l = AppLocalizationsEn();
    // The fixture's dose is at 2026-09-30 09:00 UTC.
    final before = DateTime.utc(2026, 9, 30, 8);

    setUp(() async {
      fixture = await CareRecordingFixture.create();
      repository = NextRemindersRepository(
        database: fixture.db,
        access: fixture.workspace.access,
        context: fixture.workspace.context,
      );
    });
    tearDown(() => fixture.db.close());

    Future<void> switchPerson({required bool on}) => fixture.db
        .into(fixture.db.devicePersonReminders)
        .insertOnConflictUpdate(
          DevicePersonRemindersCompanion.insert(
            profileId: fixture.person.id,
            enabled: Value(on),
          ),
        );

    Future<NextRemindersPlan> planNow() async => planNextReminders(
      await repository.load(),
      now: before,
      localizations: l,
    );

    test('lists the local routine dose of a person switched on', () async {
      await switchPerson(on: true);
      final result = await planNow();
      expect(result.upcoming, hasLength(1));
      expect(result.first?.occurrenceId, fixture.occurrence.id);
      expect(result.first?.pillName, fixture.pill.name);
      expect(result.first?.profileName, fixture.person.name);
      expect(result.first?.at, CareRecordingFixture.planned.toLocal());
    });

    test(
      'lists nothing for a person not switched on for this device',
      () async {
        await switchPerson(on: false);
        expect((await planNow()).upcoming, isEmpty);
      },
    );

    test('follows the schedule choice and the privacy choice', () async {
      await switchPerson(on: true);
      final preferences = ReminderPreferencesRepository(
        database: fixture.db,
        access: fixture.workspace.access,
        context: fixture.workspace.context,
      );
      await preferences.setFullDetails(false);
      var result = await planNow();
      expect(result.fullDetails, isFalse);
      expect(result.first?.copy.title, l.core_notifPrivateTitle);

      await preferences.setSchedule(
        fixture.occurrence.scheduleId!,
        ScheduleReminderChoice(enabled: false),
      );
      result = await planNow();
      expect(result.upcoming, isEmpty);
    });

    test('a stream publishes again when a choice changes', () async {
      await switchPerson(on: true);
      final emissions = <int>[];
      final subscription = repository.watch().listen(
        (source) => emissions.add(source.occurrences.length),
      );
      addTearDown(subscription.cancel);
      await pumpEventQueue();
      expect(emissions.last, 1);
      await switchPerson(on: false);
      await pumpEventQueue();
      expect(emissions.last, 0);
    });
  });
}
