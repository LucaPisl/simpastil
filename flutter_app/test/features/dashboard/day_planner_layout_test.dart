import 'dart:async';

import 'package:drift/drift.dart' show Value;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart'
    show MedicationOccurrencesCompanion;
import 'package:simpastil/core/medication/care_provider.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/core/storage/layout_family_preference.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/dashboard/selected_date_provider.dart';
import 'package:simpastil/features/dashboard/today_layout/day_planner_layout.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/scene/scene_clock.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/shared/widgets/capsule_mark.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import '../../helpers/care_recording_fixture.dart';
import '../../helpers/window_view.dart';

/// Holds every commit until the test releases it.
class _GatedService extends CareRecordingService {
  _GatedService({
    required super.database,
    required super.access,
    required super.context,
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
  LayoutFamily? family = LayoutFamily.dayPlanner,
  bool unknownTime = false,
  bool twoDoses = false,
  DateTime? now,
  double textScale = 1,
}) async {
  final f = await CareRecordingFixture.create();
  if (twoDoses) await _addEveningDose(f);
  if (unknownTime) {
    await (f.db.update(
      f.db.medicationOccurrences,
    )..where((o) => o.id.equals(f.occurrence.id))).write(
      const MedicationOccurrencesCompanion(plannedLocalTime: Value(null)),
    );
  }
  final service = _GatedService(
    database: f.db,
    access: f.workspace.access,
    context: f.workspace.context,
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
        theme: AppTheme.light(),
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

double _progress(WidgetTester tester, String occurrenceId) => tester
    .widget<CapsuleMark>(
      find.descendant(
        of: find.byKey(ValueKey('planner-capsule-$occurrenceId')),
        matching: find.byType(CapsuleMark),
      ),
    )
    .progress;

String _state(WidgetTester tester, String id) =>
    tester.widget<Text>(find.byKey(ValueKey('planner-state-$id'))).data!;

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

Finder _inHour(int hour, Finder item) => find.descendant(
  of: find.byKey(ValueKey('planner-hour-$hour')),
  matching: item,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  test('planned minutes parse; missing or unreadable times are unknown', () {
    expect(plannerMinuteOf('09:00:00'), 540);
    expect(plannerMinuteOf('20:15'), 1215);
    expect(plannerMinuteOf('7:05'), 425);
    expect(plannerMinuteOf(null), isNull);
    expect(plannerMinuteOf(''), isNull);
    expect(plannerMinuteOf('25:00'), isNull);
    expect(plannerMinuteOf('morning'), isNull);
  });

  testWidgets('Day planner records through the deck: promise, durable '
      'receipt, words, then undo', (tester) async {
    final h = await _mount(tester);
    final id = h.fixture.occurrence.id;
    expect(find.byKey(const ValueKey('planner-layout')), findsOneWidget);
    expect(find.byKey(const ValueKey('planner-grid')), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-taken')), findsNothing);
    expect(_state(tester, id), 'Not recorded');

    h.service
      ..gate = Completer<void>()
      ..reached = Completer<void>();
    await _tap(tester, find.byKey(ValueKey('planner-take-$id')));
    await tester.pump();
    await _pumpUntil(tester, () => h.service.reached!.isCompleted);

    // Promise only: Saving… and a selection click, no check, no words yet.
    expect(h.haptics, [_selection]);
    expect(find.text('Saving…'), findsOneWidget);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(_progress(tester, id), 0);
    }
    expect(_state(tester, id), 'Not recorded');

    h.service.gate!.complete();
    await _pumpUntil(tester, () => h.haptics.length == 2);
    expect(h.haptics, [_selection, _medium]);
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(_progress(tester, id), 1);
    expect(_state(tester, id), startsWith('Taken · '));
    expect(find.text('0 still to record'), findsOneWidget);
    expect(find.byKey(ValueKey('planner-take-$id')), findsNothing);

    h.service.gate = null;
    await _tap(tester, find.byKey(ValueKey('planner-undo-$id')));
    await tester.pumpAndSettle();
    expect(h.haptics, [_selection, _medium, _light]);
    expect(_progress(tester, id), 0);
    expect(_state(tester, id), 'Not recorded');
    expect(find.byKey(ValueKey('planner-take-$id')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('doses sit in their planned hour and now falls between them', (
    tester,
  ) async {
    final h = await _mount(
      tester,
      twoDoses: true,
      now: DateTime(2026, 9, 30, 12),
    );
    final morning = h.fixture.occurrence.id;
    expect(
      _inHour(9, find.byKey(ValueKey('planner-item-$morning'))),
      findsOneWidget,
    );
    final items = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('planner-item-'),
    );
    expect(items, findsNWidgets(2));
    final evening = items
        .evaluate()
        .map((e) => e.widget.key!)
        .firstWhere((k) => k != ValueKey('planner-item-$morning'));
    expect(_inHour(20, find.byKey(evening)), findsOneWidget);

    final now = find.byKey(const ValueKey('planner-now'));
    expect(_inHour(12, now), findsOneWidget);
    expect(
      find.descendant(of: now, matching: find.textContaining('Now, ')),
      findsOneWidget,
    );
    final nowY = tester.getTopLeft(now).dy;
    expect(
      nowY,
      greaterThan(
        tester.getTopLeft(find.byKey(ValueKey('planner-item-$morning'))).dy,
      ),
    );
    expect(nowY, lessThan(tester.getTopLeft(find.byKey(evening)).dy));
  });

  testWidgets('empty hours collapse and now sits before the first dose', (
    tester,
  ) async {
    final h = await _mount(
      tester,
      twoDoses: true,
      now: DateTime(2026, 9, 30, 6, 21),
    );
    final morning = h.fixture.occurrence.id;
    final now = find.byKey(const ValueKey('planner-now'));
    expect(_inHour(6, now), findsOneWidget);
    expect(
      tester.getTopLeft(now).dy,
      lessThan(
        tester.getTopLeft(find.byKey(ValueKey('planner-item-$morning'))).dy,
      ),
    );
    // Hours 7-8 and 10-19 are empty: no row each, one divider per run.
    expect(find.byKey(const ValueKey('planner-hour-7')), findsNothing);
    expect(find.byKey(const ValueKey('planner-hour-12')), findsNothing);
    expect(find.byKey(const ValueKey('planner-quiet-7')), findsOneWidget);
    expect(find.byKey(const ValueKey('planner-quiet-10')), findsOneWidget);
    expect(
      find.text('Nothing planned · 10 AM\u00a0–\u00a08 PM'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('planner-hour-9')), findsOneWidget);
    expect(find.byKey(const ValueKey('planner-hour-20')), findsOneWidget);
  });

  testWidgets('now after the last dose sits below it', (tester) async {
    final h = await _mount(
      tester,
      twoDoses: true,
      now: DateTime(2026, 9, 30, 22, 5),
    );
    final now = find.byKey(const ValueKey('planner-now'));
    expect(_inHour(22, now), findsOneWidget);
    final items = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('planner-item-'),
    );
    expect(items, findsNWidgets(2));
    final lastY = items
        .evaluate()
        .map((e) => tester.getTopLeft(find.byWidget(e.widget)).dy)
        .reduce((a, b) => a > b ? a : b);
    expect(tester.getTopLeft(now).dy, greaterThan(lastY));
    expect(h.fixture.occurrence.id, isNotEmpty);
  });

  test('now minute is read on the local clock', () {
    expect(plannerNowMinute(null), isNull);
    expect(plannerNowMinute(DateTime(2026, 9, 30, 6, 21)), 381);
    final utc = DateTime.utc(2026, 9, 30, 6, 21);
    final local = utc.toLocal();
    expect(plannerNowMinute(utc), local.hour * 60 + local.minute);
  });

  testWidgets('no now line on a day that is not the scene day', (tester) async {
    await _mount(tester, now: DateTime(2026, 10, 12, 12));
    expect(find.byKey(const ValueKey('planner-now')), findsNothing);
  });

  testWidgets('a dose with an unknown planned time is never plotted', (
    tester,
  ) async {
    final h = await _mount(tester, twoDoses: true, unknownTime: true);
    final id = h.fixture.occurrence.id;
    final item = find.byKey(ValueKey('planner-item-$id'));
    expect(item, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('planner-unknown')),
        matching: item,
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('planner-grid')),
        matching: item,
      ),
      findsNothing,
    );
    expect(find.text('Time unknown'), findsWidgets);
    await _tap(tester, find.byKey(ValueKey('planner-take-$id')));
    await tester.pumpAndSettle();
    expect(_state(tester, id), startsWith('Taken · '));
  });

  testWidgets('large text forces the simple agenda and keeps the action', (
    tester,
  ) async {
    final h = await _mount(
      tester,
      twoDoses: true,
      textScale: 1.3,
      now: DateTime(2026, 9, 30, 12),
    );
    final id = h.fixture.occurrence.id;
    expect(find.byKey(const ValueKey('planner-agenda')), findsOneWidget);
    expect(find.byKey(const ValueKey('planner-grid')), findsNothing);
    expect(find.text('Morning'), findsOneWidget);
    expect(find.text('Evening'), findsOneWidget);
    expect(find.byKey(const ValueKey('planner-now')), findsOneWidget);
    await _tap(tester, find.byKey(ValueKey('planner-take-$id')));
    await tester.pumpAndSettle();
    expect(_state(tester, id), startsWith('Taken · '));
    expect(tester.takeException(), isNull);
  });

  testWidgets('very large text stays an agenda without overflow', (
    tester,
  ) async {
    await _mount(tester, twoDoses: true, textScale: 2);
    expect(find.byKey(const ValueKey('planner-agenda')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
