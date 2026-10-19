import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/features/pills/presentation/medication_blister.dart';
import 'package:simpastil/features/pills/presentation/pills_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/care_recording_fixture.dart';

const _violet = Color(0xFF6E66FA), _green = Color(0xFF2E9E6A);

const _cells = [
  BlisterCell(id: 'a', name: 'Aster', color: _violet, stock: 20, threshold: 5),
  BlisterCell(id: 'b', name: 'Birch', color: _green, stock: 4, threshold: 5),
  BlisterCell(id: 'c', name: 'Cedar', color: _violet, stock: 0),
  BlisterCell(id: 'd', name: 'Dahlia', color: _green),
];

Widget _host(
  List<BlisterCell> cells, {
  ValueChanged<String>? onTap,
  ScrollController? scroll,
  bool quiet = false,
}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: AppTheme.light(),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: quiet),
    child: Scaffold(
      body: ListView(
        controller: scroll,
        children: [
          MedicationBlister(
            cells: cells,
            scroll: scroll,
            onTap: onTap ?? (_) {},
          ),
          const SizedBox(height: 2000),
        ],
      ),
    ),
  ),
);

BlisterPocketPainter _pocket(WidgetTester tester, String id) =>
    tester
            .widget<CustomPaint>(
              find.descendant(
                of: find.byKey(ValueKey('blister-$id')),
                matching: find.byType(CustomPaint),
              ),
            )
            .painter!
        as BlisterPocketPainter;

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('each pocket follows the stock capsule rule', () {
    expect(blisterStateOf(null, 5), BlisterState.untracked);
    expect(blisterStateOf(0, null), BlisterState.empty);
    expect(blisterStateOf(-2, 5), BlisterState.empty);
    expect(blisterStateOf(5, 5), BlisterState.refill);
    expect(blisterStateOf(6, 5), BlisterState.full);
    expect(blisterStateOf(1, null), BlisterState.full);
  });

  test('a routine that reaches the level within two weeks is a refill', () {
    expect(blisterStateOf(20, 5, runsLowInDays: 6), BlisterState.refill);
    expect(blisterStateOf(20, null, runsLowInDays: 14), BlisterState.refill);
    expect(blisterStateOf(20, 5, runsLowInDays: 15), BlisterState.full);
    expect(blisterStateOf(0, 5, runsLowInDays: 0), BlisterState.empty);
  });

  test('the card shows only when some medication tracks its supply', () {
    expect(MedicationBlister.shows(const []), isFalse);
    expect(MedicationBlister.shows([_cells[3]]), isFalse);
    expect(MedicationBlister.shows(_cells), isTrue);
  });

  testWidgets('one pocket per medication, and words that say the same', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_cells));
    await tester.pumpAndSettle();
    for (final c in _cells) {
      expect(find.byKey(ValueKey('blister-${c.id}')), findsOneWidget);
    }
    expect(_pocket(tester, 'a').state, BlisterState.full);
    expect(_pocket(tester, 'b').state, BlisterState.refill);
    expect(_pocket(tester, 'c').state, BlisterState.empty);
    expect(_pocket(tester, 'd').state, BlisterState.untracked);
    expect(find.text('None left: Cedar'), findsOneWidget);
    expect(find.text('Refill soon: Birch'), findsOneWidget);
    expect(find.text('Stock is fine'), findsNothing);

    await tester.pumpWidget(_host(_cells.take(1).toList()));
    await tester.pumpAndSettle();
    expect(find.text('Stock is fine'), findsOneWidget);
  });

  testWidgets('words say refill soon when the routine runs low in days', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const [
        BlisterCell(
          id: 'a',
          name: 'Aster',
          color: _violet,
          stock: 6,
          threshold: 3,
          runsLowInDays: 6,
        ),
      ]),
    );
    await tester.pumpAndSettle();
    expect(_pocket(tester, 'a').state, BlisterState.refill);
    expect(find.text('Refill soon: Aster'), findsOneWidget);
    expect(find.text('Stock is fine'), findsNothing);
  });

  testWidgets('pockets are buttons a screen reader can name', (tester) async {
    final handle = tester.ensureSemantics();
    final tapped = <String>[];
    await tester.pumpWidget(_host(_cells, onTap: tapped.add));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Medication stock'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('blister-b'))),
      matchesSemantics(
        label: 'Birch, time to refill, 4 left',
        isButton: true,
        hasTapAction: true,
        onTapHint: 'show in the list',
      ),
    );
    expect(find.bySemanticsLabel('Aster, 20 left'), findsOneWidget);
    expect(find.bySemanticsLabel('Cedar, none left'), findsOneWidget);
    expect(find.bySemanticsLabel('Dahlia, stock not tracked'), findsOneWidget);
    tester.semantics.tap(find.semantics.byLabel('Cedar, none left'));
    expect(tapped, ['c']);
    handle.dispose();
  });

  testWidgets('every pocket is a 48 dp target', (tester) async {
    await tester.pumpWidget(_host(_cells));
    await tester.pumpAndSettle();
    for (final c in _cells) {
      expect(
        tester.getSize(find.byKey(ValueKey('blister-${c.id}'))),
        const Size.square(48),
      );
    }
  });

  testWidgets('a tap presses the pocket in and lets it back up', (
    tester,
  ) async {
    final tapped = <String>[];
    await tester.pumpWidget(_host(_cells, onTap: tapped.add));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('blister-a'))),
    );
    await tester.pumpAndSettle();
    expect(_pocket(tester, 'a').dome, closeTo(.35, .001));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_pocket(tester, 'a').dome, closeTo(1, .001));
    expect(tapped, ['a']);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a refill puffs the pocket up, then rests', (tester) async {
    await tester.pumpWidget(_host([_cells[1]]));
    await tester.pumpAndSettle();
    expect(_pocket(tester, 'b').dome, closeTo(.3, .001));
    await tester.pumpWidget(
      _host(const [
        BlisterCell(id: 'b', name: 'Birch', color: _green, stock: 30),
      ]),
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(_pocket(tester, 'b').dome, inExclusiveRange(.3, 1.2));
    await tester.pumpAndSettle();
    expect(_pocket(tester, 'b').dome, closeTo(1, .001));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a change waits until the card can be seen', (tester) async {
    Widget covered(List<BlisterCell> cells, bool hidden) =>
        TickerMode(enabled: !hidden, child: _host(cells));
    await tester.pumpWidget(covered([_cells[1]], false));
    await tester.pumpAndSettle();
    const refilled = BlisterCell(
      id: 'b',
      name: 'Birch',
      color: _green,
      stock: 30,
    );
    await tester.pumpWidget(covered([refilled, _cells[0]], true));
    await tester.pumpAndSettle();
    expect(_pocket(tester, 'b').dome, closeTo(.3, .001));
    expect(_pocket(tester, 'a').arrive, 0);

    await tester.pumpWidget(covered([refilled, _cells[0]], false));
    // A beat first.
    await tester.pump(const Duration(milliseconds: 100));
    expect(_pocket(tester, 'b').dome, closeTo(.3, .001));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 120));
    expect(_pocket(tester, 'b').dome, inExclusiveRange(.3, 1.2));
    expect(_pocket(tester, 'a').arrive, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(_pocket(tester, 'b').dome, closeTo(1, .001));
    expect(_pocket(tester, 'a').arrive, 1);
  });

  testWidgets('a refill made on a page above puffs once that page is gone', (
    tester,
  ) async {
    final cells = ValueNotifier<List<BlisterCell>>([_cells[1]]);
    addTearDown(cells.dispose);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light(),
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: cells,
            builder: (context, value, _) =>
                MedicationBlister(cells: value, onTap: (_) {}),
          ),
        ),
      ),
    );
    unawaited(
      nav.currentState!.push(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 460),
          reverseTransitionDuration: const Duration(milliseconds: 460),
          pageBuilder: (_, _, _) => const Scaffold(),
          transitionsBuilder: (_, animation, _, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
    cells.value = const [
      BlisterCell(id: 'b', name: 'Birch', color: _green, stock: 30),
    ];
    await tester.pumpAndSettle();

    nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_pocket(tester, 'b').dome, closeTo(.3, .001));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_pocket(tester, 'b').dome, greaterThan(.3));
    await tester.pumpAndSettle();
    expect(_pocket(tester, 'b').dome, closeTo(1, .001));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('only a newly added pocket presses into place', (tester) async {
    await tester.pumpWidget(_host([_cells[0]]));
    await tester.pump();
    expect(_pocket(tester, 'a').arrive, 1);
    await tester.pumpWidget(_host([_cells[0], _cells[1]]));
    await tester.pump();
    expect(_pocket(tester, 'a').arrive, 1);
    expect(_pocket(tester, 'b').arrive, lessThan(1));
    await tester.pumpAndSettle();
    expect(_pocket(tester, 'b').arrive, 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('quiet mode changes pockets at once', (tester) async {
    await tester.pumpWidget(_host([_cells[1]], quiet: true));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host([
        const BlisterCell(id: 'b', name: 'Birch', color: _green, stock: 30),
        _cells[0],
      ], quiet: true),
    );
    await tester.pump();
    expect(_pocket(tester, 'b').dome, 1);
    expect(_pocket(tester, 'a').arrive, 1);
  });

  testWidgets('the sheen moves with the scroll and not otherwise', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(_host(_cells, scroll: scroll));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    var notified = 0;
    scroll.addListener(() => notified++);
    scroll.jumpTo(40);
    // The scroll is the only thing that moves it: one jump, one repaint,
    // and nothing keeps going after.
    expect(await tester.pumpAndSettle(), lessThanOrEqualTo(2));
    expect(notified, 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('the card hugs its pockets, with no filler', (tester) async {
    final many = [
      for (var i = 0; i < 7; i++)
        BlisterCell(id: '$i', name: 'M$i', color: _violet, stock: 9),
    ];
    await tester.pumpWidget(_host(many));
    await tester.pumpAndSettle();
    final card = tester.getSize(
      find
          .ancestor(
            of: find.byKey(const ValueKey('blister-0')),
            matching: find.byType(RepaintBoundary),
          )
          .first,
    );
    // 800 dp wide: up to nine across, so seven sit in one row.
    expect(card, const Size(7 * 48 + 16, 48 + 16));
    expect(find.byKey(const ValueKey('blister-7')), findsNothing);
  });

  group('on the Medications screen', () {
    Future<CareRecordingFixture> pumpScreen(
      WidgetTester tester, {
      required int? stock,
      int extra = 0,
    }) async {
      // The blister is the phone's stock summary: the page it sits on is the
      // phone page.
      tester.view.physicalSize = const Size(400, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = await CareRecordingFixture.create(legacyStock: stock);
      final now = DateTime.utc(2026, 10, 1);
      for (var i = 0; i < extra; i++) {
        await fixture.db
            .into(fixture.db.pills)
            .insert(
              PillsCompanion.insert(
                id: 'fictional-extra-$i',
                profileId: fixture.person.id,
                name: 'Fictional extra $i',
                createdAt: now,
                updatedAt: now,
                currentStock: const Value(12),
              ),
            );
      }
      final container = await fixture.workspace.createContainer();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: AppTheme.light(),
            home: const PillsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return fixture;
    }

    testWidgets('no card while no supply is tracked', (tester) async {
      await pumpScreen(tester, stock: null);
      expect(find.byType(MedicationBlister), findsNothing);
    });

    testWidgets('the words follow the routine, as the stock card on Today', (
      tester,
    ) async {
      // One dose a day: ten left lasts ten days, inside the two-week
      // heads-up, though no low-stock level is set.
      await pumpScreen(tester, stock: 10);
      expect(
        find.text('Refill soon: Fictional recorded medication'),
        findsOneWidget,
      );
      expect(find.text('Stock is fine'), findsNothing);
    });

    testWidgets('plenty for the next weeks reads as fine', (tester) async {
      await pumpScreen(tester, stock: 400);
      expect(find.text('Stock is fine'), findsOneWidget);
    });

    testWidgets('a pocket brings its medication into view and pulses it', (
      tester,
    ) async {
      final fixture = await pumpScreen(tester, stock: 3, extra: 5);
      expect(find.byType(MedicationBlister), findsOneWidget);
      const last = 'fictional-extra-4';
      final card = find.byKey(const ValueKey('medication-$last'));
      final before = tester.getTopLeft(card).dy;
      expect(before, greaterThan(700));

      await tester.tap(find.byKey(const ValueKey('blister-$last')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final after = tester.getTopLeft(card).dy;
      expect(after, lessThan(700));
      final pulse = tester.widget<BlisterPulse>(
        find.ancestor(of: card, matching: find.byType(BlisterPulse)),
      );
      expect(pulse.count, 1);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      // The fixture's own medication is low, so the words say so.
      expect(find.textContaining(fixture.pill.name), findsWidgets);
    });

    testWidgets('a pocket clears a search that hides its medication', (
      tester,
    ) async {
      final fixture = await pumpScreen(tester, stock: 3, extra: 1);
      await tester.enterText(
        find.byKey(const ValueKey('medication-search')),
        'extra',
      );
      await tester.pumpAndSettle();
      final own = find.byKey(ValueKey('medication-${fixture.pill.id}'));
      expect(own, findsNothing);
      await tester.tap(find.byKey(ValueKey('blister-${fixture.pill.id}')));
      await tester.pumpAndSettle();
      expect(own, findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('medication-search')))
            .controller!
            .text,
        isEmpty,
      );
    });
  });
}
