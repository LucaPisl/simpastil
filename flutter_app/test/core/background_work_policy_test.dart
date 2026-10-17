import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('periodic background sync uses update semantics, not keep', () {
    final main = File('lib/main.dart').readAsStringSync();
    final registration = RegExp(
      r"registerPeriodicTask\(\s*'pill_tracker_background_sync'[\s\S]*?\);",
    ).firstMatch(main);
    expect(registration, isNotNull);
    expect(registration!.group(0), contains('ExistingWorkPolicy.update'));
    expect(registration.group(0), isNot(contains('ExistingWorkPolicy.keep')));
  });
}
