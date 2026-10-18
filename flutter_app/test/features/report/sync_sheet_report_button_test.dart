import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/sync_status_notifier.dart';
import 'package:simpastil/features/settings/presentation/sync_diagnostics_sheet.dart';
import 'package:simpastil/l10n/app_localizations.dart';

const _failed = SyncStatus(
  phase: SyncPhase.failure,
  lastRun: SyncRunResult([
    SyncStageResult(
      stageId: 'flush.account',
      outcome: SyncComponentOutcome.failed(
        safeErrorCode: 'SYNC_STAGE_FAILED',
        httpStatusCode: 500,
      ),
    ),
  ]),
);

Future<int> _pump(
  WidgetTester tester,
  SyncStatus status, {
  bool wired = true,
  Size size = const Size(390, 800),
  Locale? locale,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  var taps = 0;
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SyncDiagnosticsSheet(
          status: status,
          onReport: wired ? () => taps++ : null,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return taps;
}

void main() {
  for (final entry in {
    'phone': const Size(390, 800),
    'tablet': const Size(900, 1200),
  }.entries) {
    testWidgets('a failed sync offers a report on a ${entry.key}', (
      tester,
    ) async {
      await _pump(tester, _failed, size: entry.value);
      expect(find.text('Report this problem'), findsOneWidget);
    });
  }

  testWidgets('tapping it asks for the report', (tester) async {
    var taps = 0;
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SyncDiagnosticsSheet(status: _failed, onReport: () => taps++),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('sync-sheet-report')));
    expect(taps, 1);
  });

  testWidgets('a healthy sync does not offer it', (tester) async {
    await _pump(tester, SyncStatus(lastSuccessAt: DateTime(2026, 10, 18, 12)));
    expect(find.byKey(const ValueKey('sync-sheet-report')), findsNothing);
  });

  testWidgets('an update the person must install is not a problem', (
    tester,
  ) async {
    await _pump(
      tester,
      const SyncStatus(
        phase: SyncPhase.failure,
        lastRun: SyncRunResult([
          SyncStageResult(
            stageId: 'flush.account',
            outcome: SyncComponentOutcome.failed(
              safeErrorCode: 'CLIENT_UPGRADE_REQUIRED',
              httpStatusCode: 426,
            ),
          ),
        ]),
      ),
    );
    expect(find.byKey(const ValueKey('sync-sheet-report')), findsNothing);
  });

  testWidgets('being offline is not a problem to report', (tester) async {
    await _pump(
      tester,
      const SyncStatus(
        phase: SyncPhase.failure,
        lastError: 'You appear to be offline',
        lastRun: SyncRunResult([
          SyncStageResult(
            stageId: 'flush.account',
            outcome: SyncComponentOutcome.failed(safeErrorCode: 'SYNC_OFFLINE'),
          ),
        ]),
      ),
    );
    expect(find.byKey(const ValueKey('sync-sheet-report')), findsNothing);
  });

  testWidgets('without a handler the sheet stays as it was', (tester) async {
    await _pump(tester, _failed, wired: false);
    expect(find.byKey(const ValueKey('sync-sheet-report')), findsNothing);
  });

  testWidgets('reads in Romanian', (tester) async {
    await _pump(tester, _failed, locale: const Locale('ro'));
    expect(find.text('Raportează această problemă'), findsOneWidget);
  });
}
