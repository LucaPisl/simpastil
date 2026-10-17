import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/core/storage/layout_family_preference.dart';
import 'package:simpastil/features/dashboard/dose_detail_screen.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/dashboard/selected_date_provider.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

import 'protected_workspace_fixture.dart';
import 'review_rendering.dart';
import 'window_view.dart';

/// A fictional household on the real calendar day, for the wide Today tests.
///
/// Alex takes a morning and an evening tablet and keeps [asNeeded]
/// as-needed medications; with [second] Casey also has an evening tablet. Dates are the
/// device's today (not a fixed fixture day) because the phone's low-stock
/// notices only ever show for today.
class TodayTabletFixture {
  TodayTabletFixture._({
    required this.workspace,
    required this.alex,
    required this.morning,
    required this.evening,
    required this.asNeeded,
    required this.casey,
    required this.caseyPill,
  });

  final ProtectedWorkspaceFixture workspace;
  AppDatabase get db => workspace.db;
  final Profile alex;
  final Pill morning;
  final Pill evening;
  final List<Pill> asNeeded;
  final Profile? casey;
  final Pill? caseyPill;

  /// The planned occurrence of [pill] today.
  Future<MedicationOccurrence> occurrenceOf(Pill pill) async =>
      (await db.medicationLedgerDao.getOccurrencesForUser(
        workspace.context.ownerUserId,
      )).firstWhere(
        (o) => o.pillId == pill.id && o.plannedLocalDate == todayKey,
      );

  static DateTime get today => DateTime.now();
  static String get todayKey => routineDateKey(today);

  /// [morningStock] and [lowAt] set the morning tablet's counted stock and
  /// its own low-stock level; null leaves the stock untracked.
  static Future<TodayTabletFixture> create({
    int? morningStock,
    int? lowAt,
    int asNeeded = 1,
    bool second = false,
  }) async {
    final workspace = await ProtectedWorkspaceFixture.create();
    final db = workspace.db;
    final setup = SetupRepository(
      database: db,
      access: workspace.access,
      context: workspace.context,
    );
    final routines = RoutineRepository(
      database: db,
      access: workspace.access,
      context: workspace.context,
      clock: () => DateTime.now().toUtc().subtract(const Duration(days: 2)),
    );
    final from = DateTime.now().toUtc().subtract(const Duration(days: 2));

    Future<void> routine(
      String pillId,
      List<int> hours, {
      bool prn = false,
    }) async {
      await routines.saveReviewed(
        await routines.preview(
          pillId: pillId,
          expectedRevision: 0,
          definition: RoutineDefinition(
            kind: prn ? RoutineKind.prn : RoutineKind.daily,
            timeZone: 'UTC',
            times: [
              for (final h in hours)
                RoutineTime(slotId: 'slot$h', hour: h, minute: 0),
            ],
          ),
          effectiveFrom: from,
          fromLocalDate: routineDateKey(from),
          throughLocalDate: todayKey,
        ),
      );
    }

    Future<Pill> medication(
      String personId,
      String name,
      List<int> hours, {
      bool prn = false,
      int? stock,
      int? threshold,
    }) async {
      var draft = await setup.resumeOrCreateDraft(
        purpose: SetupPurpose.medication,
        fixedPersonId: personId,
      );
      draft = (await setup.saveMedication(
        draft.id,
        draft.revision,
        MedicationReview(name: name),
      )).draft;
      final id = draft.medicationId!;
      await (db.update(db.pills)..where((p) => p.id.equals(id))).write(
        PillsCompanion(
          isPrn: Value(prn),
          currentStock: Value(stock),
          lowStockThreshold: Value(threshold),
        ),
      );
      await routine(id, hours, prn: prn);
      draft = await setup.advanceOrSkip(
        draft.id,
        draft.revision,
        SetupStep.ready,
      );
      await setup.advanceOrSkip(draft.id, draft.revision, SetupStep.complete);
      return (await db.pillsDao.getById(id))!;
    }

    // The first person and their first medication come from one draft.
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
      const MedicationReview(name: 'Fictional morning tablet'),
    )).draft;
    final morningId = draft.medicationId!;
    await (db.update(db.pills)..where((p) => p.id.equals(morningId))).write(
      PillsCompanion(
        currentStock: Value(morningStock),
        lowStockThreshold: Value(lowAt),
      ),
    );
    await routine(morningId, [9]);
    final alex = (await db.profilesDao.getById(draft.personId!))!;
    final morning = (await db.pillsDao.getById(morningId))!;
    final evening = await medication(alex.id, 'Fictional evening tablet', [20]);
    final prn = [
      for (var i = 0; i < asNeeded; i++)
        await medication(
          alex.id,
          'Fictional as-needed medication ${i + 1}',
          const [],
          prn: true,
        ),
    ];

    Profile? casey;
    Pill? caseyPill;
    if (second) {
      final person = await setup.resumeOrCreateDraft(
        purpose: SetupPurpose.person,
      );
      final saved = await setup.savePerson(
        person.id,
        person.revision,
        name: 'Fictional Casey',
        avatar: 'C',
      );
      await setup.advanceOrSkip(
        person.id,
        saved.draft.revision,
        SetupStep.complete,
      );
      casey = (await db.profilesDao.getById(saved.savedId))!;
      caseyPill = await medication(casey.id, 'Fictional noon tablet', [12]);
      // The deliberate multi-person view.
      await workspace.access.viewPerson(
        workspace.context,
        null,
        everyone: true,
      );
    }
    return TodayTabletFixture._(
      workspace: workspace,
      alex: alex,
      morning: morning,
      evening: evening,
      asNeeded: prn,
      casey: casey,
      caseyPill: caseyPill,
    );
  }
}

/// What a mounted Today leaves for the test to use.
class TodayMount {
  TodayMount(this.fixture, this.container, this.router);
  final TodayTabletFixture fixture;
  final ProviderContainer container;

  /// The router that carries Today; its location shows what was pushed.
  final GoRouter router;

  String get location =>
      router.routerDelegate.currentConfiguration.last.matchedLocation;
}

/// Mounts Today in [family] at [size] with the rest of the app's chrome as a
/// minimal router: Today at `/`, the real Dose details page at `/doses/:id`
/// and stand-ins for the other pages Today links to.
Future<TodayMount> mountToday(
  WidgetTester tester,
  TodayTabletFixture f, {
  LayoutFamily? family,
  Size size = const Size(1205, 753),
  double textScale = 1,
  bool dark = false,
}) async {
  final container = await f.workspace.createContainer();
  if (family != null) {
    await container.read(layoutFamilyProvider.notifier).apply(family);
  }
  container.read(selectedDateProvider.notifier).select(DateTime.now());
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => null,
  );
  useWindow(tester, size);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const FocusTodayScreen()),
      GoRoute(
        path: '/doses/:id',
        builder: (_, state) =>
            DoseDetailScreen(occurrenceId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/pills',
        builder: (_, _) => const Scaffold(body: Text('medications page')),
      ),
      GoRoute(
        path: '/settings',
        builder: (_, _) => const Scaffold(body: Text('settings page')),
      ),
    ],
  );
  addTearDown(() async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(f.db.close);
    await tester.pumpAndSettle();
  });
  final app = RepaintBoundary(
    key: reviewCaptureKey,
    child: MaterialApp.router(
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: reviewRenderingTheme(dark ? AppTheme.dark() : AppTheme.light()),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
    ),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: app),
  );
  await settleToday(tester);
  return TodayMount(f, container, router);
}

/// Lets database streams and animations run without waiting for a ticker that
/// never stops (the sky), in small steps. The 2.5 s default outlasts a slow
/// first query and the 200 ms a button takes to turn from dimmed to enabled,
/// so a capture shows the settled screen.
Future<void> settleToday(WidgetTester tester, [int ms = 2500]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
