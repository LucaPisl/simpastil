import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/sync_status_notifier.dart';
import 'package:simpastil/features/settings/presentation/sync_diagnostics_sheet.dart';
import 'package:simpastil/features/settings/presentation/sync_settings_section.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/widgets/status_chip.dart';

void main() {
  test('maps sync outcomes without claiming an unobserved success', () {
    expect(
      syncHeadlineState(const SyncStatus()),
      SyncHeadlineState.notYetSynced,
    );
    expect(
      syncHeadlineState(SyncStatus(lastSuccessAt: DateTime.utc(2026, 10, 8))),
      SyncHeadlineState.synced,
    );
    expect(
      syncHeadlineState(
        const SyncStatus(
          lastRun: SyncRunResult([
            SyncStageResult(
              stageId: 'pull.medicationBridge',
              outcome: SyncComponentOutcome.partiallySynced(),
            ),
          ]),
        ),
      ),
      SyncHeadlineState.partiallySynced,
    );
    expect(
      syncHeadlineState(
        const SyncStatus(phase: SyncPhase.failure, lastError: 'Sync failed'),
      ),
      SyncHeadlineState.couldNotSync,
    );
    expect(
      syncHeadlineState(
        const SyncStatus(
          phase: SyncPhase.failure,
          lastError: 'You appear to be offline',
        ),
      ),
      SyncHeadlineState.offline,
    );
    expect(
      syncHeadlineState(
        const SyncStatus(
          phase: SyncPhase.failure,
          lastRun: SyncRunResult([
            SyncStageResult(
              stageId: 'pull.account',
              outcome: SyncComponentOutcome.failed(
                safeErrorCode: 'CLIENT_UPGRADE_REQUIRED',
                httpStatusCode: 426,
              ),
            ),
          ]),
        ),
      ),
      SyncHeadlineState.updateRequired,
    );
  });

  test('review and waiting work never report fully synced', () {
    expect(
      syncHeadlineState(const SyncStatus(), reviewCount: 1),
      SyncHeadlineState.needsReview,
    );
    expect(
      syncHeadlineState(const SyncStatus(pendingCount: 1)),
      SyncHeadlineState.partiallySynced,
    );
  });

  testWidgets('diagnostics disclosure never renders untrusted canaries', (
    tester,
  ) async {
    const canary = 'PRIVATE_MEDICATION_CANARY';
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SyncDiagnosticsSheet(
            status: SyncStatus(
              phase: SyncPhase.failure,
              lastError: canary,
              lastRun: SyncRunResult([
                SyncStageResult(
                  stageId: 'pull.medication',
                  outcome: SyncComponentOutcome.failed(
                    safeErrorCode: canary,
                    safeCorrelationId: canary,
                    httpStatusCode: 500,
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining(canary), findsNothing);

    await tester.tap(find.textContaining('pull.medication'));
    await tester.pumpAndSettle();
    expect(find.textContaining(canary), findsNothing);
    expect(find.text('SYNC_STAGE_FAILED'), findsOneWidget);
  });

  for (final entry in const {
    'en': 'A routine time zone needs review. Choose a city or region.',
    'ro':
        'Fusul orar al rutinei trebuie verificat. Alege un oraș sau o regiune.',
  }.entries) {
    testWidgets('timezone review shows localized guidance in ${entry.key}', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(entry.key),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SyncDiagnosticsSheet(
              status: SyncStatus(
                phase: SyncPhase.failure,
                lastRun: SyncRunResult([
                  SyncStageResult(
                    stageId: 'pull.schedules',
                    outcome: SyncComponentOutcome.failed(
                      safeErrorCode: 'SCHEDULE_TIMEZONE_REVIEW_REQUIRED',
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('pull.schedules'));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      expect(
        find.textContaining('SCHEDULE_TIMEZONE_REVIEW_REQUIRED'),
        findsNothing,
      );
    });
  }

  for (final entry in const {
    'en':
        'The saved connection needs attention. Review it and sign in to the same account if asked.',
    'ro':
        'Conexiunea salvată necesită atenție. Verific-o și conectează-te la același cont dacă ți se cere.',
  }.entries) {
    testWidgets('explains a locally blocked sync in ${entry.key}', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(entry.key),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SyncDiagnosticsSheet(
              status: SyncStatus(
                phase: SyncPhase.failure,
                lastError: 'CLIENT_CONNECTION_ACCESS_UNAVAILABLE',
                lastRun: SyncRunResult([
                  SyncStageResult(
                    stageId: 'pull.pull',
                    outcome: SyncComponentOutcome.failed(
                      safeErrorCode: 'CLIENT_CONNECTION_ACCESS_UNAVAILABLE',
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('pull.pull'));
      await tester.pumpAndSettle();

      expect(find.text(entry.value), findsWidgets);
      expect(
        find.textContaining('CLIENT_CONNECTION_ACCESS_UNAVAILABLE'),
        findsNothing,
      );
    });
  }

  testWidgets('offers reauthentication instead of a futile sync retry', (
    tester,
  ) async {
    var reconnectRequested = false;
    var retryRequested = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SyncDiagnosticsSheet(
            status: const SyncStatus(
              phase: SyncPhase.failure,
              lastError: 'CLIENT_CONNECTION_ACCESS_UNAVAILABLE',
              lastRun: SyncRunResult([
                SyncStageResult(
                  stageId: 'pull.account',
                  outcome: SyncComponentOutcome.failed(
                    safeErrorCode: 'CLIENT_CONNECTION_ACCESS_UNAVAILABLE',
                  ),
                ),
              ]),
            ),
            onRetry: () async => retryRequested = true,
            onReconnect: () async => reconnectRequested = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Review connection'), findsOneWidget);
    expect(find.text('Retry sync'), findsNothing);
    await tester.tap(find.text('Review connection'));
    await tester.pumpAndSettle();
    expect(reconnectRequested, isTrue);
    expect(retryRequested, isFalse);
  });

  test('sync headlines map to tones', () {
    expect(syncHeadlineTone(SyncHeadlineState.synced), StatusTone.good);
    expect(syncHeadlineTone(SyncHeadlineState.syncing), StatusTone.working);
    expect(
      syncHeadlineTone(SyncHeadlineState.notYetSynced),
      StatusTone.neutral,
    );
    // Waiting work is worth a look, not an alarm.
    for (final state in [
      SyncHeadlineState.offline,
      SyncHeadlineState.needsReview,
      SyncHeadlineState.partiallySynced,
    ]) {
      expect(syncHeadlineTone(state), StatusTone.attention, reason: '$state');
    }
    for (final state in [
      SyncHeadlineState.couldNotSync,
      SyncHeadlineState.updateRequired,
    ]) {
      expect(syncHeadlineTone(state), StatusTone.problem, reason: '$state');
    }
  });
}
