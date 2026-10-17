import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

Future<Map<String, dynamic>> _fixture() async =>
    jsonDecode(
          await File(
            '../contracts/fixtures/occurrence-materializer-v1.json',
          ).readAsString(),
        )
        as Map<String, dynamic>;

ScheduledOccurrenceSource _source(
  Map<String, dynamic> identity,
  Map<String, dynamic> snapshot, {
  String? frequency,
  List<int>? frequencyDays,
  int? hour,
  int? minute,
  String? timeZone,
  String? revision,
  bool isActive = true,
  DateTime? deletedAt,
}) {
  return ScheduledOccurrenceSource(
    userId: identity['userId'] as String,
    id: identity['scheduleId'] as String,
    scheduleRevision: revision ?? identity['scheduleRevision'] as String,
    pillId: '66666666-6666-4666-8666-666666666666',
    pillName: snapshot['pillName'] as String,
    dosage: snapshot['dosage'] as String?,
    frequency: frequency ?? snapshot['frequency'] as String,
    frequencyDays:
        frequencyDays ?? (snapshot['frequencyDays'] as List?)?.cast<int>(),
    hour: hour ?? snapshot['hour'] as int,
    minute: minute ?? snapshot['minute'] as int,
    timeZone: timeZone ?? snapshot['timeZone'] as String,
    profileId: snapshot['profileId'] as String,
    profileName: snapshot['profileName'] as String,
    isActive: isActive,
    deletedAt: deletedAt,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(tz_data.initializeTimeZones);

  test(
    'matches the shared occurrence identity, snapshot, and DST vectors',
    () async {
      final fixture = await _fixture();
      expect(fixture['version'], 1);
      final identity = fixture['identity'] as Map<String, dynamic>;
      final snapshot = identity['snapshot'] as Map<String, dynamic>;
      final materializer = OccurrenceMaterializer();

      final overlap = identity['dstOverlap'] as Map<String, dynamic>;
      final overlapSnapshot = {...snapshot, 'hour': 3, 'minute': 30};
      final overlapSource = _source(
        identity,
        overlapSnapshot,
        hour: 3,
        minute: 30,
        timeZone: overlap['timeZone'] as String,
      );
      final overlapSlot = materializer
          .materialize(
            source: overlapSource,
            fromLocalDate: overlap['intendedLocalDate'] as String,
            throughLocalDate: overlap['intendedLocalDate'] as String,
          )
          .single;
      expect(
        overlapSlot.plannedAt.toUtc().toIso8601String(),
        overlap['resolvedInstant'],
      );
      expect(overlapSlot.occurrenceKey, overlap['occurrenceKey']);

      final gap = identity['dstGap'] as Map<String, dynamic>;
      final gapSource = _source(
        identity,
        snapshot,
        hour: 3,
        minute: 30,
        timeZone: gap['timeZone'] as String,
      );
      final gapSlot = materializer
          .materialize(
            source: gapSource,
            fromLocalDate: gap['intendedLocalDate'] as String,
            throughLocalDate: gap['intendedLocalDate'] as String,
          )
          .single;
      expect(
        gapSlot.plannedAt.toUtc().toIso8601String(),
        gap['resolvedLocalInstant'],
      );
      expect(gapSlot.occurrenceKey, gap['occurrenceKey']);

      expect(overlapSlot.scheduleSnapshot.toJson(), overlapSnapshot);
    },
  );

  test('implements every shared calendar and identity case', () async {
    final fixture = await _fixture();
    final identity = fixture['identity'] as Map<String, dynamic>;
    final snapshot = identity['snapshot'] as Map<String, dynamic>;
    final materializer = OccurrenceMaterializer();
    final cases = fixture['calendarCases'] as List<dynamic>;
    final handled = <String>{};

    for (final rawCase in cases) {
      final item = rawCase as Map<String, dynamic>;
      final id = item['id'] as String;
      handled.add(id);
      switch (id) {
        case 'leap-day':
        case 'month-boundary':
          final slots = materializer.materialize(
            source: _source(identity, snapshot),
            fromLocalDate: item['from'] as String,
            throughLocalDate: item['through'] as String,
          );
          expect(
            slots.map((slot) => slot.plannedLocalDate).toList(),
            item['dailyExpectedLocalDates'],
          );
        case 'weekly-iso-monday':
          final slots = materializer.materialize(
            source: _source(
              identity,
              snapshot,
              frequency: 'weekly',
              frequencyDays: [1],
            ),
            fromLocalDate: '2026-06-01',
            throughLocalDate: '2026-06-07',
          );
          expect(
            slots.map((slot) => slot.plannedLocalDate).toList(),
            item['expectedLocalDates'],
          );
        case 'custom-sorted':
          final slots = materializer.materialize(
            source: _source(
              identity,
              snapshot,
              frequency: 'custom',
              frequencyDays: (item['frequencyDaysInput'] as List).cast<int>(),
            ),
            fromLocalDate: '2026-06-01',
            throughLocalDate: '2026-06-07',
          );
          expect(
            slots.first.scheduleSnapshot.frequencyDays,
            item['frequencyDaysSnapshot'],
          );
        case 'daily-null-days':
          expect(
            materializer
                .materialize(
                  source: _source(identity, snapshot, frequencyDays: null),
                  fromLocalDate: '2026-01-01',
                  throughLocalDate: '2026-01-03',
                )
                .length,
            3,
          );
        case 'prn-null-days':
          expect(
            materializer
                .materialize(
                  source: _source(
                    identity,
                    snapshot,
                    frequency: 'prn',
                    frequencyDays: null,
                  ),
                  fromLocalDate: '2026-01-01',
                  throughLocalDate: '2026-01-03',
                )
                .length,
            item['scheduledOccurrenceCount'],
          );
        case 'two-same-day-prn':
          expect(
            (item['occurrenceIds'] as List)
                .cast<String>()
                .map(materializer.prnOccurrenceKey)
                .toList(),
            item['expectedKeys'],
          );
        case 'timezone-change':
        case 'schedule-revision-edit':
          final original = materializer
              .materialize(
                source: _source(identity, snapshot),
                fromLocalDate: '2026-06-01',
                throughLocalDate: '2026-06-01',
              )
              .single;
          final changed = materializer
              .materialize(
                source: _source(
                  identity,
                  snapshot,
                  revision: '2',
                  timeZone: id == 'timezone-change'
                      ? item['timeZone'] as String
                      : snapshot['timeZone'] as String,
                ),
                fromLocalDate: '2026-06-01',
                throughLocalDate: '2026-06-01',
              )
              .single;
          expect(changed.occurrenceKey, isNot(original.occurrenceKey));
          if (id == 'schedule-revision-edit') {
            expect(changed.scheduleRevision, item['keyUsesScheduleRevision']);
          }
        case 'inactive-schedule':
          expect(
            materializer
                .materialize(
                  source: _source(identity, snapshot, isActive: false),
                  fromLocalDate: '2026-01-01',
                  throughLocalDate: '2026-01-03',
                )
                .length,
            item['expectedOccurrenceCount'],
          );
        case 'deleted-schedule':
          expect(
            materializer
                .materialize(
                  source: _source(
                    identity,
                    snapshot,
                    deletedAt: DateTime.parse(item['deletedAt'] as String),
                  ),
                  fromLocalDate: '2026-01-01',
                  throughLocalDate: '2026-01-03',
                )
                .length,
            item['expectedOccurrenceCount'],
          );
        case 'already-acted':
          expect(
            materializer.canSupersede(
              plannedAt: DateTime.utc(2026, 12, 1),
              stateVersion: int.parse(item['stateVersion'].toString()),
              hasOccurrenceEvent: item['hasOccurrenceEvent'] as bool,
              now: DateTime.utc(2026, 6, 1),
            ),
            isFalse,
          );
        case 'future-untouched':
          expect(
            materializer.canSupersede(
              plannedAt: DateTime.utc(2026, 12, 1),
              stateVersion: int.parse(item['stateVersion'].toString()),
              hasOccurrenceEvent: item['hasOccurrenceEvent'] as bool,
              now: DateTime.utc(2026, 6, 1),
            ),
            isTrue,
          );
        default:
          fail('Unhandled occurrence fixture case: $id');
      }
    }

    expect(handled, hasLength(cases.length));
  });
}
