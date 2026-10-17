import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/setup/setup_controller.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

const _prompt = 'Press Back again to exit';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  int exits = 0;
  final handlesBack = <bool>[];
  setUp(() {
    exits = 0;
    handlesBack.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemNavigator.pop') exits++;
          if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
            handlesBack.add(call.arguments as bool);
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<bool> back(WidgetTester tester) async {
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    return handled;
  }

  /// The Reminders page reads a Drift stream: cancelling it leaves a
  /// zero-length timer that one more frame lets go of.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pumpAndSettle();
  }

  String path(GoRouter router) =>
      router.routeInformationProvider.value.uri.path;

  // On a phone Android runs its own Back (and leaves the app) unless the
  // engine was told, through the last SystemNavigator.setFrameworkHandlesBack,
  // that Flutter handles it. handlePopRoute never touches that state, so the
  // behavior tests below pass even when the phone ignores them.
  group('the engine is told Flutter handles Back', () {
    for (final tab in [
      AppPaths.home,
      AppPaths.pills,
      AppPaths.logs,
      AppPaths.profiles,
    ]) {
      testWidgets('on $tab', (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _mount(tester, start: tab);
        expect(handlesBack, isNotEmpty);
        expect(handlesBack.last, isTrue);
      });
    }

    testWidgets('after moving between tabs', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final (router, _) = await _mount(tester);
      for (final tab in [AppPaths.logs, AppPaths.pills, AppPaths.home]) {
        router.go(tab);
        await tester.pumpAndSettle();
        expect(handlesBack.last, isTrue, reason: tab);
      }
    });
  });

  group('tabs', () {
    for (final tab in [AppPaths.pills, AppPaths.logs, AppPaths.profiles]) {
      testWidgets('Back on $tab returns to Today without exiting', (
        tester,
      ) async {
        final (router, _) = await _mount(tester, start: tab);
        expect(path(router), tab);
        expect(await back(tester), isTrue);
        expect(path(router), AppPaths.home);
        expect(exits, 0);
        expect(find.text(_prompt), findsNothing);
      });
    }
  });

  group('Today', () {
    testWidgets('exits only on a second Back within two seconds', (
      tester,
    ) async {
      final (router, _) = await _mount(tester);
      expect(await back(tester), isTrue);
      expect(find.text(_prompt), findsOneWidget);
      expect(exits, 0);
      expect(path(router), AppPaths.home);
      await tester.pump(const Duration(milliseconds: 1200));
      expect(await back(tester), isTrue);
      expect(exits, 1);
    });

    testWidgets('asks again once the two seconds have passed', (tester) async {
      await _mount(tester);
      await back(tester);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      await back(tester);
      expect(exits, 0);
      expect(find.text(_prompt), findsOneWidget);
    });

    testWidgets('a sheet or dialog closes first and leaves Today alone', (
      tester,
    ) async {
      final (router, _) = await _mount(tester);
      final context = tester.element(find.byType(NavigationBar));
      unawaited(
        showModalBottomSheet<void>(
          context: context,
          builder: (_) => const SizedBox(height: 120, child: Text('SHEET')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('SHEET'), findsOneWidget);
      await back(tester);
      expect(find.text('SHEET'), findsNothing);
      expect(find.text(_prompt), findsNothing);

      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(title: Text('DIALOG')),
        ),
      );
      await tester.pumpAndSettle();
      await back(tester);
      expect(find.text('DIALOG'), findsNothing);
      expect(find.text(_prompt), findsNothing);
      expect(exits, 0);
      expect(path(router), AppPaths.home);
    });
  });

  group('pushed pages', () {
    testWidgets('Routine details pushed from Today go back to Today', (
      tester,
    ) async {
      final (router, pillId) = await _mount(tester);
      unawaited(router.push<void>('/pills/$pillId/routine'));
      await tester.pumpAndSettle();
      expect(await back(tester), isTrue);
      expect(path(router), AppPaths.home);
      expect(find.text(_prompt), findsNothing);
      expect(exits, 0);
    });

    testWidgets('Routine details pushed from Medications go back there', (
      tester,
    ) async {
      final (router, pillId) = await _mount(tester, start: AppPaths.pills);
      unawaited(router.push<void>('/pills/$pillId/routine'));
      await tester.pumpAndSettle();
      await back(tester);
      expect(path(router), AppPaths.pills);
      expect(exits, 0);
    });

    testWidgets('Routine details opened alone fall back to their tab', (
      tester,
    ) async {
      final (router, pillId) = await _mount(tester);
      router.go('/pills/$pillId/routine');
      await tester.pumpAndSettle();
      expect(router.canPop(), isFalse);
      expect(await back(tester), isTrue);
      expect(path(router), AppPaths.pills);
      expect(exits, 0);
      // Then the tab rule applies: Medications go back to Today.
      await back(tester);
      expect(path(router), AppPaths.home);
      expect(exits, 0);
    });

    testWidgets('a dose opened alone falls back to Today', (tester) async {
      final (router, _) = await _mount(tester, start: AppPaths.logs);
      router.go('/doses/anything');
      await tester.pumpAndSettle();
      await back(tester);
      expect(path(router), AppPaths.home);
      expect(exits, 0);
    });

    testWidgets('Settings pushed over the shell pops back to it', (
      tester,
    ) async {
      final (router, _) = await _mount(tester);
      unawaited(router.push<void>(AppPaths.settings));
      await tester.pumpAndSettle();
      await back(tester);
      expect(path(router), AppPaths.home);
      expect(find.text(_prompt), findsNothing);
      expect(exits, 0);
    });

    // On a wide window Settings is a list with the open page beside it, and
    // Back leaves it from whichever page is open.
    for (final size in [const Size(1205, 753), const Size(753, 1205)]) {
      final label = '${size.width.toInt()}x${size.height.toInt()}';
      testWidgets('wide Settings ($label) pushed over the shell pops back to '
          'it', (tester) async {
        final (router, _) = await _mount(tester, size: size);
        unawaited(router.push<void>(AppPaths.settings));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('settings-list')), findsOneWidget);
        await back(tester);
        await settle(tester);
        expect(find.byKey(const ValueKey('settings-list')), findsNothing);
        expect(path(router), AppPaths.home);
        expect(find.text(_prompt), findsNothing);
        expect(exits, 0);
      });

      testWidgets('wide Settings ($label) opened with go() falls back to '
          'Today', (tester) async {
        final (router, _) = await _mount(
          tester,
          start: AppPaths.pills,
          size: size,
        );
        router.go(AppPaths.settings);
        await tester.pumpAndSettle();
        expect(router.canPop(), isFalse);
        expect(find.byKey(const ValueKey('settings-list')), findsOneWidget);
        expect(await back(tester), isTrue);
        await settle(tester);
        expect(path(router), AppPaths.home);
        expect(find.byKey(const ValueKey('settings-list')), findsNothing);
        expect(exits, 0);
      });

      testWidgets('wide Settings ($label) leaves from another page too', (
        tester,
      ) async {
        final (router, _) = await _mount(tester, size: size);
        unawaited(router.push<void>(AppPaths.settings));
        await tester.pumpAndSettle();
        final about = find.byKey(const ValueKey('settings-row-about'));
        await tester.ensureVisible(about);
        await tester.pumpAndSettle();
        await tester.tap(about);
        await tester.pumpAndSettle();
        await back(tester);
        await settle(tester);
        expect(path(router), AppPaths.home);
        expect(find.byKey(const ValueKey('settings-list')), findsNothing);
        expect(exits, 0);
      });
    }

    for (final target in [
      AppPaths.settings,
      AppPaths.forgotPassword,
      AppPaths.deviceName,
      '/backups',
      '/appearance',
      '/people/manage',
    ]) {
      testWidgets('$target opened with go() falls back to Today', (
        tester,
      ) async {
        final (router, _) = await _mount(tester, start: AppPaths.pills);
        router.go(target);
        await tester.pumpAndSettle();
        expect(router.canPop(), isFalse);
        expect(await back(tester), isTrue);
        expect(path(router), AppPaths.home);
        expect(exits, 0);
      });
    }
  });

  test('the manifest opts into predictive back', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml');
    expect(
      manifest.readAsStringSync(),
      contains('android:enableOnBackInvokedCallback="true"'),
    );
  });
}

void unawaited(Future<void> future) {}

Future<(GoRouter, String)> _mount(
  WidgetTester tester, {
  String start = AppPaths.home,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fixture = await CareRecordingFixture.create();
  await fixture.db.profilesDao.upsert(
    ProfilesCompanion.insert(
      id: 'second-person',
      userId: fixture.workspace.context.ownerUserId,
      name: 'Fictional second person',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ),
  );
  final draft = (await fixture.db.select(fixture.db.setupDrafts).get()).single;
  final setup = SetupRepository(
    database: fixture.db,
    access: fixture.workspace.access,
    context: fixture.workspace.context,
  );
  final ready = await setup.advanceOrSkip(
    draft.id,
    draft.revision,
    SetupStep.ready,
  );
  await setup.advanceOrSkip(ready.id, ready.revision, SetupStep.complete);
  final container = await fixture.workspace.createContainer();
  await container.read(profileListProvider.future);
  await container.read(selectedProfileIdProvider.future);
  await container.read(unfinishedSetupDraftProvider.future);
  final router = container.read(routerProvider)..go(start);
  addTearDown(() async {
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.db.close();
    container.dispose();
    await tester.pumpAndSettle();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.light().copyWith(platform: TargetPlatform.android),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (router, fixture.pill.id);
}
