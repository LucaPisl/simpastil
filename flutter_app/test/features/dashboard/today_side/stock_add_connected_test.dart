import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_detail_provider.dart';
import 'package:simpastil/features/dashboard/today_side/stock_overview.dart';
import 'package:simpastil/features/dashboard/today_side/today_side_column.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/care_recording_fixture.dart';
import '../../../helpers/window_view.dart';
import '../../../helpers/held_provider_read.dart';

/// Medications offers "Add stock" in a connected workspace, through the
/// medication sheet. Today's Stock card must offer the same, not hide it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  // The editor loads the medication from the database before it opens, and
  // that work only completes in real time, so let it run between frames.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
  }

  Future<(CareRecordingFixture, ProviderContainer)> mount(
    WidgetTester tester, {
    required bool connected,
  }) async {
    useWindow(tester, const Size(700, 900));
    final f = await CareRecordingFixture.create(
      connected: connected,
      legacyStock: 3,
    );
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      const PillsCompanion(lowStockThreshold: Value(5)),
    );
    final c = await f.workspace.createContainer();
    await c.readHeld(medicationListProvider);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.runAsync(f.db.close);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SingleChildScrollView(child: StockCard())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (f, c);
  }

  testWidgets('a connected workspace offers Add stock on a low medication', (
    tester,
  ) async {
    final (f, c) = await mount(tester, connected: true);
    expect(c.read(todayStockProvider).requireValue.canAddStock, isTrue);
    final add = find.byKey(ValueKey('stock-add-${f.pill.id}'));
    expect(add, findsOneWidget);

    await tester.tap(add);
    await settle(tester);
    // The medication's own sheet, as the Medications page opens it there.
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Fictional recorded medication'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a low row says so with an icon and words, and ticks the bar', (
    tester,
  ) async {
    final (f, _) = await mount(tester, connected: true);
    final state = find.byKey(ValueKey('stock-state-${f.pill.id}'));
    expect(state, findsOneWidget);
    expect(
      find.descendant(of: state, matching: find.text('Low · 3 left')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: state,
        matching: find.byIcon(Icons.warning_amber_rounded),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('stock-refill-tick')), findsOneWidget);
  });

  testWidgets('a local workspace still opens the stock editor', (tester) async {
    final (f, _) = await mount(tester, connected: false);
    final add = find.byKey(ValueKey('stock-add-${f.pill.id}'));
    expect(add, findsOneWidget);
    await tester.tap(add);
    await settle(tester);
    expect(find.byKey(const ValueKey('edit-medication-stock')), findsOneWidget);
  });
}
