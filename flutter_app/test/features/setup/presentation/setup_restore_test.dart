import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/auth/token_service.dart';
import 'package:simpastil/core/medication/reviewed_time_zone.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/protected_workspace_fixture.dart';

class _NoSession extends TokenService {
  @override
  Future<String?> getApiKey() async => null;
  @override
  Future<bool> hasSession() async => false;
}

class _NoServer extends ServerConfigNotifier {
  @override
  String? build() => null;
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('the start page opens the backups screen to restore', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = await ProtectedWorkspaceFixture.create();
    final container = await fixture.createContainer(
      extraOverrides: [
        tokenServiceProvider.overrideWithValue(_NoSession()),
        serverConfigProvider.overrideWith(_NoServer.new),
        deviceTimeZoneProvider.overrideWith((ref) async => 'Europe/Bucharest'),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    final router = container.read(routerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.light(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The welcome is Today's; the setup route shows the start page itself.
    router.go('/setup');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('setup-start')), findsOneWidget);

    final restore = find.byKey(const ValueKey('setup-restore'));
    await tester.ensureVisible(restore);
    await tester.pumpAndSettle();
    expect(find.text('Not available yet'), findsNothing);
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(
      router.routerDelegate.currentConfiguration.last.matchedLocation,
      '/backups',
    );
    expect(find.byKey(const ValueKey('setup-restore')), findsNothing);
    // Restore opens on choosing the file, not on the backups overview.
    expect(find.text('Choose backup file'), findsOneWidget);
    expect(find.text('Create backup'), findsNothing);

    // Back from there leaves the backups screen in one step.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('setup-restore')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
