import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/daos/medication_ledger_dao.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/local_occurrence_snapshot.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';
import 'package:simpastil/l10n/app_localizations_ro.dart';
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

  Future<String> bodyFor(
    String quantity,
    String unit,
    AppLocalizations l,
  ) async {
    final snapshot = LocalOccurrenceSnapshot(
      pillName: 'Medicine',
      dosage: null,
      hour: 9,
      minute: 30,
      timeZone: 'Europe/Bucharest',
      profileId: _profileId,
      profileName: 'Private profile name',
      workspaceId: 'workspace',
      ownerUserId: _userId,
      routineId: 'routine',
      routineRevision: 1,
      slotId: 'morning',
      amount: MedicationAmount.known(quantity, unit),
      routineDefinition: RoutineDefinition(
        kind: RoutineKind.daily,
        timeZone: 'Europe/Bucharest',
        times: [const RoutineTime(slotId: 'morning', hour: 9, minute: 30)],
        weekdays: const [],
      ),
    );
    await db.medicationLedgerDao.upsertOccurrence(
      MedicationOccurrencesCompanion.insert(
        id: 'occurrence',
        userId: _userId,
        occurrenceKey: 'scheduled:v1:$quantity$unit',
        source: 'scheduled',
        scheduleRevision: const Value(1),
        plannedLocalDate: '2026-09-24',
        plannedLocalTime: const Value('09:30'),
        timeZone: 'Europe/Bucharest',
        plannedAt: Value(_now.add(const Duration(minutes: 1))),
        expected: const Value(true),
        scheduleSnapshotJson: jsonEncode(snapshot.toJson()),
        provenance: 'exact',
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    final records = [
      for (final o in await db.medicationLedgerDao.getOccurrencesForUser(
        _userId,
      ))
        MedicationOccurrenceRecord(occurrence: o, events: const []),
    ];
    final result = const ReminderProjectionBuilder().build(
      records: records,
      activeProfileIds: {_profileId},
      userId: _userId,
      sessionGeneration: 7,
      now: _now,
      platform: ReminderPlatformKind.android,
      localizations: l,
    );
    return result.reminders.single.body;
  }

  test('a Romanian notification names the unit in Romanian', () async {
    for (final (quantity, unit, expected) in [
      ('1', 'tablet', '1 comprimat'),
      ('2', 'tablet', '2 comprimate'),
      ('20', 'tablet', '20 de comprimate'),
      ('1/2', 'tablet', '½ comprimat'),
      ('1', 'capsule', '1 capsulă'),
      ('500', 'mg', '500 mg'),
    ]) {
      final body = await bodyFor(quantity, unit, AppLocalizationsRo());
      expect(body, contains(expected), reason: '$quantity $unit');
      expect(body, isNot(contains('tablet')), reason: '$quantity $unit');
      await db.customStatement('DELETE FROM medication_occurrences');
    }
  });

  test('an English notification keeps English unit names', () async {
    final body = await bodyFor('2', 'tablet', AppLocalizationsEn());
    expect(body, contains('2 tablets'));
  });
}
