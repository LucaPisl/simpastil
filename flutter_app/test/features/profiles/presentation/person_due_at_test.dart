import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:simpastil/features/profiles/presentation/profiles_screen.dart';

final _at = DateTime(2026, 10, 13, 12);

/// A fictional day: each dose is (id, hour, state, as needed).
CareDay _day(List<(String, int, String, bool)> doses) {
  final who = Profile(
    id: 'a',
    userId: 'u',
    name: 'Mira',
    avatarEmoji: '',
    isActive: true,
    createdAt: _at,
    updatedAt: _at,
    revision: 1,
    syncStatus: 'synced',
    isDeleted: false,
  );
  final pill = Pill(
    id: 'pill',
    stockNeedsRecount: false,
    profileId: who.id,
    name: 'Vitamin D',
    isPrn: false,
    createdAt: _at,
    updatedAt: _at,
    revision: 1,
    syncStatus: 'synced',
    isDeleted: false,
  );
  final snapshot = ScheduleSnapshotV1(
    pillName: 'Vitamin D',
    dosage: null,
    frequency: 'daily',
    frequencyDays: null,
    hour: 8,
    minute: 0,
    timeZone: 'UTC',
    profileId: who.id,
    profileName: who.name,
  );
  return CareDay(
    localDate: '2026-10-13',
    state: CareDayState.pending,
    people: [who],
    prn: const [],
    entries: [
      for (final (id, hour, state, prn) in doses)
        CareDayEntry(
          occurrence: MedicationOccurrence(
            id: id,
            userId: 'u',
            occurrenceKey: id,
            source: prn ? 'prn' : 'scheduled',
            plannedLocalDate: '2026-10-13',
            plannedLocalTime: '${hour.toString().padLeft(2, '0')}:00:00',
            plannedAt: DateTime(2026, 10, 13, hour),
            timeZone: 'UTC',
            expected: !prn,
            snapshotVersion: 1,
            scheduleSnapshotJson: jsonEncode(snapshot.toJson()),
            provenance: 'exact',
            state: state,
            stateVersion: 1,
            createdAt: _at,
            updatedAt: _at,
          ),
          person: who,
          pill: pill,
          snapshot: snapshot,
          plannedAmount: const MedicationAmount.unknown(),
          sharing: CareSharingOutcome.localOnly,
        ),
    ],
  );
}

void main() {
  test('the earliest pending dose that fell due leads', () {
    final day = _day([
      ('late', 11, 'pending', false),
      ('early', 9, 'pending', false),
      ('done', 8, 'taken', false),
    ]);
    expect(personDueAt(day, _at), DateTime(2026, 10, 13, 9));
  });

  test('doses still ahead, recorded or as needed are never due', () {
    final day = _day([
      ('ahead', 14, 'pending', false),
      ('missed', 8, 'missed', false),
      ('skipped', 9, 'skipped', false),
      ('prn', 10, 'pending', true),
    ]);
    expect(personDueAt(day, _at), isNull);
  });

  test('a dose falls due at its planned minute', () {
    final day = _day([('noon', 12, 'pending', false)]);
    expect(personDueAt(day, _at), _at);
    expect(personDueAt(null, _at), isNull);
  });
}
