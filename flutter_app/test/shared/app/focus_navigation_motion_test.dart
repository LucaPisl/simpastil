import 'dart:async';

import 'package:simpastil/core/db/database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simpastil/features/dashboard/dose_card_strip.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/dashboard/dose_detail_screen.dart';
import 'package:simpastil/features/dashboard/history_screen.dart';
import 'package:simpastil/features/pills/presentation/pills_screen.dart';
import 'package:simpastil/features/profiles/presentation/profiles_screen.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/schedules/presentation/routine_detail_screen.dart';
import 'package:simpastil/features/setup/setup_controller.dart';
import 'package:simpastil/features/setup/presentation/care_launch.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('People tab disappears safely when only one person remains', (
    tester,
  ) async {
    late CareRecordingFixture fixture;
    final router = await _mount(
      tester,
      captureFixture: (value) => fixture = value,
    );
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations,
      hasLength(4),
    );
    await tester.runAsync(() async {
      await (fixture.db.delete(
        fixture.db.profiles,
      )..where((p) => p.id.equals('second-person'))).go();
    });
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, AppPaths.home);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations,
      hasLength(3),
    );
    expect(find.byKey(const ValueKey('view-everyone')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('View routine never paints People and Today text together', (
    tester,
  ) async {
    final router = await _mount(tester);
    expect(_paintedOpacity(_heading(ProfilesScreen, 'People today')), 1);
    await tester.tap(find.text('View routine').first);

    var observedIncoming = false;
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final people = _paintedOpacity(_heading(ProfilesScreen, 'People today'));
      final today = _paintedOpacity(_heading(FocusTodayScreen, 'Today'));
      observedIncoming |= today > 0;
      expect(
        people > 0 && today > 0,
        isFalse,
        reason: 'Frame $frame paints People ($people) and Today ($today)',
      );
    }
    await tester.pumpAndSettle();
    expect(observedIncoming, isTrue);
    expect(router.routeInformationProvider.value.uri.path, AppPaths.home);
    expect(_paintedOpacity(_heading(FocusTodayScreen, 'Today')), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('primary replacement and Back keep just one readable page', (
    tester,
  ) async {
    final router = await _mount(tester);
    router.go(AppPaths.pills);
    await _sampleTransition(
      tester,
      ProfilesScreen,
      PillsScreen,
      requireFade: false,
    );
    expect(router.canPop(), isFalse);

    // Preserve the existing explicit push/pop back stack as well as tab go().
    final pushed = router.push<void>(AppPaths.logs);
    await _sampleTransition(tester, PillsScreen, HistoryScreen);
    expect(router.canPop(), isTrue);
    router.pop();
    await _sampleTransition(tester, HistoryScreen, PillsScreen);
    await pushed;
    expect(router.routeInformationProvider.value.uri.path, AppPaths.pills);

    router.go(AppPaths.home);
    await _sampleTransition(
      tester,
      PillsScreen,
      CareLaunch,
      requireFade: false,
    );
    expect(router.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pushed detail rises 12 dp, branch roots and quiet mode do not', (
    tester,
  ) async {
    late String pillId;
    final router = await _mount(tester, capturePill: (id) => pillId = id);
    // Branch switch: fade-through only, no vertical travel.
    router.go(AppPaths.pills);
    await tester.pump();
    var restTop = double.nan;
    var maxRise = 0.0;
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final top = tester.getTopLeft(find.byType(PillsScreen)).dy;
      restTop = restTop.isNaN ? top : restTop;
      maxRise = maxRise < (top - restTop).abs()
          ? (top - restTop).abs()
          : maxRise;
    }
    await tester.pumpAndSettle();
    expect(maxRise, 0);

    router.go(AppPaths.home);
    await tester.pumpAndSettle();
    unawaited(router.push<void>('/pills/$pillId/routine'));
    await tester.pump();
    var risen = 0.0;
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final finder = find.byType(RoutineDetailScreen);
      if (finder.evaluate().isEmpty) continue;
      final top = tester.getTopLeft(finder).dy;
      risen = risen < top ? top : risen;
    }
    await tester.pumpAndSettle();
    final settled = tester.getTopLeft(find.byType(RoutineDetailScreen)).dy;
    expect(risen - settled, greaterThan(0));
    expect(risen - settled, lessThanOrEqualTo(12.01));
    expect(tester.takeException(), isNull);
  });

  for (final reduced in [false, true]) {
    testWidgets('the tab bar selects at once only in quiet mode '
        '(reduced: $reduced)', (tester) async {
      final router = await _mount(tester, disableAnimations: reduced);
      router.go(AppPaths.home);
      await tester.pumpAndSettle();
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.animationDuration, reduced ? Duration.zero : isNull);
    });
  }

  testWidgets('quiet mode pushes with no rise', (tester) async {
    late String pillId;
    final router = await _mount(
      tester,
      disableAnimations: true,
      capturePill: (id) => pillId = id,
    );
    router.go(AppPaths.home);
    await tester.pumpAndSettle();
    unawaited(router.push<void>('/pills/$pillId/routine'));
    await tester.pump();
    await tester.pump();
    final settled = tester.getTopLeft(find.byType(RoutineDetailScreen)).dy;
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(RoutineDetailScreen)).dy, settled);
    expect(tester.takeException(), isNull);
  });

  for (final reduced in [false, true]) {
    testWidgets(
      'exact routine push and Back ${reduced ? 'switch immediately' : 'never paint both pages'}',
      (tester) async {
        late String pillId;
        final router = await _mount(
          tester,
          disableAnimations: reduced,
          capturePill: (id) => pillId = id,
        );
        await tester.tap(find.text('View routine').first);
        await tester.pumpAndSettle();
        final occurrenceId = _currentOccurrenceId(tester);
        final pushed = router.push<void>('/pills/$pillId/routine');
        if (reduced) {
          await tester.pump();
          await tester.pump();
          expect(_paintedOpacity(find.byType(CareLaunch)), 0);
          expect(_paintedOpacity(find.byType(RoutineDetailScreen)), 1);
          await tester.pumpAndSettle();
        } else {
          await _sampleTransition(tester, CareLaunch, RoutineDetailScreen);
        }
        expect(
          tester
              .widget<RoutineDetailScreen>(find.byType(RoutineDetailScreen))
              .pillId,
          pillId,
        );
        expect(
          GoRouterState.of(
            tester.element(find.byType(RoutineDetailScreen)),
          ).uri.path,
          '/pills/$pillId/routine',
        );
        expect(find.text('For Fictional Alex'), findsOneWidget);
        expect(find.text('Fictional recorded medication'), findsOneWidget);
        expect(router.canPop(), isTrue);

        await tester.binding.handlePopRoute();
        if (reduced) {
          await tester.pump();
          await tester.pump();
          expect(_paintedOpacity(find.byType(RoutineDetailScreen)), 0);
          expect(_paintedOpacity(find.byType(CareLaunch)), 1);
          await tester.pumpAndSettle();
        } else {
          await _sampleTransition(tester, RoutineDetailScreen, CareLaunch);
        }
        await pushed;
        expect(router.routeInformationProvider.value.uri.path, AppPaths.home);
        expect(_currentOccurrenceId(tester), occurrenceId);
        expect(find.byKey(const ValueKey('focus-taken')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'exact dose push and Back ${reduced ? 'switch immediately' : 'never paint both pages'}',
      (tester) async {
        final router = await _mount(tester, disableAnimations: reduced);
        await tester.tap(find.text('View routine').first);
        await tester.pumpAndSettle();
        final occurrenceId = _currentOccurrenceId(tester);
        await tester.ensureVisible(find.text('Dose details'));
        await tester.pumpAndSettle();
        expect(find.text('Dose details').hitTestable(), findsOneWidget);
        await tester.tap(find.text('Dose details'));
        if (reduced) {
          await tester.pump();
          await tester.pump();
          expect(_paintedOpacity(find.byType(CareLaunch)), 0);
          expect(_paintedOpacity(find.byType(DoseDetailScreen)), 1);
          await tester.pumpAndSettle();
        } else {
          await _sampleTransition(tester, CareLaunch, DoseDetailScreen);
        }
        expect(
          tester
              .widget<DoseDetailScreen>(find.byType(DoseDetailScreen))
              .occurrenceId,
          occurrenceId,
        );
        expect(
          GoRouterState.of(
            tester.element(find.byType(DoseDetailScreen)),
          ).uri.path,
          '/doses/$occurrenceId',
        );
        expect(find.text('For Fictional Alex'), findsOneWidget);
        expect(find.text('Fictional recorded medication'), findsOneWidget);
        expect(router.canPop(), isTrue);

        await tester.binding.handlePopRoute();
        if (reduced) {
          await tester.pump();
          await tester.pump();
          expect(_paintedOpacity(find.byType(DoseDetailScreen)), 0);
          expect(_paintedOpacity(find.byType(CareLaunch)), 1);
          await tester.pumpAndSettle();
        } else {
          await _sampleTransition(tester, DoseDetailScreen, CareLaunch);
        }
        expect(router.routeInformationProvider.value.uri.path, AppPaths.home);
        expect(_currentOccurrenceId(tester), occurrenceId);
        expect(find.byKey(const ValueKey('focus-taken')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final accessibleNavigation in [false, true]) {
    testWidgets(
      'Reduced motion${accessibleNavigation ? ' with accessible navigation' : ''} '
      'shows only the new primary page on its first frame',
      (tester) async {
        final router = await _mount(
          tester,
          disableAnimations: true,
          accessibleNavigation: accessibleNavigation,
        );
        Type outgoing = ProfilesScreen;
        for (final destination in <(String, Type)>[
          (AppPaths.home, CareLaunch),
          (AppPaths.pills, PillsScreen),
          (AppPaths.logs, HistoryScreen),
          (AppPaths.profiles, ProfilesScreen),
        ]) {
          router.go(destination.$1);
          // Flush routing microtasks without advancing the animation clock.
          await tester.pump();
          await tester.pump();
          expect(_paintedOpacity(find.byType(outgoing)), 0);
          expect(_paintedOpacity(find.byType(destination.$2)), 1);
          await tester.pumpAndSettle();
          outgoing = destination.$2;
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Accessible navigation alone still crossfades between primary pages',
    (tester) async {
      // Android reports accessible navigation for any accessibility service
      // (password managers, automation apps); only "Remove animations" quiets.
      final router = await _mount(tester, accessibleNavigation: true);
      router.go(AppPaths.pills);
      await tester.pump();
      await tester.pump();
      expect(_paintedOpacity(find.byType(PillsScreen)), lessThan(1));
      await tester.pumpAndSettle();
      expect(_paintedOpacity(find.byType(PillsScreen)), 1);
      expect(tester.takeException(), isNull);
    },
  );
}

String _currentOccurrenceId(WidgetTester tester) {
  final currentCard = find.byKey(const ValueKey('focus-current-card'));
  expect(currentCard, findsOneWidget);
  final selectedId = tester
      .widget<DoseCardStrip>(find.byType(DoseCardStrip))
      .selectedId;
  expect(
    find.ancestor(
      of: currentCard,
      matching: find.byKey(ValueKey('focus-card-$selectedId')),
    ),
    findsOneWidget,
  );
  return selectedId;
}

Future<void> _sampleTransition(
  WidgetTester tester,
  Type outgoing,
  Type incoming, {
  bool requireFade = true,
}) async {
  var sawFade = false;
  for (var frame = 0; frame < 20; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    final oldOpacity = _paintedOpacity(find.byType(outgoing));
    final newOpacity = _paintedOpacity(find.byType(incoming));
    expect(
      oldOpacity > 0 && newOpacity > 0,
      isFalse,
      reason: '$outgoing → $incoming frame $frame: $oldOpacity / $newOpacity',
    );
    sawFade |=
        (oldOpacity > 0 && oldOpacity < 1) ||
        (newOpacity > 0 && newOpacity < 1);
  }
  if (requireFade) expect(sawFade, isTrue);
  await tester.pumpAndSettle();
  expect(_paintedOpacity(find.byType(outgoing)), 0);
  expect(_paintedOpacity(find.byType(incoming)), 1);
}

Finder _heading(Type screen, String text) =>
    find.descendant(of: find.byType(screen), matching: find.text(text));

// Inspect the actual render ancestry, including the platform route's fades;
// finding both widgets alone would incorrectly fail an invisible retained page.
double _paintedOpacity(Finder finder) {
  var maximum = 0.0;
  for (final element in finder.evaluate()) {
    RenderObject? object = element.findRenderObject();
    var opacity = 1.0;
    while (object != null) {
      if (object is RenderAnimatedOpacity) opacity *= object.opacity.value;
      if (object is RenderOpacity) opacity *= object.opacity;
      if (object is RenderOffstage && object.offstage) opacity = 0;
      object = object.parent;
    }
    if (opacity > maximum) maximum = opacity;
  }
  return maximum;
}

Future<GoRouter> _mount(
  WidgetTester tester, {
  bool disableAnimations = false,
  bool accessibleNavigation = false,
  ValueChanged<String>? capturePill,
  ValueChanged<CareRecordingFixture>? captureFixture,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fixture = await CareRecordingFixture.create();
  capturePill?.call(fixture.pill.id);
  captureFixture?.call(fixture);
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
  final router = container.read(routerProvider)..go(AppPaths.profiles);
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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: disableAnimations,
            accessibleNavigation: accessibleNavigation,
          ),
          child: child!,
        ),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}
