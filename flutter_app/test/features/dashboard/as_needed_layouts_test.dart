import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart' show OccurrenceEvent;
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:simpastil/core/storage/layout_family_preference.dart';
import 'package:simpastil/features/dashboard/today_layout/as_needed_entry.dart';
import 'package:simpastil/features/dashboard/today_layout/layout_preview.dart';
import 'package:simpastil/features/dashboard/today_layout/today_layout.dart';
import 'package:simpastil/features/dashboard/today_layout/today_layouts.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

final _now = DateTime(2026, 9, 30, 15);
const _asNeededId = 'preview-as-needed';

late AppLocalizations _l;

Future<void> _load() async {
  tzdata.initializeTimeZones();
  _l = await AppLocalizations.delegate.load(const Locale('en'));
}

/// The preview's own example day, with the recorded as-needed dose supplied
/// by [asNeeded] (default: the preview's 12:05 Ibuprofen).
({CareDay day, List<CareDayEntry> asNeeded}) _fixture({
  List<CareDayEntry> Function(List<CareDayEntry> sample)? asNeeded,
  bool inEntries = false,
}) {
  final day = layoutPreviewDay(_l, _now);
  final sample = layoutPreviewAsNeeded(_l, _now);
  final extra = asNeeded == null ? sample : asNeeded(sample);
  if (!inEntries) return (day: day, asNeeded: extra);
  return (
    day: CareDay(
      localDate: day.localDate,
      state: day.state,
      people: day.people,
      entries: [...day.entries, ...extra],
      prn: const [],
    ),
    asNeeded: const [],
  );
}

CareDayEntry _withHead(CareDayEntry e, OccurrenceEvent? head) => CareDayEntry(
  occurrence: e.occurrence,
  person: e.person,
  pill: e.pill,
  snapshot: e.snapshot,
  plannedAmount: e.plannedAmount,
  sharing: e.sharing,
  head: head,
);

/// The sample with its actual time marked unknown.
CareDayEntry _unknownTime(CareDayEntry e) {
  final h = e.head!;
  return _withHead(
    e,
    OccurrenceEvent(
      id: h.id,
      userId: h.userId,
      occurrenceId: h.occurrenceId,
      commandId: h.commandId,
      action: h.action,
      fromState: h.fromState,
      toState: h.toState,
      actualAt: null,
      actualTimeKnown: false,
      origin: h.origin,
      baseVersion: h.baseVersion,
      resultVersion: h.resultVersion,
      recordedAt: h.recordedAt,
    ),
  );
}

/// A not yet recorded as-needed row: the hidden sentinel.
CareDayEntry _sentinel(CareDayEntry e, {String id = 'preview-sentinel'}) =>
    CareDayEntry(
      occurrence: e.occurrence.copyWith(
        id: id,
        state: 'pending',
        stateVersion: 0,
      ),
      person: e.person,
      pill: e.pill.copyWith(name: 'Sentinel tablet'),
      snapshot: ScheduleSnapshotV1(
        pillName: 'Sentinel tablet',
        dosage: null,
        frequency: 'prn',
        frequencyDays: null,
        hour: 0,
        minute: 0,
        timeZone: 'UTC',
        profileId: e.person.id,
        profileName: e.person.name,
      ),
      plannedAmount: e.plannedAmount,
      sharing: e.sharing,
    );

TodayLayoutData _data(({CareDay day, List<CareDayEntry> asNeeded}) f) =>
    TodayLayoutData(
      day: f.day,
      asNeeded: f.asNeeded,
      focusedId: null,
      busyId: null,
      error: null,
      rowOf: (e) => e.occurrence,
      headOf: (e) => e.head,
      sharingOf: (e) => e.sharing,
      momentOf: (_) => null,
      settleToken: null,
      claimMoment: (_) => true,
      onMomentDone: (_) {},
      travelTimeOf: (_) => null,
      isToday: true,
      now: DateTime.now(),
      onTake: (_) {},
      onUndo: (_) {},
      onFocus: (_) {},
      onOpenDetails: (_) {},
    );

Future<void> _mount(
  WidgetTester tester,
  LayoutFamily family,
  ({CareDay day, List<CareDayEntry> asNeeded}) f, {
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(const Size(412, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final data = _data(f);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Builder(
              builder: (context) => todayLayouts[family]!(context, data),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
}

Finder _record() => find.byKey(const ValueKey('as-needed-record-$_asNeededId'));
Finder _time() => find.byKey(const ValueKey('as-needed-time-$_asNeededId'));
double _top(Finder f) => f.evaluate().isEmpty
    ? throw StateError('missing $f')
    : (f.evaluate().first.renderObject! as RenderBox)
          .localToGlobal(Offset.zero)
          .dy;

void main() {
  setUpAll(_load);

  group('shared helper', () {
    testWidgets('reads the actual recorded time and ignores pending rows', (
      tester,
    ) async {
      final f = _fixture(asNeeded: (s) => [s.single, _sentinel(s.single)]);
      await _mount(tester, LayoutFamily.timeline, f);
      final data = _data(f);
      final records = data.asNeededRecords;
      expect(records, hasLength(1));
      expect(records.single.minuteOfDay, 12 * 60 + 5);
      expect(data.scheduledEntries.any(isAsNeededEntry), isFalse);
      expect(data.scheduledEntries, hasLength(3));
    });

    testWidgets('unknown actual time is unknown, not a guessed time', (
      tester,
    ) async {
      final f = _fixture(asNeeded: (s) => [_unknownTime(s.single)]);
      await _mount(tester, LayoutFamily.timeline, f);
      expect(_time(), findsOneWidget);
      expect(
        tester.widget<Text>(_time()).data,
        _l.t08_unknownTime,
        reason: 'never labelled as a time that is not known',
      );
    });
  });

  group('Timeline', () {
    testWidgets('a recorded as-needed dose sits at its real time with a tag', (
      tester,
    ) async {
      await _mount(tester, LayoutFamily.timeline, _fixture());
      expect(_record(), findsOneWidget);
      expect(tester.widget<Text>(_time()).data, contains('12:05'));
      // The tag says As needed; the time slot never does.
      expect(
        find.descendant(of: _record(), matching: find.text(_l.t08_asNeeded)),
        findsOneWidget,
      );
      expect(tester.widget<Text>(_time()).data, isNot(_l.t08_asNeeded));
      // Between the 08:00 and the 13:00 dose on the spine.
      final morning = _top(
        find.byKey(const ValueKey('timeline-item-preview-morning')),
      );
      final noon = _top(
        find.byKey(const ValueKey('timeline-item-preview-noon')),
      );
      final dose = _top(_record());
      expect(dose, greaterThan(morning));
      expect(dose, lessThan(noon));
    });

    testWidgets('has no take or undo action and no pending sentinel', (
      tester,
    ) async {
      await _mount(
        tester,
        LayoutFamily.timeline,
        _fixture(asNeeded: (s) => [s.single, _sentinel(s.single)]),
      );
      expect(
        find.byKey(const ValueKey('timeline-take-$_asNeededId')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('timeline-undo-$_asNeededId')),
        findsNothing,
      );
      expect(find.text('Sentinel tablet'), findsNothing);
    });
  });

  group('People lanes', () {
    testWidgets('the lane count leaves as-needed doses out', (tester) async {
      await _mount(tester, LayoutFamily.peopleLanes, _fixture());
      // Alex has two scheduled doses (one taken) and one as-needed dose.
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(
                  const ValueKey('lanes-summary-preview-person-a'),
                ),
                matching: find.byType(Text),
              ),
            )
            .data,
        '${_l.widget_summary(1, 2)} · ${_l.lay_asNeededCount(1)}',
      );
      expect(_record(), findsOneWidget);
    });

    testWidgets('a person with only an as-needed dose gets its own lane', (
      tester,
    ) async {
      final base = _fixture();
      final solo = layoutPreviewDay(_l, _now).people.first;
      final day = CareDay(
        localDate: base.day.localDate,
        state: base.day.state,
        people: [solo],
        entries: const [],
        prn: const [],
      );
      await _mount(tester, LayoutFamily.peopleLanes, (
        day: day,
        asNeeded: base.asNeeded,
      ));
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(
                  const ValueKey('lanes-summary-preview-person-a'),
                ),
                matching: find.byType(Text),
              ),
            )
            .data,
        _l.lay_asNeededCount(1),
      );
      expect(find.textContaining('1 of 1'), findsNothing);
    });
  });

  group('Day planner', () {
    testWidgets('lands in its hour of the grid, not under Time unknown', (
      tester,
    ) async {
      await _mount(tester, LayoutFamily.dayPlanner, _fixture());
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('planner-hour-12')),
          matching: _record(),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('planner-unknown')), findsNothing);
    });

    testWidgets('only a genuinely unknown time stays under Time unknown', (
      tester,
    ) async {
      await _mount(
        tester,
        LayoutFamily.dayPlanner,
        _fixture(asNeeded: (s) => [_unknownTime(s.single)]),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('planner-unknown')),
          matching: _record(),
        ),
        findsOneWidget,
      );
    });

    testWidgets('lands in the agenda at large text too', (tester) async {
      await _mount(tester, LayoutFamily.dayPlanner, _fixture(), textScale: 1.5);
      expect(find.byKey(const ValueKey('planner-agenda')), findsOneWidget);
      expect(_record(), findsOneWidget);
      expect(find.byKey(const ValueKey('planner-unknown')), findsNothing);
    });
  });

  group('Action inbox', () {
    testWidgets('lists it under Recorded today with a tag, never to do', (
      tester,
    ) async {
      await _mount(tester, LayoutFamily.actionInbox, _fixture());
      expect(_record(), findsOneWidget);
      expect(
        find.descendant(of: _record(), matching: find.text(_l.t08_asNeeded)),
        findsOneWidget,
      );
      // Recorded today holds the morning dose and the as-needed one.
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('inbox-heading-rec')))
            .data,
        '${_l.ibx_recordedToday} · 2',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('inbox-heading-needs')))
            .data,
        '${_l.ibx_needsYou} · 2',
      );
      expect(
        find.byKey(const ValueKey('inbox-take-$_asNeededId')),
        findsNothing,
      );
      expect(
        _top(_record()),
        greaterThan(_top(find.byKey(const ValueKey('inbox-heading-rec')))),
      );
    });

    testWidgets('a pending as-needed row is never actionable', (tester) async {
      await _mount(
        tester,
        LayoutFamily.actionInbox,
        _fixture(asNeeded: (s) => [_sentinel(s.single)], inEntries: true),
      );
      expect(find.text('Sentinel tablet'), findsNothing);
      expect(
        find.byKey(const ValueKey('inbox-take-$_asNeededId')),
        findsNothing,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('inbox-heading-needs')))
            .data,
        '${_l.ibx_needsYou} · 2',
      );
    });
  });

  group('Daily journal', () {
    testWidgets('files it under the period of its actual time', (tester) async {
      await _mount(tester, LayoutFamily.dailyJournal, _fixture());
      final text = tester.widget<Text>(
        find.byKey(const ValueKey('journal-text-$_asNeededId')),
      );
      expect(text.data, contains('12:05'));
      expect(text.data, contains('as needed'));
      final afternoon = _top(
        find.byKey(const ValueKey('journal-period-afternoon')),
      );
      final evening = _top(
        find.byKey(const ValueKey('journal-period-evening')),
      );
      final line = _top(
        find.byKey(const ValueKey('journal-line-$_asNeededId')),
      );
      expect(line, greaterThan(afternoon));
      expect(line, lessThan(evening));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('journal-line-$_asNeededId')),
          matching: find.text(_l.t08_asNeeded),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('journal-take-$_asNeededId')),
        findsNothing,
      );
    });

    testWidgets('an as-needed dose does not count in a period well', (
      tester,
    ) async {
      await _mount(tester, LayoutFamily.dailyJournal, _fixture());
      // Afternoon holds Sam's 13:00 dose (unrecorded) plus the as-needed one:
      // the well still counts one planned dose.
      final header = find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.header == true &&
            w.properties.label == _l.jrn_periodSummary(_l.jrn_afternoon, 0, 1),
      );
      expect(header, findsOneWidget);
    });
  });

  group('previews', () {
    testWidgets('every other layout previews an as-needed sample', (
      tester,
    ) async {
      for (final family in todayLayouts.keys) {
        await tester.binding.setSurfaceSize(const Size(412, 2400));
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: AppTheme.light(),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: LayoutPreview(family: family, now: _now),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(
          find.textContaining(_l.lay_exampleAsNeeded),
          findsWidgets,
          reason: '$family',
        );
      }
      addTearDown(() => tester.binding.setSurfaceSize(null));
    });
  });
}
