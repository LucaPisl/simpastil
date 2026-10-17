import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/adherence_calculator.dart';

void main() {
  group('AdherenceCalculator', () {
    test('counts all due scheduled occurrences and separates outcomes', () {
      final now = DateTime.utc(2026, 6, 1, 12);
      final result = const AdherenceCalculator().calculate(
        now: now,
        occurrences: [
          AdherenceOccurrence(
            id: 'taken',
            source: 'scheduled',
            expected: true,
            plannedAt: DateTime.utc(2026, 6, 1, 8),
            state: 'taken',
            provenance: 'exact',
          ),
          AdherenceOccurrence(
            id: 'skipped',
            source: 'scheduled',
            expected: true,
            plannedAt: DateTime.utc(2026, 6, 1, 9),
            state: 'skipped',
            provenance: 'exact',
          ),
          AdherenceOccurrence(
            id: 'overdue-pending',
            source: 'scheduled',
            expected: true,
            plannedAt: DateTime.utc(2026, 6, 1, 10),
            state: 'pending',
            provenance: 'exact',
          ),
          AdherenceOccurrence(
            id: 'future',
            source: 'scheduled',
            expected: true,
            plannedAt: DateTime.utc(2026, 6, 1, 18),
            state: 'pending',
            provenance: 'exact',
          ),
          const AdherenceOccurrence(
            id: 'prn-taken',
            source: 'prn',
            expected: false,
            plannedAt: null,
            state: 'taken',
            provenance: 'exact',
          ),
          const AdherenceOccurrence(
            id: 'legacy-estimate',
            source: 'legacy',
            expected: false,
            plannedAt: null,
            state: 'taken',
            provenance: 'legacy_estimated',
          ),
          AdherenceOccurrence(
            id: 'superseded',
            source: 'scheduled',
            expected: true,
            plannedAt: DateTime.utc(2026, 6, 1, 7),
            state: 'pending',
            provenance: 'exact',
            superseded: true,
          ),
        ],
        events: const [],
      );

      expect(result.dueScheduled, 3);
      expect(result.takenScheduled, 1);
      expect(result.skippedScheduled, 1);
      expect(result.missedScheduled, 0);
      expect(result.unrecordedScheduled, 1);
      expect(result.scheduledAdherence, closeTo(1 / 3, 0.000001));
      expect(result.prnTaken, 1);
      expect(
        result.history
            .singleWhere((item) => item.occurrenceId == 'overdue-pending')
            .status,
        'unrecorded',
      );
      expect(
        result.history
            .singleWhere((item) => item.occurrenceId == 'legacy-estimate')
            .provenance,
        'legacy_estimated',
      );
    });

    test('keeps unknown actual time and its provenance explicit', () {
      final result = const AdherenceCalculator().calculate(
        now: DateTime.utc(2026, 6, 1, 12),
        occurrences: [
          const AdherenceOccurrence(
            id: 'unknown-time',
            source: 'legacy',
            expected: false,
            plannedAt: null,
            state: 'taken',
            provenance: 'legacy_estimated',
          ),
        ],
        events: [
          AdherenceEvent(
            occurrenceId: 'unknown-time',
            resultVersion: 1,
            action: 'take',
            toState: 'taken',
            actualAt: null,
            actualTimeKnown: false,
            recordedAt: DateTime.utc(2026, 6, 1, 12),
            origin: 'legacy_backfill',
          ),
        ],
      );

      expect(result.dueScheduled, 0);
      expect(result.history.single.actualAt, isNull);
      expect(result.history.single.actualTimeKnown, isFalse);
      expect(result.history.single.provenance, 'legacy_estimated');
    });

    test(
      'does not mutate the event log when an overdue pending dose is unrecorded',
      () {
        final events = <AdherenceEvent>[];
        final result = const AdherenceCalculator().calculate(
          now: DateTime.utc(2026, 6, 1, 12),
          occurrences: [
            AdherenceOccurrence(
              id: 'pending',
              source: 'scheduled',
              expected: true,
              plannedAt: DateTime.utc(2026, 6, 1, 8),
              state: 'pending',
              provenance: 'exact',
            ),
          ],
          events: events,
        );

        expect(result.history.single.status, 'unrecorded');
        expect(events, isEmpty);
      },
    );

    test('a recorded miss counts as missed and a late take as taken', () {
      final result = const AdherenceCalculator().calculate(
        now: DateTime.utc(2026, 6, 1, 12),
        occurrences: [
          AdherenceOccurrence(
            id: 'recorded-miss',
            source: 'scheduled',
            expected: true,
            plannedAt: DateTime.utc(2026, 6, 1, 8),
            state: 'missed',
            provenance: 'exact',
          ),
          AdherenceOccurrence(
            id: 'late-take',
            source: 'scheduled',
            expected: true,
            plannedAt: DateTime.utc(2026, 6, 1, 9),
            state: 'taken',
            provenance: 'exact',
          ),
          AdherenceOccurrence(
            id: 'nobody-recorded',
            source: 'scheduled',
            expected: true,
            plannedAt: DateTime.utc(2026, 6, 1, 10),
            state: 'pending',
            provenance: 'exact',
          ),
        ],
        events: const [],
      );

      expect(result.dueScheduled, 3);
      expect(result.missedScheduled, 1);
      expect(result.takenScheduled, 1);
      expect(result.unrecordedScheduled, 1);
      expect(result.scheduledAdherence, closeTo(1 / 3, 0.000001));
      expect(
        {for (final item in result.history) item.occurrenceId: item.status},
        {
          'recorded-miss': 'missed',
          'late-take': 'taken',
          'nobody-recorded': 'unrecorded',
        },
      );
    });
  });
}
