import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/storage/as_needed_shortcut_preference.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/protected_workspace_fixture.dart';
import '../../helpers/review_rendering.dart';
import '../../helpers/window_view.dart';

Finder _card(String pillId) => find.byKey(ValueKey('as-needed-card-$pillId'));
final _jump = find.byKey(const ValueKey('as-needed-jump'));

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

/// True when the pill is faded in and can be tapped.
bool _shown(WidgetTester tester) {
  if (_jump.evaluate().isEmpty) return false;
  final opacity = tester.widget<AnimatedOpacity>(
    find.ancestor(of: _jump, matching: find.byType(AnimatedOpacity)).first,
  );
  final ignore = tester.widget<IgnorePointer>(
    find.ancestor(of: _jump, matching: find.byType(IgnorePointer)).first,
  );
  return opacity.opacity == 1 && !ignore.ignoring;
}

Future<ProviderContainer> _open(
  WidgetTester tester, {
  bool quiet = false,
  bool shortcutOn = true,
}) async {
  useWindow(tester, const Size(412, 520));
  final f = await _connectedPrnFixture();
  final container = await f.workspace.createContainer();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pumpAndSettle();
    await tester.runAsync(f.db.close);
  });
  if (!shortcutOn) {
    await container.read(asNeededShortcutProvider.notifier).setEnabled(false);
  }
  await _pumpApp(tester, container, quiet: quiet);
  _pillId = f.pill.id;
  return container;
}

String _pillId = '';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadReviewFonts();
  });

  testWidgets('the pill shows while As needed is below the visible area', (
    tester,
  ) async {
    await _open(tester);
    expect(_shown(tester), isTrue);
    expect(find.text('As needed'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping it scrolls the section into view and the pill leaves', (
    tester,
  ) async {
    await _open(tester);
    final before = tester
        .getTopLeft(find.byKey(const ValueKey('as-needed-jump')))
        .dy;
    expect(before, greaterThan(0));
    await tester.tap(_jump);
    await _pump(tester, 1000);
    final card = _card(_pillId);
    expect(card, findsOneWidget);
    expect(tester.getTopLeft(card).dy, lessThan(520 - 140));
    expect(_shown(tester), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('under Reduce motion the jump is instant', (tester) async {
    await _open(tester, quiet: true);
    expect(_shown(tester), isTrue);
    await tester.tap(_jump);
    // Nothing animates: a few plain frames (measure, then rebuild) settle it.
    await _pump(tester, 150);
    expect(tester.getTopLeft(_card(_pillId)).dy, lessThan(520 - 140));
    expect(_shown(tester), isFalse);
  });

  testWidgets('scrolling the section into view by hand hides the pill', (
    tester,
  ) async {
    await _open(tester);
    expect(_shown(tester), isTrue);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
    await _pump(tester, 1500);
    expect(_shown(tester), isFalse);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
    await _pump(tester, 1500);
    expect(_shown(tester), isTrue);
  });

  testWidgets('the pill has its own strip and does not cover the last '
      'actions on Today', (tester) async {
    await _open(tester);
    expect(_shown(tester), isTrue);
    final list = find.byType(Scrollable).first;
    // The list ends above the pill, so Dose details and Select doses at the
    // fold are never underneath it.
    expect(
      tester.getRect(list).bottom,
      lessThanOrEqualTo(tester.getRect(_jump).top),
    );
    // With As needed in view the pill leaves and the page has its height back.
    await tester.drag(list, const Offset(0, -2000));
    await _pump(tester, 1500);
    expect(_shown(tester), isFalse);
    expect(tester.getRect(find.byType(Scrollable).first).bottom, 520);
    // Scrolling back up brings the pill and its strip back.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
    await _pump(tester, 1500);
    expect(_shown(tester), isTrue);
    expect(
      tester.getRect(find.byType(Scrollable).first).bottom,
      lessThanOrEqualTo(tester.getRect(_jump).top),
    );
  });

  testWidgets('with the shortcut off nothing is lifted', (tester) async {
    await _open(tester, shortcutOn: false);
    expect(_jump, findsNothing);
    expect(tester.getRect(find.byType(Scrollable).first).bottom, 520);
  });

  testWidgets('turned off in Appearance, no pill is built', (tester) async {
    await _open(tester, shortcutOn: false);
    expect(_jump, findsNothing);
  });

  testWidgets('turning the preference off removes the pill at once', (
    tester,
  ) async {
    final container = await _open(tester);
    expect(_shown(tester), isTrue);
    await container.read(asNeededShortcutProvider.notifier).setEnabled(false);
    await tester.pumpAndSettle();
    expect(_jump, findsNothing);
  });
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
