import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/features/pills/pill_provider.dart';
import 'package:simpastil/features/pills/presentation/medication_form_kit.dart';
import 'package:simpastil/features/pills/pill_repository.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/care_recording_fixture.dart';

Future<void> _open(
  WidgetTester tester, {
  required Size size,
  double textScale = 1,
  ThemeData? theme,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({
    LedgerModeHint.fractionalStockKey: true,
  });
  final f = await CareRecordingFixture.create(
    connected: true,
    preferences: await SharedPreferences.getInstance(),
  );
  await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
    const PillsCompanion(
      currentStock: Value(10),
      stockQuantity: Value('10'),
      stockUnit: Value('tablet'),
      stockNeedsRecount: Value(true),
    ),
  );
  final container = await f.workspace.createContainer(
    extraOverrides: [
      pillRepositoryProvider.overrideWithValue(
        PillRepositoryImpl(
          db: f.db,
          dao: f.db.pillsDao,
          profilesDao: f.db.profilesDao,
          schedulesDao: f.db.schedulesDao,
          pendingOperations: PendingOperationRepository(
            f.db,
            access: f.workspace.access,
            context: f.workspace.context,
          ),
          reconcileProjections: () async {},
        ),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await f.db.close();
    container.dispose();
    await tester.pumpAndSettle();
  });
  final router = container.read(routerProvider)..go('/pills');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: theme ?? AppTheme.light(),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('medication-${f.pill.id}')));
  await tester.pumpAndSettle();
  _pillId = f.pill.id;
  _db = f.db;
}

late String _pillId;
late AppDatabase _db;

Future<Pill> _pill() async => (await _db.pillsDao.getById(_pillId))!;

Future<void> _recount(WidgetTester tester, String count) async {
  final handle = tester.ensureSemantics();
  final button = find.byKey(const ValueKey('recount-stock'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
  expect(
    tester.getSemantics(button).label,
    'Recount Fictional recorded medication',
  );
  await tester.tap(button);
  await tester.pumpAndSettle();
  expect(find.text('How many are left?'), findsOneWidget);
  await tester.enterText(find.byKey(const ValueKey('recount-field')), count);
  await tester.tap(find.byKey(const ValueKey('recount-save')));
  await tester.pumpAndSettle();
  handle.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  for (final layout in [
    ('phone', const Size(412, 915)),
    ('tablet', const Size(1100, 900)),
  ]) {
    testWidgets(
      'Recount saves the count and clears the mark on the ${layout.$1}',
      (tester) async {
        await _open(tester, size: layout.$2, textScale: 1.3);
        expect((await _pill()).stockNeedsRecount, isTrue);
        await _recount(tester, '7.5');
        final pill = await _pill();
        expect(pill.stockNeedsRecount, isFalse);
        expect(pill.stockQuantity, '7.5');
        expect(pill.stockUnit, 'tablet');
        expect(find.byKey(const ValueKey('recount-stock')), findsNothing);
      },
    );
  }

  testWidgets('one part button opens a pop-up that types the fraction', (
    tester,
  ) async {
    await _open(tester, size: const Size(412, 915), textScale: 1.3);
    final handle = tester.ensureSemantics();
    final button = find.byKey(const ValueKey('recount-stock'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('recount-field'));
    String text() => tester.widget<StockWholeField>(field).controller.text;
    String shown() => tester
        .widget<TextFormField>(
          find.descendant(of: field, matching: find.byType(TextFormField)),
        )
        .controller!
        .text;
    await tester.enterText(field, '7');
    await tester.pump();
    // Only the one button shows until it is pressed.
    expect(find.byKey(const ValueKey('stock-part-2')), findsNothing);
    final part = find.byKey(const ValueKey('stock-part-button'));
    expect(find.text('Add a part'), findsOneWidget);
    expect(tester.getSize(part).height, greaterThanOrEqualTo(48));

    Future<void> pick(int quarters) async {
      await tester.tap(part);
      await tester.pumpAndSettle();
      expect(find.text('Part of a tablet'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('stock-part-$quarters')));
      await tester.pumpAndSettle();
    }

    await tester.tap(part);
    await tester.pumpAndSettle();
    final half = find.byKey(const ValueKey('stock-part-2'));
    expect(tester.getSemantics(half).label, 'A half');
    expect(tester.getSize(half).height, greaterThanOrEqualTo(48));
    // "None" is the current choice, marked by more than colour.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('stock-part-0')),
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );
    // Cancel leaves the count alone.
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(text(), '7');

    await pick(2);
    expect(text(), '7 1/2');
    // The field keeps the whole count; the part lives on the button.
    expect(shown(), '7');
    expect(find.text('Part: ½'), findsOneWidget);
    await pick(3);
    expect(text(), '7 3/4');
    await pick(0);
    expect(text(), '7');
    await pick(1);
    await tester.tap(find.byKey(const ValueKey('recount-save')));
    await tester.pumpAndSettle();
    expect((await _pill()).stockQuantity, '7.25');
    handle.dispose();
  });

  testWidgets(
    'an invalid count keeps the dialog open, Cancel changes nothing',
    (tester) async {
      await _open(tester, size: const Size(412, 915), theme: AppTheme.dark());
      final button = find.byKey(const ValueKey('recount-stock'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('recount-field')),
        'abc',
      );
      await tester.tap(find.byKey(const ValueKey('recount-save')));
      await tester.pumpAndSettle();
      expect(find.text('Use a number, like 30, 7.5 or 7 1/2.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('How many are left?'), findsNothing);
      expect((await _pill()).stockNeedsRecount, isTrue);
    },
  );
}
