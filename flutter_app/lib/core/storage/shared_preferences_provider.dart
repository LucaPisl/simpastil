import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pre-loaded SharedPreferences instance, injected in [main] before [runApp].
///
/// Never override with a lazy `SharedPreferences.getInstance()` call — the
/// value must be ready synchronously so [ServerConfigNotifier.build] can read
/// it without an async build method.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError(
    'sharedPreferencesProvider must be overridden in main() '
    'with a pre-loaded SharedPreferences instance.',
  ),
);
