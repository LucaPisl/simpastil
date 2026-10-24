import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/storage/layout_family_preference.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/review_rendering.dart';
import '../../helpers/today_tablet_fixture.dart';

// The weight rule every Today layout shares: the next due slot carries the
// filled "Taken now", a later dose a small outlined one, a finished dose one
// quiet line with a text Undo; and the low-stock row with Later.

const _phone = Size(412, 915);

/// The key prefix each list layout gives its dose controls.
const _prefixes = <LayoutFamily, String>{
  LayoutFamily.timeline: 'timeline',
  LayoutFamily.peopleLanes: 'lanes',
  LayoutFamily.dayPlanner: 'planner',
  LayoutFamily.actionInbox: 'inbox',
  LayoutFamily.dailyJournal: 'journal',
};

Finder _key(String key) => find.byKey(ValueKey(key));

/// Yesterday at [hour]:[minute] UTC, as Today's clock. The fixture's
/// routines use UTC (the morning tablet is due at 9:00, the evening one at
/// 20:00), and a miss can only be recorded once its planned time has passed
/// on the real clock, so the day under test is the one before the real one.
DateTime Function() _at(int hour, [int minute = 0]) {
  final today = TodayTabletFixture.today;
  final at = DateTime.utc(today.year, today.month, today.day - 1, hour, minute);
  return () => at;
}

/// The occurrence of [pillId] on [clock]'s day.
Future<String> _occurrence(
  WidgetTester tester,
  TodayTabletFixture f,
  String pillId,
  DateTime Function() clock,
) async {
  final day = routineDateKey(clock());
  final rows = await tester.runAsync(
    () => (f.db.select(
      f.db.medicationOccurrences,
    )..where((o) => o.pillId.equals(pillId))).get(),
  );
  return rows!.singleWhere((o) => o.plannedLocalDate == day).id;
}

/// Records [action] on [occurrenceId] before Today is mounted.
Future<void> _record(
  WidgetTester tester,
  TodayTabletFixture f,
  String occurrenceId,
  MedicationAction action,
) async {
  await tester.runAsync(
    () =>
        MedicationRepository(
          f.db,
          access: f.workspace.access,
          context: f.workspace.context,
        ).apply(
          userId: f.workspace.context.ownerUserId,
          occurrenceId: occurrenceId,
          action: action,
          actualTimeKnown: false,
          expectedStateVersion: 0,
        ),
  );
}

/// The fill the take button paints: every dose button is one outlined
/// button whose fill carries its weight, so it can morph into its Undo.
Color _fill(Finder take) {
  expect(take, findsOneWidget);
  final button = take.evaluate().single.widget as ButtonStyleButton;
  return button.style!.backgroundColor!.resolve(const {})!;
}

void _expectFilled(Finder take) {
  final primary = Theme.of(take.evaluate().single).colorScheme.primary;
  expect(_fill(take), primary);
}

void _expectOutlined(Finder take) {
  expect(_fill(take).a, 0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadReviewFonts();
  });

  group('the next due slot carries the filled Taken now', () {
    for (final MapEntry(key: family, value: prefix) in _prefixes.entries) {
      testWidgets('${family.name}: the earliest dose ahead is next', (
        tester,
      ) async {
        final clock = _at(7);
        final f = await TodayTabletFixture.create(asNeeded: 0);
        final morning = await _occurrence(tester, f, f.morning.id, clock);
        final evening = await _occurrence(tester, f, f.evening.id, clock);
        await mountToday(tester, f, family: family, size: _phone, clock: clock);
        _expectFilled(_key('$prefix-take-$morning'));
        _expectOutlined(_key('$prefix-take-$evening'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('${family.name}: an overdue dose still counts as next', (
        tester,
      ) async {
        final clock = _at(9, 30);
        final f = await TodayTabletFixture.create(asNeeded: 0);
        final morning = await _occurrence(tester, f, f.morning.id, clock);
        final evening = await _occurrence(tester, f, f.evening.id, clock);
        await mountToday(tester, f, family: family, size: _phone, clock: clock);
        _expectFilled(_key('$prefix-take-$morning'));
        _expectOutlined(_key('$prefix-take-$evening'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('${family.name}: a taken dose is one quiet line with a '
          'text Undo, and the next slot moves on', (tester) async {
        final clock = _at(9, 30);
        final f = await TodayTabletFixture.create(asNeeded: 0);
        final morning = await _occurrence(tester, f, f.morning.id, clock);
        final evening = await _occurrence(tester, f, f.evening.id, clock);
        await _record(tester, f, morning, MedicationAction.take);
        await mountToday(tester, f, family: family, size: _phone, clock: clock);
        expect(_key('$prefix-take-$morning'), findsNothing);
        final undo = _key('$prefix-undo-$morning');
        expect(undo, findsOneWidget);
        expect(undo.evaluate().single.widget, isA<TextButton>());
        // One line: Undo sits beside the name, not under it.
        // The Journal tells the dose as one sentence, with its state in it.
        final state = tester.getRect(
          _key(
            family == LayoutFamily.dailyJournal
                ? 'journal-text-$morning'
                : '$prefix-state-$morning',
          ),
        );
        final undoRect = tester.getRect(undo);
        expect(undoRect.top, lessThan(state.bottom));
        expect(undoRect.bottom, greaterThan(state.top));
        _expectFilled(_key('$prefix-take-$evening'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('${family.name}: a missed dose offers a small late take '
          'and a text Undo', (tester) async {
        final clock = _at(20, 30);
        final f = await TodayTabletFixture.create(asNeeded: 0);
        final morning = await _occurrence(tester, f, f.morning.id, clock);
        final evening = await _occurrence(tester, f, f.evening.id, clock);
        await _record(tester, f, morning, MedicationAction.miss);
        await mountToday(tester, f, family: family, size: _phone, clock: clock);
        final late = _key('$prefix-take-$morning');
        _expectOutlined(late);
        expect(
          find.descendant(of: late, matching: find.text('Taken now (late)')),
          findsOneWidget,
        );
        final undo = _key('$prefix-undo-$morning');
        expect(undo.evaluate().single.widget, isA<TextButton>());
        _expectFilled(_key('$prefix-take-$evening'));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('Focus deck', () {
    testWidgets('the next dose has the filled Taken now', (tester) async {
      final clock = _at(7);
      final f = await TodayTabletFixture.create(asNeeded: 0);
      final morning = await _occurrence(tester, f, f.morning.id, clock);
      await mountToday(
        tester,
        f,
        family: LayoutFamily.focusDeck,
        size: _phone,
        clock: clock,
      );
      expect(
        find.descendant(
          of: _key('focus-current-card'),
          matching: _key('focus-capsule-$morning'),
        ),
        findsOneWidget,
      );
      _expectFilled(_key('focus-taken'));
      // The evening dose is later: outlined, still one tap.
      await tester.ensureVisible(_key('focus-next'));
      await tester.tap(_key('focus-next'));
      await settleToday(tester, 800);
      _expectOutlined(_key('focus-taken'));
      expect(tester.takeException(), isNull);
    });

    for (final overdue in [false, true]) {
      testWidgets(
        'skip then Undo gives back the same Taken now (overdue=$overdue)',
        (tester) async {
          final clock = overdue ? _at(9, 30) : _at(7);
          final f = await TodayTabletFixture.create(asNeeded: 0);
          await mountToday(
            tester,
            f,
            family: LayoutFamily.focusDeck,
            size: _phone,
            clock: clock,
          );
          _expectFilled(_key('focus-taken'));
          final before = tester.getSize(_key('focus-taken'));
          await tester.ensureVisible(_key('focus-skip'));
          await tester.tap(_key('focus-skip'));
          await settleToday(tester, 3000);
          expect(_key('focus-undo'), findsOneWidget);
          await tester.tap(_key('focus-undo'));
          await settleToday(tester, 3000);
          _expectFilled(_key('focus-taken'));
          expect(tester.getSize(_key('focus-taken')), before);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('skip then Undo of the later dose keeps its weight', (
      tester,
    ) async {
      final clock = _at(9, 30);
      final f = await TodayTabletFixture.create(asNeeded: 0);
      final morning = await _occurrence(tester, f, f.morning.id, clock);
      await _record(tester, f, morning, MedicationAction.take);
      await mountToday(
        tester,
        f,
        family: LayoutFamily.focusDeck,
        size: _phone,
        clock: clock,
      );
      _expectFilled(_key('focus-taken'));
      await tester.ensureVisible(_key('focus-skip'));
      await tester.tap(_key('focus-skip'));
      await settleToday(tester, 3000);
      await tester.tap(_key('focus-undo'));
      await settleToday(tester, 3000);
      _expectFilled(_key('focus-taken'));
      expect(tester.takeException(), isNull);
    });

    // The jump row names the dose two cards ahead, so it exists at the first
    // of three doses and at no other, in every language.
    for (final lang in ['en', 'ro']) {
      testWidgets('the jump row does not depend on the language, $lang', (
        tester,
      ) async {
        final clock = _at(7);
        final f = await TodayTabletFixture.create(asNeeded: 0, second: true);
        await mountToday(
          tester,
          f,
          family: LayoutFamily.focusDeck,
          size: _phone,
          clock: clock,
          locale: Locale(lang),
        );
        final jump = find.byIcon(Icons.schedule);
        expect(jump, findsOneWidget);
        expect(find.textContaining('Fictional evening tablet'), findsWidgets);
        await tester.ensureVisible(_key('focus-next'));
        await tester.tap(_key('focus-next'));
        await settleToday(tester, 800);
        expect(jump, findsNothing);
        await tester.ensureVisible(_key('focus-next'));
        await tester.tap(_key('focus-next'));
        await settleToday(tester, 800);
        expect(jump, findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('opens on the first dose still to record', (tester) async {
      final clock = _at(9, 30);
      final f = await TodayTabletFixture.create(asNeeded: 0);
      final morning = await _occurrence(tester, f, f.morning.id, clock);
      final evening = await _occurrence(tester, f, f.evening.id, clock);
      await _record(tester, f, morning, MedicationAction.take);
      await mountToday(
        tester,
        f,
        family: LayoutFamily.focusDeck,
        size: _phone,
        clock: clock,
      );
      expect(
        find.descendant(
          of: _key('focus-current-card'),
          matching: _key('focus-capsule-$evening'),
        ),
        findsOneWidget,
      );
      // The evening dose is now the next one.
      _expectFilled(_key('focus-taken'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a taken dose offers an outlined Undo in the main slot', (
      tester,
    ) async {
      final clock = _at(9, 30);
      final f = await TodayTabletFixture.create(asNeeded: 0);
      final morning = await _occurrence(tester, f, f.morning.id, clock);
      final evening = await _occurrence(tester, f, f.evening.id, clock);
      await _record(tester, f, morning, MedicationAction.take);
      await _record(tester, f, evening, MedicationAction.take);
      await mountToday(
        tester,
        f,
        family: LayoutFamily.focusDeck,
        size: _phone,
        clock: clock,
      );
      expect(_key('focus-taken'), findsNothing);
      // Never filled, and as wide as the "Taken now" it replaced.
      final undo = _key('focus-undo');
      _expectOutlined(undo);
      final card = tester.getRect(_key('focus-current-card'));
      expect(tester.getSize(undo).width, greaterThan(card.width * .7));
      expect(tester.takeException(), isNull);
    });

    for (final scale in [1.0, 1.3]) {
      testWidgets('at x$scale the stock row sits under the deck', (
        tester,
      ) async {
        final clock = _at(7);
        final f = await TodayTabletFixture.create(
          morningStock: 3,
          lowAt: 5,
          asNeeded: 0,
        );
        await mountToday(
          tester,
          f,
          family: LayoutFamily.focusDeck,
          size: _phone,
          textScale: scale,
          clock: clock,
        );
        final card = tester.getRect(_key('focus-current-card'));
        final stock = tester.getRect(_key('low-stock-${f.morning.id}'));
        expect(stock.top, greaterThanOrEqualTo(card.bottom));
        // The deck's action is on the first screen.
        expect(tester.getRect(_key('focus-taken')).bottom, lessThan(915));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('the low-stock row', () {
    for (final family in LayoutFamily.values) {
      testWidgets('${family.name}: Refill soon, with Add stock and Later', (
        tester,
      ) async {
        final f = await TodayTabletFixture.create(
          morningStock: 3,
          lowAt: 5,
          asNeeded: 0,
        );
        await mountToday(
          tester,
          f,
          family: family,
          size: _phone,
          clock: _at(7),
        );
        final row = _key('low-stock-${f.morning.id}');
        expect(row, findsOneWidget);
        expect(
          find.descendant(of: row, matching: find.text('Refill soon · 3 left')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: row, matching: _key('low-stock-add')),
          findsOneWidget,
        );
        final later = find.descendant(
          of: row,
          matching: _key('low-stock-later'),
        );
        await tester.ensureVisible(later);
        await settleToday(tester, 300);
        await tester.tap(later);
        await settleToday(tester, 600);
        // Put off until tomorrow, on this device only.
        expect(row, findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the Planner gives stock its own section, with no All day', (
      tester,
    ) async {
      final f = await TodayTabletFixture.create(
        morningStock: 3,
        lowAt: 5,
        asNeeded: 0,
      );
      await mountToday(
        tester,
        f,
        family: LayoutFamily.dayPlanner,
        size: _phone,
        clock: _at(7),
      );
      expect(
        find.descendant(
          of: _key('planner-stock'),
          matching: _key('low-stock-${f.morning.id}'),
        ),
        findsOneWidget,
      );
      expect(find.text('All day'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('all recorded', () {
    for (final family in LayoutFamily.values) {
      testWidgets('${family.name}: not claimed when a dose was missed', (
        tester,
      ) async {
        final clock = _at(21, 30);
        final f = await TodayTabletFixture.create(asNeeded: 0);
        final morning = await _occurrence(tester, f, f.morning.id, clock);
        final evening = await _occurrence(tester, f, f.evening.id, clock);
        await _record(tester, f, morning, MedicationAction.take);
        await _record(tester, f, evening, MedicationAction.miss);
        await mountToday(tester, f, family: family, size: _phone, clock: clock);
        expect(
          find.text('All planned entries have a recorded outcome.'),
          findsNothing,
        );
        expect(find.text('All recorded for today'), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('${family.name}: said once every dose is taken', (
        tester,
      ) async {
        final clock = _at(21, 30);
        final f = await TodayTabletFixture.create(asNeeded: 0);
        final morning = await _occurrence(tester, f, f.morning.id, clock);
        final evening = await _occurrence(tester, f, f.evening.id, clock);
        await _record(tester, f, morning, MedicationAction.take);
        await _record(tester, f, evening, MedicationAction.take);
        await mountToday(tester, f, family: family, size: _phone, clock: clock);
        // The Focus deck's count says it on today, with no second line that
        // would push the card down as the last dose is taken.
        final deck = family == LayoutFamily.focusDeck;
        expect(
          find.text('All planned entries have a recorded outcome.'),
          deck ? findsNothing : findsOneWidget,
        );
        if (deck) {
          expect(find.text('All recorded for today'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }
  });
}
