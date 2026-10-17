import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/core/storage/layout_family_preference.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/dashboard/selected_date_provider.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/features/dashboard/today_side/week_strip.dart';
import 'package:simpastil/shared/motion/ambient_motion.dart';
import 'package:simpastil/shared/scene/horizon_model.dart';
import 'package:simpastil/shared/scene/horizon_scene.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/shared/widgets/capsule_mark.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import '../../helpers/care_recording_fixture.dart';
import '../../helpers/window_view.dart';

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

Future<CareRecordingFixture> _mount(
  WidgetTester tester, {
  double textScale = 1,
  ThemeData? theme,
  bool ambient = false,
  bool quiet = false,
  bool twentyFourHour = false,
}) async {
  final f = await CareRecordingFixture.create();
  await _addEveningDose(f);
  final container = await f.workspace.createContainer();
  container
      .read(selectedDateProvider.notifier)
      .select(CareRecordingFixture.planned);
  useWindow(tester, const Size(412, 914));
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
        theme: theme ?? AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 24),
            textScaler: TextScaler.linear(textScale),
            disableAnimations: quiet,
            alwaysUse24HourFormat: twentyFourHour,
          ),
          child: AmbientMotion(enabled: ambient, child: child!),
        ),
        home: const FocusTodayScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return f;
}

double _takenTop(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(const ValueKey('focus-taken'))).dy;

/// The interactive scene behind the header (the app bar strip repeats its top).
final _headerScene = find.descendant(
  of: find.byType(ListView),
  matching: find.byType(HorizonScene),
);

ScrollPosition _todayScroll(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

/// The top of the same scene, drawn in the app bar.
HorizonScene _strip(WidgetTester tester) => tester.widget<HorizonScene>(
  find.descendant(of: find.byType(AppBar), matching: find.byType(HorizonScene)),
);

HorizonScene _scene(WidgetTester tester) =>
    tester.widget<HorizonScene>(_headerScene);

String _focusedText(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('focus-current-card')),
        matching: find.byType(Text),
      ),
    )
    .map((t) => t.data ?? '')
    .join(' | ');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  // Measured on the header before the sky was mounted (412x914, 24 dp inset),
  // plus the 9 dp the date line now keeps free for the marks beneath it.
  // The test font wraps the date to two lines, where the old fixed 48 dp band
  // was already overrun; with real fonts at 1x the band is unchanged.
  // They were taken on a 24-hour clock, so these checks run on one: the
  // card's time is a different length on a 12-hour clock.
  const takenTopBefore = 580.0;
  const takenTopBeforeLarge = 812.0;
  // The week strip sits beside the title and adds nothing. At 1.3x the test
  // font's title (a full square per letter) leaves no room beside it, so the
  // strip takes a row of its own under the date: its height and a 6 dp gap.
  final stripRow = 6 + WeekStrip.heightFor(const TextScaler.linear(1.3));

  testWidgets('the sky adds no height: Taken stays where it was', (
    tester,
  ) async {
    await _mount(tester, twentyFourHour: true);
    expect(_headerScene, findsOneWidget);
    // The app bar strip draws the top of the same scene from the same model.
    final scenes = tester.widgetList<HorizonScene>(find.byType(HorizonScene));
    expect(scenes, hasLength(2));
    expect(scenes.first.model.size, scenes.last.model.size);
    expect(_takenTop(tester), closeTo(takenTopBefore, 2));
  });

  testWidgets('no added height at 1.3x text either', (tester) async {
    await _mount(tester, textScale: 1.3, twentyFourHour: true);
    expect(_takenTop(tester), closeTo(takenTopBeforeLarge + stripRow, 2));
  });

  for (final scale in [1.0, 1.3, 2.0]) {
    testWidgets(
      'no mark or sky body sits behind the title or date at ${scale}x',
      (tester) async {
        await _mount(tester, textScale: scale);
        final origin = tester.getTopLeft(_headerScene);
        final words = [
          tester.getRect(find.text('Today')),
          tester.getRect(find.textContaining(RegExp(r'^\w+day, '))),
        ];
        final model = _scene(tester).model;
        expect(model.marks, isNotEmpty);
        for (final mark in model.marks) {
          final r = mark.rect.shift(origin);
          for (final w in words) {
            expect(r.overlaps(w), isFalse, reason: 'mark $r over text $w');
          }
        }
        for (final body in [model.sun, model.moon]) {
          if (body == null) continue;
          for (final w in words) {
            expect(w.contains(body + origin), isFalse, reason: 'body at $body');
          }
        }
      },
    );
  }

  testWidgets('sky carries the day in words and marks', (tester) async {
    final handle = tester.ensureSemantics();
    await _mount(tester);
    final scene = _scene(tester);
    expect(scene.model.marks, hasLength(2));
    expect(
      scene.model.marks.map((m) => m.minute),
      containsAll([9 * 60, 20 * 60]),
    );
    expect(
      find.bySemanticsLabel('Day sky: 0 of 2 recorded, next 9:00 AM'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('tapping a mark focuses that dose card', (tester) async {
    await _mount(tester);
    expect(_focusedText(tester), isNot(contains('Fictional evening')));
    final scene = _scene(tester);
    final evening = scene.model.marks.singleWhere((m) => m.minute == 20 * 60);
    final origin = tester.getTopLeft(_headerScene);
    await tester.tapAt(origin + evening.rect.center);
    await tester.pumpAndSettle();
    expect(_focusedText(tester), contains('Fictional evening medication'));
    // And back to the morning mark.
    final morning = scene.model.marks.singleWhere((m) => m.minute == 9 * 60);
    await tester.tapAt(origin + morning.rect.center);
    await tester.pumpAndSettle();
    expect(_focusedText(tester), isNot(contains('Fictional evening')));
  });

  testWidgets('a durable take twinkles its mark and fills it', (tester) async {
    final f = await _mount(tester);
    final take = find.byKey(const ValueKey('focus-taken'));
    await tester.ensureVisible(take);
    await tester.pumpAndSettle();
    await tester.tap(take);
    for (var i = 0; i < 100 && _scene(tester).celebrateId == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(_scene(tester).celebrateId, f.occurrence.id);
    await tester.pumpAndSettle();
    final mark = _scene(
      tester,
    ).model.marks.singleWhere((m) => m.id == f.occurrence.id);
    expect(mark.state, HorizonMarkState.taken);
  });

  testWidgets('a durable take flies its check up to the mark, then twinkles', (
    tester,
  ) async {
    final f = await _mount(tester);
    final cards = find.byType(CapsuleMark).evaluate().length;
    final take = find.byKey(const ValueKey('focus-taken'));
    await tester.ensureVisible(take);
    await tester.pumpAndSettle();
    await tester.tap(take);
    var flying = false;
    for (var i = 0; i < 100 && !flying; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      flying = find.byType(CapsuleMark).evaluate().length > cards;
    }
    expect(flying, isTrue, reason: 'a ghost of the check leaves the card');
    expect(
      _scene(tester).celebrateId,
      isNull,
      reason: 'the mark waits for the check to arrive',
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byType(CapsuleMark).evaluate().length, cards);
    expect(_scene(tester).celebrateId, f.occurrence.id);
    await tester.pumpAndSettle();
  });

  testWidgets('quiet motion: no flight, the mark twinkles at once', (
    tester,
  ) async {
    final f = await _mount(tester, quiet: true);
    final cards = find.byType(CapsuleMark).evaluate().length;
    final take = find.byKey(const ValueKey('focus-taken'));
    await tester.ensureVisible(take);
    await tester.pumpAndSettle();
    await tester.tap(take);
    for (var i = 0; i < 100 && _scene(tester).celebrateId == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        find.byType(CapsuleMark).evaluate().length,
        lessThanOrEqualTo(cards),
      );
    }
    expect(_scene(tester).celebrateId, f.occurrence.id);
    await tester.pumpAndSettle();
  });

  testWidgets(
    'the last dose settles the day: still one haptic per take, then the sweep',
    (tester) async {
      final f = await _mount(tester);
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
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      Future<void> take() async {
        final button = find.byKey(const ValueKey('focus-taken'));
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.tap(button);
        for (var i = 0; i < 60; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
      }

      await take();
      expect(_scene(tester).sweepId, isNull);
      expect(
        haptics.where((h) => h == 'HapticFeedbackType.mediumImpact'),
        hasLength(1),
      );

      final evening = _scene(
        tester,
      ).model.marks.singleWhere((m) => m.minute == 20 * 60);
      await tester.tapAt(tester.getTopLeft(_headerScene) + evening.rect.center);
      await tester.pumpAndSettle();
      await take();
      expect(_scene(tester).model.settled, isTrue);
      expect(_scene(tester).sweepId, isNotNull);
      // Settling adds no haptic of its own: one receipt, one impact.
      expect(
        haptics.where((h) => h == 'HapticFeedbackType.mediumImpact'),
        hasLength(2),
      );
      expect(haptics, isNot(contains('HapticFeedbackType.heavyImpact')));
      expect(f.occurrence.id, isNotEmpty);
    },
  );

  testWidgets('the scene collapses with the header, never over content', (
    tester,
  ) async {
    await _mount(tester, textScale: 1.3);
    // Status bar (24) + app bar (48): the title and the clock live above.
    const appBarBottom = 72.0;
    final sceneTop = tester.getTopLeft(_headerScene).dy;
    final titleTop = tester.getTopLeft(find.text('Today')).dy;
    final contentTop = tester.getTopLeft(find.byType(FocusDeck)).dy;
    expect(_scene(tester).collapse!.value, 0);
    var sawPartialFade = false;
    for (var step = 0; step < 12; step++) {
      if (find.text('Today').evaluate().isEmpty) break;
      final scrolled = titleTop - tester.getTopLeft(find.text('Today')).dy;
      // Scene, header and content travel together, 1:1.
      expect(
        tester.getTopLeft(_headerScene).dy,
        closeTo(sceneTop - scrolled, .5),
      );
      final scene = _scene(tester);
      final fold = scene.collapse!.value;
      if (fold > 0 && fold < 1) sawPartialFade = true;
      final origin = tester.getTopLeft(_headerScene);
      final content = contentTop - scrolled;
      for (final mark in scene.model.marks) {
        final rect = mark.rect.shift(origin);
        // A mark never sits on the count row or the cards below it...
        expect(rect.bottom, lessThanOrEqualTo(content + .5));
        // ...and has faded out before it reaches the title or status bar.
        if (rect.top < appBarBottom) expect(fold, 1, reason: '$rect');
      }
      _todayScroll(tester).jumpTo(
        math.min(_todayScroll(tester).maxScrollExtent, (step + 1) * 16.0),
      );
      await tester.pumpAndSettle();
    }
    expect(sawPartialFade, isTrue);
    expect(_strip(tester).collapse!.value, 1);
    // The strip in the app bar carries the same fold.
    for (final s in tester.widgetList<HorizonScene>(
      find.byType(HorizonScene),
    )) {
      expect(s.collapse!.value, 1);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a folded scene takes no mark taps', (tester) async {
    await _mount(tester, textScale: 1.3);
    _todayScroll(tester).jumpTo(120);
    await tester.pumpAndSettle();
    expect(_scene(tester).collapse!.value, 1);
    // Taps on where the marks were no longer focus a dose.
    final before = _focusedText(tester);
    final origin = tester.getTopLeft(_headerScene);
    final mark = _scene(tester).model.marks.last;
    final hit = mark.rect.center + origin;
    if (hit.dy > 72) {
      await tester.tapAt(hit);
      await tester.pumpAndSettle();
      expect(_focusedText(tester), before);
    }
  });

  testWidgets('a new layout opens on the full header', (tester) async {
    await _mount(tester, textScale: 1.3);
    final titleTop = tester.getTopLeft(find.text('Today')).dy;
    _todayScroll(tester).jumpTo(120);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Today')).dy, lessThan(titleTop - 40));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FocusTodayScreen)),
    );
    await tester.runAsync(
      () => container
          .read(layoutFamilyProvider.notifier)
          .apply(LayoutFamily.timeline),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Today')).dy, closeTo(titleTop, .5));
    expect(_scene(tester).collapse!.value, 0);
  });

  testWidgets('pulling the sky down sinks the sun, then eases back', (
    tester,
  ) async {
    await _mount(tester);
    expect(_scene(tester).pull!.value, 0);
    final gesture = await tester.startGesture(const Offset(200, 400));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 14));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final held = _scene(tester).pull!.value;
    expect(held, greaterThan(.3));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 200));
    expect(_scene(tester).pull!.value, lessThan(held));
    await tester.pumpAndSettle();
    expect(_scene(tester).pull!.value, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the app bar strip follows the pull, so one sun shows', (
    tester,
  ) async {
    // The strip repeats the top of the header's scene; if only the header
    // sinks its sun, the strip's sun stays behind and two suns show.
    await _mount(tester);
    final gesture = await tester.startGesture(const Offset(200, 400));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 14));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final held = _scene(tester).pull!.value;
    expect(held, greaterThan(.3));
    expect(_strip(tester).pull, isNotNull);
    expect(_strip(tester).pull!.value, held);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_strip(tester).pull!.value, 0);
  });

  testWidgets('dragging back up lifts the sun again while the finger holds', (
    tester,
  ) async {
    await _mount(tester);
    final gesture = await tester.startGesture(const Offset(200, 400));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 14));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final sunk = _scene(tester).pull!.value;
    expect(sunk, greaterThan(.3));
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(0, -14));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_scene(tester).pull!.value, lessThan(sunk));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_scene(tester).pull!.value, 0);
  });

  testWidgets('quiet motion keeps the sun still while pulling', (tester) async {
    await _mount(tester, quiet: true);
    final gesture = await tester.startGesture(const Offset(200, 400));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 14));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_scene(tester).pull!.value, 0);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('halo breath follows touch, then stops by itself', (
    tester,
  ) async {
    await _mount(tester, ambient: true);
    await tester.tap(find.text('Today'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_scene(tester).breath!.value, greaterThan(0));
    // Three 4 s breaths, then still: pumpAndSettle must finish.
    await tester.pumpAndSettle();
    expect(_scene(tester).breath!.value, 0);
    expect(_scene(tester).breath!.isAnimating, isFalse);
  });

  for (final (name, theme) in [
    ('dark', AppTheme.dark()),
    ('dark high contrast', AppTheme.dark(highContrast: true)),
    ('light high contrast', AppTheme.light(highContrast: true)),
  ]) {
    testWidgets('header stays legible over the sky: $name', (tester) async {
      await _mount(tester, theme: theme, twentyFourHour: true);
      final scene = _scene(tester);
      final model = scene.model;
      final ink = theme.colorScheme.onSurface;
      final sky = model.highContrast
          ? theme.scaffoldBackgroundColor
          : model.skyColorAt(120);
      final a = ink.computeLuminance(), b = sky.computeLuminance();
      final ratio = (math.max(a, b) + .05) / (math.min(a, b) + .05);
      expect(ratio, greaterThanOrEqualTo(7));
      expect(_takenTop(tester), closeTo(takenTopBefore, 2));
    });
  }
}
