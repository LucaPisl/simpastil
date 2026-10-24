import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/network/server_pin_providers.dart';
import 'package:simpastil/core/network/server_pin_store.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import '../../helpers/protected_workspace_fixture.dart';
import '../../helpers/tls_test_server.dart';

Future<ProviderContainer> makeContainer({
  Map<String, Object> initialPrefs = const {},
  ServerPinStore? pins,
  String? ownerId,
}) async {
  final fixture = await ProtectedWorkspaceFixture.create(
    initialPreferences: initialPrefs,
    ownerId: ownerId,
  );
  addTearDown(fixture.db.close);
  return fixture.createContainer(
    extraOverrides: [
      if (pins != null) serverPinStoreProvider.overrideWithValue(pins),
    ],
  );
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

  group('server pin lifecycle', () {
    const fingerprint =
        '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:'
        '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:01';
    final home = ServerAuthority('home.example.test', 443);
    final other = ServerAuthority('other.example.test', 443);

    test('switching to another server forgets the old pin only', () async {
      final pins = SecureServerPinStore(MemorySlots());
      await pins.save(home, fingerprint);
      await pins.save(other, fingerprint);
      final container = await makeContainer(
        initialPrefs: {'server_url': 'https://home.example.test'},
        pins: pins,
      );
      addTearDown(container.dispose);

      // The device records the endpoint it was configured with, so the
      // switch is a real change from `home` to `new`.
      final notifier = container.read(serverConfigProvider.notifier);
      await notifier.setUrl('https://home.example.test');
      expect((await pins.read(home))?.fingerprint, fingerprint);
      await notifier.setUrl('https://new.example.test');

      expect(await pins.read(home), isNull);
      expect(await pins.read(other), isNotNull);
    });

    test('re-saving the same server keeps its pin', () async {
      final pins = SecureServerPinStore(MemorySlots());
      await pins.save(home, fingerprint);
      final container = await makeContainer(
        initialPrefs: {'server_url': 'https://home.example.test'},
        pins: pins,
      );
      addTearDown(container.dispose);

      final notifier = container.read(serverConfigProvider.notifier);
      await notifier.setUrl('https://home.example.test');
      await notifier.setUrl('https://home.example.test');

      expect((await pins.read(home))?.fingerprint, fingerprint);
    });
  });

  group('stopping a server that was never signed in to', () {
    const fingerprint =
        '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:'
        '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:01';
    final home = ServerAuthority('home.example.test', 443);

    test('forgets the address, its pin and the device endpoint', () async {
      final pins = SecureServerPinStore(MemorySlots());
      await pins.save(home, fingerprint);
      final container = await makeContainer(pins: pins);
      addTearDown(container.dispose);
      final notifier = container.read(serverConfigProvider.notifier);
      await notifier.setUrl('https://home.example.test');

      expect(await notifier.forget(), isTrue);

      expect(container.read(serverConfigProvider), isNull);
      expect(
        container.read(sharedPreferencesProvider).getString('server_url'),
        isNull,
      );
      expect(await pins.read(home), isNull);
      final device = await container
          .read(workspaceAccessRepositoryProvider)
          .workspaces
          .deviceState();
      expect(device.configuredEndpoint, isNull);
    });

    test('refuses while a session is signed in', () async {
      const endpoint = 'https://fictional-workspace.test/care';
      final container = await makeContainer(
        initialPrefs: {'server_url': endpoint},
        ownerId: 'owner-signed-in',
      );
      addTearDown(container.dispose);

      expect(
        await container.read(serverConfigProvider.notifier).forget(),
        isFalse,
      );

      expect(container.read(serverConfigProvider), endpoint);
      final device = await container
          .read(workspaceAccessRepositoryProvider)
          .workspaces
          .deviceState();
      expect(device.configuredEndpoint, endpoint);
      expect(device.networkOwnerId, 'owner-signed-in');
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
