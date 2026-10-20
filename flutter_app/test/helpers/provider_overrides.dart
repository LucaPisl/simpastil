import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:simpastil/features/auth/auth_repository.dart';
import 'package:simpastil/l10n/app_localizations.dart';

import 'fake_auth_repository.dart';

/// Wraps [child] in a [ProviderScope] with sensible test overrides.
///
/// Use for **widget tests** — pass additional [overrides] to control specific
/// providers per test case.
Widget makeTestApp(
  Widget child, {
  FakeAuthRepository? fakeAuth,
  List<Override> overrides = const [],
}) {
  final fake = fakeAuth ?? FakeAuthRepository();
  return ProviderScope(
    overrides: [authRepositoryProvider.overrideWithValue(fake), ...overrides],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}
