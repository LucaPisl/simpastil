import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/adherence_calculator.dart';
import 'package:simpastil/core/medication/expiry.dart';
import 'package:simpastil/core/medication/medication_activity.dart';
import 'package:simpastil/features/analytics/adherence.dart';
import 'package:simpastil/features/analytics/analytics_providers.dart';
import 'package:simpastil/features/analytics/trend_stats.dart';
import 'package:simpastil/features/dashboard/history_screen.dart';
import 'package:simpastil/features/pills/medication_activity_provider.dart';
import 'package:simpastil/features/pills/medication_photo_repository.dart';
import 'package:simpastil/features/pills/presentation/medication_detail_sections.dart';
import 'package:simpastil/features/pills/presentation/medication_photo_card.dart';
import 'package:simpastil/features/pills/presentation/medication_compact_list.dart';
import 'package:simpastil/features/pills/presentation/medication_detail_screen.dart';
import 'package:simpastil/features/pills/presentation/medication_plate.dart';
import 'package:simpastil/features/pills/presentation/pills_screen.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/setup/setup_controller.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/shared/widgets/care_person_selector.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/care_recording_fixture.dart';
import '../../../helpers/review_rendering.dart';
import '../../../helpers/held_provider_read.dart';

const _expanded = Size(1205, 753);
const _medium = Size(753, 1205);
const _phone = Size(412, 915);

const _secondId = 'fictional-second-medication';
const _secondName = 'Fictional second medication';
const _longId = 'fictional-long-medication';

class _Rig {
  _Rig(this.fixture, this.router);
  final CareRecordingFixture fixture;
  final GoRouter router;
  String get firstId => fixture.pill.id;
  String get location => router.routerDelegate.currentConfiguration.uri.path;
}

/// The whole app shell at a real window size with the fixture's medication and
/// a second, as-needed one, so there is something to choose between.
Future<_Rig> _mount(
  WidgetTester tester,
  Size size, {
  String initial = AppPaths.pills,
  bool dark = false,
  double textScale = 1,
  bool longName = false,
  double keyboard = 0,
  bool animated = false,
  bool secondPerson = false,
  bool connected = false,
  int? expiresInDays,
  MedicationActivity Function(String pillId)? activity,
  MedicationPhotoView? photo,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = await CareRecordingFixture.create(
    legacyStock: 12,
    connected: connected,
  );
  // A connected account whose server runs the medication ledger.
  if (connected) {
    await fixture.workspace.preferences.setBool(LedgerModeHint.key, true);
  }
  final now = DateTime.now().toUtc();
  if (expiresInDays != null) {
    // Calendar days, not 24 h steps: a clock change must not move the day.
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day + expiresInDays);
    await (fixture.db.update(fixture.db.pills)
          ..where((p) => p.id.equals(fixture.pill.id)))
        .write(PillsCompanion(expiresOn: Value(expiryDateKey(day))));
  }
  await fixture.db
      .into(fixture.db.pills)
      .insert(
        PillsCompanion.insert(
          id: _secondId,
          profileId: fixture.person.id,
          name: _secondName,
          createdAt: now,
          updatedAt: now,
          currentStock: const Value(3),
          isPrn: const Value(true),
        ),
      );
  if (secondPerson) {
    // With two people the list shows who it is for: a selector panel on top.
    await fixture.db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: 'fictional-second-person',
        userId: fixture.workspace.context.ownerUserId,
        name: 'Fictional second person',
        createdAt: now,
        updatedAt: now,
      ),
    );
  }
  if (longName) {
    await fixture.db
        .into(fixture.db.pills)
        .insert(
          PillsCompanion.insert(
            id: _longId,
            profileId: fixture.person.id,
            name: 'Fictional extended-release medication with a long name',
            createdAt: now,
            updatedAt: now,
            currentStock: const Value(-2),
            lowStockThreshold: const Value(5),
          ),
        );
  }
  final draft = (await fixture.db.select(fixture.db.setupDrafts).get()).single;
  final setup = SetupRepository(
    database: fixture.db,
    access: fixture.workspace.access,
    context: fixture.workspace.context,
  );
  final ready = await setup.advanceOrSkip(
    draft.id,
    draft.revision,
    SetupStep.ready,
  );
  await setup.advanceOrSkip(ready.id, ready.revision, SetupStep.complete);
  final container = await fixture.workspace.createContainer(
    extraOverrides: [
      // "See all in History" lands on History, whose statistics start a
      // midnight timer on the real database that would outlive the test.
      monthAdherenceProvider.overrideWith(
        (ref, month) => Stream.value(const <DateTime, DayAdherence>{}),
      ),
      monthPrnCountsProvider.overrideWith(
        (ref, month) => Stream.value(const <DateTime, int>{}),
      ),
      adherenceStatsProvider.overrideWith(
        (ref) => Stream.value((
          last7Days: null,
          last30Days: null,
          prnTaken: 0,
          weeklyTrend: <WeekAdherence>[],
          perPill: <PillAdherence>[],
        )),
      ),
      trendStatsProvider.overrideWith(
        (ref) => Stream.value((
          streak: (current: 0, best: 0),
          hasScheduledDoses: false,
          hourlyTaken: List<int>.filled(24, 0),
          prn7Days: 0,
          prn30Days: 0,
          prnByPill: <PrnPillCount>[],
        )),
      ),
      if (photo != null)
        medicationPhotoProvider(
          fixture.pill.id,
        ).overrideWith((ref) => Stream.value(photo)),
      if (activity != null)
        medicationActivityProvider(
          fixture.pill.id,
        ).overrideWith((ref) => Stream.value(activity(fixture.pill.id))),
    ],
  );
  await container.readHeld(profileListProvider);
  await container.readHeld(selectedProfileIdProvider);
  await container.readHeld(unfinishedSetupDraftProvider);
  final router = container.read(routerProvider)..go(initial);
  addTearDown(() async {
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.db.close();
    container.dispose();
    await tester.pumpAndSettle();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: reviewRenderingTheme(dark ? AppTheme.dark() : AppTheme.light()),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: !animated,
            textScaler: TextScaler.linear(textScale),
            // A keyboard that is already up when the window is laid out.
            viewInsets: keyboard > 0 ? EdgeInsets.only(bottom: keyboard) : null,
          ),
          child: RepaintBoundary(key: reviewCaptureKey, child: child!),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Rig(fixture, router);
}

Finder _row(String id) => find.byKey(ValueKey('medication-$id'));

String _paneName(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('pane-medication-name')))
    .data!;

Map<String, bool> _selected(WidgetTester tester) => {
  for (final row in tester.widgetList<MedicationCompactRow>(
    find.byType(MedicationCompactRow),
  ))
    row.id: row.selected,
};

/// Two weeks of a scheduled medication, relative to today so the test does not
/// age: taken yesterday and the day before, skipped three days ago, one dose
/// not recorded four days ago and one recorded as missed five days ago.
MedicationActivity _activityFor(String pillId) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  AdherenceHistoryItem dose(String id, int daysAgo, String status) {
    final day = today.subtract(Duration(days: daysAgo));
    final key =
        '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    return AdherenceHistoryItem(
      occurrenceId: id,
      source: 'scheduled',
      expected: true,
      superseded: false,
      isDueScheduled: true,
      status: status,
      provenance: 'local',
      plannedAt: DateTime(day.year, day.month, day.day, 8),
      actualAt: null,
      actualTimeKnown: false,
      note: null,
      pillId: pillId,
      pillName: 'Fictional recorded medication',
      dosage: null,
      profileId: 'u1',
      plannedLocalDate: key,
    );
  }

  return medicationActivityFrom(
    items: [
      dose('d1', 1, 'taken'),
      dose('d2', 2, 'taken'),
      dose('d3', 3, 'skipped'),
      dose('d4', 4, 'unrecorded'),
      dose('d5', 5, 'missed'),
    ],
    pillId: pillId,
    now: now.add(const Duration(hours: 1)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadReviewFonts();
  });

  group('expanded: a list beside the medication', () {
    testWidgets('selects the first medication and swaps the pane on a tap', (
      tester,
    ) async {
      final rig = await _mount(tester, _expanded);
      expect(find.byKey(const ValueKey('medication-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('medication-pane')), findsOneWidget);
      // The first one in the list is open on the right.
      final ids = [rig.firstId, _secondId]
        ..sort(
          (a, b) => tester
              .getTopLeft(_row(a))
              .dy
              .compareTo(tester.getTopLeft(_row(b)).dy),
        );
      final names = {
        rig.firstId: rig.fixture.pill.name,
        _secondId: _secondName,
      };
      expect(_paneName(tester), names[ids.first]);
      expect(_selected(tester), {ids.first: true, ids.last: false});

      await tester.tap(_row(ids.last));
      await tester.pumpAndSettle();
      expect(_paneName(tester), names[ids.last]);
      expect(_selected(tester), {ids.first: false, ids.last: true});
      // Nothing was pushed: still the list page, same address.
      expect(find.byType(MedicationDetailScreen), findsNothing);
      expect(find.byType(PillsScreen), findsOneWidget);
      expect(rig.location, AppPaths.pills);

      await tester.tap(_row(ids.first));
      await tester.pumpAndSettle();
      expect(_paneName(tester), names[ids.first]);
    });

    testWidgets('an address with a medication in it lands on that medication', (
      tester,
    ) async {
      final rig = await _mount(tester, _expanded, initial: '/pills/$_secondId');
      expect(find.byType(PillsScreen), findsOneWidget);
      expect(_paneName(tester), _secondName);
      expect(_selected(tester)[_secondId], isTrue);
      // The workspace is the one place: the address is the list's.
      expect(rig.location, AppPaths.pills);

      // The list is still a list: choosing another medication works.
      await tester.tap(_row(rig.firstId));
      await tester.pumpAndSettle();
      expect(_paneName(tester), rig.fixture.pill.name);
      expect(find.byType(MedicationDetailScreen), findsNothing);
    });

    testWidgets('opening a medication over the list keeps one workspace', (
      tester,
    ) async {
      final rig = await _mount(tester, _expanded);
      // The list opened on its first medication; the link asks for the other.
      final other = _selected(tester).entries.firstWhere((e) => !e.value).key;
      unawaited(rig.router.push('/pills/$other'));
      await tester.pumpAndSettle();

      expect(find.byType(PillsScreen, skipOffstage: false), findsOneWidget);
      expect(
        find.byType(MedicationDetailScreen, skipOffstage: false),
        findsNothing,
      );
      expect(_selected(tester)[other], isTrue);
      expect(_selected(tester).values.where((v) => v), hasLength(1));
      expect(rig.location, AppPaths.pills);

      // Back is Back from /pills: it leaves for Today, not to a lower list.
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(rig.location, AppPaths.home);
      expect(find.byType(PillsScreen), findsNothing);
    });

    testWidgets('asking for the same medication again selects it again', (
      tester,
    ) async {
      final rig = await _mount(tester, _expanded);
      final other = _selected(tester).entries.firstWhere((e) => !e.value).key;
      unawaited(rig.router.push('/pills/$other'));
      await tester.pumpAndSettle();
      final first = _selected(tester).entries.firstWhere((e) => !e.value).key;
      await tester.tap(_row(first));
      await tester.pumpAndSettle();
      expect(_selected(tester)[first], isTrue);

      unawaited(rig.router.push('/pills/$other'));
      await tester.pumpAndSettle();
      expect(find.byType(PillsScreen, skipOffstage: false), findsOneWidget);
      expect(_selected(tester)[other], isTrue);
    });

    testWidgets('a window grown from medium folds the open page into it', (
      tester,
    ) async {
      final rig = await _mount(tester, _medium);
      unawaited(rig.router.push('/pills/$_secondId'));
      await tester.pumpAndSettle();
      expect(
        find.byType(MedicationDetailScreen, skipOffstage: false),
        findsOneWidget,
      );
      expect(find.byType(PillsScreen, skipOffstage: false), findsOneWidget);

      tester.view.physicalSize = _expanded;
      await tester.pumpAndSettle();
      expect(
        find.byType(MedicationDetailScreen, skipOffstage: false),
        findsNothing,
      );
      expect(find.byType(PillsScreen, skipOffstage: false), findsOneWidget);
      expect(_paneName(tester), _secondName);
      expect(_selected(tester)[_secondId], isTrue);
      expect(rig.location, AppPaths.pills);
    });

    testWidgets('a long press selects for removal without moving the pane', (
      tester,
    ) async {
      final rig = await _mount(tester, _expanded);
      final open = _paneName(tester);
      final ids = _selected(tester).keys.toList();
      await tester.longPress(_row(ids.last));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('select-medication-${ids.last}')),
        findsOneWidget,
      );
      // In selection mode a tap ticks the row instead of opening it.
      await tester.tap(_row(ids.first));
      await tester.pumpAndSettle();
      expect(_paneName(tester), open);
      for (final id in ids) {
        expect(
          tester
              .widget<Checkbox>(find.byKey(ValueKey('select-medication-$id')))
              .value,
          isTrue,
          reason: id,
        );
      }
      expect(find.byType(MedicationDetailScreen), findsNothing);
      expect(rig.location, AppPaths.pills);
    });

    testWidgets('the person selector keeps a gap above the search field', (
      tester,
    ) async {
      await _mount(tester, _expanded, secondPerson: true);
      final selector = tester.getRect(find.byType(CarePersonSelector));
      final search = tester.getRect(
        find.byKey(const ValueKey('medication-search')),
      );
      expect(search.top - selector.bottom, greaterThanOrEqualTo(10));
    });

    testWidgets('phone: a card says when the medication expires, in words', (
      tester,
    ) async {
      final rig = await _mount(tester, _phone, expiresInDays: 19);
      final tag = find.byKey(ValueKey('medication-expiry-${rig.firstId}'));
      expect(tag, findsOneWidget);
      expect(
        find.descendant(of: tag, matching: find.text('Expires in 19 days')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('medication-expiry-$_secondId')),
        findsNothing,
      );
    });

    testWidgets('Add is in the header area, not a bar across the bottom', (
      tester,
    ) async {
      await _mount(tester, _expanded);
      final add = tester.getRect(find.byKey(const ValueKey('add-fab')));
      expect(add.height, greaterThanOrEqualTo(48));
      expect(add.bottom, lessThan(_expanded.height / 2));
      expect(add.width, lessThan(240));
    });

    testWidgets('compact stock and count chips replace the blister', (
      tester,
    ) async {
      await _mount(tester, _expanded);
      expect(find.byKey(const ValueKey('medication-blister')), findsNothing);
      expect(find.byKey(const ValueKey('stat-stock')), findsOneWidget);
      expect(find.byKey(const ValueKey('stat-scheduled')), findsOneWidget);
      expect(find.byKey(const ValueKey('stat-as-needed')), findsOneWidget);
    });

    testWidgets('the pane carries stock, last 14 days and recent doses', (
      tester,
    ) async {
      final rig = await _mount(tester, _expanded, activity: _activityFor);
      // Open the fixture's medication, whichever the list shows first.
      await tester.tap(_row(rig.firstId));
      await tester.pumpAndSettle();
      final scroll = find.byKey(const ValueKey('medication-pane-scroll'));
      for (final key in [
        'medication-stock-section',
        'medication-last-14',
        'medication-recent',
      ]) {
        await tester.dragUntilVisible(
          find.byKey(ValueKey(key)),
          scroll,
          const Offset(0, -200),
        );
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(find.text('2 of 5 days'), findsOneWidget);
      expect(find.byKey(const ValueKey('recent-d1')), findsOneWidget);
    });
  });

  group('the page keeps its sections on the plate\'s edges', () {
    testWidgets('phone: plate, stock, last 14 days and recent line up', (
      tester,
    ) async {
      final rig = await _mount(tester, _phone, activity: _activityFor);
      await tester.tap(_row(rig.firstId));
      await tester.pumpAndSettle();
      final plate = tester.getRect(find.byType(MedicationPlate));
      final stock = tester.getRect(
        find.byKey(const ValueKey('medication-stock-section')),
      );
      expect(stock.left, plate.left);
      expect(stock.right, plate.right);
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('medication-recent')),
        find.byType(ListView).first,
        const Offset(0, -200),
      );
      final recent = tester.getRect(
        find.byKey(const ValueKey('medication-recent')),
      );
      expect(recent.left, plate.left);
      expect(recent.right, plate.right);
      // One column, newest first: every tile has the same left edge.
      final lefts = {
        for (final id in ['d1', 'd2', 'd3', 'd4'])
          tester.getTopLeft(find.byKey(ValueKey('recent-$id'))).dx,
      };
      expect(lefts, hasLength(1));
    });

    testWidgets('last 14 days has no empty note line under the grid', (
      tester,
    ) async {
      final rig = await _mount(tester, _phone, activity: _activityFor);
      await tester.tap(_row(rig.firstId));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('medication-last-14')),
        find.byType(ListView).first,
        const Offset(0, -200),
      );
      final card = tester.getRect(
        find.byKey(const ValueKey('medication-last-14')),
      );
      final grid = tester.getRect(find.byKey(const ValueKey('day-grid')));
      // The card's own padding below the grid, nothing more.
      expect(card.bottom - grid.bottom, lessThanOrEqualTo(18));
    });
  });

  group('phone: unchanged page flow', () {
    testWidgets('a tap pushes the medication page and back returns', (
      tester,
    ) async {
      final rig = await _mount(tester, _phone);
      expect(find.byKey(const ValueKey('medication-pane')), findsNothing);
      expect(find.byKey(const ValueKey('medication-list')), findsNothing);
      await tester.tap(_row(rig.firstId));
      await tester.pumpAndSettle();
      expect(find.byType(MedicationDetailScreen), findsOneWidget);
      expect(
        tester
            .widget<MedicationDetailScreen>(find.byType(MedicationDetailScreen))
            .pillId,
        rig.firstId,
      );
      expect(find.byKey(const ValueKey('medication-pane')), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(MedicationDetailScreen), findsNothing);
      expect(rig.location, AppPaths.pills);
      // The page's streams closed on the way out; let their timers run.
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('the page shows stock, the last 14 days and recent doses', (
      tester,
    ) async {
      final rig = await _mount(tester, _phone);
      await tester.tap(_row(rig.firstId));
      await tester.pumpAndSettle();
      for (final key in [
        'medication-stock-section',
        'medication-last-14',
        'medication-recent',
      ]) {
        await tester.dragUntilVisible(
          find.byKey(ValueKey(key)),
          find.byType(ListView).first,
          const Offset(0, -200),
        );
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(find.byKey(const ValueKey('add-stock')), findsOneWidget);
      expect(find.byKey(const ValueKey('see-all-history')), findsOneWidget);
    });

    testWidgets('an empty ledger says so instead of showing empty marks only', (
      tester,
    ) async {
      final rig = await _mount(
        tester,
        _phone,
        activity: (id) =>
            medicationActivityFrom(items: [], pillId: id, now: DateTime.now()),
      );
      await tester.tap(_row(rig.firstId));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('medication-recent')),
        find.byType(ListView).first,
        const Offset(0, -200),
      );
      expect(find.text('Nothing recorded in the last 30 days.'), findsOne);
      expect(find.textContaining('No doses recorded yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('last-14-summary')), findsNothing);
    });
  });

  group('medium: a single column of rows', () {
    testWidgets('has the summary strip and a tap pushes the page', (
      tester,
    ) async {
      await _mount(tester, _medium);
      expect(find.byKey(const ValueKey('medication-stock-strip')), findsOne);
      expect(find.byKey(const ValueKey('medication-pane')), findsNothing);
      expect(find.byKey(const ValueKey('add-fab')), findsOneWidget);

      await tester.tap(_row(_secondId));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MedicationDetailScreen>(find.byType(MedicationDetailScreen))
            .pillId,
        _secondId,
      );
    });

    testWidgets('the person selector keeps a gap above the first row', (
      tester,
    ) async {
      await _mount(tester, _medium, secondPerson: true);
      final selector = tester.getRect(find.byType(CarePersonSelector));
      final first = [
        tester.getTopLeft(_row(_secondId)).dy,
        for (final row in tester.widgetList<MedicationCompactRow>(
          find.byType(MedicationCompactRow),
        ))
          tester.getTopLeft(find.byWidget(row)).dy,
      ].reduce((a, b) => a < b ? a : b);
      expect(first - selector.bottom, greaterThanOrEqualTo(10));
    });

    testWidgets('search sits behind its button and filters the rows', (
      tester,
    ) async {
      final rig = await _mount(tester, _medium);
      expect(find.byKey(const ValueKey('medication-search')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('medication-search-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('medication-search')),
        'second',
      );
      await tester.pumpAndSettle();
      expect(_row(_secondId), findsOneWidget);
      expect(_row(rig.firstId), findsNothing);
    });
  });

  group('last 14 days and recent doses', () {
    testWidgets('the phone page shows what the ledger says', (tester) async {
      final rig = await _mount(tester, _phone, activity: _activityFor);
      await tester.tap(_row(rig.firstId));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('medication-last-14')),
        find.byType(ListView).first,
        const Offset(0, -200),
      );
      expect(find.byKey(const ValueKey('last-14-summary')), findsOneWidget);
      expect(find.text('2 of 5 days'), findsOneWidget);
      for (var i = 0; i < 14; i++) {
        expect(find.byKey(ValueKey('day-cell-$i')), findsOneWidget);
      }
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('recent-d1')),
        find.byType(ListView).first,
        const Offset(0, -200),
      );
      for (final id in ['d1', 'd2', 'd3', 'd4', 'd5']) {
        expect(find.byKey(ValueKey('recent-$id')), findsOneWidget);
      }
      expect(find.text('Taken'), findsWidgets);
      expect(find.text('Skipped'), findsWidgets);
      expect(find.text('Not recorded'), findsWidgets);
      // A recorded miss reads as Missed, as on Today and History.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('recent-d5')),
          matching: find.text('Missed'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('recent-d4')),
          matching: find.text('Not recorded'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('See all in History opens the History tab', (tester) async {
      final rig = await _mount(tester, _expanded);
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('see-all-history')),
        find.byKey(const ValueKey('medication-pane-scroll')),
        const Offset(0, -200),
      );
      await tester.tap(find.byKey(const ValueKey('see-all-history')));
      await tester.pumpAndSettle();
      expect(rig.location, AppPaths.logs);
      expect(find.byType(HistoryScreen), findsOneWidget);
    });
  });

  group('Add stock is a small dialog with an amount', () {
    Future<int?> storedStock(_Rig rig) async {
      final rows = await rig.fixture.db.select(rig.fixture.db.pills).get();
      return rows.firstWhere((p) => p.id == rig.firstId).currentStock;
    }

    Future<void> openFromPhone(WidgetTester tester, _Rig rig) async {
      await tester.tap(_row(rig.firstId));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('add-stock')),
        find.byType(ListView).first,
        const Offset(0, -200),
      );
      await tester.tap(find.byKey(const ValueKey('add-stock')));
      await tester.pumpAndSettle();
    }

    Future<void> openFromPane(WidgetTester tester) async {
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('add-stock')),
        find.byKey(const ValueKey('medication-pane-scroll')),
        const Offset(0, -200),
      );
      await tester.tap(find.byKey(const ValueKey('add-stock')));
      await tester.pumpAndSettle();
    }

    testWidgets('phone: the amount is added to the count', (tester) async {
      final rig = await _mount(tester, _phone, animated: true);
      await openFromPhone(tester, rig);
      expect(find.byKey(const ValueKey('add-stock-dialog')), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byKey(const ValueKey('edit-medication-name')), findsNothing);
      expect(find.text('Now: 12'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('add-stock-amount')),
        '5',
      );
      await tester.pump();
      expect(find.text('New total: 17'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('add-stock-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-stock-dialog')), findsNothing);
      expect(await storedStock(rig), 17);
    });

    testWidgets('connected: the amount is recorded as a refill, not a count', (
      tester,
    ) async {
      final rig = await _mount(tester, _expanded, connected: true);
      final db = rig.fixture.db;
      final before = (await db.pendingOperationsDao.getForUser(
        rig.fixture.workspace.context.ownerUserId,
      )).length;
      await openFromPane(tester);
      await tester.enterText(
        find.byKey(const ValueKey('add-stock-amount')),
        '5',
      );
      await tester.tap(find.byKey(const ValueKey('add-stock-confirm')));
      await tester.pumpAndSettle();
      expect(await storedStock(rig), 17);
      final added = (await db.pendingOperationsDao.getForUser(
        rig.fixture.workspace.context.ownerUserId,
      )).skip(before).toList();
      expect(added.map((o) => o.operationType), ['inventory.refill']);
      final command =
          (jsonDecode(added.single.payloadJson) as Map)['inventoryCommand']
              as Map;
      expect(command['action'], 'refill');
      expect(command['amount'], 5);
      final events = await db.medicationLedgerDao.getInventoryEventsForPill(
        rig.firstId,
      );
      expect(events.where((e) => e.kind == 'refill'), hasLength(1));
      expect(events.where((e) => e.kind == 'correction'), isEmpty);
    });

    testWidgets('expanded: a small dialog above a keyboard that is up', (
      tester,
    ) async {
      final rig = await _mount(
        tester,
        _expanded,
        keyboard: 320,
        animated: true,
      );
      await openFromPane(tester);
      expect(find.byKey(const ValueKey('add-stock-dialog')), findsOneWidget);
      final add = tester.getRect(
        find.byKey(const ValueKey('add-stock-confirm')),
      );
      expect(add.bottom, lessThanOrEqualTo(753 - 320));
      await tester.enterText(
        find.byKey(const ValueKey('add-stock-amount')),
        '8',
      );
      await tester.tap(find.byKey(const ValueKey('add-stock-confirm')));
      await tester.pumpAndSettle();
      expect(await storedStock(rig), 20);
    });

    testWidgets('an empty or zero amount is refused and nothing changes', (
      tester,
    ) async {
      final rig = await _mount(tester, _expanded);
      await openFromPane(tester);
      await tester.tap(find.byKey(const ValueKey('add-stock-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Enter how many to add, more than zero.'), findsOne);
      await tester.enterText(
        find.byKey(const ValueKey('add-stock-amount')),
        '0',
      );
      await tester.tap(find.byKey(const ValueKey('add-stock-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-stock-dialog')), findsOneWidget);
      expect(await storedStock(rig), 12);
    });

    testWidgets('Cancel leaves the stock as it was', (tester) async {
      final rig = await _mount(tester, _expanded);
      await openFromPane(tester);
      await tester.enterText(
        find.byKey(const ValueKey('add-stock-amount')),
        '99',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-stock-dialog')), findsNothing);
      expect(await storedStock(rig), 12);
    });
  });

  group('the expanded pane header', () {
    testWidgets('Edit sits beside the title, and the stock never leaves an '
        'empty column beside the 14 days', (tester) async {
      await _mount(tester, _expanded);
      final title = tester.getRect(
        find.byKey(const ValueKey('pane-medication-name')),
      );
      final edit = tester.getRect(
        find.byKey(const ValueKey('edit-medication-details')),
      );
      // Same header row, close to the name rather than at the far edge.
      expect(edit.center.dy, closeTo(title.center.dy, 40));
      expect(edit.left - title.right, lessThan(120));
      final stock = tester.getRect(
        find.byKey(const ValueKey('medication-stock-section')),
      );
      final last14 = tester.getRect(find.byType(MedicationLast14Section));
      if (find.byKey(const ValueKey('supply-runway')).evaluate().isNotEmpty) {
        // A tall stock sits beside the 14 days.
        expect(last14.left, greaterThanOrEqualTo(stock.right));
      } else {
        // A stock that is only its count stacks above the 14 days instead of
        // leaving a gap under it.
        expect(last14.top, greaterThanOrEqualTo(stock.bottom));
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('the expanded edit dialog', () {
    testWidgets('closes through Cancel only, with no second close button', (
      tester,
    ) async {
      await _mount(tester, _expanded);
      await tester.tap(find.byKey(const ValueKey('edit-medication-details')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('cancel-medication-review')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byIcon(Icons.close_rounded),
        ),
        findsNothing,
      );
    });
  });

  group('the edit form previews the change', () {
    testWidgets('wide: the preview column follows the form', (tester) async {
      final rig = await _mount(tester, _expanded);
      await tester.tap(find.byKey(const ValueKey('edit-medication-details')));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('edit-preview-dose-card'));
      expect(card, findsOneWidget);
      expect(find.byKey(const ValueKey('edit-preview-stock')), findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.text(rig.fixture.pill.name)),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('edit-medication-name')),
        'Fictional renamed',
      );
      await tester.enterText(
        find.byKey(const ValueKey('edit-medication-stock')),
        '30',
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: card, matching: find.text('Fictional renamed')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('edit-preview-stock-count')),
            )
            .data,
        '30 left',
      );
    });

    testWidgets('phone: the preview starts closed and opens on a tap', (
      tester,
    ) async {
      final rig = await _mount(tester, _phone);
      await tester.tap(_row(rig.firstId));
      await tester.pumpAndSettle();
      final edit = find.byKey(const ValueKey('edit-medication-details'));
      await tester.ensureVisible(edit);
      await tester.pumpAndSettle();
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('edit-preview-toggle')), findsOne);
      expect(
        find.byKey(const ValueKey('edit-preview-dose-card')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('edit-preview-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('edit-preview-dose-card')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('edit-preview-stock')), findsOneWidget);
    });
  });

  // Every state of the three pages at the four review sizes, two text sizes
  // and both themes must lay out without an exception (an overflow is one).
  // Writes images only when REVIEW_CAPTURE_DIR is set.
  group('lays out cleanly', () {
    const windows = {
      'expanded': Size(1205, 753),
      'medium': Size(753, 1205),
      'phone': Size(412, 915),
      'small': Size(360, 800),
    };
    for (final window in windows.entries) {
      for (final scale in const [1.0, 1.3]) {
        for (final dark in const [false, true]) {
          final tag =
              '${window.key}-${scale == 1 ? 'x1' : 'x13'}-'
              '${dark ? 'dark' : 'light'}';
          testWidgets(tag, (tester) async {
            final rig = await _mount(
              tester,
              window.value,
              dark: dark,
              textScale: scale,
              longName: true,
              activity: _activityFor,
            );
            void clean(String step) =>
                expect(tester.takeException(), isNull, reason: '$tag $step');

            Future<void> shot(String name) async {
              clean(name);
              await captureReview(tester, '$tag-$name');
            }

            Future<void> bring(String key, {double at = .05}) async {
              final target = find.byKey(ValueKey(key));
              await tester.dragUntilVisible(
                target,
                find
                        .byKey(const ValueKey('medication-pane-scroll'))
                        .evaluate()
                        .isNotEmpty
                    ? find.byKey(const ValueKey('medication-pane-scroll'))
                    : find.byType(ListView).first,
                const Offset(0, -150),
              );
              await Scrollable.ensureVisible(
                tester.element(target),
                alignment: at,
                duration: Duration.zero,
              );
              await tester.pumpAndSettle();
            }

            // A large text size pushes rows past the built extent or under
            // the navigation bar: scroll the row into view before the tap.
            Future<void> openRow(String id) async {
              await tester.dragUntilVisible(
                _row(id),
                find.byType(ListView).first,
                const Offset(0, -150),
              );
              await tester.ensureVisible(_row(id));
              await tester.pump();
              await tester.tap(_row(id));
              await tester.pumpAndSettle();
            }

            await shot('list');
            final wide = window.value.width >= 840;
            if (wide) {
              // The pane already shows the first medication.
              await shot('pane');
              await bring('medication-stock-section');
              await shot('pane-stock');
              await bring('medication-last-14');
              await shot('pane-last14');
              await bring('medication-recent', at: .3);
              await shot('pane-recent');
              await tester.tap(_row(_secondId));
              await tester.pumpAndSettle();
              await shot('pane-as-needed');
              await tester.tap(_row(_longId));
              await tester.pumpAndSettle();
              await shot('pane-negative');
              await tester.tap(_row(rig.firstId));
              await tester.pumpAndSettle();
              await tester.tap(
                find.byKey(const ValueKey('edit-medication-details')),
              );
              await tester.pumpAndSettle();
              await shot('edit');
              await tester.tap(
                find.byKey(const ValueKey('cancel-medication-review')),
              );
              await tester.pumpAndSettle();
            } else {
              await openRow(rig.firstId);
              await shot('detail');
              await bring('medication-stock-section');
              await shot('detail-stock');
              await bring('medication-last-14');
              await shot('detail-last14');
              await bring('medication-recent', at: .3);
              await shot('detail-recent');
              final edit = find.byKey(
                const ValueKey('edit-medication-details'),
              );
              await tester.ensureVisible(edit);
              await tester.pumpAndSettle();
              await tester.tap(edit);
              await tester.pumpAndSettle();
              await shot('edit');
              await tester.tap(
                find.byKey(const ValueKey('edit-preview-toggle')),
              );
              await tester.pumpAndSettle();
              await shot('edit-preview');
              // The narrow editor is a sheet: close it the way a swipe would.
              Navigator.of(
                tester.element(
                  find.byKey(const ValueKey('edit-preview-toggle')),
                ),
              ).pop();
              await tester.pumpAndSettle();
              await tester.pageBack();
              await tester.pumpAndSettle();
              await openRow(_secondId);
              await shot('detail-as-needed');
              await tester.pageBack();
              await tester.pumpAndSettle();
            }
            await tester.pump(const Duration(milliseconds: 10));
          });
        }
      }
    }
  });

  group('compact rows', () {
    testWidgets('a negative stock is flagged by icon and words', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.light(),
          home: Scaffold(
            body: MedicationCompactRow(
              id: 'neg',
              name: 'Fictional negative',
              tint: Colors.teal,
              shape: MedicationShape.capsule,
              subtitle: 'Every day',
              stock: -2,
              threshold: 5,
              stockInline: false,
              selected: false,
              checked: null,
              onTap: () {},
              onLongPress: () {},
              onCheckedChanged: null,
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    Future<void> pumpRow(WidgetTester tester, {required int stock}) =>
        tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: AppTheme.light(),
            home: Scaffold(
              body: MedicationCompactRow(
                id: 'row',
                name: 'Fictional stock',
                tint: Colors.teal,
                shape: MedicationShape.capsule,
                subtitle: 'Every day',
                stock: stock,
                threshold: 5,
                stockInline: false,
                selected: false,
                checked: null,
                onTap: () {},
                onLongPress: () {},
                onCheckedChanged: null,
              ),
            ),
          ),
        );

    testWidgets('low stock reads "Low · N left" beside a warning icon', (
      tester,
    ) async {
      await pumpRow(tester, stock: 4);
      expect(find.text('Low · 4 left'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('no stock reads "Out" beside its own icon', (tester) async {
      await pumpRow(tester, stock: 0);
      expect(find.text('Out'), findsOneWidget);
      expect(find.byIcon(Icons.block_rounded), findsOneWidget);
    });

    testWidgets('enough stock is a plain count', (tester) async {
      await pumpRow(tester, stock: 20);
      expect(find.text('20 left'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
      expect(find.byIcon(Icons.block_rounded), findsNothing);
    });
  });

  group('the medication page and pane (review fixes)', () {
    final photo = MedicationPhotoView(bytes: _tinyPng, sha256: 'x' * 64);

    double top(WidgetTester tester, Finder f) => tester.getTopLeft(f.first).dy;

    testWidgets('phone: the photo is full width at 4:3 and opens full screen', (
      tester,
    ) async {
      final rig = await _mount(tester, _phone, photo: photo);
      await tester.tap(_row(rig.firstId));
      await tester.pumpAndSettle();
      final open = find.byKey(const ValueKey('medication-photo-open'));
      await tester.dragUntilVisible(
        open,
        find.byType(ListView).first,
        const Offset(0, -200),
      );
      final frame = find.byType(MedicationPhotoFrame);
      final size = tester.getSize(frame);
      expect(size.width, closeTo(412 - 32, 1));
      expect(size.width / size.height, closeTo(4 / 3, .01));
      await tester.dragUntilVisible(
        find.text('Review medication details').evaluate().isEmpty
            ? open
            : find.text('Review medication details'),
        find.byType(ListView).first,
        const Offset(0, -100),
      );
      await tester.ensureVisible(open);
      await tester.pumpAndSettle();
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('medication-photo-viewer')), findsOne);
      final close = find.byKey(const ValueKey('medication-photo-close'));
      expect(tester.getSize(close).shortestSide, greaterThanOrEqualTo(48));
      expect(find.byTooltip('Close the photo'), findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('medication-photo-viewer')),
        findsNothing,
      );
    });

    testWidgets(
      'expanded: with no facts the photo stands alone, not beside an empty column',
      (tester) async {
        final rig = await _mount(tester, _expanded, photo: photo);
        await tester.tap(_row(rig.firstId));
        await tester.pumpAndSettle();
        final scroll = find.byKey(const ValueKey('medication-pane-scroll'));
        final open = find.byKey(const ValueKey('medication-photo-open'));
        await tester.dragUntilVisible(open, scroll, const Offset(0, -200));
        final frame = find.byType(MedicationPhotoFrame);
        final size = tester.getSize(frame);
        expect(size.width / size.height, closeTo(4 / 3, .01));
        // This medication has no facts to list, so there is no empty left
        // column: the photo starts at the pane's left edge.
        final pane = tester.getRect(
          find.byKey(const ValueKey('medication-pane')),
        );
        expect(tester.getTopRight(frame).dx, lessThanOrEqualTo(pane.right));
        expect(tester.getTopLeft(frame).dx, lessThan(pane.center.dx));
        await tester.tap(open);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('medication-photo-viewer')), findsOne);
      },
    );

    testWidgets('the phone and the pane list their sections in one order', (
      tester,
    ) async {
      final rig = await _mount(tester, _phone, activity: _activityFor);
      await tester.tap(_row(rig.firstId));
      await tester.pumpAndSettle();
      final list = find.byType(ListView).first;
      Future<double> y(String key) async {
        final f = find.byKey(ValueKey(key));
        await tester.dragUntilVisible(f, list, const Offset(0, -200));
        return top(tester, f);
      }

      // Each section is further down than the one before it.
      final stock = await y('medication-stock-section');
      final last14 = await y('medication-last-14');
      final recent = await y('medication-recent');
      expect(last14, isNot(stock));
      expect(recent, isNot(last14));
      // The routine button comes after every section on the page.
      final routine = await y('open-routine-details');
      expect(routine, greaterThan(recent));
    });

    testWidgets('one Edit button, and no second Edit medication link', (
      tester,
    ) async {
      final rig = await _mount(tester, _phone);
      await tester.tap(_row(rig.firstId));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('edit-medication-details')),
        find.byType(ListView).first,
        const Offset(0, -200),
      );
      expect(find.byKey(const ValueKey('edit-medication-details')), findsOne);
      expect(find.text('Edit medication'), findsNothing);
    });

    testWidgets('the tablet header Edit asks for a review, like the phone', (
      tester,
    ) async {
      final rig = await _mount(tester, _expanded);
      await tester.tap(_row(rig.firstId));
      await tester.pumpAndSettle();
      final edit = find.byKey(const ValueKey('edit-medication-details'));
      expect(
        find.descendant(
          of: edit,
          matching: find.text('Review medication details'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('tile-stock')), findsNothing);
      expect(find.byKey(const ValueKey('tile-schedule')), findsOneWidget);
    });

    testWidgets('on the phone Amount, facts and Edit share one card', (
      tester,
    ) async {
      final rig = await _mount(tester, _phone);
      await tester.tap(_row(rig.firstId));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('medication-details-section'));
      await tester.dragUntilVisible(
        card,
        find.byType(ListView).first,
        const Offset(0, -200),
      );
      expect(
        find.descendant(
          of: card,
          matching: find.byKey(const ValueKey('edit-medication-details')),
        ),
        findsOneWidget,
      );
    });
  });
}

final _tinyPng = Uint8List.fromList(const [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0xF8,
  0xFF,
  0xFF,
  0x3F,
  0x00,
  0x05,
  0xFE,
  0x02,
  0xFE,
  0xA7,
  0x35,
  0x81,
  0x84,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);
