import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/features/dashboard/as_needed/as_needed_dose_editor.dart';
import 'package:simpastil/features/pills/presentation/medication_detail_screen.dart';
import 'package:simpastil/features/pills/presentation/pills_screen.dart';
import 'package:simpastil/features/schedules/presentation/routine_detail_screen.dart';
import 'package:simpastil/features/schedules/presentation/schedules_screen.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/care_recording_fixture.dart';
import '../../../helpers/protected_workspace_fixture.dart';

/// An as-needed medicine never shows a routine or schedule to the person.
const _forbidden = [
  'Add a routine',
  'No routine yet',
  'Routine details',
  'Routine',
  'No schedules yet',
  'Add schedule',
  'No active schedules',
];

void _expectNoRoutine() {
  for (final text in _forbidden) {
    expect(find.text(text), findsNothing, reason: text);
  }
  expect(find.byKey(const ValueKey('open-routine-details')), findsNothing);
}

Future<void> _pump(WidgetTester tester, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _show(
  WidgetTester tester,
  ProviderContainer container,
  Widget home,
) async {
  // A phone-sized window, so the pages lay out as they do on a phone.
  tester.view
    ..physicalSize = const Size(412, 1000)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light(),
        home: home,
      ),
    ),
  );
  await _pump(tester);
}

Future<({CareRecordingFixture fixture, ProviderContainer container})> _localPrn(
  WidgetTester tester,
) async {
  final fixture = await CareRecordingFixture.create();
  final repo = RoutineRepository(
    database: fixture.db,
    access: fixture.workspace.access,
    context: fixture.workspace.context,
    clock: () => DateTime.utc(2026, 9, 30, 8),
  );
  await repo.saveReviewed(
    await repo.preview(
      pillId: fixture.pill.id,
      routineId: (await repo.loadForPill(fixture.pill.id)).last.routineId,
      expectedRevision: 1,
      definition: RoutineDefinition(
        kind: RoutineKind.prn,
        timeZone: 'UTC',
        times: const [],
      ),
      effectiveFrom: DateTime.utc(2026, 9, 30, 8),
      fromLocalDate: '2026-09-30',
      throughLocalDate: '2026-09-30',
    ),
  );
  final container = await fixture.workspace.createContainer();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pumpAndSettle();
    await tester.runAsync(fixture.db.close);
  });
  return (fixture: fixture, container: container);
}

Future<
  ({
    ProtectedWorkspaceFixture workspace,
    Pill pill,
    ProviderContainer container,
  })
>
_connectedPrn(WidgetTester tester) async {
  final workspace = await ProtectedWorkspaceFixture.create(
    ownerId: '10000000-0000-4000-8000-000000000001',
  );
  final db = workspace.db;
  final setup = SetupRepository(
    database: db,
    access: workspace.access,
    context: workspace.context,
  );
  var draft = await setup.resumeOrCreateDraft();
  draft = (await setup.savePerson(
    draft.id,
    draft.revision,
    name: 'Fictional Alex',
    avatar: 'A',
  )).draft;
  draft = (await setup.saveMedication(
    draft.id,
    draft.revision,
    const MedicationReview(name: 'Fictional as-needed medication'),
  )).draft;
  await (db.update(db.pills)..where((p) => p.id.equals(draft.medicationId!)))
      .write(const PillsCompanion(isPrn: Value(true)));
  final pill = (await db.pillsDao.getById(draft.medicationId!))!;
  final now = DateTime.utc(2026, 9, 30);
  await db.schedulesDao.upsert(
    SchedulesCompanion.insert(
      id: '10000000-0000-4000-8000-000000000002',
      pillId: pill.id,
      hour: 0,
      minute: 0,
      frequency: 'prn',
      timeZone: const Value('Europe/Bucharest'),
      timeZoneStatus: const Value('known'),
      createdAt: now,
      updatedAt: now,
    ),
  );
  final container = await workspace.createContainer();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pumpAndSettle();
    await tester.runAsync(db.close);
  });
  return (workspace: workspace, pill: pill, container: container);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('Medications: a local as-needed medicine says so and offers no '
      'routine', (tester) async {
    final f = await _localPrn(tester);
    await _show(tester, f.container, const PillsScreen());
    expect(find.text(f.fixture.pill.name), findsOneWidget);
    expect(find.text('Only when needed'), findsOneWidget);
    _expectNoRoutine();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Medication details: local as-needed shows the summary and a '
      'Record button instead of a routine', (tester) async {
    final f = await _localPrn(tester);
    await _show(
      tester,
      f.container,
      MedicationDetailScreen(pillId: f.fixture.pill.id),
    );
    expect(find.byKey(const ValueKey('as-needed-panel')), findsOneWidget);
    expect(find.text('As needed'), findsOneWidget);
    expect(find.text('Last 7 days'), findsOneWidget);
    expect(find.text('Last dose'), findsOneWidget);
    expect(find.text('No doses in the last 7 days'), findsOneWidget);
    _expectNoRoutine();
    final record = find.byKey(const ValueKey('as-needed-record-dose'));
    await tester.ensureVisible(record);
    await tester.pump();
    await tester.tap(record);
    await _pump(tester, 800);
    expect(find.byType(AsNeededDoseEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Routine details: unreachable content for a local as-needed '
      'medicine shows the summary', (tester) async {
    final f = await _localPrn(tester);
    await _show(
      tester,
      f.container,
      RoutineDetailScreen(pillId: f.fixture.pill.id),
    );
    expect(find.byKey(const ValueKey('as-needed-panel')), findsOneWidget);
    _expectNoRoutine();
    expect(find.byKey(const ValueKey('routine-editor')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Schedules list: an as-needed row reads as such', (tester) async {
    final f = await _localPrn(tester);
    await _show(tester, f.container, const SchedulesScreen());
    expect(find.textContaining('Only when needed'), findsOneWidget);
    expect(find.textContaining('As needed'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connected: details and routine details show no schedules for '
      'an as-needed medicine', (tester) async {
    final f = await _connectedPrn(tester);
    await _show(tester, f.container, MedicationDetailScreen(pillId: f.pill.id));
    expect(find.byKey(const ValueKey('as-needed-panel')), findsOneWidget);
    _expectNoRoutine();
    await tester.pumpWidget(const SizedBox.shrink());
    await _show(tester, f.container, RoutineDetailScreen(pillId: f.pill.id));
    expect(find.byKey(const ValueKey('as-needed-panel')), findsOneWidget);
    _expectNoRoutine();
    expect(tester.takeException(), isNull);
  });

  testWidgets('connected: the Medications list says only when needed', (
    tester,
  ) async {
    final f = await _connectedPrn(tester);
    await _show(tester, f.container, const PillsScreen());
    expect(find.text('Only when needed'), findsOneWidget);
    _expectNoRoutine();
  });
}
