import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/features/analytics/adherence.dart';
import 'package:simpastil/features/analytics/analytics_providers.dart';
import 'package:simpastil/features/analytics/trend_stats.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/dashboard/history_screen.dart';
import 'package:simpastil/features/pills/presentation/pills_screen.dart';
import 'package:simpastil/features/profiles/presentation/profiles_screen.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/settings/presentation/settings_screen.dart';
import 'package:simpastil/features/setup/setup_controller.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/layouts/window_size.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/shared/widgets/capsule_mark.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';
import '../../helpers/review_rendering.dart';
import '../../helpers/held_provider_read.dart';

/// Landscape and portrait tablet windows, and a phone, in logical pixels.
const _landscape = Size(1205, 753);
const _portrait = Size(753, 1205);
const _phone = Size(390, 844);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadReviewFonts();
  });

  for (final size in [_landscape, _portrait]) {
    testWidgets('${size.width.toInt()}x${size.height.toInt()} shows a rail '
        'and no bottom bar', (tester) async {
      await _mount(tester, size);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.destinations, hasLength(4));
      expect(rail.selectedIndex, 0);
      expect(rail.labelType, NavigationRailLabelType.all);
      // The tabs and the settings entry are all labelled.
      for (final label in ['Today', 'Medications', 'History', 'People']) {
        expect(
          find.descendant(
            of: find.byType(NavigationRail),
            matching: find.text(label),
          ),
          findsOneWidget,
          reason: label,
        );
      }
      expect(find.byKey(const ValueKey('shell-rail-settings')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.byType(CapsuleMark),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await captureReview(
        tester,
        'rail-${size.width.toInt()}x${size.height.toInt()}-light',
      );
    });
  }

  testWidgets('the rail looks right in the dark theme too', (tester) async {
    await _mount(tester, _landscape, dark: true);
    expect(find.byType(NavigationRail), findsOneWidget);
    await captureReview(tester, 'rail-1205x753-dark');
    await tester.tap(find.text('Medications'));
    await tester.pumpAndSettle();
    await captureReview(tester, 'rail-1205x753-dark-medications');
  });

  testWidgets('a phone keeps the bottom bar and has no rail', (tester) async {
    await _mount(tester, _phone);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations,
      hasLength(4),
    );
    expect(find.byKey(const ValueKey('shell-rail-settings')), findsNothing);
    // The app bar keeps its own settings entry on a phone.
    expect(find.byTooltip('Settings'), findsWidgets);
  });

  testWidgets('window class follows the width, not the pane', (tester) async {
    await _mount(tester, const Size(599, 900));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    tester.view.physicalSize = const Size(600, 900);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('turning the window keeps the open tab and its state', (
    tester,
  ) async {
    final router = await _mount(tester, _landscape);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Medications'),
      ),
    );
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, AppPaths.pills);
    expect(find.byType(PillsScreen), findsOneWidget);
    tester.view.physicalSize = _phone;
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(PillsScreen), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
    tester.view.physicalSize = _portrait;
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      1,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('rail destinations keep the branch indexes', (tester) async {
    final router = await _mount(tester, _landscape);
    String path() => router.routeInformationProvider.value.uri.path;
    Finder tab(String label) => find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text(label),
    );
    expect(path(), AppPaths.home);
    await tester.tap(tab('Medications'));
    await tester.pumpAndSettle();
    expect(path(), AppPaths.pills);
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      1,
    );
    await tester.tap(tab('Today'));
    await tester.pumpAndSettle();
    expect(path(), AppPaths.home);
    expect(find.byType(FocusTodayScreen), findsOneWidget);
    await tester.tap(tab('History'));
    await tester.pumpAndSettle();
    expect(path(), AppPaths.logs);
    expect(find.byType(HistoryScreen), findsOneWidget);
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      2,
    );
    await tester.tap(tab('People'));
    await tester.pumpAndSettle();
    expect(path(), AppPaths.profiles);
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      3,
    );
  });

  group('choosing the open tab again', () {
    // A page deeper in the Medications tab, then its tab chosen once more.
    Future<void> returnsToFirstPage(
      WidgetTester tester,
      Size size,
      Finder tab,
    ) async {
      final router = await _mount(tester, size);
      String path() => router.routeInformationProvider.value.uri.path;
      await tester.tap(tab);
      await tester.pumpAndSettle();
      expect(path(), AppPaths.pills);
      router.go(AppPaths.schedules);
      await tester.pumpAndSettle();
      expect(path(), AppPaths.schedules);
      await tester.tap(tab);
      await tester.pumpAndSettle();
      expect(path(), AppPaths.pills);
      expect(find.byType(PillsScreen), findsOneWidget);
    }

    testWidgets('a rail tab returns to the tab\'s first page', (tester) async {
      await returnsToFirstPage(
        tester,
        _landscape,
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text('Medications'),
        ),
      );
    });

    testWidgets('a bar tab returns to the tab\'s first page', (tester) async {
      await returnsToFirstPage(
        tester,
        _phone,
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Medications'),
        ),
      );
    });

    testWidgets('another tab still opens where it was left', (tester) async {
      final router = await _mount(tester, _landscape);
      String path() => router.routeInformationProvider.value.uri.path;
      Finder tab(String label) => find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text(label),
      );
      await tester.tap(tab('Medications'));
      await tester.pumpAndSettle();
      router.go(AppPaths.schedules);
      await tester.pumpAndSettle();
      await tester.tap(tab('Today'));
      await tester.pumpAndSettle();
      await tester.tap(tab('Medications'));
      await tester.pumpAndSettle();
      expect(path(), AppPaths.schedules);
    });
  });

  testWidgets('the rail settings button opens Settings on top', (tester) async {
    final router = await _mount(tester, _landscape);
    await tester.tap(find.byKey(const ValueKey('shell-rail-settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    // It is pushed over the shell, so Back returns to the open tab.
    router.pop();
    await tester.pumpAndSettle();
    // Settings opens on Reminders, whose cancelled Drift watches leave a
    // zero-length timer; only advancing time runs it before the test ends.
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(SettingsScreen), findsNothing);
    expect(router.routeInformationProvider.value.uri.path, AppPaths.home);
  });

  testWidgets('People shows in the rail only while more than one is shown', (
    tester,
  ) async {
    late CareRecordingFixture fixture;
    final router = await _mount(
      tester,
      _landscape,
      initial: AppPaths.profiles,
      captureFixture: (value) => fixture = value,
    );
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).destinations,
      hasLength(4),
    );
    await tester.runAsync(() async {
      await (fixture.db.delete(
        fixture.db.profiles,
      )..where((p) => p.id.equals('second-person'))).go();
    });
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, AppPaths.home);
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.destinations, hasLength(3));
    expect(rail.selectedIndex, 0);
    expect(tester.takeException(), isNull);
  });

  group('columns line up and the side margins scroll', () {
    // The pane is what is left of the window beside the rail.
    double pane(Size size) =>
        size.width - WindowClass.forWidth(size.width).railWidth;
    for (final example in [
      (size: _landscape, column: 720.0),
      (size: _portrait, column: 640.0),
    ]) {
      final size = example.size;
      final label = '${size.width.toInt()}x${size.height.toInt()}';

      testWidgets(
        '$label: Medications keeps Add in the page, inside the pane',
        (tester) async {
          await _mount(tester, size, initial: AppPaths.pills);
          final add = tester.getRect(find.byKey(const ValueKey('add-fab')));
          final paneLeft = WindowClass.forWidth(size.width).railWidth;
          // Add sits in the page header (no full-width bar on the bottom edge),
          // centred nowhere but inside the pane and a comfortable tap target.
          expect(add.left, greaterThanOrEqualTo(paneLeft));
          expect(add.right, lessThanOrEqualTo(size.width));
          expect(add.height, greaterThanOrEqualTo(48));
          expect(add.width, lessThan(example.column));
          expect(add.bottom, lessThan(size.height - 80));
          await captureReview(tester, 'medications-$label-light');
        },
      );

      testWidgets('$label: Today, Medications, History and People span the '
          'pane and keep one column', (tester) async {
        final router = await _mount(tester, size);
        for (final screen in [
          (path: AppPaths.home, type: FocusTodayScreen),
          (path: AppPaths.pills, type: PillsScreen),
          (path: AppPaths.logs, type: HistoryScreen),
          (path: AppPaths.profiles, type: ProfilesScreen),
        ]) {
          router.go(screen.path);
          await tester.pumpAndSettle();
          // The page scrolls across the whole pane, so a swipe in the side
          // margins moves it.
          final scrollables = find
              .descendant(
                of: find.byType(screen.type),
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is Scrollable && w.axisDirection == AxisDirection.down,
                ),
              )
              .evaluate()
              .map((e) => tester.getRect(find.byWidget(e.widget)))
              .toList();
          expect(scrollables, isNotEmpty, reason: screen.path);
          if (screen.type == PillsScreen && size.width >= 840) {
            // Expanded Medications is a list beside a detail pane: together
            // they run from the page margin to the other, not one column.
            final list = tester.getRect(
              find.byKey(const ValueKey('medication-list')),
            );
            final detail = tester.getRect(
              find.byKey(const ValueKey('medication-pane')),
            );
            expect(list.left, 88 + 24, reason: screen.path);
            expect(detail.right, size.width - 24, reason: screen.path);
            expect(list.right, lessThan(detail.left), reason: screen.path);
            continue;
          }
          if (screen.type == FocusTodayScreen &&
              WindowClass.forWidth(size.width).isExpanded) {
            // Two panes scroll on their own; together they span the pane,
            // so a swipe in either side margin moves its pane.
            expect(scrollables, hasLength(2), reason: screen.path);
            scrollables.sort((a, b) => a.left.compareTo(b.left));
            expect(scrollables.first.left, 88, reason: screen.path);
            expect(scrollables.first.right, scrollables.last.left);
            expect(scrollables.last.right, size.width, reason: screen.path);
            continue;
          }
          final widest = scrollables.reduce(
            (a, b) => a.width >= b.width ? a : b,
          );
          if (screen.type == HistoryScreen && size.width >= 840) {
            // An expanded History is a calendar beside the selected day, so
            // no single list spans the pane. What scrolls stays inside it,
            // and the day's records take the wider, right-hand side.
            for (final rect in scrollables) {
              expect(rect.left, greaterThanOrEqualTo(88), reason: 'history');
              expect(rect.right, lessThanOrEqualTo(size.width));
            }
            expect(widest.right, greaterThan(size.width - 32));
            continue;
          }
          expect(widest.width, pane(size), reason: screen.path);
          expect(widest.left, 88, reason: screen.path);
        }
      });
    }
  });

  group('the soft keyboard', () {
    // The pane's screens make room for the keyboard exactly once: the shell
    // either lets its Scaffold do it (a bottom bar hides behind the keyboard)
    // or leaves it to them (a rail keeps its height).
    for (final example in [
      (size: _landscape, keyboard: 330.0),
      (size: _portrait, keyboard: 420.0),
      (size: _phone, keyboard: 320.0),
    ]) {
      final size = example.size;
      final label = '${size.width.toInt()}x${size.height.toInt()}';
      for (final screen in [
        (path: AppPaths.logs, type: HistoryScreen),
        (path: AppPaths.pills, type: PillsScreen),
      ]) {
        testWidgets('$label: ${screen.type} keeps the space above the '
            'keyboard, once', (tester) async {
          await _mount(tester, size, initial: screen.path);
          final before = _pageScroll(tester, screen.type);
          tester.view.viewInsets = FakeViewPadding(bottom: example.keyboard);
          addTearDown(tester.view.resetViewInsets);
          await tester.pumpAndSettle();
          // The calendar's card used to be given a negative minimum height
          // here: the keyboard was taken off the pane twice.
          expect(tester.takeException(), isNull);
          final room = size.height - example.keyboard;
          final after = _pageScroll(tester, screen.type);
          expect(after.bottom, lessThanOrEqualTo(room), reason: 'above keys');
          // Not shrunk a second time: the page ends within its own padding
          // (and a phone's Add button) of the keyboard, not a keyboard's
          // height short of it.
          expect(after.bottom, greaterThan(room - 90), reason: 'dead band');
          expect(after.height, greaterThan(150), reason: 'room to read');
          expect(before.bottom, greaterThan(room), reason: 'it was taller');
          // Close the tabs so the cancelled Drift watches end with the test.
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 1));
        });
      }
    }

    testWidgets('a rail keeps its height and a bar its place behind the '
        'keyboard', (tester) async {
      await _mount(tester, _landscape);
      tester.view.viewInsets = const FakeViewPadding(bottom: 330);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byType(NavigationRail)).height, 753);
      tester.view.physicalSize = _phone;
      await tester.pumpAndSettle();
      final bar = tester.getRect(find.byType(NavigationBar));
      expect(bar.bottom, 844);
      expect(tester.takeException(), isNull);
    });
  });

  group('a short window', () {
    for (final size in [const Size(700, 300), const Size(844, 390)]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}: the rail '
          'scrolls its tabs instead of overflowing', (tester) async {
        await _mount(tester, size);
        expect(tester.takeException(), isNull);
        expect(find.byType(NavigationRail), findsOneWidget);
        // Settings stays at the foot and every tab can be reached.
        expect(
          tester.getRect(find.byKey(const ValueKey('shell-rail-settings'))),
          isNotNull,
        );
        final tabs = find.descendant(
          of: find.byType(NavigationRail),
          matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          ),
        );
        expect(tabs, findsOneWidget);
        await tester.scrollUntilVisible(
          find.descendant(
            of: find.byType(NavigationRail),
            matching: find.byIcon(Icons.people_outline),
          ),
          40,
          scrollable: tabs,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a rail with the keyboard open at text scale 1.3 does not '
        'overflow', (tester) async {
      await _mount(tester, _landscape);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 330);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  // Evidence for review: every tab in both themes and both tablet shapes.
  // Writes images only when REVIEW_CAPTURE_DIR is set.
  for (final dark in [false, true]) {
    for (final size in [_landscape, _portrait]) {
      testWidgets(
        'every tab renders at ${size.width.toInt()}x${size.height.toInt()}'
        '${dark ? ' in the dark theme' : ''}',
        (tester) async {
          final router = await _mount(tester, size, dark: dark);
          final theme = dark ? 'dark' : 'light';
          for (final tab in [
            (name: 'today', path: AppPaths.home),
            (name: 'medications', path: AppPaths.pills),
            (name: 'history', path: AppPaths.logs),
            (name: 'people', path: AppPaths.profiles),
          ]) {
            router.go(tab.path);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: tab.name);
            await captureReview(
              tester,
              'tab-${tab.name}-${size.width.toInt()}x${size.height.toInt()}'
              '-$theme',
            );
          }
        },
      );
    }
  }

  testWidgets('Today, Medications and People drop their duplicate settings '
      'icon when the rail has one', (tester) async {
    final router = await _mount(tester, _landscape);
    int appBarSettings() => find
        .descendant(
          of: find.byType(AppBar),
          matching: find.byTooltip('Settings'),
        )
        .evaluate()
        .length;
    for (final path in [AppPaths.home, AppPaths.pills, AppPaths.profiles]) {
      router.go(path);
      await tester.pumpAndSettle();
      expect(appBarSettings(), 0, reason: path);
      expect(find.byTooltip('Settings'), findsOneWidget, reason: path);
    }
  });
}

/// The widest vertical scroll view of [type] (the page's own list, not a
/// calendar or card scrolling inside it), by its rectangle.
Rect _pageScroll(WidgetTester tester, Type type) {
  final rects = find
      .descendant(
        of: find.byType(type),
        matching: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      )
      .evaluate()
      .map((e) => tester.getRect(find.byWidget(e.widget)))
      .toList();
  expect(rects, isNotEmpty);
  return rects.reduce((a, b) => a.width >= b.width ? a : b);
}

Future<GoRouter> _mount(
  WidgetTester tester,
  Size size, {
  bool dark = false,
  String initial = AppPaths.home,
  ValueChanged<CareRecordingFixture>? captureFixture,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fixture = await CareRecordingFixture.create();
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
  // History opens on its calendar and statistics on wide windows. Their
  // providers start a midnight timer on the real database, which would
  // outlive the test body; this test is about the shell, so they read nothing.
  final container = await fixture.workspace.createContainer(
    extraOverrides: [
      monthAdherenceProvider.overrideWith(
        (ref, month) => Stream.value(const <DateTime, DayAdherence>{}),
      ),
      monthPrnCountsProvider.overrideWith(
        (ref, month) => Stream.value(const <DateTime, int>{}),
      ),
      adherenceStatsProvider.overrideWith(
        (ref) => Stream.value((
          last7Days: null,
          last30Days: null,
          prnTaken: 0,
          weeklyTrend: <WeekAdherence>[],
          perPill: <PillAdherence>[],
        )),
      ),
      trendStatsProvider.overrideWith(
        (ref) => Stream.value((
          streak: (current: 0, best: 0),
          hasScheduledDoses: false,
          hourlyTaken: List<int>.filled(24, 0),
          prn7Days: 0,
          prn30Days: 0,
          prnByPill: <PrnPillCount>[],
        )),
      ),
    ],
  );
  await container.readHeld(profileListProvider);
  await container.readHeld(selectedProfileIdProvider);
  await container.readHeld(unfinishedSetupDraftProvider);
  final router = container.read(routerProvider)..go(initial);
  addTearDown(() async {
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.db.close();
    container.dispose();
    await tester.pumpAndSettle();
  });
  final theme = dark ? AppTheme.dark() : AppTheme.light();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: _withReviewFont(
          theme.copyWith(platform: TargetPlatform.android),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: RepaintBoundary(key: reviewCaptureKey, child: child!),
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

/// The review typeface for the rail's own label styles (which the shared
/// helper leaves alone), so screenshots show real text.
ThemeData _withReviewFont(ThemeData theme) {
  final themed = reviewRenderingTheme(theme);
  if (identical(themed, theme)) return theme;
  final rail = theme.navigationRailTheme;
  return themed.copyWith(
    navigationRailTheme: rail.copyWith(
      selectedLabelTextStyle: rail.selectedLabelTextStyle?.copyWith(
        fontFamily: 'Roboto',
      ),
      unselectedLabelTextStyle: rail.unselectedLabelTextStyle?.copyWith(
        fontFamily: 'Roboto',
      ),
    ),
  );
}
