import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/tls_fixtures.dart';

/// Runs once per test file (each in its own process). Removes the TLS fixtures
/// that `tlsFixture` generated for the file, if any.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  tearDownAll(deleteTlsFixtures);
  await testMain();
}
