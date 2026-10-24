import 'dart:async';
import 'dart:math' as math;

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
  LayoutFamily? family = LayoutFamily.timeline,
  bool twoDoses = false,
  DateTime? now,
  double textScale = 1,
}) async {
  final f = await CareRecordingFixture.create();
  if (twoDoses) await _addEveningDose(f);
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
        of: find.byKey(ValueKey('timeline-capsule-$occurrenceId')),
        matching: find.byType(CapsuleMark),
      ),
    )
    .progress;

String _state(WidgetTester tester, String id) =>
    tester.widget<Text>(find.byKey(ValueKey('timeline-state-$id'))).data!;

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

double _shown(Finder finder) {
  var best = 0.0;
  for (final element in finder.evaluate()) {
    var opacity = 1.0;
    element.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is FadeTransition) opacity *= widget.opacity.value;
      if (widget is Opacity) opacity *= widget.opacity;
      return true;
    });
    best = math.max(best, opacity);
  }
  return best;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('without a stored choice Today stays Focus deck', (tester) async {
    await _mount(tester, family: null);
    expect(find.byKey(const ValueKey('focus-taken')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline-layout')), findsNothing);
  });

  testWidgets('Timeline records through the deck: promise, durable receipt, '
      'words, then undo', (tester) async {
    final h = await _mount(tester);
    final id = h.fixture.occurrence.id;
    expect(find.byKey(const ValueKey('timeline-layout')), findsOneWidget);
    // The medication's own mark, as on the Focus deck card.
    expect(find.byKey(ValueKey('entry-mark-$id')), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-taken')), findsNothing);
    expect(_state(tester, id), 'Not recorded');

    h.service
      ..gate = Completer<void>()
      ..reached = Completer<void>();
    await _tap(tester, find.byKey(ValueKey('timeline-take-$id')));
    await tester.pump();
    await _pumpUntil(tester, () => h.service.reached!.isCompleted);

    // Promise only: a selection click, no check, no state words yet.
    expect(h.haptics, [_selection]);
    // A quick save keeps the pressed look with no new words; only a save
    // that takes longer than 400 ms says Saving….
    expect(find.text('Saving…'), findsNothing);
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.text('Saving…'), findsOneWidget);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(_progress(tester, id), 0);
    }
    expect(_state(tester, id), 'Not recorded');

    // Receipt: the same moment as Focus deck, and the state in words.
    h.service.gate!.complete();
    await _pumpUntil(tester, () => h.haptics.length == 2);
    expect(h.haptics, [_selection, _medium]);
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(_progress(tester, id), 1);
    expect(_state(tester, id), startsWith('Taken · '));
    expect(find.text('0 still to record'), findsOneWidget);
    expect(find.byKey(ValueKey('timeline-take-$id')), findsNothing);

    // Undo uses the same guarded path, light impact, no replayed ring.
    h.service.gate = null;
    await _tap(tester, find.byKey(ValueKey('timeline-undo-$id')));
    await tester.pumpAndSettle();
    expect(h.haptics, [_selection, _medium, _light]);
    expect(_progress(tester, id), 0);
    expect(_state(tester, id), 'Not recorded');
    expect(find.byKey(ValueKey('timeline-take-$id')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final MapEntry(key: family, value: prefix) in const {
    LayoutFamily.timeline: 'timeline',
    LayoutFamily.peopleLanes: 'lanes',
    LayoutFamily.dayPlanner: 'planner',
    LayoutFamily.actionInbox: 'inbox',
    LayoutFamily.dailyJournal: 'journal',
  }.entries) {
    testWidgets('${family.name}: the pressed button plays the check, then '
        'the row collapses to its quiet line', (tester) async {
      final h = await _mount(tester, family: family);
      final id = h.fixture.occurrence.id;
      await _tap(tester, find.byKey(ValueKey('$prefix-take-$id')));
      await _pumpUntil(tester, () => h.haptics.length == 2);
      await tester.pump(const Duration(milliseconds: 300));
      // The button is the dose's Undo already, still showing "Taken".
      final button = find.byKey(ValueKey('$prefix-undo-$id'));
      expect(tester.widget(button), isA<OutlinedButton>());
      expect(
        _shown(
          find.descendant(of: button, matching: find.textContaining('Taken ')),
        ),
        1,
      );
      await tester.pumpAndSettle();
      // Then the one quiet line, with its text Undo.
      expect(tester.widget(button), isA<TextButton>());
      expect(find.byKey(ValueKey('$prefix-take-$id')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('receipt order on the rail, and the ring has room', (
    tester,
  ) async {
    final h = await _mount(tester);
    final id = h.fixture.occurrence.id;
    h.service
      ..gate = Completer<void>()
      ..reached = Completer<void>();
    await _tap(tester, find.byKey(ValueKey('timeline-take-$id')));
    await tester.pump();
    await _pumpUntil(tester, () => h.service.reached!.isCompleted);
    h.service.gate!.complete();
    await _pumpUntil(tester, () => h.haptics.length == 2);
    final capsule = find.byKey(ValueKey('timeline-capsule-$id'));
    final ring = tester.widget<CustomPaint>(
      find.descendant(of: capsule, matching: find.byType(CustomPaint)).first,
    );
    final reach = (ring.painter as dynamic).reach as double;
    final center = tester.getCenter(capsule).dx;
    expect(
      reach,
      lessThanOrEqualTo(center),
      reason: 'the ring never runs past the screen edge',
    );
    for (var frame = 0; frame < 30; frame++) {
      // The pressed button plays the moment, then the row collapses to its
      // quiet line, whose text Undo never comes before the Taken words.
      final undo = _shown(find.text('Undo'));
      final taken = _shown(
        find.byWidgetPredicate(
          (w) =>
              w is Text &&
              w.key == ValueKey('timeline-state-$id') &&
              (w.data ?? '').startsWith('Taken'),
        ),
      );
      final unrecorded = _shown(find.text('Not recorded'));
      if (undo > 0) {
        expect(taken, greaterThan(0), reason: 'frame $frame: Taken first');
        expect(unrecorded, 0, reason: 'frame $frame: no overlap');
      }
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(_shown(find.byKey(ValueKey('timeline-undo-$id'))), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the sun marks now between earlier and later doses', (
    tester,
  ) async {
    final h = await _mount(
      tester,
      twoDoses: true,
      now: DateTime.utc(2026, 9, 30, 12).toLocal(),
    );
    final morning = h.fixture.occurrence.id;
    final now = find.byKey(const ValueKey('timeline-now'));
    expect(now, findsOneWidget);
    expect(
      find.descendant(of: now, matching: find.textContaining('Now, ')),
      findsOneWidget,
    );
    final items = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('timeline-item-'),
    );
    expect(items, findsNWidgets(2));
    final ys = [
      for (final e in items.evaluate())
        tester.getTopLeft(find.byWidget(e.widget)).dy,
    ];
    final nowY = tester.getTopLeft(now).dy;
    expect(
      tester.getTopLeft(find.byKey(ValueKey('timeline-item-$morning'))).dy,
      ys.reduce((a, b) => a < b ? a : b),
    );
    expect(nowY, greaterThan(ys[0]));
    expect(nowY, lessThan(ys[1]));
  });

  testWidgets('no sun on a day that is not the scene day', (tester) async {
    await _mount(tester, now: DateTime(2026, 10, 12, 12));
    expect(find.byKey(const ValueKey('timeline-now')), findsNothing);
  });

  testWidgets('rows expand for details and collapse again', (tester) async {
    final h = await _mount(tester);
    final id = h.fixture.occurrence.id;
    final details = find.byKey(ValueKey('timeline-details-$id'));
    expect(details, findsNothing);
    await _tap(tester, find.byKey(ValueKey('timeline-item-$id')));
    await tester.pumpAndSettle();
    expect(details, findsOneWidget);
    expect(find.text('Amount not specified'), findsOneWidget);
    await _tap(tester, find.byKey(ValueKey('timeline-item-$id')));
    await tester.pumpAndSettle();
    expect(details, findsNothing);
  });

  testWidgets('large text keeps the action reachable without overflow', (
    tester,
  ) async {
    final h = await _mount(tester, twoDoses: true, textScale: 2);
    final id = h.fixture.occurrence.id;
    await _tap(tester, find.byKey(ValueKey('timeline-item-$id')));
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(ValueKey('timeline-take-$id')));
    await tester.pumpAndSettle();
    expect(_state(tester, id), startsWith('Taken · '));
    expect(tester.takeException(), isNull);
  });
}
