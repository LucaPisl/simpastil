import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/recorded_by.dart';
import 'package:simpastil/core/sync/medication_projection_merger.dart';

// The shared Recorded-by name on a pulled dose event, against the contract
// fixture the server tests also use.
const _userId = 'user-1';
const _profileId = '00000000-0000-4000-8000-000000000001';
const _pillId = '00000000-0000-4000-8000-000000000002';
const _scheduleId = '00000000-0000-4000-8000-000000000003';
const _occurrenceId = '00000000-0000-4000-8000-000000000004';
const _serverOccurrenceId = '00000000-0000-4000-8000-000000000007';

Future<AppDatabase> _database() async {
  final db = AppDatabase(NativeDatabase.memory());
  final now = DateTime.utc(2026, 9, 24, 5, 0);
  await db
      .into(db.users)
      .insert(
        UsersCompanion.insert(
          id: _userId,
          email: 'user@test.com',
          createdAt: now,
          updatedAt: now,
        ),
      );
  await db.profilesDao.upsert(
    ProfilesCompanion.insert(
      id: _profileId,
      userId: _userId,
      name: 'Ada',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await db.pillsDao.upsert(
    PillsCompanion.insert(
      id: _pillId,
      profileId: _profileId,
      name: 'Medication',
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
  await db.medicationLedgerDao.upsertOccurrence(
    MedicationOccurrencesCompanion.insert(
      id: _occurrenceId,
      userId: _userId,
      serverId: const Value(_serverOccurrenceId),
      pillId: const Value(_pillId),
      scheduleId: const Value(_scheduleId),
      occurrenceKey: 'scheduled:v1:fixture',
      source: 'scheduled',
      scheduleRevision: const Value(1),
      plannedLocalDate: '2026-09-24',
      plannedLocalTime: const Value('08:00'),
      timeZone: 'Europe/Bucharest',
      plannedAt: Value(now),
      expected: const Value(true),
      scheduleSnapshotJson: jsonEncode({
        'version': 1,
        'frequency': 'daily',
        'dosage': null,
        'frequencyDays': null,
        'hour': 8,
        'minute': 0,
        'profileId': _profileId,
        'profileName': 'Ada',
        'pillName': 'Medication',
        'timeZone': 'Europe/Bucharest',
      }),
      provenance: 'exact',
      createdAt: now,
      updatedAt: now,
    ),
  );
  return db;
}

Map<String, dynamic> _payload(Map<String, dynamic> change) =>
    Map<String, dynamic>.from(change['payload'] as Map)..remove('kind');

void main() {
  final fixture =
      jsonDecode(
            File(
              '../contracts/fixtures/medication-recorded-by-v1.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final cases = (fixture['eventChanges'] as List).cast<Map<String, dynamic>>();

  for (final c in cases) {
    test('contract fixture ${c['name']} reads as expected', () async {
      final db = await _database();
      addTearDown(db.close);
      await MedicationProjectionMerger(db).mergeOccurrenceEvent(
        _userId,
        _payload(c['change'] as Map<String, dynamic>),
      );
      final event = (await db.medicationLedgerDao.getEventsForOccurrence(
        _occurrenceId,
      )).single;
      final recordedBy = event.recordedBy;
      expect(recordedBy != null, c['expectedKnown']);
      expect(recordedBy?.name, c['expectedName']);
      // The shared name is also what the dose shows as its author.
      expect(careAuthorName(null, event), c['expectedName']);
    });
  }

  group('a name that cannot be read', () {
    Future<OccurrenceEvent> pulled(Object? recordedBy) async {
      final db = await _database();
      addTearDown(db.close);
      final change = cases.first['change'] as Map<String, dynamic>;
      final payload = _payload(change)..['recordedBy'] = recordedBy;
      await MedicationProjectionMerger(
        db,
      ).mergeOccurrenceEvent(_userId, payload);
      return (await db.medicationLedgerDao.getEventsForOccurrence(
        _occurrenceId,
      )).single;
    }

    test('an unknown version is ignored without failing the pull', () async {
      final event = await pulled({'version': 2, 'name': 'Mama'});
      expect(event.recordedBy, isNull);
      expect(event.recordedByJson, isNull);
    });

    test('a wrong shape is ignored without failing the pull', () async {
      expect((await pulled('Mama')).recordedBy, isNull);
      expect(
        (await pulled({'version': 1, 'name': ' Mama '})).recordedBy,
        isNull,
      );
      expect(
        (await pulled({'version': 1, 'name': 'M', 'extra': 1})).recordedBy,
        isNull,
      );
    });
  });

  test('the first shared name stays: a later pull never rewrites it', () async {
    final db = await _database();
    addTearDown(db.close);
    final merger = MedicationProjectionMerger(db);
    final change = cases.first['change'] as Map<String, dynamic>;
    await merger.mergeOccurrenceEvent(_userId, _payload(change));
    final again = _payload(change)
      ..['recordedBy'] = {'version': 1, 'name': 'Someone else'};
    await merger.mergeOccurrenceEvent(_userId, again);
    final event = (await db.medicationLedgerDao.getEventsForOccurrence(
      _occurrenceId,
    )).single;
    expect(event.recordedBy?.name, 'Mama');
  });

  test('the device that recorded the dose keeps its own typed name', () {
    final event = RecordedBy.fromWire({'version': 1, 'name': 'Shared'});
    expect(event?.name, 'Shared');
    expect(RecordedBy.snapshotName('  ${'x' * 120}  ')!.length, 100);
    expect(RecordedBy.snapshotName('   '), isNull);
  });
}
