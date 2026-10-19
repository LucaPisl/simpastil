import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/auth/token_service.dart';
import 'package:simpastil/core/medication/reviewed_time_zone.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/features/setup/setup_controller.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
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

/// A repository whose draft writes can be made to never finish.
class _StuckRepository extends SetupRepository {
  _StuckRepository({
    required super.database,
    required super.access,
    required super.context,
  });
  bool stuck = false;
  @override
  Future<SetupDraftData> saveDraft(
    String draftId,
    int expectedRevision,
    SetupReview review,
  ) => stuck
      ? Completer<SetupDraftData>().future
      : super.saveDraft(draftId, expectedRevision, review);
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  var exits = 0;
  setUp(() {
    exits = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemNavigator.pop') exits++;
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<_StuckRepository> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = await ProtectedWorkspaceFixture.create();
    final repository = _StuckRepository(
      database: fixture.db,
      access: fixture.access,
      context: fixture.context,
    );
    final container = await fixture.createContainer(
      extraOverrides: [
        tokenServiceProvider.overrideWithValue(_NoSession()),
        serverConfigProvider.overrideWith(_NoServer.new),
        deviceTimeZoneProvider.overrideWith((ref) async => 'Europe/Bucharest'),
        setupRepositoryProvider.overrideWith((ref) async => repository),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: container.read(routerProvider),
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('setup-begin')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('setup-begin')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('person-name')), findsOneWidget);
    return repository;
  }

  testWidgets('system Back in setup goes one step back, then follows Today', (
    tester,
  ) async {
    await mount(tester);
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('person-name')), findsNothing);
    expect(find.byKey(const ValueKey('setup-begin')), findsOneWidget);
    expect(exits, 0);
    expect(find.text('Press Back again to exit'), findsNothing);

    // On the welcome nothing is left to step back: Today's exit rule applies.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Press Back again to exit'), findsOneWidget);
    expect(exits, 0);
  });

  testWidgets('system Back with a sheet open closes the sheet first', (
    tester,
  ) async {
    await mount(tester);
    final context = tester.element(find.byKey(const ValueKey('person-name')));
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        builder: (_) => const SizedBox(height: 100, child: Text('SHEET')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('SHEET'), findsNothing);
    expect(find.byKey(const ValueKey('person-name')), findsOneWidget);
  });

  testWidgets('a draft write that never finishes does not freeze setup', (
    tester,
  ) async {
    final repository = await mount(tester);
    repository.stuck = true;
    await tester.enterText(
      find.byKey(const ValueKey('person-name')),
      'Fictional Mara',
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    IconButton back() => tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.arrow_back),
    );
    expect(back().onPressed, isNull, reason: 'busy while it waits');

    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(back().onPressed, isNotNull, reason: 'the wait is bounded');
    expect(
      find.text(
        AppLocalizations.of(
          tester.element(find.byType(Scaffold).last),
        ).t08_saveError,
      ),
      findsOneWidget,
    );
    // The typed name is still there; nothing was lost by giving up waiting.
    expect(find.text('Fictional Mara'), findsOneWidget);
  });
}
