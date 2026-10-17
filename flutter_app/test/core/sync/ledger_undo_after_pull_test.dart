import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/sync/medication_projection_merger.dart';

// Ledger-mode undo after a sync pull. The server mints its own occurrence
// event id, so the pulled inventory event names the server id while the local
// take event keeps the id the phone generated.
const _userId = 'user-1';
const _profileId = '00000000-0000-4000-8000-000000000001';
const _pillId = '00000000-0000-4000-8000-000000000002';
const _scheduleId = '00000000-0000-4000-8000-000000000003';
const _occurrenceId = '00000000-0000-4000-8000-000000000004';
const _serverOccurrenceId = '00000000-0000-4000-8000-0000000000a4';
const _serverEventId = '00000000-0000-4000-8000-0000000000e1';
const _serverInventoryId = '00000000-0000-4000-8000-0000000000e2';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
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
        currentStock: const Value(5),
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
  });

  tearDown(() => db.close());

  Future<void> pullTake(MedicationCommand take) async {
    final merger = MedicationProjectionMerger(db);
    final recordedAt = DateTime.utc(2026, 9, 24, 5, 1).toIso8601String();
    await merger.mergeOccurrenceEvent(_userId, {
      'id': _serverEventId,
      'commandId': take.commandId,
      'occurrenceId': _serverOccurrenceId,
      'action': 'take',
      'fromState': 'pending',
      'toState': 'taken',
      'reversesEventId': null,
      'rebasesCommandId': null,
      'actualAt': recordedAt,
      'actualTimeKnown': true,
      'note': null,
      'origin': 'native',
      'baseVersion': '0',
      'resultVersion': '1',
      'serverSequence': '10',
      'recordedAt': recordedAt,
    });
    await merger.mergeInventoryEvent(_userId, {
      'id': _serverInventoryId,
      'commandId': take.commandId,
      'pillId': _pillId,
      'eventKind': 'dose',
      'delta': -1,
      'occurrenceEventId': _serverEventId,
      'reversesInventoryEventId': null,
      'provenance': 'native',
      'note': null,
      'serverSequence': '11',
      'recordedAt': recordedAt,
    }, const {});
  }

  for (final bySeverId in [false, true]) {
    test('undo after take and pull finds the synced inventory event '
        '(reverses by ${bySeverId ? 'server' : 'local'} event id)', () async {
      final repository = MedicationRepository(db);
      final take = await repository.apply(
        userId: _userId,
        occurrenceId: _occurrenceId,
        action: MedicationAction.take,
        actualAt: DateTime.utc(2026, 9, 24, 5, 1),
        actualTimeKnown: true,
      );
      expect((await db.pillsDao.getById(_pillId))!.currentStock, 4);
      final localEvent = (await db.medicationLedgerDao.getEventsForOccurrence(
        _occurrenceId,
      )).single;
      await pullTake(take);
      final merged = (await db.medicationLedgerDao.getEventsForOccurrence(
        _occurrenceId,
      )).single;
      expect(merged.id, localEvent.id);
      expect(merged.serverId, _serverEventId);

      await repository.apply(
        userId: _userId,
        occurrenceId: _occurrenceId,
        action: MedicationAction.undo,
        actualTimeKnown: false,
        intendedState: MedicationState.pending,
        reversesEventId: bySeverId ? _serverEventId : localEvent.id,
      );
      expect((await db.pillsDao.getById(_pillId))!.currentStock, 5);
    });
  }
}
