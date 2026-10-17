import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/pills/presentation/medication_identity.dart';
import 'package:simpastil/shared/widgets/person_avatar.dart';
import 'package:simpastil/core/medication/care_provider.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/core/storage/layout_family_preference.dart';
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

SetupRepository _setup(CareRecordingFixture f) => SetupRepository(
  database: f.db,
  access: f.workspace.access,
  context: f.workspace.context,
);

/// Adds a fictional second person and returns their id.
Future<String> _addPerson(CareRecordingFixture f, String name) async {
  final setup = _setup(f);
  final draft = await setup.resumeOrCreateDraft(purpose: SetupPurpose.person);
  final saved = await setup.savePerson(
    draft.id,
    draft.revision,
    name: name,
    avatar: name.substring(0, 1),
  );
  await setup.advanceOrSkip(draft.id, saved.draft.revision, SetupStep.complete);
  return saved.savedId;
}

Future<void> _addDose(
  CareRecordingFixture f, {
  required String personId,
  required String name,
  required int hour,
}) async {
  final setup = _setup(f);
  var draft = await setup.resumeOrCreateDraft(
    purpose: SetupPurpose.medication,
    fixedPersonId: personId,
  );
  draft = (await setup.saveMedication(
    draft.id,
    draft.revision,
    MedicationReview(name: name),
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
        times: [RoutineTime(slotId: 'slot$hour', hour: hour, minute: 0)],
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
  LayoutFamily? family = LayoutFamily.peopleLanes,
  Future<void> Function(CareRecordingFixture f)? seed,
  double textScale = 1,
  Size size = const Size(412, 914),
}) async {
  final f = await CareRecordingFixture.create();
  if (seed != null) await seed(f);
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
  useWindow(tester, size);
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
        of: find.byKey(ValueKey('lanes-capsule-$occurrenceId')),
        matching: find.byType(CapsuleMark),
      ),
    )
    .progress;

String _state(WidgetTester tester, String id) =>
    tester.widget<Text>(find.byKey(ValueKey('lanes-state-$id'))).data!;

Finder _summary(String personId) => find.descendant(
  of: find.byKey(ValueKey('lanes-summary-$personId')),
  matching: find.byType(Text),
);

Finder _lanes() => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('lanes-lane-'),
);

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

Future<String> _twoPeople(CareRecordingFixture f) async {
  final casey = await _addPerson(f, 'Fictional Casey');
  await _addDose(
    f,
    personId: casey,
    name: 'Fictional evening tablet',
    hour: 18,
  );
  await _addDose(f, personId: casey, name: 'Fictional noon tablet', hour: 12);
  // The deliberate multi-person view.
  await f.workspace.access.viewPerson(
    f.workspace.context,
    null,
    everyone: true,
  );
  return casey;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('People lanes records through the deck: promise, durable '
      'receipt, lane words, then undo', (tester) async {
    final h = await _mount(tester);
    final id = h.fixture.occurrence.id;
    final person = h.fixture.person.id;
    expect(find.byKey(const ValueKey('people-lanes-layout')), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-taken')), findsNothing);
    expect(_lanes(), findsOneWidget);
    expect(find.text('Fictional Alex'), findsOneWidget);
    expect(tester.widget<Text>(_summary(person)).data, '0 of 1 taken');
    expect(_state(tester, id), 'Not recorded');

    h.service
      ..gate = Completer<void>()
      ..reached = Completer<void>();
    await _tap(tester, find.byKey(ValueKey('lanes-take-$id')));
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

    // Receipt: the same moment as Focus deck, and the state in words.
    h.service.gate!.complete();
    await _pumpUntil(tester, () => h.haptics.length == 2);
    expect(h.haptics, [_selection, _medium]);
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(_progress(tester, id), 1);
    expect(_state(tester, id), startsWith('Taken · '));
    expect(tester.widget<Text>(_summary(person)).data, '1 of 1 taken');
    expect(find.text('0 still to record'), findsOneWidget);
    expect(find.byKey(ValueKey('lanes-take-$id')), findsNothing);

    // Undo uses the same guarded path, light impact, no replayed ring.
    h.service.gate = null;
    await _tap(tester, find.byKey(ValueKey('lanes-undo-$id')));
    await tester.pumpAndSettle();
    expect(h.haptics, [_selection, _medium, _light]);
    expect(_progress(tester, id), 0);
    expect(_state(tester, id), 'Not recorded');
    expect(tester.widget<Text>(_summary(person)).data, '0 of 1 taken');
    expect(find.byKey(ValueKey('lanes-take-$id')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the person ring pops once when their day finishes, never '
      'on first build or undo', (tester) async {
    final h = await _mount(tester);
    final id = h.fixture.occurrence.id;
    final person = h.fixture.person.id;
    double scale() => tester
        .widget<ScaleTransition>(
          find.descendant(
            of: find.byKey(ValueKey('lanes-ring-$person')),
            matching: find.byType(ScaleTransition),
          ),
        )
        .scale
        .value;
    expect(scale(), 1);
    expect(tester.widget<Text>(_summary(person)).data, '0 of 1 taken');

    await _tap(tester, find.byKey(ValueKey('lanes-take-$id')));
    await _pumpUntil(tester, () => h.haptics.length == 2);
    var peak = 1.0;
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      peak = peak < scale() ? scale() : peak;
    }
    expect(peak, greaterThan(1.03));
    await tester.pumpAndSettle();
    expect(scale(), 1);
    // The words stay: the ring only adds to them.
    expect(tester.widget<Text>(_summary(person)).data, '1 of 1 taken');

    await _tap(tester, find.byKey(ValueKey('lanes-undo-$id')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(scale(), 1);
    }
    await tester.pumpAndSettle();
  });

  testWidgets('a day finished by someone else (sync) fills the ring without '
      'a pop', (tester) async {
    final h = await _mount(tester);
    final id = h.fixture.occurrence.id;
    final person = h.fixture.person.id;
    final f = h.fixture;
    double scale() => tester
        .widget<ScaleTransition>(
          find.descendant(
            of: find.byKey(ValueKey('lanes-ring-$person')),
            matching: find.byType(ScaleTransition),
          ),
        )
        .scale
        .value;
    // Written straight to the database, as a pull from another device would:
    // no take was made on this screen, so no receipt moment exists.
    final writer = CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
    );
    await tester.runAsync(() async {
      await writer.commit(
        await writer.prepareTakenNow(
          personId: person,
          occurrenceId: id,
          expectedStateVersion: 0,
          amount: const MedicationAmount.unknown(),
        ),
      );
    });
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(scale(), 1);
    }
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(_summary(person)).data, '1 of 1 taken');
    expect(scale(), 1);
  });

  testWidgets('everyone: one lane per person, doses in time order', (
    tester,
  ) async {
    late String casey;
    final h = await _mount(
      tester,
      seed: (f) async => casey = await _twoPeople(f),
    );
    expect(_lanes(), findsNWidgets(2));
    expect(find.text('Fictional Casey'), findsOneWidget);
    expect(tester.widget<Text>(_summary(casey)).data, '0 of 2 taken');
    final caseyLane = find.byKey(ValueKey('lanes-lane-$casey'));
    final noon = find.descendant(
      of: caseyLane,
      matching: find.text('Fictional noon tablet'),
    );
    final evening = find.descendant(
      of: caseyLane,
      matching: find.text('Fictional evening tablet'),
    );
    expect(noon, findsOneWidget);
    expect(evening, findsOneWidget);
    expect(tester.getTopLeft(noon).dy, lessThan(tester.getTopLeft(evening).dy));
    // Alex's dose stays in Alex's lane.
    expect(
      find.descendant(
        of: find.byKey(ValueKey('lanes-lane-${h.fixture.person.id}')),
        matching: find.text('Fictional recorded medication'),
      ),
      findsOneWidget,
    );
    // Each lane leads with the person's own face and tint, and each dose
    // with its medication's mark, as on People and the Focus deck.
    for (final id in [casey, h.fixture.person.id]) {
      final face = find.byKey(ValueKey('lanes-face-$id'));
      expect(face, findsOneWidget);
      expect(tester.widget<PersonAvatar>(face).id, id);
    }
    expect(find.byType(MedicationMark), findsNWidgets(3));
    // Narrow phone: lanes stack.
    final a = tester.getTopLeft(_lanes().at(0));
    final b = tester.getTopLeft(_lanes().at(1));
    expect(a.dx, b.dx);
    expect(tester.takeException(), isNull);
  });

  testWidgets('medium screens put lanes side by side', (tester) async {
    await _mount(tester, seed: _twoPeople, size: const Size(800, 1000));
    expect(_lanes(), findsNWidgets(2));
    final a = tester.getTopLeft(_lanes().at(0));
    final b = tester.getTopLeft(_lanes().at(1));
    expect(a.dy, b.dy);
    expect(a.dx, isNot(b.dx));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the left pane of an expanded window stacks the lanes', (
    tester,
  ) async {
    // Each lane keeps a comfortable width: the pane is narrower than two.
    await _mount(tester, seed: _twoPeople, size: const Size(1100, 1000));
    expect(_lanes(), findsNWidgets(2));
    final a = tester.getTopLeft(_lanes().at(0));
    final b = tester.getTopLeft(_lanes().at(1));
    expect(a.dx, b.dx);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rows expand for details and collapse again', (tester) async {
    final h = await _mount(tester);
    final id = h.fixture.occurrence.id;
    final details = find.byKey(ValueKey('lanes-details-$id'));
    expect(details, findsNothing);
    await _tap(tester, find.byKey(ValueKey('lanes-item-$id')));
    await tester.pumpAndSettle();
    expect(details, findsOneWidget);
    expect(find.text('Amount per use: Not specified'), findsOneWidget);
    await _tap(tester, find.byKey(ValueKey('lanes-item-$id')));
    await tester.pumpAndSettle();
    expect(details, findsNothing);
  });

  testWidgets('large text stacks lanes and keeps the action reachable', (
    tester,
  ) async {
    final h = await _mount(
      tester,
      seed: _twoPeople,
      textScale: 2,
      size: const Size(1100, 1000),
    );
    final a = tester.getTopLeft(_lanes().at(0));
    final b = tester.getTopLeft(_lanes().at(1));
    expect(a.dx, b.dx);
    final id = h.fixture.occurrence.id;
    await _tap(tester, find.byKey(ValueKey('lanes-item-$id')));
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(ValueKey('lanes-take-$id')));
    await tester.pumpAndSettle();
    expect(_state(tester, id), startsWith('Taken · '));
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text on a phone does not overflow', (tester) async {
    await _mount(tester, seed: _twoPeople, textScale: 2);
    expect(_lanes(), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
