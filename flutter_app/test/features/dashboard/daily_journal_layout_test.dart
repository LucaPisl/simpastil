import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/care_provider.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/core/storage/layout_family_preference.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/dashboard/today_layout/daily_journal_layout.dart';
import 'package:simpastil/features/dashboard/today_layout/journal_page.dart';
import 'package:simpastil/features/dashboard/selected_date_provider.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/scene/scene_clock.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/shared/widgets/capsule_mark.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import '../../helpers/care_recording_fixture.dart';
import '../../helpers/window_view.dart';

/// Holds every commit until the test releases it.
class _GatedService extends CareRecordingService {
  _GatedService({
    required super.database,
    required super.access,
    required super.context,
    super.clock,
  });

  Completer<void>? gate;
  Completer<void>? reached;

  @override
  Future<CareRecordingReceipt> commit(PreparedCareIntent intent) async {
    if (reached != null && !reached!.isCompleted) reached!.complete();
    if (gate != null) await gate!.future;
    return super.commit(intent);
  }
}

class _Harness {
  _Harness(this.fixture, this.service, this.haptics, this.container);
  final CareRecordingFixture fixture;
  final _GatedService service;
  final List<String> haptics;
  final ProviderContainer container;
}

const _selection = 'HapticFeedbackType.selectionClick';
const _medium = 'HapticFeedbackType.mediumImpact';
const _light = 'HapticFeedbackType.lightImpact';

Future<void> _addEveningDose(CareRecordingFixture f) async {
  final setup = SetupRepository(
    database: f.db,
    access: f.workspace.access,
    context: f.workspace.context,
  );
  var draft = await setup.resumeOrCreateDraft(
    purpose: SetupPurpose.medication,
    fixedPersonId: f.person.id,
  );
  draft = (await setup.saveMedication(
    draft.id,
    draft.revision,
    const MedicationReview(name: 'Fictional evening medication'),
  )).draft;
  final routines = RoutineRepository(
    database: f.db,
    access: f.workspace.access,
    context: f.workspace.context,
    clock: () => DateTime.utc(2026, 9, 30, 8),
  );
  await routines.saveReviewed(
    await routines.preview(
      pillId: draft.medicationId!,
      expectedRevision: 0,
      definition: RoutineDefinition(
        kind: RoutineKind.daily,
        timeZone: 'UTC',
        times: [const RoutineTime(slotId: 'evening', hour: 20, minute: 0)],
      ),
      effectiveFrom: DateTime.utc(2026, 9, 30, 8),
      fromLocalDate: '2026-09-30',
      throughLocalDate: '2026-09-30',
    ),
  );
  draft = await setup.advanceOrSkip(draft.id, draft.revision, SetupStep.ready);
  await setup.advanceOrSkip(draft.id, draft.revision, SetupStep.complete);
}

Future<_Harness> _mount(
  WidgetTester tester, {
  LayoutFamily? family = LayoutFamily.dailyJournal,
  bool twoDoses = false,
  DateTime? now,
  double textScale = 1,
  bool dark = false,
  DateTime Function()? recordClock,
}) async {
  final f = await CareRecordingFixture.create();
  if (twoDoses) await _addEveningDose(f);
  final service = _GatedService(
    database: f.db,
    access: f.workspace.access,
    context: f.workspace.context,
    clock: recordClock,
  );
  final container = await f.workspace.createContainer(
    extraOverrides: [
      careRecordingServiceProvider.overrideWith((_) async => service),
      if (now != null) sceneClockProvider.overrideWithValue(() => now),
    ],
  );
  if (family != null) {
    await container.read(layoutFamilyProvider.notifier).apply(family);
  }
  container
      .read(selectedDateProvider.notifier)
      .select(CareRecordingFixture.planned);
  final haptics = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String);
      }
      return null;
    },
  );
  useWindow(tester, const Size(412, 914));
  addTearDown(() async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
    await tester.binding.setSurfaceSize(null);
    await tester.pumpWidget(const SizedBox.shrink());
    final gate = service.gate;
    if (gate != null && !gate.isCompleted) gate.complete();
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
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const FocusTodayScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(f, service, haptics, container);
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'the gated step should be reached');
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

double _progress(WidgetTester tester, String id) => tester
    .widget<CapsuleMark>(
      find.descendant(
        of: find.byKey(ValueKey('journal-capsule-$id')),
        matching: find.byType(CapsuleMark),
      ),
    )
    .progress;

String _text(WidgetTester tester, String id) =>
    tester.widget<Text>(find.byKey(ValueKey('journal-text-$id'))).data!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  test('periods follow the hour with sound boundaries', () {
    expect(DailyJournalLayout.periodOfHour(4), 'night');
    expect(DailyJournalLayout.periodOfHour(5), 'morning');
    expect(DailyJournalLayout.periodOfHour(6), 'morning');
    expect(DailyJournalLayout.periodOfHour(11), 'morning');
    expect(DailyJournalLayout.periodOfHour(12), 'afternoon');
    expect(DailyJournalLayout.periodOfHour(16), 'afternoon');
    expect(DailyJournalLayout.periodOfHour(17), 'evening');
    expect(DailyJournalLayout.periodOfHour(20), 'evening');
    expect(DailyJournalLayout.periodOfHour(21), 'night');
    expect(DailyJournalLayout.periodOfHour(0), 'night');
    expect(DailyJournalLayout.periodOfHour(null), 'morning');
  });

  testWidgets('a recorded dose is filed under the time it was taken', (
    tester,
  ) async {
    final h = await _mount(tester, twoDoses: true);
    final morning = h.fixture.occurrence.id;
    final takes = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('journal-take-'),
    );
    final eveningKey = takes
        .evaluate()
        .map((e) => e.widget.key! as ValueKey<String>)
        .firstWhere((k) => k.value != 'journal-take-$morning');
    final evening = eveningKey.value.substring('journal-take-'.length);
    await _tap(tester, find.byKey(eveningKey));
    await tester.pumpAndSettle();
    final text = _text(tester, evening);
    final taken = RegExp(r'^(\d{1,2}):\d{2}\s(AM|PM) · .*').firstMatch(text);
    expect(taken, isNotNull, reason: text);
    // The phone reads a 12-hour clock: "7:56 PM" is hour 19.
    final period = DailyJournalLayout.periodOfHour(
      int.parse(taken!.group(1)!) % 12 + (taken.group(2) == 'PM' ? 12 : 0),
    );
    final heading = find.byKey(ValueKey('journal-period-$period'));
    expect(heading, findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(ValueKey('journal-line-$evening'))).dy,
      greaterThan(tester.getTopLeft(heading).dy),
    );
    if (period != 'evening') {
      expect(
        find.byKey(const ValueKey('journal-period-evening')),
        findsNothing,
      );
    }
  });

  testWidgets('Journal reads the day in periods and records inline', (
    tester,
  ) async {
    final h = await _mount(tester, twoDoses: true);
    final id = h.fixture.occurrence.id;
    expect(find.byKey(const ValueKey('journal-layout')), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-taken')), findsNothing);
    expect(
      find.byKey(const ValueKey('journal-period-morning')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('journal-period-evening')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('journal-period-night')), findsNothing);
    expect(
      tester.getTopLeft(find.text('Morning')).dy,
      lessThan(tester.getTopLeft(find.text('Evening')).dy),
    );
    expect(
      _text(tester, id),
      'Planned 9:00 AM · Fictional Alex to take Fictional recorded medication',
    );
    expect(find.textContaining('Planned 8:00 PM · '), findsOneWidget);

    // The primary action has the same filled weight as in other layouts.
    final takeMaterial = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(ValueKey('journal-take-$id')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(
      takeMaterial.color,
      Theme.of(
        tester.element(find.byKey(ValueKey('journal-take-$id'))),
      ).colorScheme.primary,
    );

    h.service
      ..gate = Completer<void>()
      ..reached = Completer<void>();
    await _tap(tester, find.byKey(ValueKey('journal-take-$id')));
    await tester.pump();
    await _pumpUntil(tester, () => h.service.reached!.isCompleted);
    expect(h.haptics, [_selection]);
    expect(find.text('Saving…'), findsOneWidget);
    expect(_text(tester, id), startsWith('Planned 9:00 AM'));
    expect(_progress(tester, id), 0);

    h.service.gate!.complete();
    await _pumpUntil(tester, () => h.haptics.length == 2);
    await tester.pumpAndSettle();
    expect(h.haptics, [_selection, _medium]);
    expect(_progress(tester, id), 1);
    expect(
      _text(tester, id),
      matches(
        r'^\d{1,2}:\d{2}\s(AM|PM) · Fictional Alex took Fictional recorded medication$',
      ),
    );
    expect(find.byKey(ValueKey('journal-take-$id')), findsNothing);

    h.service.gate = null;
    await _tap(tester, find.byKey(ValueKey('journal-undo-$id')));
    await tester.pumpAndSettle();
    expect(h.haptics, [_selection, _medium, _light]);
    expect(_text(tester, id), startsWith('Planned 9:00 AM'));
    expect(find.byKey(ValueKey('journal-take-$id')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text and dark mode keep lines and actions reachable', (
    tester,
  ) async {
    final h = await _mount(tester, twoDoses: true, textScale: 2, dark: true);
    final id = h.fixture.occurrence.id;
    await _tap(tester, find.byKey(ValueKey('journal-take-$id')));
    await tester.pumpAndSettle();
    expect(_text(tester, id), contains(' took '));
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching layout keeps the receipt this screen holds', (
    tester,
  ) async {
    final h = await _mount(tester);
    final id = h.fixture.occurrence.id;
    await _tap(tester, find.byKey(ValueKey('journal-take-$id')));
    await tester.pumpAndSettle();
    await h.container
        .read(layoutFamilyProvider.notifier)
        .apply(LayoutFamily.focusDeck);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('focus-undo')), findsOneWidget);
    expect(h.haptics, [_selection, _medium]);
  });

  group('the page', () {
    JournalInkWell well(WidgetTester tester, String period) => tester
        .widget<JournalInkWell>(find.byKey(ValueKey('journal-well-$period')));

    testWidgets('each period opens with its ink well, today\'s outlined', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _mount(tester, twoDoses: true, now: DateTime(2026, 9, 30, 10));
      final morning = well(tester, 'morning');
      expect(morning.time, JournalPeriodTime.now);
      expect(morning.states, ['pending']);
      final evening = well(tester, 'evening');
      expect(evening.time, JournalPeriodTime.future);
      expect(find.bySemanticsLabel('Morning, 0 of 1 recorded'), findsOneWidget);
      expect(find.bySemanticsLabel('Evening, 0 of 1 recorded'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a dose recorded into a new period fills that well', (
      tester,
    ) async {
      final h = await _mount(
        tester,
        twoDoses: true,
        now: DateTime(2026, 9, 30, 22, 10),
        recordClock: () => DateTime.utc(2026, 9, 30, 22, 10),
      );
      expect(find.byKey(const ValueKey('journal-well-night')), findsNothing);
      await _tap(
        tester,
        find.byKey(ValueKey('journal-take-${h.fixture.occurrence.id}')),
      );
      JournalInkWellPainter? night() {
        final paint = find.descendant(
          of: find.byKey(const ValueKey('journal-well-night')),
          matching: find.byType(CustomPaint),
        );
        return paint.evaluate().isEmpty
            ? null
            : tester.widget<CustomPaint>(paint).painter!
                  as JournalInkWellPainter;
      }

      await tester.pump();
      for (var i = 0; i < 300 && night() == null; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      // The line moved to Night; its well fills from empty, not at once.
      expect(night()!.level, lessThan(1));
      await tester.pump(const Duration(milliseconds: 200));
      expect(night()!.level, inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(night()!.level, 1);
      expect(find.byKey(const ValueKey('journal-well-morning')), findsNothing);
    });

    testWidgets('another day shows its wells at rest', (tester) async {
      await _mount(tester, twoDoses: true, now: DateTime(2026, 10, 2, 10));
      expect(well(tester, 'morning').time, JournalPeriodTime.past);
      expect(well(tester, 'evening').time, JournalPeriodTime.past);
    });

    testWidgets('taking a dose writes its ink, even when it changes period', (
      tester,
    ) async {
      final h = await _mount(tester, twoDoses: true, textScale: 1.6);
      final id = h.fixture.occurrence.id;
      InkSignature ink() =>
          tester.widget<InkSignature>(find.byKey(ValueKey('journal-ink-$id')));
      expect(ink().state, 'pending');
      await _tap(tester, find.byKey(ValueKey('journal-take-$id')));
      await tester.pump();
      for (var i = 0; i < 300 && ink().state == 'pending'; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(ink().state, 'taken');
      await tester.pump(const Duration(milliseconds: 200));
      final painter = tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: find.byKey(ValueKey('journal-ink-$id')),
              matching: find.byType(CustomPaint),
            ),
          )
          .map((p) => p.painter)
          .whereType<InkSignaturePainter>()
          .single;
      // Still being written, not appearing already finished.
      expect(painter.progress, inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Wherever the clock files it, the wells hold one recorded dose of
      // the two.
      final wells = tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: find.byType(JournalInkWell),
              matching: find.byType(CustomPaint),
            ),
          )
          .map((p) => p.painter! as JournalInkWellPainter);
      expect(wells.fold<int>(0, (n, w) => n + w.marks), 2);
      expect(
        wells.fold<double>(0, (n, w) => n + w.level * w.marks),
        closeTo(1, 1e-9),
      );
    });
  });
}
