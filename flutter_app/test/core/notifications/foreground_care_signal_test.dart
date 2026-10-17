import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/notifications/foreground_care_signal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a background engine notifies the visible app', () async {
    final received = Completer<void>();
    final signal = ForegroundCareSignal.listen(received.complete);
    addTearDown(signal.close);

    ForegroundCareSignal.notify();

    await received.future.timeout(const Duration(seconds: 2));
  });

  test('notifying with no app on screen does nothing', () {
    expect(ForegroundCareSignal.notify, returnsNormally);
  });

  test('a newer app replaces a registration left behind', () async {
    final stale = ForegroundCareSignal.listen(() => fail('stale listener'));
    final received = Completer<void>();
    final current = ForegroundCareSignal.listen(received.complete);
    addTearDown(current.close);

    ForegroundCareSignal.notify();
    await received.future.timeout(const Duration(seconds: 2));

    // Closing the replaced registration must not drop the current one.
    stale.close();
    final again = Completer<void>();
    final latest = ForegroundCareSignal.listen(again.complete);
    addTearDown(latest.close);
    ForegroundCareSignal.notify();
    await again.future.timeout(const Duration(seconds: 2));
  });
}
