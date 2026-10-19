import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/storage/layout_family_preference.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/dashboard/selected_date_provider.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

/// How one Today layout shows a recorded miss and its late take.
class _Layout {
  const _Layout(this.family, {required this.take, this.state, this.undo});
  final LayoutFamily family;

  /// The primary action of a row, by dose id.
  final String Function(String id) take;
  final String Function(String id)? state;
  final String Function(String id)? undo;
}

final _layouts = <_Layout>[
  _Layout(
    LayoutFamily.timeline,
    take: (id) => 'timeline-take-$id',
    state: (id) => 'timeline-state-$id',
    undo: (id) => 'timeline-undo-$id',
  ),
  _Layout(
    LayoutFamily.peopleLanes,
    take: (id) => 'lanes-take-$id',
    state: (id) => 'lanes-state-$id',
    undo: (id) => 'lanes-undo-$id',
  ),
  _Layout(
    LayoutFamily.dayPlanner,
    take: (id) => 'planner-take-$id',
    state: (id) => 'planner-state-$id',
    undo: (id) => 'planner-undo-$id',
  ),
  _Layout(
    LayoutFamily.actionInbox,
    take: (id) => 'inbox-take-$id',
    state: (id) => 'inbox-state-$id',
    undo: (id) => 'inbox-undo-$id',
  ),
  _Layout(
    LayoutFamily.dailyJournal,
    take: (id) => 'journal-take-$id',
    undo: (id) => 'journal-undo-$id',
  ),
];

Future<(CareRecordingFixture, ProviderContainer)> _mount(
  WidgetTester tester,
  LayoutFamily family, {
  bool miss = true,
  Size size = const Size(412, 914),
}) async {
  final f = await CareRecordingFixture.create();
  if (miss) await f.recordMiss();
  final container = await f.workspace.createContainer();
  await container.read(layoutFamilyProvider.notifier).apply(family);
  container
      .read(selectedDateProvider.notifier)
      .select(CareRecordingFixture.planned);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() async {
    await tester.binding.setSurfaceSize(null);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
    await f.db.close();
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
        home: const FocusTodayScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (f, container);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  for (final layout in _layouts) {
    testWidgets('${layout.family.name} shows a missed dose and takes it late', (
      tester,
    ) async {
      final (f, _) = await _mount(tester, layout.family);
      final id = f.occurrence.id;

      // A recorded miss, not an open dose: it says so and offers the late take.
      final take = find.byKey(ValueKey(layout.take(id)));
      expect(take, findsOneWidget);
      expect(
        find.descendant(of: take, matching: find.text('Taken now (late)')),
        findsOneWidget,
      );
      expect(find.text('Taken now'), findsNothing);
      if (layout.state != null) {
        final state = tester.widget<Text>(
          find.byKey(ValueKey(layout.state!(id))),
        );
        expect(state.data, 'Missed');
      } else {
        expect(find.textContaining('missed'), findsWidgets);
      }
      expect(find.text('All recorded'), findsNothing);
      expect(find.text('1 dose missed'), findsOneWidget);

      await _tap(tester, take);
      final row = await f.db.medicationLedgerDao.getOccurrenceById(id);
      expect(row!.state, 'taken');
      final events = await f.db.medicationLedgerDao.getEventsForOccurrence(id);
      expect(events.map((e) => e.action), ['miss', 'correct']);
      expect(events.last.fromState, 'missed');

      // It reads as taken late, and the undo returns to the miss.
      if (layout.state != null) {
        expect(
          tester.widget<Text>(find.byKey(ValueKey(layout.state!(id)))).data,
          startsWith('Taken (late)'),
        );
      } else {
        expect(find.textContaining('late'), findsWidgets);
      }
      final undo = find.byKey(ValueKey(layout.undo!(id)));
      expect(undo, findsOneWidget);
      await _tap(tester, undo);
      final undone = await f.db.medicationLedgerDao.getOccurrenceById(id);
      expect(undone!.state, 'missed');
      expect(find.byKey(ValueKey(layout.take(id))), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final layout in _layouts) {
    testWidgets('${layout.family.name} lets a missed dose be withdrawn', (
      tester,
    ) async {
      final (f, _) = await _mount(tester, layout.family);
      final id = f.occurrence.id;
      final undo = find.byKey(ValueKey(layout.undo!(id)));
      expect(undo, findsOneWidget);
      expect(find.byKey(ValueKey(layout.take(id))), findsOneWidget);
      await _tap(tester, undo);
      final row = await f.db.medicationLedgerDao.getOccurrenceById(id);
      expect(row!.state, 'pending');
      final events = await f.db.medicationLedgerDao.getEventsForOccurrence(id);
      expect(events.map((e) => e.action), ['miss', 'undo']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the Focus deck offers the late take and counts the miss', (
    tester,
  ) async {
    final (f, _) = await _mount(tester, LayoutFamily.focusDeck);
    final id = f.occurrence.id;
    final take = find.byKey(const ValueKey('focus-taken'));
    expect(take, findsOneWidget);
    expect(
      find.descendant(of: take, matching: find.text('Taken now (late)')),
      findsOneWidget,
    );
    expect(find.text('Missed'), findsWidgets);
    expect(find.text('1 dose missed'), findsOneWidget);
    expect(find.text('All recorded'), findsNothing);
    expect(find.byKey(const ValueKey('focus-undo')), findsOneWidget);

    await _tap(tester, take);
    final row = await f.db.medicationLedgerDao.getOccurrenceById(id);
    expect(row!.state, 'taken');
    expect(find.text('Taken (late)'), findsWidgets);
    expect(find.byKey(const ValueKey('focus-undo')), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-taken')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the tablet Focus deck takes a missed dose late or skips it', (
    tester,
  ) async {
    final (f, _) = await _mount(
      tester,
      LayoutFamily.focusDeck,
      size: const Size(1205, 753),
    );
    final take = find.byKey(const ValueKey('focus-taken'));
    expect(
      find.descendant(of: take, matching: find.text('Taken now (late)')),
      findsOneWidget,
    );
    // The same review actions a pending dose has, and Undo of the miss.
    expect(find.byKey(const ValueKey('focus-other-time')), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-skip')), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-undo')), findsOneWidget);
    expect(find.text('1 dose missed'), findsOneWidget);

    await _tap(tester, take);
    final row = await f.db.medicationLedgerDao.getOccurrenceById(
      f.occurrence.id,
    );
    expect(row!.state, 'taken');
    expect(find.text('Taken (late)'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an unrecorded overdue dose stays open and is not called missed',
    (tester) async {
      final (f, _) = await _mount(tester, LayoutFamily.timeline, miss: false);
      final id = f.occurrence.id;
      expect(
        find.descendant(
          of: find.byKey(ValueKey('timeline-take-$id')),
          matching: find.text('Taken now'),
        ),
        findsOneWidget,
      );
      expect(find.text('Missed'), findsNothing);
      expect(find.text('Not recorded'), findsWidgets);
    },
  );
}
