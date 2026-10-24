import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/sync/refill_refusal.dart';
import 'package:simpastil/core/sync/sync_recovery_service.dart';
import 'package:simpastil/features/pills/pill_provider.dart';
import 'package:simpastil/features/pills/pill_repository.dart';
import 'package:simpastil/features/settings/presentation/sync_recovery_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/care_recording_fixture.dart';

/// A refill an older server refused leaves the server's count on the phone.
/// The medication's stock says why, on the phone and the tablet alike.
Future<void> _open(
  WidgetTester tester, {
  required Size size,
  double textScale = 1,
  ThemeData? theme,
  Locale locale = const Locale('en'),
  bool refused = true,
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
    ),
  );
  if (refused) {
    await f.db.pendingOperationsDao.enqueue(
      PendingOperationsCompanion.insert(
        id: 'refused-refill',
        userId: f.person.userId,
        mutationId: 'm-refused-refill',
        component: 'medication',
        operationType: 'inventory.refill',
        contractVersion: 2,
        state: const Value('blocked'),
        safeErrorCode: const Value(refillNeedsLedgerCode),
        payloadJson: jsonEncode({
          'entityType': 'pill',
          'entityLocalId': f.pill.id,
          'inventoryCommand': {
            'commandId': 'm-refused-refill',
            'action': 'refill',
            'pillId': f.pill.id,
            'amount': 5,
          },
        }),
        createdAt: DateTime.utc(2026, 10, 23, 8),
      ),
    );
  }
  final container = await f.workspace.createContainer(
    extraOverrides: [
      recoveryCapabilitiesLoaderProvider.overrideWithValue(() async => null),
      syncRecoveryServiceProvider.overrideWithValue(
        SyncRecoveryService(
          db: f.db,
          flush: (_) async {},
          pull: (_) async => true,
          write: <T>(_, action) => f.db.transaction(action),
        ),
      ),
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
        locale: locale,
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
}

const _notice = ValueKey('stock-refill-refused');
const _fix = ValueKey('stock-refill-open-recovery');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  for (final layout in [
    ('phone', const Size(412, 915)),
    ('tablet', const Size(1100, 900)),
  ]) {
    for (final dark in [false, true]) {
      testWidgets(
        'the stock says the server needs an update on the ${layout.$1}, '
        '${dark ? 'dark' : 'light'}',
        (tester) async {
          final handle = tester.ensureSemantics();
          await _open(
            tester,
            size: layout.$2,
            textScale: 1.3,
            theme: dark ? AppTheme.dark() : AppTheme.light(),
          );
          final notice = find.byKey(_notice);
          await tester.ensureVisible(notice);
          await tester.pumpAndSettle();
          expect(
            find.text(
              'The server needs an update before it can add stock, so the '
              'stock you added is not counted. After the update, retry it '
              'in Fix sync problems.',
            ),
            findsOneWidget,
          );
          // Words carry it, not colour: an icon and a full sentence.
          expect(
            find.descendant(
              of: notice,
              matching: find.byIcon(Icons.cloud_off_outlined),
            ),
            findsOneWidget,
          );
          // The notice names Fix sync problems and leads there.
          final fix = find.byKey(_fix);
          expect(
            find.descendant(of: fix, matching: find.text('Fix sync problems')),
            findsOneWidget,
          );
          final size = tester.getSize(fix);
          expect(size.height, greaterThanOrEqualTo(48));
          expect(size.width, greaterThanOrEqualTo(48));
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          handle.dispose();
        },
      );
    }
  }

  testWidgets('the notice reads in Romanian', (tester) async {
    await _open(tester, size: const Size(412, 915), locale: const Locale('ro'));
    final notice = find.byKey(_notice);
    await tester.ensureVisible(notice);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Serverul are nevoie de o actualizare'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(_fix),
        matching: find.text('Rezolvă problemele de sincronizare'),
      ),
      findsOneWidget,
    );
  });

  for (final layout in [
    ('phone', const Size(412, 915)),
    ('tablet', const Size(1100, 900)),
  ]) {
    testWidgets('the button opens Fix sync problems on the ${layout.$1}', (
      tester,
    ) async {
      await _open(tester, size: layout.$2);
      final fix = find.byKey(_fix);
      await tester.ensureVisible(fix);
      await tester.pumpAndSettle();
      await tester.tap(fix);
      await tester.pumpAndSettle();
      expect(find.byType(SyncRecoveryScreen), findsOneWidget);
    });
  }

  testWidgets('no notice without a refused refill', (tester) async {
    await _open(tester, size: const Size(412, 915), refused: false);
    expect(find.byKey(_notice), findsNothing);
    expect(find.byKey(_fix), findsNothing);
  });
}
