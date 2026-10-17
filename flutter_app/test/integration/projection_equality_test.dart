import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/daos/medication_ledger_dao.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/occurrence_history.dart';
import 'package:simpastil/features/analytics/adherence.dart';

void main() {
  late AppDatabase db;
  final now = DateTime.utc(2026, 9, 25, 12);

  setUp(() async {
    db = AppDatabase.forTesting();
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: 'acceptance-user',
        email: 'acceptance-user@example.invalid',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await _insertOccurrence(
      db,
      id: 'scheduled-taken',
      now: now,
      plannedAt: DateTime.utc(2026, 9, 25, 8),
      state: 'taken',
      source: 'scheduled',
      expected: true,
    );
    await _insertOccurrence(
      db,
      id: 'scheduled-skipped',
      now: now,
      plannedAt: DateTime.utc(2026, 9, 25, 9),
      state: 'skipped',
      source: 'scheduled',
      expected: true,
    );
    await _insertOccurrence(
      db,
      id: 'scheduled-future',
      now: now,
      plannedAt: DateTime.utc(2026, 9, 25, 18),
      state: 'pending',
      source: 'scheduled',
      expected: true,
    );
    await _insertOccurrence(
      db,
      id: 'prn-taken',
      now: now,
      plannedAt: null,
      state: 'taken',
      source: 'prn',
      expected: false,
    );
    await db.medicationLedgerDao.appendOccurrenceEvent(
      OccurrenceEventsCompanion.insert(
        id: 'event-scheduled-taken',
        userId: 'acceptance-user',
        occurrenceId: 'scheduled-taken',
        commandId: 'command-scheduled-taken',
        action: 'take',
        fromState: 'pending',
        toState: 'taken',
        actualAt: Value(DateTime.utc(2026, 9, 25, 8, 4)),
        actualTimeKnown: const Value(true),
        origin: 'native',
        baseVersion: 0,
        resultVersion: 1,
        recordedAt: DateTime.utc(2026, 9, 25, 8, 4),
      ),
    );
  });

  tearDown(() => db.close());

  test(
    'history and daily analytics project equal counts from the same occurrence ledger',
    () async {
      final occurrences = await db.select(db.medicationOccurrences).get();
      final records = <MedicationOccurrenceRecord>[
        for (final occurrence in occurrences)
          MedicationOccurrenceRecord(
            occurrence: occurrence,
            events: await db.medicationLedgerDao.getEventsForOccurrence(
              occurrence.id,
            ),
          ),
      ];
      final summary = calculateOccurrenceAdherence(records: records, now: now);
      final day = dayAdherenceFromOccurrences(
        records: records,
        day: DateTime(2026, 9, 25),
        now: now,
      );

      expect(summary.dueScheduled, 2);
      expect(summary.takenScheduled, 1);
      expect(summary.skippedScheduled, 1);
      expect(summary.prnTaken, 1);
      expect(day, (taken: 1, skipped: 1, missed: 0, expected: 2));
      expect(
        adherenceRatio(day.taken, day.skipped, day.expected),
        summary.scheduledAdherence,
      );
    },
  );
}

Future<void> _insertOccurrence(
  AppDatabase db, {
  required String id,
  required DateTime now,
  required DateTime? plannedAt,
  required String state,
  required String source,
  required bool expected,
}) async {
  const localDate = '2026-09-25';
  await db.medicationLedgerDao.upsertOccurrence(
    MedicationOccurrencesCompanion.insert(
      id: id,
      userId: 'acceptance-user',
      occurrenceKey: 'acceptance:$id',
      source: source,
      plannedLocalDate: localDate,
      timeZone: 'Europe/Bucharest',
      scheduleSnapshotJson: jsonEncode({'version': 1, 'pillName': 'Fixture'}),
      provenance: 'exact',
      state: Value(state),
      expected: Value(expected),
      plannedLocalTime: plannedAt == null
          ? const Value.absent()
          : const Value('08:00:00'),
      plannedAt: Value(plannedAt),
      createdAt: now,
      updatedAt: now,
    ),
  );
}
