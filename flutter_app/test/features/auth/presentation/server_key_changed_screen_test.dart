import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/network/pinned_connection.dart';
import 'package:simpastil/core/network/server_pin_controller.dart';
import 'package:simpastil/core/network/server_pin_providers.dart';
import 'package:simpastil/core/network/server_pin_store.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/features/auth/presentation/server_key_changed_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

import '../../../helpers/tls_test_server.dart';
import '../../../helpers/held_provider_read.dart';

const _pinned =
    '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:'
    '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:01';
const _presented =
    'A1:B2:C3:D4:E5:F6:07:18:29:3A:4B:5C:6D:7E:8F:90:'
    'A1:B2:C3:D4:E5:F6:07:18:29:3A:4B:5C:6D:7E:8F:91';

Future<SharedPreferences> _prefs() async {
  SharedPreferences.setMockInitialValues({
    'server_url': 'https://home.example.test:8443',
  });
  return SharedPreferences.getInstance();
}

final _authority = ServerAuthority('home.example.test', 8443);

class _Harness {
  _Harness(this.pins, this.container);
  final SecureServerPinStore pins;
  final ProviderContainer container;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  ServerCertificateProber? probe,
  bool pinned = true,
  bool mismatch = true,
  Locale locale = const Locale('en'),
  bool dark = false,
  Size size = const Size(420, 1800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final pins = SecureServerPinStore(MemorySlots());
  if (pinned) {
    await pins.save(_authority, _pinned);
    if (mismatch) await pins.recordMismatch(_authority, _presented);
  }
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(await _prefs()),
      serverPinStoreProvider.overrideWithValue(pins),
      serverCertificateProbeProvider.overrideWithValue(
        probe ??
            (a) async => const ServerCertificateProbe(
              fingerprint: _presented,
              chainValid: false,
            ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<ServerKeyOutcome>(
                    builder: (_) => const ServerKeyChangedScreen(),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return _Harness(pins, container);
}

void main() {
  testWidgets('shows both fingerprints and keeps traffic blocked', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Server key changed'), findsWidgets);
    expect(find.text('Trusted on this phone'), findsOneWidget);
    expect(find.text('Presented now'), findsOneWidget);
    // Fingerprints are shown in full, not abbreviated.
    expect(find.textContaining('11:22:33:44:55:66:77:88'), findsOneWidget);
    expect(find.textContaining('A1:B2:C3:D4:E5:F6:07:18'), findsOneWidget);
    expect(find.byKey(const ValueKey('server-key-keep')), findsOneWidget);
    expect(find.byKey(const ValueKey('server-key-trust')), findsOneWidget);
  });

  testWidgets('"normal checking" is hidden unless the chain is CA-valid', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byKey(const ValueKey('server-key-normal')), findsNothing);
  });

  testWidgets('"normal checking" is offered for a CA-valid certificate', (
    tester,
  ) async {
    await _pump(
      tester,
      probe: (a) async => const ServerCertificateProbe(
        fingerprint: _presented,
        chainValid: true,
      ),
    );
    expect(find.byKey(const ValueKey('server-key-normal')), findsOneWidget);
  });

  testWidgets('keep blocked changes nothing', (tester) async {
    final h = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('server-key-keep')));
    await tester.pump(const Duration(seconds: 1));
    final pin = await h.pins.read(_authority);
    expect(pin!.fingerprint, _pinned);
    expect(pin.mismatch, isNotNull);
  });

  testWidgets('trusting the new key pins the live fingerprint after confirm', (
    tester,
  ) async {
    final h = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('server-key-trust')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Trust the new key?'), findsOneWidget);
    expect((await h.pins.read(_authority))!.fingerprint, _pinned);
    await tester.tap(find.text('Trust new key'));
    await tester.pump(const Duration(seconds: 1));
    final pin = (await h.pins.read(_authority))!;
    expect(pin.fingerprint, _presented);
    expect(pin.mismatch, isNull);
  });

  testWidgets('a probe failure still blocks and offers a retry only', (
    tester,
  ) async {
    await _pump(
      tester,
      probe: (a) async => throw const HandshakeException('down'),
    );
    expect(
      find.byKey(const ValueKey('server-key-check-again')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('server-key-trust')), findsNothing);
    expect(find.byKey(const ValueKey('server-key-normal')), findsNothing);
    // Only the recorded value is shown; it can't be trusted without a live read.
    expect(find.textContaining('A1:B2:C3:D4'), findsOneWidget);
  });

  testWidgets('the old key coming back offers to dismiss the notice', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      probe: (a) async =>
          const ServerCertificateProbe(fingerprint: _pinned, chainValid: false),
    );
    expect(find.byKey(const ValueKey('server-key-dismiss')), findsOneWidget);
    expect(find.byKey(const ValueKey('server-key-trust')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('server-key-dismiss')));
    await tester.pump(const Duration(seconds: 1));
    final pin = (await h.pins.read(_authority))!;
    expect(pin.fingerprint, _pinned);
    expect(pin.mismatch, isNull);
  });

  for (final dark in [false, true]) {
    for (final (name, size) in [
      ('phone', const Size(420, 1800)),
      ('tablet', const Size(1200, 900)),
    ]) {
      testWidgets('builds in ${dark ? 'dark' : 'light'} on a $name in ro', (
        tester,
      ) async {
        await _pump(tester, locale: const Locale('ro'), dark: dark, size: size);
        expect(tester.takeException(), isNull);
        expect(find.text('Cheia serverului s-a schimbat'), findsWidgets);
      });
    }
  }

  group('ServerPinController', () {
    testWidgets('reports pinned, mismatched and cleared states', (
      tester,
    ) async {
      final h = await _pump(tester);
      final state = await h.container.readHeld(serverPinControllerProvider);
      expect(state.isPinned, isTrue);
      expect(state.hasMismatch, isTrue);
      expect(state.authority, _authority);

      await h.container
          .read(serverPinControllerProvider.notifier)
          .dismissMismatch(_authority);
      final after = await h.container.readHeld(serverPinControllerProvider);
      expect(after.hasMismatch, isFalse);
      expect(after.pin!.fingerprint, _pinned);

      await h.container
          .read(serverPinControllerProvider.notifier)
          .useNormalChecking(_authority);
      final plain = await h.container.readHeld(serverPinControllerProvider);
      expect(plain.isPinned, isFalse);
    });

    test('an unreadable pin fails closed', () async {
      final slots = MemorySlots()
        ..values[SecureServerPinStore.keyFor(_authority)] = 'garbage';
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(await _prefs()),
          serverPinStoreProvider.overrideWithValue(SecureServerPinStore(slots)),
        ],
      );
      addTearDown(container.dispose);
      final state = await container.readHeld(serverPinControllerProvider);
      expect(state.unreadable, isTrue);
      expect(state.isPinned, isTrue);
    });
  });
}
