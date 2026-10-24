import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/expiry.dart';

void main() {
  final today = DateTime(2026, 6, 15, 9, 30);

  test('no date means no state', () {
    expect(expiryState(null, today).phase, ExpiryPhase.none);
    expect(expiryState('not-a-date', today).phase, ExpiryPhase.none);
    expect(expiryState('2026-02-30', today).phase, ExpiryPhase.none);
  });

  test('more than 30 days ahead is fine', () {
    final state = expiryState('2026-07-16', today);
    expect(state.phase, ExpiryPhase.ok);
    expect(state.daysLeft, 31);
    expect(state.needsNotice, isFalse);
  });

  test('the notice starts 30 days before', () {
    final state = expiryState('2026-07-15', today);
    expect(state.phase, ExpiryPhase.soon);
    expect(state.daysLeft, 30);
    expect(state.needsNotice, isTrue);
  });

  test('the expiry day itself is the last good day', () {
    final state = expiryState('2026-06-15', today);
    expect(state.phase, ExpiryPhase.soon);
    expect(state.daysLeft, 0);
  });

  test('the day after is expired', () {
    final state = expiryState('2026-06-14', today);
    expect(state.phase, ExpiryPhase.expired);
    expect(state.daysLeft, -1);
    expect(state.needsNotice, isTrue);
  });

  test('time of day and daylight saving never move the answer', () {
    final lateNight = DateTime(2026, 3, 28, 23, 59);
    expect(expiryState('2026-03-29', lateNight).daysLeft, 1);
    expect(expiryState('2026-03-28', lateNight).phase, ExpiryPhase.soon);
    expect(expiryState('2026-04-27', lateNight).daysLeft, 30);
  });

  test('date keys round trip', () {
    expect(expiryDateKey(DateTime(2026, 1, 5)), '2026-01-05');
    expect(parseExpiryDate('2026-01-05'), DateTime(2026, 1, 5));
  });
}
