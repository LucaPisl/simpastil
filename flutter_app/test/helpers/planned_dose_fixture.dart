import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';

/// Stores one planned, pending dose of fictional medication for [userId] and
/// returns the stored row, as the occurrence model keeps it.
///
/// [now] only stamps the row's creation time.
Future<MedicationOccurrence> storePlannedDose(
  AppDatabase db, {
  required String userId,
  required String id,
  required DateTime at,
  required DateTime now,
  required String profileId,
  required String profileName,
  String pill = 'Fictional vitamin',
  String? dosage = '10 mg',
  String? scheduleId = 'schedule-1',
  String source = 'scheduled',
  String state = 'pending',
}) async {
  final snapshot = ScheduleSnapshotV1(
    pillName: pill,
    dosage: dosage,
    frequency: 'daily',
    frequencyDays: null,
    hour: at.hour,
    minute: at.minute,
    timeZone: 'UTC',
    profileId: profileId,
    profileName: profileName,
  );
  await db.medicationLedgerDao.upsertOccurrence(
    MedicationOccurrencesCompanion.insert(
      id: id,
      userId: userId,
      scheduleId: Value(scheduleId),
      occurrenceKey: 'scheduled:v1:$id',
      source: source,
      scheduleRevision: const Value(1),
      plannedLocalDate: '2026-09-24',
      plannedLocalTime: const Value('09:00'),
      timeZone: 'UTC',
      plannedAt: Value(at),
      expected: Value(source == 'scheduled'),
      scheduleSnapshotJson: jsonEncode(snapshot.toJson()),
      provenance: 'exact',
      state: Value(state),
      createdAt: now,
      updatedAt: now,
    ),
  );
  return (await db.medicationLedgerDao.getOccurrencesForUser(
    userId,
  )).firstWhere((row) => row.id == id);
}
