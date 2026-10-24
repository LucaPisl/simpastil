import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/prn_limits.dart';
import 'package:simpastil/features/dashboard/as_needed/as_needed_summary.dart';

PrnLimitDose _at(DateTime instant) => PrnLimitDose(instant);

PrnLimitState _judge({
  int? max,
  int? gap,
  required List<DateTime> doses,
  required DateTime at,
}) => evaluatePrnLimit(
  maxPer24h: max,
  minGapMinutes: gap,
  doses: doses.map(_at),
  at: at,
);

void main() {
  group('rolling 24 hours', () {
    test('a 23:30 dose still counts at 00:30 the next day', () {
      final state = _judge(
        max: 1,
        doses: [DateTime(2026, 3, 10, 23, 30)],
        at: DateTime(2026, 3, 11, 0, 30),
      );
      expect(state.countIn24h, 1);
      expect(state.breach, PrnLimitBreach.daily);
      expect(state.nextAllowedAt, DateTime(2026, 3, 11, 23, 30));
    });

    test('a dose exactly 24 hours old has left the window', () {
      final state = _judge(
        max: 1,
        doses: [DateTime.utc(2026, 3, 10, 12)],
        at: DateTime.utc(2026, 3, 11, 12),
      );
      expect(state.countIn24h, 0);
      expect(state.overLimit, isFalse);
    });

    test(
      'moving from UTC+2 to UTC-5 does not move a dose out of the window',
      () {
        // 23:30 in UTC+2 is 21:30Z. Five hours west of Greenwich the clock
        // reads 16:30 for that same instant; the next morning at 00:30 in
        // UTC+2 (22:30Z the same evening) and at 17:30 in UTC-5 are the same
        // moment, so both see one dose in the window.
        final dose = DateTime.utc(2026, 3, 10, 21, 30);
        final now = DateTime.utc(2026, 3, 10, 22, 30);
        expect(_judge(max: 1, doses: [dose], at: now).countIn24h, 1);
        // Five hours later, the same dose still counts wherever the clock is.
        expect(
          _judge(
            max: 1,
            doses: [dose],
            at: now.add(const Duration(hours: 5)),
          ).countIn24h,
          1,
        );
      },
    );

    test('a dose recorded later than the judged moment is not counted', () {
      final state = _judge(
        max: 1,
        doses: [DateTime.utc(2026, 3, 10, 18)],
        at: DateTime.utc(2026, 3, 10, 8),
      );
      expect(state.countIn24h, 0);
    });

    test('the next allowed time waits for enough old doses to leave', () {
      final first = DateTime.utc(2026, 3, 10, 6);
      final second = DateTime.utc(2026, 3, 10, 10);
      final third = DateTime.utc(2026, 3, 10, 14);
      final state = _judge(
        max: 2,
        doses: [third, first, second],
        at: DateTime.utc(2026, 3, 10, 15),
      );
      expect(state.countIn24h, 3);
      expect(
        state.nextAllowedAt?.toUtc(),
        DateTime.utc(2026, 3, 11, 10),
        reason: 'the second dose must leave, so only one remains',
      );
    });
  });

  group('minimum gap', () {
    test('measures from the latest earlier dose', () {
      final state = _judge(
        gap: 240,
        doses: [DateTime.utc(2026, 3, 10, 8), DateTime.utc(2026, 3, 10, 6)],
        at: DateTime.utc(2026, 3, 10, 11),
      );
      expect(state.breach, PrnLimitBreach.gap);
      expect(state.nextAllowedAt?.toUtc(), DateTime.utc(2026, 3, 10, 12));
    });

    test('exactly the gap apart is allowed', () {
      final state = _judge(
        gap: 240,
        doses: [DateTime.utc(2026, 3, 10, 8)],
        at: DateTime.utc(2026, 3, 10, 12),
      );
      expect(state.overLimit, isFalse);
      expect(state.nextAllowedAt, isNull);
    });

    test('both limits reported together', () {
      final state = _judge(
        max: 1,
        gap: 60,
        doses: [DateTime.utc(2026, 3, 10, 8)],
        at: DateTime.utc(2026, 3, 10, 8, 30),
      );
      expect(state.breach, PrnLimitBreach.both);
    });

    test('no limits set never breaches', () {
      final state = _judge(
        doses: [DateTime.utc(2026, 3, 10, 8)],
        at: DateTime.utc(2026, 3, 10, 8, 1),
      );
      expect(state.hasLimit, isFalse);
      expect(state.overLimit, isFalse);
    });
  });

  test('a dose with an unknown time counts at when it was recorded', () {
    final recorded = DateTime.utc(2026, 3, 10, 22);
    final dose = AsNeededDose(
      occurrenceId: 'o',
      pillId: 'p',
      day: DateTime(2026, 3, 10),
      takenAt: null,
      amount: const MedicationAmount.unknown(),
      note: null,
      recordedAt: recorded,
    );
    expect(dose.countedAt?.toUtc(), recorded);
    final state = _judge(
      max: 1,
      doses: [dose.countedAt!],
      at: DateTime.utc(2026, 3, 11, 1),
    );
    expect(state.countIn24h, 1);

    final known = AsNeededDose(
      occurrenceId: 'o',
      pillId: 'p',
      day: DateTime(2026, 3, 10),
      takenAt: DateTime.utc(2026, 3, 10, 7),
      amount: const MedicationAmount.unknown(),
      note: null,
      recordedAt: recorded,
    );
    expect(known.countedAt, DateTime.utc(2026, 3, 10, 7));
  });
}
