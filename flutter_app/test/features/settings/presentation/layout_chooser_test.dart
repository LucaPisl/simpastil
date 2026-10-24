import 'package:flutter/material.dart';
import 'package:simpastil/features/pills/medication_look_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/reviewed_time_zone.dart';
import 'package:simpastil/core/storage/layout_family_preference.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/features/dashboard/today_layout/layout_preview.dart';
import 'package:simpastil/features/dashboard/today_layout/today_layouts.dart';
import 'package:simpastil/features/settings/presentation/layout_chooser_screen.dart';
import 'package:simpastil/features/settings/presentation/settings_overview.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/scene/scene_clock.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

Future<SharedPreferences> _mount(
  WidgetTester tester, {
  Map<String, Object> stored = const {},
  Locale locale = const Locale('en'),
  Size size = const Size(412, 914),
  LayoutPreviewDay? own,
}) async {
  SharedPreferences.setMockInitialValues(stored);
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        sceneClockProvider.overrideWithValue(() => DateTime(2026, 9, 30, 10)),
        layoutPreviewOwnDayProvider.overrideWith((ref) => own),
        deviceTimeZoneProvider.overrideWith((ref) async => 'UTC'),
        // The previews draw sample medications: no lookup, no database.
        medicationLooksProvider.overrideWith((ref) => const Stream.empty()),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light(),
        home: Scaffold(
          body: SettingsOverview(onSection: (_) {}, onLanguage: () {}),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return preferences;
}

const _names = {
  LayoutFamily.timeline: 'Timeline',
  LayoutFamily.peopleLanes: 'People lanes',
  LayoutFamily.dayPlanner: 'Day planner',
  LayoutFamily.actionInbox: 'Action inbox',
  LayoutFamily.dailyJournal: 'Daily journal',
};

Finder _entry() => find.byKey(const ValueKey('layout-entry'));

Future<void> _openChooser(WidgetTester tester) async {
  await tester.ensureVisible(_entry());
  await tester.tap(_entry());
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('layout-chooser')), findsOneWidget);
}

/// Scrolls the chooser (not a miniature's own list) to a family's card.
Future<Finder> _reveal(WidgetTester tester, LayoutFamily family) async {
  final card = find.byKey(ValueKey('layout-card-${family.name}'));
  await tester.scrollUntilVisible(
    card,
    200,
    scrollable: find
        .descendant(
          of: find.byKey(const ValueKey('layout-chooser')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.ensureVisible(card);
  await tester.pumpAndSettle();
  return card;
}

Future<void> _openCard(WidgetTester tester, LayoutFamily family) async {
  final card = await _reveal(tester, family);
  await tester.tap(find.descendant(of: card, matching: find.byType(Icon)).last);
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('layout-preview')), findsOneWidget);
}

FilledButton _apply(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const ValueKey('layout-apply')));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('Settings names the active layout; Focus deck by default', (
    tester,
  ) async {
    await _mount(tester);
    expect(
      find.descendant(of: _entry(), matching: find.text('Focus deck')),
      findsOneWidget,
    );
  });

  testWidgets('the chooser shows all six layouts, all available', (
    tester,
  ) async {
    await _mount(tester);
    await _openChooser(tester);
    for (final family in LayoutFamily.values) {
      final card = await _reveal(tester, family);
      expect(card, findsOneWidget, reason: family.name);
    }
    // Focus deck is in use; nothing is marked unavailable.
    expect(find.text('In use', skipOffstage: false), findsOneWidget);
    expect(find.text('Not available yet', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final family in LayoutFamily.values) {
    if (family == LayoutFamily.focusDeck) continue;
    testWidgets('${family.name} can be previewed and applied', (tester) async {
      final preferences = await _mount(tester);
      await _openChooser(tester);
      await _openCard(tester, family);
      expect(_apply(tester).onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('layout-apply')));
      await tester.pumpAndSettle();
      expect(preferences.getString(kLayoutFamilyPreferenceKey), family.name);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: _entry(), matching: find.text(_names[family]!)),
        findsOneWidget,
      );
    });
  }

  testWidgets('a family with no registered builder cannot be applied', (
    tester,
  ) async {
    final removed = todayLayouts.remove(LayoutFamily.dayPlanner)!;
    addTearDown(() => todayLayouts[LayoutFamily.dayPlanner] = removed);
    final preferences = await _mount(tester);
    await _openChooser(tester);
    await _openCard(tester, LayoutFamily.dayPlanner);
    expect(_apply(tester).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('layout-cancel')));
    await tester.pumpAndSettle();
    expect(preferences.containsKey(kLayoutFamilyPreferenceKey), isFalse);
  });

  testWidgets('Cancel after previewing Timeline changes nothing', (
    tester,
  ) async {
    final preferences = await _mount(tester);
    // The example day now also holds an as-needed dose, so the preview is
    // taller than the default test surface.
    await tester.binding.setSurfaceSize(const Size(412, 1300));
    await _openChooser(tester);
    await _openCard(tester, LayoutFamily.timeline);
    expect(find.byKey(const ValueKey('timeline-layout')), findsOneWidget);
    // A preview only shows: a tap inside it records nothing.
    final take = find.byKey(const ValueKey('timeline-take-preview-noon'));
    await tester.ensureVisible(take);
    await tester.tap(take, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('timeline-undo-preview-noon')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('layout-cancel')));
    await tester.pumpAndSettle();
    expect(preferences.containsKey(kLayoutFamilyPreferenceKey), isFalse);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _entry(), matching: find.text('Focus deck')),
      findsOneWidget,
    );
  });

  testWidgets('Apply saves Timeline and Settings shows its name', (
    tester,
  ) async {
    final preferences = await _mount(tester);
    await _openChooser(tester);
    await _openCard(tester, LayoutFamily.timeline);
    expect(find.text('Use Timeline'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('layout-apply')));
    await tester.pumpAndSettle();
    expect(preferences.getString(kLayoutFamilyPreferenceKey), 'timeline');
    expect(find.byKey(const ValueKey('layout-applied')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _entry(), matching: find.text('Timeline')),
      findsOneWidget,
    );
  });

  testWidgets("a card's miniature flies into its preview and back", (
    tester,
  ) async {
    await _mount(tester);
    await _openChooser(tester);
    final card = await _reveal(tester, LayoutFamily.timeline);
    // The flying copy is the one preview that no Hero holds.
    int flying() => find
        .byWidgetPredicate(
          (w) => w is LayoutPreview && w.family == LayoutFamily.timeline,
          skipOffstage: false,
        )
        .evaluate()
        .where((e) => e.findAncestorWidgetOfExactType<Hero>() == null)
        .length;
    expect(flying(), 0);
    await tester.tap(
      find.descendant(of: card, matching: find.byType(Icon)).last,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(flying(), 1);
    await tester.pumpAndSettle();
    expect(flying(), 0);
    expect(find.byKey(const ValueKey('layout-preview')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('layout-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(flying(), 1);
    await tester.pumpAndSettle();
    expect(flying(), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Apply confirms in place, then the ring moves to the card', (
    tester,
  ) async {
    await _mount(tester);
    await _openChooser(tester);
    await _openCard(tester, LayoutFamily.timeline);
    await tester.tap(find.byKey(const ValueKey('layout-apply')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byKey(const ValueKey('layout-applied-check')), findsOneWidget);
    expect(find.byKey(const ValueKey('layout-preview')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('layout-preview')), findsNothing);
    final timeline = await _reveal(tester, LayoutFamily.timeline);
    expect(
      find.descendant(of: timeline, matching: find.text('In use')),
      findsOneWidget,
    );
    expect(find.text('In use'), findsOneWidget);
  });

  testWidgets('a stored non-default layout shows its own name', (tester) async {
    await _mount(
      tester,
      stored: {kLayoutFamilyPreferenceKey: LayoutFamily.peopleLanes.name},
    );
    expect(
      find.descendant(of: _entry(), matching: find.text('People lanes')),
      findsOneWidget,
    );
  });

  testWidgets('an unknown stored value falls back to Focus deck', (
    tester,
  ) async {
    await _mount(tester, stored: {kLayoutFamilyPreferenceKey: 'nonsense'});
    expect(
      find.descendant(of: _entry(), matching: find.text('Focus deck')),
      findsOneWidget,
    );
  });

  testWidgets('the chooser reads in Romanian and with large text', (
    tester,
  ) async {
    await _mount(tester, locale: const Locale('ro'));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    await _openChooser(tester);
    await _openCard(tester, LayoutFamily.timeline);
    expect(find.text('Folosește aspectul „Cronologie”'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text scales each preview whole instead of cropping it', (
    tester,
  ) async {
    await _mount(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    await _openChooser(tester);
    final frames = find.byKey(const ValueKey('layout-miniature-frame'));
    expect(frames, findsWidgets);
    for (final frame in frames.evaluate()) {
      final size = (frame.renderObject! as RenderBox).size;
      // The whole 380 x 600 canvas is shown, at one scale, never a top slice.
      expect(size.width / size.height, closeTo(380 / 600, .01));
      expect(size.width, lessThan(300));
    }
    final fitted = find.descendant(
      of: frames.first,
      matching: find.byType(FittedBox),
    );
    expect(tester.widget<FittedBox>(fitted.first).fit, BoxFit.contain);
    expect(tester.takeException(), isNull);
  });

  for (final entry in {
    'expanded': const Size(1205, 753),
    'medium': const Size(753, 1205),
    'phone': const Size(412, 915),
  }.entries) {
    testWidgets('${entry.key}: the cards of a row share one height', (
      tester,
    ) async {
      await _mount(tester, size: entry.value);
      await _openChooser(tester);
      await _reveal(tester, LayoutFamily.dailyJournal);
      double heightOf(LayoutFamily f) => tester
          .getSize(
            find.byKey(ValueKey('layout-card-${f.name}'), skipOffstage: false),
          )
          .height;
      final columns = entry.value.width >= 600 ? 3 : 2;
      const all = LayoutFamily.values;
      for (var start = 0; start < all.length; start += columns) {
        final row = all.skip(start).take(columns).map(heightOf).toList();
        for (final h in row) {
          expect(h, closeTo(row.first, .5), reason: 'row at $start: $row');
        }
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('${entry.key}: Cancel and Use keep the preview column', (
      tester,
    ) async {
      await _mount(tester, size: entry.value);
      await _openChooser(tester);
      await _openCard(tester, LayoutFamily.timeline);
      final preview = tester.getRect(find.byType(LayoutPreview));
      final cancel = tester.getRect(
        find.byKey(const ValueKey('layout-cancel')),
      );
      final apply = tester.getRect(find.byKey(const ValueKey('layout-apply')));
      expect(cancel.left, closeTo(preview.left, .5));
      expect(apply.right, closeTo(preview.right, .5));
      if (entry.value.width >= 600) {
        // Wider than the column: the buttons do not run edge to edge.
        expect(cancel.left, greaterThan(20));
      }
      expect(tester.takeException(), isNull);
    });
  }

  test('a card label ends each part with one period', () {
    expect(
      layoutCardLabel(['Timeline', 'The whole day in time order.', 'In use']),
      'Timeline. The whole day in time order. In use',
    );
  });

  testWidgets('each card is one labelled button that opens its preview', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _mount(tester);
    await _openChooser(tester);
    final card = await _reveal(tester, LayoutFamily.timeline);
    final node = tester.getSemantics(card);
    expect(node, isSemantics(isButton: true, hasTapAction: true));
    expect(
      node.label,
      startsWith('Timeline. The whole day in time order, with the sun'),
    );
    expect(node.label, isNot(contains('..')));
    tester.semantics.tap(find.semantics.byLabel(node.label));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('layout-preview')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets("previews show the person's own day when there is one", (
    tester,
  ) async {
    final l = lookupAppLocalizations(const Locale('en'));
    final sample = layoutPreviewDay(l, DateTime(2026, 9, 30, 10));
    final first = sample.people.first;
    final own = (
      day: CareDay(
        localDate: sample.localDate,
        state: sample.state,
        people: [first],
        entries: [
          for (final e in sample.entries)
            if (e.person.id == first.id) e,
        ],
        prn: const [],
      ),
      asNeeded: const <CareDayEntry>[],
    );
    await _mount(tester, own: own);
    await tester.binding.setSurfaceSize(const Size(412, 1300));
    await _openChooser(tester);
    await _openCard(tester, LayoutFamily.timeline);
    expect(find.text(l.lay_previewYours), findsOneWidget);
    expect(find.text(l.lay_previewNotice), findsNothing);
    final preview = find.byType(LayoutPreview);
    expect(
      find.descendant(of: preview, matching: find.textContaining('Sam')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: preview,
        matching: find.textContaining(l.lay_exampleNoon),
      ),
      findsNothing,
    );
  });

  testWidgets('a Use label too long for its half stacks the buttons', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _mount(tester);
    await _openChooser(tester);
    await _openCard(tester, LayoutFamily.dailyJournal);
    final cancel = tester.getRect(find.byKey(const ValueKey('layout-cancel')));
    final apply = tester.getRect(find.byKey(const ValueKey('layout-apply')));
    expect(apply.bottom, lessThanOrEqualTo(cancel.top));
    expect(tester.takeException(), isNull);
  });
}
