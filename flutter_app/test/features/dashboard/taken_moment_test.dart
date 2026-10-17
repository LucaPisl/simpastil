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
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/dashboard/selected_date_provider.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/shared/widgets/capsule_mark.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import '../../helpers/care_recording_fixture.dart';
import '../../helpers/window_view.dart';

/// Holds every commit until the test releases it, optionally failing it.
class _GatedService extends CareRecordingService {
  _GatedService({
    required super.database,
    required super.access,
    required super.context,
  });

  Completer<void>? gate;
  Completer<void>? reached;
  bool fail = false;

  @override
  Future<CareRecordingReceipt> commit(PreparedCareIntent intent) async {
    if (reached != null && !reached!.isCompleted) reached!.complete();
    if (gate != null) await gate!.future;
    if (fail) throw StateError('fictional commit failure');
    return super.commit(intent);
  }
}

class _Harness {
  _Harness(this.fixture, this.service, this.haptics);
  final CareRecordingFixture fixture;
  final _GatedService service;
  final List<String> haptics;
}

const _selection = 'HapticFeedbackType.selectionClick';
const _medium = 'HapticFeedbackType.mediumImpact';
const _light = 'HapticFeedbackType.lightImpact';

Future<void> _addSecondDose(CareRecordingFixture f) async {
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
  bool quiet = false,
  bool twoDoses = false,
}) async {
  final f = await CareRecordingFixture.create();
  if (twoDoses) await _addSecondDose(f);
  final service = _GatedService(
    database: f.db,
    access: f.workspace.access,
    context: f.workspace.context,
  );
  final container = await f.workspace.createContainer(
    extraOverrides: [
      careRecordingServiceProvider.overrideWith((_) async => service),
    ],
  );
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
          data: MediaQuery.of(context).copyWith(disableAnimations: quiet),
          child: child!,
        ),
        home: const FocusTodayScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(f, service, haptics);
}

double _progress(WidgetTester tester, String occurrenceId) => tester
    .widget<CapsuleMark>(
      find.descendant(
        of: find.byKey(ValueKey('focus-capsule-$occurrenceId')),
        matching: find.byType(CapsuleMark),
      ),
    )
    .progress;

Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'the gated step should be reached');
}

Future<void> _tapTaken(WidgetTester tester, _Harness h) async {
  final take = find.byKey(const ValueKey('focus-taken'));
  await tester.ensureVisible(take);
  await tester.pumpAndSettle();
  await tester.tap(take);
  await tester.pump();
  await _pumpUntil(tester, () => h.service.reached!.isCompleted);
}

/// How visible [finder] is: its strongest match, through every fade above it.
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

  testWidgets('promise waits for the durable receipt, then plays once', (
    tester,
  ) async {
    final h = await _mount(tester);
    final id = h.fixture.occurrence.id;
    h.service
      ..gate = Completer<void>()
      ..reached = Completer<void>();
    await _tapTaken(tester, h);

    // Promise: one selection click and "Saving…" on this card, nothing else.
    expect(h.haptics, [_selection]);
    expect(find.text('Saving…'), findsOneWidget);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(_progress(tester, id), 0);
    }
    expect(h.haptics, [_selection]);
    expect(find.byKey(const ValueKey('focus-undo')), findsNothing);

    // Receipt: medium impact once, the capsule morphs to its check.
    h.service.gate!.complete();
    await _pumpUntil(tester, () => h.haptics.length == 2);
    expect(h.haptics, [_selection, _medium]);
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(_progress(tester, id), 1);
    expect(find.byKey(const ValueKey('focus-undo')), findsOneWidget);
    expect(find.text('Taken'), findsWidgets);
    expect(h.haptics, [_selection, _medium]);

    // Later rebuilds (provider refresh, more frames) never replay it.
    await tester.pump(const Duration(seconds: 2));
    expect(tester.hasRunningAnimations, isFalse);
    expect(h.haptics, [_selection, _medium]);

    // Undo folds the check back with a light impact only, no ring.
    h.service.gate = null;
    await tester.ensureVisible(find.byKey(const ValueKey('focus-undo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('focus-undo')));
    await tester.pumpAndSettle();
    expect(h.haptics, [_selection, _medium, _light]);
    expect(_progress(tester, id), 0);
    expect(find.byKey(const ValueKey('focus-taken')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('receipt order: Undo and "Saved" never precede Taken', (
    tester,
  ) async {
    final h = await _mount(tester);
    h.service
      ..gate = Completer<void>()
      ..reached = Completer<void>();
    await _tapTaken(tester, h);
    final card = find.byKey(const ValueKey('focus-current-card'));
    Finder inCard(Finder f) => find.descendant(of: card, matching: f);
    h.service.gate!.complete();
    await _pumpUntil(tester, () => h.haptics.length == 2);
    var sawTaken = false;
    for (var frame = 0; frame < 40; frame++) {
      final taken = _shown(inCard(find.text('Taken')));
      final unrecorded = _shown(inCard(find.text('Not recorded')));
      final saving = _shown(inCard(find.text('Saving…')));
      final undo = _shown(find.byKey(const ValueKey('focus-undo')));
      final saved = _shown(inCard(find.text('Saved on this device')));
      for (final receipt in [undo, saved]) {
        if (receipt > 0) {
          expect(taken, greaterThan(0), reason: 'frame $frame: Taken first');
          expect(unrecorded + saving, 0, reason: 'frame $frame: no overlap');
        }
      }
      if (taken > 0) {
        sawTaken = true;
        expect(unrecorded, 0, reason: 'frame $frame: one state at a time');
      }
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(sawTaken, isTrue);
    expect(_shown(find.byKey(const ValueKey('focus-undo'))), 1);
    expect(_shown(inCard(find.text('Saved on this device'))), 1);
    expect(h.haptics, [_selection, _medium]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed commit shows words only, no receipt', (tester) async {
    final h = await _mount(tester);
    final id = h.fixture.occurrence.id;
    h.service
      ..gate = Completer<void>()
      ..reached = Completer<void>()
      ..fail = true;
    await _tapTaken(tester, h);
    h.service.gate!.complete();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      expect(_progress(tester, id), 0);
    }
    await tester.pumpAndSettle();
    expect(h.haptics, [_selection]);
    expect(_progress(tester, id), 0);
    expect(
      find.text(
        'This entry changed or could not be saved. Review it before trying again.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('focus-taken')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling a received card away and back does not replay', (
    tester,
  ) async {
    final h = await _mount(tester, twoDoses: true);
    final id = h.fixture.occurrence.id;
    expect(find.text('2 still to record'), findsOneWidget);
    h.service.reached = Completer<void>();
    await _tapTaken(tester, h);
    await tester.pumpAndSettle();
    expect(h.haptics, [_selection, _medium]);
    expect(_progress(tester, id), 1);
    // The count rolled to the receipt this screen holds.
    expect(find.text('1 still to record'), findsOneWidget);

    for (final key in ['focus-next', 'focus-previous']) {
      final button = find.byKey(ValueKey(key));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(_progress(tester, id), 1, reason: 'no morph replay');
      }
      await tester.pumpAndSettle();
    }
    expect(h.haptics, [_selection, _medium]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the receipt sub-line grows in: the card never jumps', (
    tester,
  ) async {
    final h = await _mount(tester);
    h.service.reached = Completer<void>();
    final strip = find.byKey(const ValueKey('focus-card-scroll'));
    await _tapTaken(tester, h);
    final before = tester.getTopLeft(strip).dy;
    var last = before, largestStep = 0.0;
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final top = tester.getTopLeft(strip).dy;
      largestStep = (top - last).abs() > largestStep
          ? (top - last).abs()
          : largestStep;
      last = top;
    }
    await tester.pumpAndSettle();
    expect(
      find.text('All planned entries have a recorded outcome.'),
      findsOneWidget,
    );
    final grown = tester.getTopLeft(strip).dy - before;
    expect(grown, greaterThan(10), reason: 'the sub-line takes its room');
    expect(
      largestStep,
      lessThan(grown / 3),
      reason: 'the card eases down over several frames, never in one',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('neighbour actions never flash disabled during focus change', (
    tester,
  ) async {
    await _mount(tester, twoDoses: true);
    final taken = find.ancestor(
      of: find.text('Taken now'),
      matching: find.byWidgetPredicate((w) => w is FilledButton),
    );
    bool allEnabled() => tester
        .widgetList<FilledButton>(taken)
        .every((b) => b.onPressed != null);
    expect(taken, findsNWidgets(2));
    expect(allEnabled(), isTrue);
    final next = find.byKey(const ValueKey('focus-next'));
    await tester.ensureVisible(next);
    await tester.pumpAndSettle();
    await tester.tap(next);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(allEnabled(), isTrue, reason: 'frame $i of the focus change');
    }
    await tester.pumpAndSettle();
    expect(allEnabled(), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion shows final frames with the same words and '
      'haptics', (tester) async {
    final h = await _mount(tester, quiet: true);
    final id = h.fixture.occurrence.id;
    h.service
      ..gate = Completer<void>()
      ..reached = Completer<void>();
    await _tapTaken(tester, h);
    expect(find.text('Saving…'), findsOneWidget);
    h.service.gate!.complete();
    await _pumpUntil(tester, () => h.haptics.length == 2);
    await tester.pump();
    // Final frame at once: no morph is in flight.
    expect(_progress(tester, id), 1);
    await tester.pumpAndSettle();
    expect(h.haptics, [_selection, _medium]);
    expect(find.byKey(const ValueKey('focus-undo')), findsOneWidget);
    expect(find.text('0 still to record'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
