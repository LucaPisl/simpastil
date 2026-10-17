import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import '../../helpers/protected_workspace_fixture.dart';

Future<ProviderContainer> makeContainer({
  Map<String, Object> initialPrefs = const {},
}) async {
  final fixture = await ProtectedWorkspaceFixture.create(
    initialPreferences: initialPrefs,
  );
  addTearDown(fixture.db.close);
  return fixture.createContainer();
}

void main() {
  group('ServerConfigNotifier', () {
    test('initial state is null when no URL stored', () async {
      final container = await makeContainer();
      addTearDown(container.dispose);
      expect(container.read(serverConfigProvider), isNull);
    });

    test('initial state reads stored URL from SharedPreferences', () async {
      final container = await makeContainer(
        initialPrefs: {'server_url': 'https://example.com'},
      );
      addTearDown(container.dispose);
      expect(container.read(serverConfigProvider), 'https://example.com');
    });

    test('setUrl updates state and persists to SharedPreferences', () async {
      final container = await makeContainer();
      addTearDown(container.dispose);
      await container
          .read(serverConfigProvider.notifier)
          .setUrl('https://mypills.example.com');
      expect(
        container.read(serverConfigProvider),
        'https://mypills.example.com',
      );

      // Verify persistence
      final prefs = container.read(sharedPreferencesProvider);
      expect(prefs.getString('server_url'), 'https://mypills.example.com');
    });

    test('setUrl throws ArgumentError for non-HTTPS URL', () async {
      final container = await makeContainer();
      addTearDown(container.dispose);
      expect(
        () => container
            .read(serverConfigProvider.notifier)
            .setUrl('http://plain.example.com'),
        throwsArgumentError,
      );
      expect(container.read(serverConfigProvider), isNull);
    });
  });

  group('serverHealthCheckProvider', () {
    test('is a function provider', () async {
      final container = await makeContainer();
      addTearDown(container.dispose);
      final fn = container.read(serverHealthCheckProvider);
      expect(fn, isA<Future<bool> Function(String)>());
    });
  });
}
