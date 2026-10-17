import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/dashboard/history_seen_from.dart';
import 'package:simpastil/features/dashboard/models/history_entry.dart';

HistoryEntry _entry(
  String person, {
  String? date,
  DateTime? takenAt,
  DateTime? recordedAt,
}) => HistoryEntry(
  doseLogId: '$person-${date ?? takenAt ?? recordedAt}',
  pillName: 'Fictional pill',
  scheduledAt: null,
  takenAt: takenAt,
  recordedAt: recordedAt,
  plannedLocalDate: date,
  status: 'taken',
  occurrenceState: 'taken',
  profileName: 'Fictional $person',
  personId: person,
  scheduleId: 'schedule-$person',
  source: date == null ? 'prn' : 'scheduled',
);

void main() {
  final firstSeen = {
    'mira': DateTime(2026, 10, 10, 18, 45),
    'ion': DateTime(2026, 10, 5, 7),
  };

  test('is the day this phone first knew the person', () {
    expect(
      historySeenFrom(people: ['mira'], firstSeen: firstSeen, entries: []),
      DateTime(2026, 10, 10),
    );
  });

  test('moves back to the oldest record, so no record is ever unseen', () {
    expect(
      historySeenFrom(
        people: ['mira'],
        firstSeen: firstSeen,
        entries: [_entry('mira', date: '2026-10-03')],
      ),
      DateTime(2026, 10, 3),
    );
    expect(
      historySeenFrom(
        people: ['mira'],
        firstSeen: firstSeen,
        entries: [
          _entry('mira', takenAt: DateTime(2026, 10, 1, 9)),
          _entry('mira', recordedAt: DateTime(2026, 9, 30, 22)),
        ],
      ),
      DateTime(2026, 9, 30),
      reason: 'as-needed doses have no planned day but still count',
    );
  });

  test('for everyone it is the earliest of all of them', () {
    expect(
      historySeenFrom(
        people: ['mira', 'ion'],
        firstSeen: firstSeen,
        entries: [],
      ),
      DateTime(2026, 10, 5),
    );
  });

  test('is unknown without a first-seen moment or anyone to view', () {
    expect(
      historySeenFrom(
        people: ['mira', 'nobody'],
        firstSeen: firstSeen,
        entries: [],
      ),
      isNull,
    );
    expect(
      historySeenFrom(people: [], firstSeen: firstSeen, entries: []),
      isNull,
    );
  });
}
