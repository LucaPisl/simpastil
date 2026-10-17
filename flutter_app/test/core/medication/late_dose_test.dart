import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/late_dose.dart';

OccurrenceEvent _event({required String action, required String fromState}) =>
    OccurrenceEvent(
      id: 'event',
      userId: 'user',
      occurrenceId: 'occurrence',
      commandId: 'command',
      action: action,
      fromState: fromState,
      toState: 'taken',
      actualTimeKnown: true,
      origin: 'user',
      baseVersion: 1,
      resultVersion: 2,
      recordedAt: DateTime.utc(2026, 9, 30, 11),
    );

void main() {
  test('a take that corrects a miss is late', () {
    expect(
      isTakenLate('taken', _event(action: 'correct', fromState: 'missed')),
      isTrue,
    );
  });

  test('an ordinary take, or a correction of another state, is not late', () {
    expect(
      isTakenLate('taken', _event(action: 'take', fromState: 'pending')),
      isFalse,
    );
    expect(
      isTakenLate('taken', _event(action: 'correct', fromState: 'skipped')),
      isFalse,
    );
  });

  test('only a taken dose can be late, and only with a head event', () {
    expect(
      isTakenLate('skipped', _event(action: 'correct', fromState: 'missed')),
      isFalse,
    );
    expect(
      isTakenLate('missed', _event(action: 'miss', fromState: 'pending')),
      isFalse,
    );
    expect(isTakenLate('taken', null), isFalse);
  });
}
