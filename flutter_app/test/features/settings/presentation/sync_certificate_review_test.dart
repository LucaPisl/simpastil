import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/medication/care_sharing_provider.dart';
import 'package:simpastil/core/medication/care_sharing_status.dart';
import 'package:simpastil/core/network/pinned_connection.dart';
import 'package:simpastil/core/network/server_pin_controller.dart';
import 'package:simpastil/core/network/server_pin_providers.dart';
import 'package:simpastil/core/network/server_pin_store.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/core/sync/auto_sync_service.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/settings/migration_issue_provider.dart';
import 'package:simpastil/features/settings/presentation/sync_recovery_screen.dart';
import 'package:simpastil/features/settings/presentation/sync_settings_section.dart';
import 'package:simpastil/l10n/app_localizations.dart';

import '../../../helpers/held_provider_read.dart';
import '../../../helpers/tls_test_server.dart';

const _presented =
    'A1:B2:C3:D4:E5:F6:07:18:29:3A:4B:5C:6D:7E:8F:90:'
    'A1:B2:C3:D4:E5:F6:07:18:29:3A:4B:5C:6D:7E:8F:91';
const _pinned =
    '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:'
    '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:01';
final _authority = ServerAuthority('home.example.test', 8443);

class _Sync implements AutoSyncService {
  final users = <String>[];
  @override
  Future<void> syncNow(String userId, {int? generation}) async =>
      users.add(userId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Access implements WorkspaceAccessRepository {
  @override
  Future<NetworkCapability?> currentNetworkCapability() async =>
      const NetworkCapability(
        ownerId: 'user-1',
        endpoint: 'https://home.example.test:8443',
        epoch: 1,
        generation: 1,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<SharedPreferences> _prefs() async {
  SharedPreferences.setMockInitialValues({
    'server_url': 'https://home.example.test:8443',
  });
  return SharedPreferences.getInstance();
}

void main() {
  setUp(ServerPinEvents.resetRejections);

  group('ServerPinController — refused certificate', () {
    test('an unpinned refusal is reported until the person decides', () async {
      final pins = SecureServerPinStore(MemorySlots());
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(await _prefs()),
          serverPinStoreProvider.overrideWithValue(pins),
        ],
      );
      addTearDown(container.dispose);
      expect(
        (await container.readHeld(
          serverPinControllerProvider,
        )).certificateRejected,
        isFalse,
      );

      ServerPinEvents.noteRejectedForTest(_authority);
      // The held listener sees the controller rebuild.
      await Future<void>.delayed(Duration.zero);
      final refused = await container.readHeld(serverPinControllerProvider);
      expect(refused.certificateRejected, isTrue);
      expect(refused.hasMismatch, isFalse);

      await container
          .read(serverPinControllerProvider.notifier)
          .trust(_authority, _presented);
      await Future<void>.delayed(Duration.zero);
      final trusted = await container.readHeld(serverPinControllerProvider);
      expect(trusted.certificateRejected, isFalse);
      expect(trusted.pin!.fingerprint, _presented);
    });

    test('a pinned server is never reported as refused', () async {
      final pins = SecureServerPinStore(MemorySlots());
      await pins.save(_authority, _pinned);
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(await _prefs()),
          serverPinStoreProvider.overrideWithValue(pins),
        ],
      );
      addTearDown(container.dispose);
      ServerPinEvents.noteRejectedForTest(_authority);
      expect(
        (await container.readHeld(
          serverPinControllerProvider,
        )).certificateRejected,
        isFalse,
      );
    });
  });

  for (final (name, size) in const [
    ('phone', Size(400, 1000)),
    ('tablet', Size(1100, 1000)),
  ]) {
    group('Sync screen — refused certificate on $name', () {
      late SecureServerPinStore pins;
      late _Sync sync;

      Future<void> pump(
        WidgetTester tester, {
        bool refused = true,
        bool pinMismatch = false,
      }) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        pins = SecureServerPinStore(MemorySlots());
        sync = _Sync();
        if (pinMismatch) {
          await pins.save(_authority, _pinned);
          await pins.recordMismatch(_authority, _presented);
        }
        if (refused) ServerPinEvents.noteRejectedForTest(_authority);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(await _prefs()),
              serverPinStoreProvider.overrideWithValue(pins),
              serverCertificateProbeProvider.overrideWithValue(
                (_) async => const ServerCertificateProbe(
                  fingerprint: _presented,
                  chainValid: false,
                ),
              ),
              autoSyncServiceProvider.overrideWithValue(sync),
              workspaceAccessRepositoryProvider.overrideWithValue(_Access()),
              currentUserIdProvider.overrideWithValue('user-1'),
              careSharingStatusProvider.overrideWith(
                (_) => Stream.value(
                  const CareSharingStatus(
                    isLocalOnly: false,
                    lastCarePullAt: null,
                    pendingCount: 0,
                    needsReviewCount: 0,
                    uncertainCount: 0,
                  ),
                ),
              ),
              keptNotesCountProvider.overrideWith((_) => Future.value(0)),
              migrationIssuesProvider.overrideWith(
                (_) => Stream.value(const []),
              ),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: SyncSettingsSection(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
      }

      final entry = find.byKey(const ValueKey('sync-server-certificate-entry'));

      testWidgets('offers a review of the key', (tester) async {
        await pump(tester);
        expect(find.text('Server certificate not trusted'), findsOneWidget);
        expect(
          find.textContaining('home.example.test presents a certificate'),
          findsOneWidget,
        );
        expect(entry, findsOneWidget);
        expect(find.text('Review server key'), findsOneWidget);
      });

      testWidgets('shows nothing when the server was not refused', (
        tester,
      ) async {
        await pump(tester, refused: false);
        expect(entry, findsNothing);
        expect(find.text('Server certificate not trusted'), findsNothing);
      });

      testWidgets('a changed pinned key keeps its own entry only', (
        tester,
      ) async {
        await pump(tester, pinMismatch: true);
        expect(entry, findsNothing);
        expect(
          find.byKey(const ValueKey('sync-server-key-entry')),
          findsOneWidget,
        );
      });

      testWidgets('cancelling the review trusts nothing and does not sync', (
        tester,
      ) async {
        await pump(tester);
        await tester.ensureVisible(entry);
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(find.text("Trust this server's certificate?"), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(await pins.read(_authority), isNull);
        expect(sync.users, isEmpty);
        expect(entry, findsOneWidget);
      });

      testWidgets('trusting the key pins it, clears the entry and syncs', (
        tester,
      ) async {
        await pump(tester);
        await tester.ensureVisible(entry);
        await tester.tap(entry);
        await tester.pumpAndSettle();
        // Nothing is trusted just by opening the review.
        expect(await pins.read(_authority), isNull);

        await tester.tap(find.text('Trust this key'));
        await tester.pumpAndSettle();

        expect((await pins.read(_authority))?.fingerprint, _presented);
        expect(sync.users, ['user-1']);
        expect(entry, findsNothing);
      });
    });
  }
}
