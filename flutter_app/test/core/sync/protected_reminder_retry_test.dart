import 'dart:ui' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/projections/projection_reconciler.dart';
import 'package:simpastil/core/projections/reminder_retry.dart';
import 'package:simpastil/core/sync/protected_background_sync.dart';

class _FakeReconciler implements ProjectionReconciler {
  _FakeReconciler(this.next);
  Object Function() next;
  int calls = 0;

  @override
  Future<ReconcileAllResult> reconcileAll({
    Locale? locale,
    bool refreshActiveActions = false,
    String? buildKey,
  }) async {
    calls++;
    final value = next();
    if (value is ReconcileAllResult) return value;
    throw value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<bool> run(_FakeReconciler fake) =>
      runProtectedReminderRetry(reconciler: fake, preferences: prefs);

  test('an unready or signed-out pass is final success', () async {
    final fake = _FakeReconciler(() => const ReconcileAllResult.failed());
    expect(await run(fake), isTrue);
    expect(prefs.containsKey(reminderRetryAttemptsKey), isFalse);
  });

  test('a healthy pass is final success', () async {
    final fake = _FakeReconciler(() => const ReconcileAllResult(ready: true));
    expect(await run(fake), isTrue);
  });

  test('a busy pass asks for a retry, but only up to the cap', () async {
    final fake = _FakeReconciler(
      () => const ReconcileAllResult(ready: false, busy: true),
    );
    final results = <bool>[];
    for (var i = 0; i < reminderRetryMaxAttempts; i++) {
      results.add(await run(fake));
    }
    expect(results, [
      ...List.filled(reminderRetryMaxAttempts - 1, false),
      true,
    ]);
    // The counter restarts for the next chain.
    expect(await run(fake), isFalse);
  });

  test('a thrown error is bounded the same way', () async {
    final fake = _FakeReconciler(() => StateError('synthetic'));
    final results = <bool>[];
    for (var i = 0; i < reminderRetryMaxAttempts; i++) {
      results.add(await run(fake));
    }
    expect(results.last, isTrue);
    expect(results.take(reminderRetryMaxAttempts - 1), everyElement(isFalse));
  });
}
