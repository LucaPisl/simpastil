import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/network/pinned_connection.dart';
import 'package:simpastil/core/sync/auto_sync_service.dart';
import 'package:simpastil/core/sync/sync_status_notifier.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
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

/// Records the manual syncs the screen asks for.
class _Sync implements AutoSyncService {
  final users = <String>[];
  @override
  Future<void> syncNow(String userId, {int? generation}) async =>
      users.add(userId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Access implements WorkspaceAccessRepository {
  _Access({required this.signedIn});
  final bool signedIn;
  @override
  Future<NetworkCapability?> currentNetworkCapability() async => signedIn
      ? const NetworkCapability(
          ownerId: 'user-1',
          endpoint: 'https://home.example.test:8443',
          epoch: 1,
          generation: 1,
        )
      : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
  _Sync? sync,
  bool signedIn = true,
  ServerAuthority? authority,
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
      if (sync != null) ...[
        autoSyncServiceProvider.overrideWithValue(sync),
        workspaceAccessRepositoryProvider.overrideWithValue(
          _Access(signedIn: signedIn),
        ),
        currentUserIdProvider.overrideWithValue('user-1'),
      ],
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
                    builder: (_) =>
                        ServerKeyChangedScreen(authority: authority),
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
    expect(find.text('Trusted on this device'), findsOneWidget);
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

  for (final (name, size) in const [
    ('phone', Size(420, 1800)),
    ('tablet', Size(1000, 1300)),
  ]) {
    testWidgets('trusting the new key starts a sync on $name', (tester) async {
      final sync = _Sync();
      await _pump(tester, sync: sync, size: size);
      await tester.tap(find.byKey(const ValueKey('server-key-trust')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Trust new key'));
      await tester.pump(const Duration(seconds: 1));
      expect(sync.users, ['user-1']);
    });

    testWidgets('trusting the new key forgets the old key-changed error on '
        '$name', (tester) async {
      final sync = _Sync();
      final h = await _pump(tester, sync: sync, size: size);
      final status = h.container.read(syncStatusProvider.notifier);
      await status.markFailure(
        const CertificatePinMismatch(
          host: 'home.example.test',
          port: 8443,
          pinned: _pinned,
          presented: _presented,
        ),
        pendingCount: 2,
      );
      expect(h.container.read(syncStatusProvider).lastError, isNotNull);

      await tester.tap(find.byKey(const ValueKey('server-key-trust')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Trust new key'));
      await tester.pump(const Duration(seconds: 1));

      final after = h.container.read(syncStatusProvider);
      expect(after.lastError, isNull);
      expect(after.failingSince, isNull);
      expect(after.pendingCount, 2);
    });
  }

  testWidgets('using normal certificate checking starts a sync', (
    tester,
  ) async {
    final sync = _Sync();
    await _pump(
      tester,
      sync: sync,
      probe: (a) async => const ServerCertificateProbe(
        fingerprint: _presented,
        chainValid: true,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('server-key-normal')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Use normal checking'));
    await tester.pump(const Duration(seconds: 1));
    expect(sync.users, ['user-1']);
  });

  testWidgets('keeping the server blocked does not sync', (tester) async {
    final sync = _Sync();
    await _pump(tester, sync: sync);
    await tester.tap(find.byKey(const ValueKey('server-key-keep')));
    await tester.pump(const Duration(seconds: 1));
    expect(sync.users, isEmpty);
  });

  testWidgets('no sync without a signed-in account', (tester) async {
    final sync = _Sync();
    await _pump(tester, sync: sync, signedIn: false);
    await tester.tap(find.byKey(const ValueKey('server-key-trust')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Trust new key'));
    await tester.pump(const Duration(seconds: 1));
    expect(sync.users, isEmpty);
  });

  testWidgets('first-connect review of another server does not sync', (
    tester,
  ) async {
    final sync = _Sync();
    await _pump(tester, sync: sync, authority: _authority);
    await tester.tap(find.byKey(const ValueKey('server-key-trust')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Trust new key'));
    await tester.pump(const Duration(seconds: 1));
    expect(sync.users, isEmpty);
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

  for (final (name, size) in [
    ('phone', const Size(420, 900)),
    ('tablet', const Size(1100, 800)),
  ]) {
    group('one key review on $name', () {
      testWidgets('a second review is not opened on top of the first', (
        tester,
      ) async {
        await _pump(tester, size: size);
        expect(find.byType(ServerKeyChangedScreen), findsOneWidget);
        expect(serverKeyReviewIsOpen, isTrue);

        final context = tester.element(find.byType(ServerKeyChangedScreen));
        expect(await openServerKeyReview(context), isNull);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(ServerKeyChangedScreen), findsOneWidget);
      });

      testWidgets('the review can be opened again once it was closed', (
        tester,
      ) async {
        await _pump(tester, size: size);
        await tester.tap(find.byKey(const ValueKey('server-key-keep')));
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(ServerKeyChangedScreen), findsNothing);
        expect(serverKeyReviewIsOpen, isFalse);

        final context = tester.element(find.text('open'));
        final result = openServerKeyReview(context);
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(ServerKeyChangedScreen), findsOneWidget);
        expect(serverKeyReviewIsOpen, isTrue);
        unawaited(result);
      });

      testWidgets('the review closes by itself once the key was dealt with '
          'elsewhere', (tester) async {
        final h = await _pump(tester, size: size);
        expect(find.byType(ServerKeyChangedScreen), findsOneWidget);

        await h.container
            .read(serverPinControllerProvider.notifier)
            .dismissMismatch(_authority);
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(ServerKeyChangedScreen), findsNothing);
        expect(find.text('open'), findsOneWidget);
      });
    });
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
