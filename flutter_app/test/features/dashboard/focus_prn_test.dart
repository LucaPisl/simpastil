import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/core/notifications/notification_plugin.dart';
import 'package:simpastil/features/dashboard/dose_detail_screen.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/settings/migration_issue_provider.dart';
import 'package:simpastil/features/settings/presentation/settings_overview.dart';
import 'package:simpastil/features/settings/presentation/settings_screen.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';
import '../../helpers/fake_notifications_plugin.dart';
import '../../helpers/protected_workspace_fixture.dart';
import '../../helpers/review_rendering.dart';
import '../../helpers/window_view.dart';

Finder _card(String pillId) => find.byKey(ValueKey('as-needed-card-$pillId'));
Finder _undo(String pillId) => find.byKey(ValueKey('as-needed-undo-$pillId'));

/// Lets queued database work and animations run, in small steps.
Future<void> _pump(WidgetTester tester, [int ms = 1000]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pumpApp(
  WidgetTester tester,
  ProviderContainer container, {
  bool quiet = false,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: reviewRenderingTheme(AppTheme.light()),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: quiet),
          child: child!,
        ),
        home: const FocusTodayScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await _pump(tester, 300);
}

/// Holds [finder] for [ms] and lets go.
Future<void> _hold(WidgetTester tester, Finder finder, {int ms = 900}) async {
  final gesture = await tester.startGesture(tester.getCenter(finder));
  await tester.pump(); // the ticker's first frame has zero elapsed time
  await tester.pump(Duration(milliseconds: ms));
  await gesture.up();
  await _pump(tester, 800);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadReviewFonts();
  });

  Future<({CareRecordingFixture fixture, ProviderContainer container})>
  localFixture(WidgetTester tester) async {
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
    return (fixture: fixture, container: container);
  }

  testWidgets('a short press opens the details and records nothing', (
    tester,
  ) async {
    useWindow(tester, const Size(412, 914));
    final f = await _connectedPrnFixture();
    final container = await f.workspace.createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pumpAndSettle();
      await tester.runAsync(f.db.close);
    });
    await _pumpApp(tester, container);
    await _reveal(tester, _card(f.pill.id));
    await tester.tap(_card(f.pill.id));
    await _pump(tester, 600);
    expect(find.byKey(const ValueKey('as-needed-record-now')), findsOneWidget);
    expect(find.byKey(const ValueKey('as-needed-open-editor')), findsOneWidget);
    expect(
      await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('releasing early drains the ring, says so, and records nothing', (
    tester,
  ) async {
    useWindow(tester, const Size(412, 914));
    final f = await _connectedPrnFixture();
    final container = await f.workspace.createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pumpAndSettle();
      await tester.runAsync(f.db.close);
    });
    await _pumpApp(tester, container);
    await _reveal(tester, _card(f.pill.id));
    final gesture = await tester.startGesture(
      tester.getCenter(_card(f.pill.id)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Keep holding'), findsOneWidget);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Hold to record'), findsOneWidget);
    expect(find.byKey(const ValueKey('as-needed-record-now')), findsNothing);
    await _pump(tester, 2000);
    expect(find.text('Hold to record'), findsNothing);
    expect(
      await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
      isEmpty,
    );
  });

  testWidgets('connected: a full hold records a dose with its time, and Undo '
      'reverses it', (tester) async {
    useWindow(tester, const Size(412, 914));
    final f = await _connectedPrnFixture();
    expect(await f.db.select(f.db.medicationOccurrences).get(), isEmpty);
    final container = await f.workspace.createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pumpAndSettle();
      await tester.runAsync(f.db.close);
    });
    await _pumpApp(tester, container);
    await _reveal(tester, _card(f.pill.id));
    await _hold(tester, _card(f.pill.id));
    final events = await _read(
      tester,
      f.db.select(f.db.occurrenceEvents).get(),
    );
    expect(events, hasLength(1));
    final occurrence = (await _read(
      tester,
      f.db.select(f.db.medicationOccurrences).get(),
    )).single;
    expect(events.single.occurrenceId, occurrence.id);
    expect(occurrence.source, 'prn');
    expect(occurrence.plannedAt, isNull);
    expect(occurrence.expected, isFalse);
    expect(events.single.actualTimeKnown, isTrue);
    expect(events.single.actualAt, isNotNull);
    expect(
      await _read(
        tester,
        f.db.pendingOperationsDao.getByMutationId(
          f.workspace.context.ownerUserId,
          events.single.commandId,
        ),
      ),
      isNotNull,
    );
    // The taken dose is not a card in the deck, and Undo is on the card.
    expect(_undo(f.pill.id), findsOneWidget);
    await tester.tap(_undo(f.pill.id));
    await _pump(tester, 800);
    final after = await _read(tester, f.db.select(f.db.occurrenceEvents).get());
    expect(after, hasLength(2));
    expect(after.last.action, 'undo');
    expect(_undo(f.pill.id).hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final unavailable in [
    'ambiguous',
    'quarantined',
    'unknown-zone',
    'invalid-zone',
  ]) {
    testWidgets('connected PRN $unavailable needs review and a hold does '
        'nothing', (tester) async {
      useWindow(tester, const Size(412, 914));
      final f = await _connectedPrnFixture();
      if (unavailable == 'ambiguous') {
        await f.db.schedulesDao.upsert(
          f.sentinel
              .copyWith(id: '10000000-0000-4000-8000-000000000008')
              .toCompanion(false),
        );
      } else if (unavailable == 'quarantined') {
        await (f.db.update(
          f.db.schedules,
        )..where((s) => s.id.equals(f.sentinel.id))).write(
          const SchedulesCompanion(
            frequency: Value('invalid-legacy'),
            isActive: Value(false),
          ),
        );
      } else if (unavailable == 'invalid-zone') {
        await (f.db.update(
          f.db.schedules,
        )..where((s) => s.id.equals(f.sentinel.id))).write(
          const SchedulesCompanion(
            timeZone: Value('Not/AZone'),
            timeZoneStatus: Value('known'),
          ),
        );
      } else {
        await (f.db.update(
          f.db.schedules,
        )..where((s) => s.id.equals(f.sentinel.id))).write(
          const SchedulesCompanion(
            timeZone: Value(null),
            timeZoneStatus: Value('legacy_unknown'),
          ),
        );
      }
      notificationsPlugin = FakeNotificationsPlugin();
      PackageInfo.setMockInitialValues(
        appName: 'Simpastil',
        packageName: 'fictional',
        version: '1',
        buildNumber: '1',
        buildSignature: '',
      );
      final container = await f.workspace.createContainer(
        extraOverrides: [
          migrationIssuesProvider.overrideWith((_) => Stream.value(const [])),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await tester.pumpAndSettle();
        await tester.runAsync(f.db.close);
      });
      await _pumpApp(tester, container);
      await _reveal(tester, _card(f.pill.id));
      expect(find.text('Needs review'), findsOneWidget);
      final explanation = switch (unavailable) {
        'ambiguous' =>
          'More than one as-needed routine is active. Review them before recording.',
        'quarantined' =>
          'This as-needed routine is paused or needs review. Check its saved details before recording.',
        _ => 'Confirm this routine’s time zone before recording.',
      };
      expect(find.text(explanation), findsOneWidget);
      expect(find.text('Care is temporarily unavailable'), findsNothing);
      // Holding does nothing and opens nothing.
      await _hold(tester, _card(f.pill.id), ms: 1200);
      expect(find.byType(SettingsScreen), findsNothing);
      expect(
        await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
        isEmpty,
      );
      // A tap opens the existing review.
      await tester.tap(_card(f.pill.id));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SettingsScreen>(find.byType(SettingsScreen)).section,
        SettingsSection.data,
      );
      expect(
        await _read(tester, f.db.select(f.db.medicationOccurrences).get()),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'connected PRN missing its hidden sentinel still records a dose',
    (tester) async {
      useWindow(tester, const Size(412, 914));
      final f = await _connectedPrnFixture();
      await f.db.delete(f.db.schedules).go();
      final container = await f.workspace.createContainer(
        extraOverrides: [
          migrationIssuesProvider.overrideWith((_) => Stream.value(const [])),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await tester.pumpAndSettle();
        await tester.runAsync(f.db.close);
      });
      await _pumpApp(tester, container);
      expect(find.text('Needs review'), findsNothing);
      await _reveal(tester, _card(f.pill.id));
      await _hold(tester, _card(f.pill.id));
      final rows = await _read(tester, f.db.select(f.db.schedules).get());
      expect(rows, hasLength(1));
      expect(rows.single.frequency, 'prn');
      expect(rows.single.pillId, f.pill.id);
      expect(rows.single.isActive, isTrue);
      expect(rows.single.timeZoneStatus, 'known');
      final occurrence = (await _read(
        tester,
        f.db.select(f.db.medicationOccurrences).get(),
      )).single;
      expect(occurrence.source, 'prn');
      expect(occurrence.scheduleId, rows.single.id);
      expect(
        await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('local: hold records, Undo reverses, and a second hold records '
      'a new dose', (tester) async {
    useWindow(tester, const Size(412, 914));
    final (:fixture, :container) = await localFixture(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pumpAndSettle();
      await tester.runAsync(fixture.db.close);
    });
    await _pumpApp(tester, container);
    expect(find.text(fixture.pill.name), findsOneWidget);
    await _reveal(tester, _card(fixture.pill.id));
    await _hold(tester, _card(fixture.pill.id));
    var events = await _read(
      tester,
      fixture.db.select(fixture.db.occurrenceEvents).get(),
    );
    expect(events, hasLength(1));
    expect(events.single.actualTimeKnown, isTrue);
    // The recorded PRN dose never becomes a deck card.
    expect(find.text('Review this record'), findsNothing);
    await tester.tap(_undo(fixture.pill.id));
    await _pump(tester, 800);
    events = await _read(
      tester,
      fixture.db.select(fixture.db.occurrenceEvents).get(),
    );
    expect(events, hasLength(2));
    expect(events.last.action, 'undo');
    await _hold(tester, _card(fixture.pill.id));
    events = await _read(
      tester,
      fixture.db.select(fixture.db.occurrenceEvents).get(),
    );
    expect(events, hasLength(3));
    expect(
      events
          .where((e) => e.action == 'take')
          .map((e) => e.occurrenceId)
          .toSet(),
      hasLength(2),
    );
    expect(
      await _read(
        tester,
        fixture.db.select(fixture.db.pendingOperations).get(),
      ),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('quiet motion: the hold is still required and still records', (
    tester,
  ) async {
    useWindow(tester, const Size(412, 914));
    final (:fixture, :container) = await localFixture(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pumpAndSettle();
      await tester.runAsync(fixture.db.close);
    });
    await _pumpApp(tester, container, quiet: true);
    await _reveal(tester, _card(fixture.pill.id));
    // Half a hold records nothing.
    final gesture = await tester.startGesture(
      tester.getCenter(_card(fixture.pill.id)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await _pump(tester, 400);
    expect(
      await _read(tester, fixture.db.select(fixture.db.occurrenceEvents).get()),
      isEmpty,
    );
    await _hold(tester, _card(fixture.pill.id));
    expect(
      await _read(tester, fixture.db.select(fixture.db.occurrenceEvents).get()),
      hasLength(1),
    );
    // The success is shown at once, with Undo.
    expect(_undo(fixture.pill.id), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the details sheet records now and lists the recent dose', (
    tester,
  ) async {
    useWindow(tester, const Size(412, 914));
    final (:fixture, :container) = await localFixture(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pumpAndSettle();
      await tester.runAsync(fixture.db.close);
    });
    await _pumpApp(tester, container);
    await _reveal(tester, _card(fixture.pill.id));
    await tester.tap(_card(fixture.pill.id));
    await _pump(tester, 600);
    expect(find.text('Recent doses'), findsOneWidget);
    expect(find.text('No doses in the last 7 days'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('as-needed-record-now')));
    await _pump(tester, 1000);
    expect(
      await _read(tester, fixture.db.select(fixture.db.occurrenceEvents).get()),
      hasLength(1),
    );
    expect(_undo(fixture.pill.id), findsOneWidget);
    // Reopened, the sheet lists the dose, which opens its detail screen.
    await _pump(tester, 6500);
    await tester.tap(_card(fixture.pill.id));
    await _pump(tester, 600);
    expect(find.text('No doses in the last 7 days'), findsNothing);
    final row = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('as-needed-dose-'),
    );
    expect(row, findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(DoseDetailScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the dose editor saves an amount, a time and a note in one '
      'step', (tester) async {
    useWindow(tester, const Size(412, 914));
    final (:fixture, :container) = await localFixture(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pumpAndSettle();
      await tester.runAsync(fixture.db.close);
    });
    await _pumpApp(tester, container);
    await _reveal(tester, _card(fixture.pill.id));
    await tester.tap(_card(fixture.pill.id));
    await _pump(tester, 600);
    await tester.tap(find.byKey(const ValueKey('as-needed-open-editor')));
    await tester.pumpAndSettle();
    expect(find.text('Record a dose'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('as-needed-when-h1')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('as-needed-note')),
      'After lunch',
    );
    await tester.tap(find.byKey(const ValueKey('as-needed-save')));
    await _pump(tester, 1500);
    final events = await _read(
      tester,
      fixture.db.select(fixture.db.occurrenceEvents).get(),
    );
    expect(events, hasLength(1));
    expect(events.single.note, 'After lunch');
    expect(events.single.actualTimeKnown, isTrue);
    // Back on Today the card shows the dose with Undo.
    expect(find.text('Record a dose'), findsNothing);
    expect(_undo(fixture.pill.id), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<T> _read<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  T? value;
  Object? error;
  future.then(
    (v) {
      value = v;
      done = true;
    },
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  for (var i = 0; i < 200 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (!done) throw StateError('Query did not settle');
  if (error != null) throw error!;
  return value as T;
}

Future<
  ({
    ProtectedWorkspaceFixture workspace,
    AppDatabase db,
    Pill pill,
    Profile person,
    Schedule sentinel,
  })
>
_connectedPrnFixture() async {
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
  final person = (await db.profilesDao.getById(draft.personId!))!;
  const sentinelId = '10000000-0000-4000-8000-000000000002';
  final now = DateTime.utc(2026, 9, 30);
  await db.schedulesDao.upsert(
    SchedulesCompanion.insert(
      id: sentinelId,
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
  return (
    workspace: workspace,
    db: db,
    pill: pill,
    person: person,
    sentinel: (await db.schedulesDao.getById(sentinelId))!,
  );
}
