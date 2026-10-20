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
  @override
  String? build() => 'https://home.example.test';
}

class _Auth extends AuthNotifier {
  int logouts = 0;
  @override
  Future<void> logout() async => logouts++;
}

class _Sync implements SyncService {
  _Sync(this.pending);
  final int pending;
  @override
  Future<int> countPending({String? userId}) async => pending;

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

      Future<void> pump(WidgetTester tester, {required int pending}) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        auth = _Auth();
        autoSync = _AutoSync();
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
              serverConfigProvider.overrideWith(_Server.new),
              syncServiceProvider.overrideWithValue(_Sync(pending)),
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

      Future<void> tapLogOut(WidgetTester tester) async {
        final tile = find.widgetWithText(ListTile, 'Log out');
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await tester.pumpAndSettle();
      }

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
    });
  }
}
