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
  LayoutFamily? family = LayoutFamily.actionInbox,
  bool twoDoses = false,
  DateTime? now,
  double textScale = 1,
  bool dark = false,
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
        of: find.byKey(ValueKey('inbox-capsule-$id')),
        matching: find.byType(CapsuleMark),
      ),
    )
    .progress;

/// Which section heading the dose's row sits under, by position.
String _section(WidgetTester tester, String id) {
  final y = tester.getTopLeft(find.byKey(ValueKey('inbox-item-$id'))).dy;
  final rec = tester
      .getTopLeft(find.byKey(const ValueKey('inbox-heading-rec')))
      .dy;
  return y > rec ? 'rec' : 'needs';
}

String _state(WidgetTester tester, String id) =>
    tester.widget<Text>(find.byKey(ValueKey('inbox-state-$id'))).data!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('Inbox records through the deck and moves the dose between '
      'sections with focus following', (tester) async {
    final h = await _mount(tester);
    final id = h.fixture.occurrence.id;
    expect(find.byKey(const ValueKey('inbox-layout')), findsOneWidget);
    // The medication's own mark, as on the Focus deck card.
    expect(find.byKey(ValueKey('entry-mark-$id')), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-taken')), findsNothing);
    expect(find.text('Needs you · 1'), findsOneWidget);
    // The fixture's day is past, so the dose is due, not coming up later.
    expect(find.byKey(ValueKey('inbox-later-$id')), findsNothing);
    expect(find.text('Recorded today · 0'), findsOneWidget);
    expect(_state(tester, id), 'Not recorded');
    expect(_section(tester, id), 'needs');

    h.service
      ..gate = Completer<void>()
      ..reached = Completer<void>();
    await _tap(tester, find.byKey(ValueKey('inbox-take-$id')));
    await tester.pump();
    await _pumpUntil(tester, () => h.service.reached!.isCompleted);
    // Promise only: nothing has moved, no check, no medium haptic.
    expect(h.haptics, [_selection]);
    // A quick save keeps the pressed look with no new words; only a save
    // that takes longer than 400 ms says Saving….
    expect(find.text('Saving…'), findsNothing);
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.text('Saving…'), findsOneWidget);
    expect(find.text('Needs you · 1'), findsOneWidget);
    expect(_progress(tester, id), 0);

    h.service.gate!.complete();
    await _pumpUntil(tester, () => h.haptics.length == 2);
    expect(h.haptics, [_selection, _medium]);
    await tester.pumpAndSettle();
    expect(find.text('Needs you · 0'), findsOneWidget);
    expect(find.text('Recorded today · 1'), findsOneWidget);
    expect(find.text('Nothing needs you right now.'), findsOneWidget);
    expect(find.byKey(ValueKey('inbox-take-$id')), findsNothing);
    expect(_state(tester, id), startsWith('Taken · '));
    expect(_progress(tester, id), 1);
    expect(find.textContaining('moved to Recorded today'), findsOneWidget);
    // Focus followed the dose to its Undo action.
    final undo = find.byKey(ValueKey('inbox-undo-$id'));
    expect(undo, findsOneWidget);
    expect(_section(tester, id), 'rec');
    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(
      find.descendant(of: undo, matching: find.byWidget(focused.widget)),
      findsWidgets,
      reason: 'focus follows the moved dose to its Undo action',
    );

    h.service.gate = null;
    await _tap(tester, undo);
    await tester.pumpAndSettle();
    expect(h.haptics, [_selection, _medium, _light]);
    expect(find.text('Needs you · 1'), findsOneWidget);
    expect(find.text('Recorded today · 0'), findsOneWidget);
    expect(_state(tester, id), 'Not recorded');
    expect(find.textContaining('moved back to Needs you'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a moving row travels between sections, never grey', (
    tester,
  ) async {
    final h = await _mount(tester, twoDoses: true);
    final id = h.fixture.occurrence.id;
    final item = find.byKey(ValueKey('inbox-item-$id'));
    // Where the row is painted (the travel paints it away from its slot).
    // While the card fades through to its quiet line both hold the capsule;
    // the incoming one is last.
    final capsule = find.byKey(ValueKey('inbox-capsule-$id')).last;
    await _tap(tester, find.byKey(ValueKey('inbox-take-$id')));
    final from = tester.getTopLeft(capsule).dy;
    await _pumpUntil(tester, () => h.haptics.length == 2);
    final ys = <double>[];
    for (var frame = 0; frame < 40; frame++) {
      expect(item, findsOneWidget, reason: 'one row, never a copy');
      // No frame shows the taken dose as a grey, disabled "Taken now".
      final greyTake = tester
          .widgetList<FilledButton>(
            find.descendant(
              of: item,
              matching: find.byWidgetPredicate((w) => w is FilledButton),
            ),
          )
          .where((b) => b.onPressed == null);
      for (final button in greyTake) {
        expect(
          find.descendant(
            of: find.byWidget(button),
            matching: find.text('Taken now'),
          ),
          findsNothing,
          reason: 'frame $frame',
        );
      }
      ys.add(tester.getTopLeft(capsule).dy);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    final to = tester.getTopLeft(capsule).dy;
    expect(_section(tester, id), 'rec');
    expect(to, greaterThan(from + 40), reason: 'it lands lower, in Recorded');
    final between = ys.where((y) => y > from + 4 && y < to - 4).length;
    expect(
      between,
      greaterThanOrEqualTo(6),
      reason: 'visible travel, not a jump: $ys',
    );
    // Monotonic glide downwards.
    for (var i = 1; i < ys.length; i++) {
      expect(ys[i], greaterThanOrEqualTo(ys[i - 1] - .5));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text and dark mode keep both sections usable', (
    tester,
  ) async {
    final h = await _mount(tester, twoDoses: true, textScale: 2, dark: true);
    final id = h.fixture.occurrence.id;
    expect(find.text('Needs you · 2'), findsOneWidget);
    await _tap(tester, find.byKey(ValueKey('inbox-take-$id')));
    await tester.pumpAndSettle();
    expect(find.text('Needs you · 1'), findsOneWidget);
    expect(find.text('Recorded today · 1'), findsOneWidget);
    expect(_state(tester, id), startsWith('Taken · '));
    expect(tester.takeException(), isNull);
  });
}
