import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/core/sync/auto_sync_service.dart';
import 'package:simpastil/core/sync/sync_service.dart';
import 'package:simpastil/features/auth/auth_provider.dart';
import 'package:simpastil/features/settings/presentation/account_settings_section.dart';
import 'package:simpastil/l10n/app_localizations.dart';

class _Server extends ServerConfigNotifier {
  int forgets = 0;
  bool refuse = false;
  @override
  String? build() => 'https://home.example.test';
  @override
  Future<bool> forget() async {
    forgets++;
    if (refuse) return false;
    state = null;
    return true;
  }
}

class _Auth extends AuthNotifier {
  _Auth({this.signedIn = true});
  final bool signedIn;
  int logouts = 0;
  @override
  AuthState build() =>
      signedIn ? const AuthAuthenticated('u1') : const AuthUnauthenticated();
  @override
  Future<void> logout() async => logouts++;
}

class _Sync implements SyncService {
  _Sync(this.pending);
  final Future<int> Function() pending;
  @override
  Future<int> countPending({String? userId}) => pending();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AutoSync implements AutoSyncService {
  int stops = 0;
  @override
  void stop() => stops++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final (name, size) in const [
    ('phone', Size(400, 900)),
    ('tablet', Size(1100, 900)),
  ]) {
    group('Log out confirmation on $name', () {
      late _Auth auth;
      late _AutoSync autoSync;
      late _Server server;

      Future<void> pump(
        WidgetTester tester, {
        int pending = 0,
        Future<int> Function()? counting,
        bool signedIn = true,
      }) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        auth = _Auth(signedIn: signedIn);
        autoSync = _AutoSync();
        server = _Server();
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const AccountSettingsSection(),
            ),
            GoRoute(
              path: '/login',
              builder: (_, _) => const Scaffold(body: Text('login page')),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              serverConfigProvider.overrideWith(() => server),
              syncServiceProvider.overrideWithValue(
                _Sync(counting ?? () async => pending),
              ),
              autoSyncServiceProvider.overrideWithValue(autoSync),
              authNotifierProvider.overrideWith(() => auth),
            ],
            child: MaterialApp.router(
              routerConfig: router,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> tapLogOut(WidgetTester tester, {bool settle = true}) async {
        final tile = find.widgetWithText(ListTile, 'Log out');
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        if (settle) {
          await tester.pumpAndSettle();
        } else {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
        }
      }

      TextButton confirm(WidgetTester tester) => tester.widget<TextButton>(
        find.byKey(const ValueKey('log-out-confirm')),
      );

      testWidgets('opens at once while the unsynced count is slow', (
        tester,
      ) async {
        final count = Completer<int>();
        await pump(tester, counting: () => count.future);
        await tapLogOut(tester, settle: false);

        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          find.text('Checking for changes that have not synced yet…'),
          findsOneWidget,
        );
        expect(confirm(tester).onPressed, isNull);

        count.complete(2);
        await tester.pumpAndSettle();
        expect(find.textContaining('2 unsynced changes'), findsOneWidget);
        expect(confirm(tester).onPressed, isNotNull);
      });

      testWidgets('a count that never arrives still lets you log out', (
        tester,
      ) async {
        await pump(tester, counting: () => Completer<int>().future);
        await tapLogOut(tester, settle: false);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('may be lost when you log out'),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('log-out-confirm')));
        await tester.pumpAndSettle();
        expect(auth.logouts, 1);
        expect(find.text('login page'), findsOneWidget);
      });

      testWidgets('asks first even when nothing is unsynced', (tester) async {
        await pump(tester, pending: 0);
        await tapLogOut(tester);

        expect(auth.logouts, 0);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          find.text(
            'You will be signed out and need to sign in again to sync on '
            'this device.',
          ),
          findsOneWidget,
        );

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(auth.logouts, 0);
        expect(autoSync.stops, 0);
        expect(find.text('login page'), findsNothing);
      });

      testWidgets('confirming logs out and returns to sign-in', (tester) async {
        await pump(tester, pending: 0);
        await tapLogOut(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Log out'));
        await tester.pumpAndSettle();

        expect(auth.logouts, 1);
        expect(autoSync.stops, 1);
        expect(find.text('login page'), findsOneWidget);
      });

      testWidgets('unsynced changes keep their own warning', (tester) async {
        await pump(tester, pending: 3);
        await tapLogOut(tester);

        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.textContaining('3 unsynced changes'), findsOneWidget);
        expect(find.textContaining('need to sign in again'), findsNothing);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(auth.logouts, 0);
      });

      testWidgets('an unfinished sign-in shows only how to finish or stop', (
        tester,
      ) async {
        await pump(tester, signedIn: false);

        expect(find.text('Not signed in yet'), findsOneWidget);
        expect(find.text('Finish signing in'), findsOneWidget);
        expect(find.text('Log out'), findsNothing);
        expect(find.text('Change password'), findsNothing);
        expect(find.text('Connected server'), findsNothing);

        await tester.tap(find.byKey(const ValueKey('finish-signing-in')));
        await tester.pumpAndSettle();
        expect(find.text('login page'), findsOneWidget);
      });

      testWidgets('stopping an unfinished server asks, then forgets it', (
        tester,
      ) async {
        await pump(tester, signedIn: false);
        final stop = find.byKey(const ValueKey('stop-using-server'));
        await tester.ensureVisible(stop);
        await tester.tap(stop);
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(server.forgets, 0);

        await tester.tap(stop);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Stop using server'));
        await tester.pumpAndSettle();
        expect(server.forgets, 1);
        // Back to working locally: the connect choice returns.
        expect(find.text('Connect to a server'), findsOneWidget);
        expect(find.text('Not signed in yet'), findsNothing);
      });

      testWidgets('a saved session makes stopping say what to do instead', (
        tester,
      ) async {
        await pump(tester, signedIn: false);
        server.refuse = true;
        final stop = find.byKey(const ValueKey('stop-using-server'));
        await tester.ensureVisible(stop);
        await tester.tap(stop);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Stop using server'));
        await tester.pumpAndSettle();

        expect(find.textContaining('still saved'), findsOneWidget);
        expect(find.text('Not signed in yet'), findsOneWidget);
      });
    });
  }
}
