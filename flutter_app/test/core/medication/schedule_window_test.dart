import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/local_occurrence_snapshot.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/schedule_window.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

const _userId = '11111111-1111-4111-8111-111111111111';

ScheduledOccurrenceSource _source({
  String frequency = 'daily',
  List<int>? frequencyDays,
  int hour = 8,
  int minute = 30,
  String timeZone = 'Europe/Bucharest',
  int? everyDays,
  String? anchorDate,
  String? startDate,
  String? endDate,
}) => ScheduledOccurrenceSource(
  userId: _userId,
  id: '22222222-2222-4222-8222-222222222222',
  scheduleRevision: '1',
  pillId: '44444444-4444-4444-8444-444444444444',
  pillName: 'Example medication',
  dosage: '10mg',
  frequency: frequency,
  frequencyDays: frequencyDays,
  hour: hour,
  minute: minute,
  timeZone: timeZone,
  profileId: '33333333-3333-4333-8333-333333333333',
  profileName: 'Example profile',
  everyDays: everyDays,
  anchorDate: anchorDate,
  startDate: startDate,
  endDate: endDate,
);

void main() {
  setUpAll(tz_data.initializeTimeZones);

  late Map<String, dynamic> fixture;
  setUpAll(() async {
    fixture =
        jsonDecode(
              await File(
                '../contracts/fixtures/occurrence-materializer-v3.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
  });

  test('every shared interval and window case yields the same local dates', () {
    final materializer = OccurrenceMaterializer();
    for (final raw in fixture['cases'] as List) {
      final item = raw as Map<String, dynamic>;
      final slots = materializer.materialize(
        source: _source(
          frequency: item['frequency'] as String,
          frequencyDays: (item['frequencyDays'] as List?)?.cast<int>(),
          hour: item['hour'] as int? ?? 8,
          minute: item['minute'] as int? ?? 30,
          timeZone: item['timeZone'] as String? ?? 'Europe/Bucharest',
          everyDays: item['everyDays'] as int?,
          anchorDate: item['anchorDate'] as String?,
          startDate: item['startDate'] as String?,
          endDate: item['endDate'] as String?,
        ),
        fromLocalDate: item['from'] as String,
        throughLocalDate: item['through'] as String,
      );
      expect(
        slots.map((slot) => slot.plannedLocalDate).toList(),
        item['expectedLocalDates'],
        reason: item['id'] as String,
      );
      final instants = item['expectedInstants'] as Map<String, dynamic>?;
      for (final slot in slots) {
        final expected = instants?[slot.plannedLocalDate];
        if (expected != null) {
          expect(slot.plannedAt.toUtc().toIso8601String(), expected);
        }
      }
    }
  });

  test('interval and window slots carry snapshot version 3', () {
    final slots = OccurrenceMaterializer().materialize(
      source: _source(
        frequency: 'interval',
        everyDays: 3,
        anchorDate: '2026-03-01',
      ),
      fromLocalDate: '2026-03-01',
      throughLocalDate: '2026-03-04',
    );
    expect(slots, hasLength(2));
    for (final slot in slots) {
      expect(slot.scheduleSnapshot, isA<ScheduleSnapshotV3>());
      expect(slot.scheduleSnapshot.toJson(), {
        ...(fixture['snapshotV3'] as Map)['interval'] as Map<String, dynamic>,
      });
    }
    final windowed = OccurrenceMaterializer().materialize(
      source: _source(startDate: '2026-06-03', endDate: '2026-06-05'),
      fromLocalDate: '2026-06-03',
      throughLocalDate: '2026-06-03',
    );
    expect(
      windowed.single.scheduleSnapshot.toJson(),
      (fixture['snapshotV3'] as Map)['dailyWithWindow'],
    );
  });

  test('a schedule without the new fields keeps its version 1 snapshot', () {
    final slot = OccurrenceMaterializer()
        .materialize(
          source: _source(),
          fromLocalDate: '2026-06-03',
          throughLocalDate: '2026-06-03',
        )
        .single;
    expect(slot.scheduleSnapshot, isNot(isA<ScheduleSnapshotV3>()));
    expect(slot.scheduleSnapshot.toJson(), {
      'version': 1,
      'pillName': 'Example medication',
      'dosage': '10mg',
      'frequency': 'daily',
      'frequencyDays': null,
      'hour': 8,
      'minute': 30,
      'timeZone': 'Europe/Bucharest',
      'profileId': '33333333-3333-4333-8333-333333333333',
      'profileName': 'Example profile',
    });
  });

  test('the occurrence key ignores the interval and the window', () {
    final plain = OccurrenceMaterializer().materialize(
      source: _source(),
      fromLocalDate: '2026-06-03',
      throughLocalDate: '2026-06-03',
    );
    final windowed = OccurrenceMaterializer().materialize(
      source: _source(startDate: '2026-06-01', endDate: '2026-06-30'),
      fromLocalDate: '2026-06-03',
      throughLocalDate: '2026-06-03',
    );
    expect(windowed.single.occurrenceKey, plain.single.occurrenceKey);
    expect(windowed.single.occurrenceKey, startsWith('scheduled:v1:'));
  });

  test('snapshot version 3 round trips and v1 still decodes', () {
    for (final raw in (fixture['snapshotV3'] as Map).values) {
      final json = raw as Map<String, dynamic>;
      final decoded = decodeScheduleSnapshot(json);
      expect(decoded, isA<ScheduleSnapshotV3>());
      expect(decoded.toJson(), json);
      expect(decodeScheduleSnapshot(decoded.toJson()).toJson(), json);
    }
    final v1 = {
      'version': 1,
      'pillName': 'Example medication',
      'dosage': null,
      'frequency': 'daily',
      'frequencyDays': null,
      'hour': 8,
      'minute': 30,
      'timeZone': 'Europe/Bucharest',
      'profileId': 'p',
      'profileName': 'Person',
    };
    expect(decodeScheduleSnapshot(v1), isNot(isA<ScheduleSnapshotV3>()));
    expect(decodeScheduleSnapshot(v1).toJson(), v1);
    expect(
      () => decodeScheduleSnapshot({
        ...(fixture['snapshotV3'] as Map)['interval'] as Map<String, dynamic>,
        'everyDays': 'three',
      }),
      throwsFormatException,
    );
    expect(
      () => decodeScheduleSnapshot({...v1, 'version': 4}),
      throwsFormatException,
    );
  });

  test('the materializer refuses an invalid interval or window', () {
    final materializer = OccurrenceMaterializer();
    for (final bad in [
      _source(frequency: 'interval'),
      _source(frequency: 'interval', everyDays: 0, anchorDate: '2026-03-01'),
      _source(frequency: 'daily', everyDays: 2, anchorDate: '2026-03-01'),
      _source(startDate: '2026-06-05', endDate: '2026-06-01'),
    ]) {
      expect(
        () => materializer.materialize(
          source: bad,
          fromLocalDate: '2026-06-01',
          throughLocalDate: '2026-06-03',
        ),
        throwsA(anything),
      );
    }
  });

  group('ScheduleWindow', () {
    test('json keeps all four keys and reads a missing key as null', () {
      const window = ScheduleWindow(everyDays: 3, anchorDate: '2026-03-01');
      expect(window.toJson(), {
        'everyDays': 3,
        'anchorDate': '2026-03-01',
        'startDate': null,
        'endDate': null,
      });
      expect(ScheduleWindow.fromJson(const {}).isSet, isFalse);
      expect(ScheduleWindow.fromJson(window.toJson()), window);
    });

    test('validates the contract shapes', () {
      bool ok(String f, ScheduleWindow w) => w.isValidFor(f);
      expect(ok('daily', const ScheduleWindow()), isTrue);
      expect(
        ok(
          'interval',
          const ScheduleWindow(everyDays: 2, anchorDate: '2026-01-01'),
        ),
        isTrue,
      );
      expect(ok('interval', const ScheduleWindow(everyDays: 2)), isFalse);
      expect(
        ok(
          'interval',
          const ScheduleWindow(everyDays: 36501, anchorDate: '2026-01-01'),
        ),
        isFalse,
      );
      expect(
        ok(
          'daily',
          const ScheduleWindow(everyDays: 2, anchorDate: '2026-01-01'),
        ),
        isFalse,
      );
      expect(ok('prn', const ScheduleWindow(startDate: '2026-01-01')), isFalse);
      expect(
        ok('weekly', const ScheduleWindow(startDate: '2026-02-30')),
        isFalse,
      );
      expect(
        ok(
          'daily',
          const ScheduleWindow(startDate: '2026-02-01', endDate: '2026-01-01'),
        ),
        isFalse,
      );
      expect(
        ok(
          'daily',
          const ScheduleWindow(startDate: '2026-01-01', endDate: '2026-01-01'),
        ),
        isTrue,
      );
    });

    test('the interval rule matches RoutineDefinition.includes', () {
      final definition = RoutineDefinition(
        kind: RoutineKind.interval,
        timeZone: 'Europe/Bucharest',
        everyDays: 4,
        anchorDate: '2026-02-26',
        times: [const RoutineTime(slotId: 'm', hour: 8, minute: 0)],
      );
      const window = ScheduleWindow(everyDays: 4, anchorDate: '2026-02-26');
      for (var i = -3; i < 60; i++) {
        final date = DateTime.utc(2026, 2, 26).add(Duration(days: i));
        expect(
          scheduleWindowIncludes('interval', window, date),
          definition.includes(date),
          reason: '$date',
        );
      }
    });
  });
}
