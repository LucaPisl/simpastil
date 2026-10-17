import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/projections/reminder_retry.dart';

void main() {
  Future<void> noWait(Duration _) async {}

  test('a busy pass that recovers is not handed off', () async {
    var attempts = 0;
    final handedOff = <Duration>[];
    final healthy = await retryReconcileAfterAction(
      attempt: () async => ++attempts == 3,
      stillCurrent: () async => true,
      handOff: (delay) async => handedOff.add(delay),
      wait: noWait,
    );
    expect(healthy, isTrue);
    expect(attempts, 3);
    expect(handedOff, isEmpty);
  });

  test('a pass that never recovers is handed to a background task', () async {
    var attempts = 0;
    final handedOff = <Duration>[];
    final healthy = await retryReconcileAfterAction(
      attempt: () async {
        attempts++;
        return false;
      },
      stillCurrent: () async => true,
      handOff: (delay) async => handedOff.add(delay),
      wait: noWait,
    );
    expect(healthy, isFalse);
    expect(attempts, 3);
    expect(handedOff, [reminderRetryTaskDelay]);
  });

  test('a session that moved on stops the retries and the hand-off', () async {
    var attempts = 0;
    final handedOff = <Duration>[];
    final healthy = await retryReconcileAfterAction(
      attempt: () async {
        attempts++;
        return false;
      },
      stillCurrent: () async => false,
      handOff: (delay) async => handedOff.add(delay),
      wait: noWait,
    );
    expect(healthy, isFalse);
    expect(attempts, 1);
    expect(handedOff, isEmpty);
  });

  test('a failing hand-off never throws', () async {
    final healthy = await retryReconcileAfterAction(
      attempt: () async => false,
      stillCurrent: () async => true,
      handOff: (_) async => throw StateError('no workmanager'),
      delays: const [],
      wait: noWait,
    );
    expect(healthy, isFalse);
  });

  group('reminderRetryShouldRepeat', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('a pass that is not busy is final and clears the counter', () async {
      expect(await reminderRetryShouldRepeat(prefs, busy: true), isTrue);
      expect(await reminderRetryShouldRepeat(prefs, busy: false), isFalse);
      expect(prefs.containsKey(reminderRetryAttemptsKey), isFalse);
    });

    test('a busy pass repeats until the attempt cap, then stops', () async {
      for (var run = 1; run < reminderRetryMaxAttempts; run++) {
        expect(await reminderRetryShouldRepeat(prefs, busy: true), isTrue);
        expect(prefs.getInt(reminderRetryAttemptsKey), run);
      }
      expect(await reminderRetryShouldRepeat(prefs, busy: true), isFalse);
      expect(prefs.containsKey(reminderRetryAttemptsKey), isFalse);
    });
  });
}
