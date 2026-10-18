import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/diagnostics/report/diagnostic_report.dart';
import 'package:simpastil/core/startup/optional_capability.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/sync_status_notifier.dart';
import 'package:simpastil/features/report/report_sources.dart';

void main() {
  final now = DateTime.utc(2026, 10, 18, 14);

  group('reportSyncFrom', () {
    test('a phone without a server says so and carries nothing else', () {
      final sync = reportSyncFrom(
        SyncStatus(
          lastError: 'https://sync.example.org said no',
          lastSuccessAt: now,
        ),
        connected: false,
        now: now,
      );
      expect(sync.connected, isFalse);
      expect(sync.state, isNull);
      expect(sync.stages, isEmpty);
      final text = DiagnosticReport(createdAt: now, sync: sync).toText();
      expect(text, isNot(contains('example.org')));
    });

    test('a failed run keeps its steps, codes and request identifiers', () {
      final sync = reportSyncFrom(
        SyncStatus(
          phase: SyncPhase.failure,
          lastSuccessAt: now.subtract(const Duration(hours: 5)),
          pendingCount: 3,
          lastRun: const SyncRunResult([
            SyncStageResult(
              stageId: 'flush.account',
              outcome: SyncComponentOutcome.failed(
                safeErrorCode: 'SYNC_STAGE_FAILED',
                safeCorrelationId: '0f4d4d92-6a6a-4f4e-8d2e-5c9a6a2b7f10',
                httpStatusCode: 500,
                retryCount: 1,
                duration: Duration(milliseconds: 1400),
              ),
            ),
            SyncStageResult(
              stageId: 'pull.stable',
              outcome: SyncComponentOutcome.succeeded(),
            ),
          ]),
        ),
        connected: true,
        now: now,
      );
      final text = DiagnosticReport(createdAt: now, sync: sync).toText();
      expect(text, contains('connected: yes'));
      expect(text, contains('status: partiallySynced'));
      expect(text, contains('last-success: 1-6h'));
      expect(text, contains('pending: 2-5'));
      expect(
        text,
        contains(
          'stage: flush.account failed code=SYNC_STAGE_FAILED http=500 '
          'retries=1 took=1-5s corr=0f4d4d92-6a6a-4f4e-8d2e-5c9a6a2b7f10',
        ),
      );
      expect(text, contains('stage: pull.stable succeeded'));
    });

    test('a sync that never succeeded says so instead of guessing', () {
      final text = DiagnosticReport(
        createdAt: now,
        sync: reportSyncFrom(const SyncStatus(), connected: true, now: now),
      ).toText();
      expect(text, contains('last-success: unavailable'));
      expect(text, contains('status: notYetSynced'));
    });
  });

  group('reportCapabilitiesFrom', () {
    test('keeps the id, phase and failure type but not the label', () {
      final capabilities = reportCapabilitiesFrom(
        const OptionalCapabilityState({
          'widget': OptionalCapabilityStatus(
            id: 'widget',
            label: "Maria's home screen widget",
            phase: OptionalCapabilityPhase.degraded,
            failureType: 'PlatformException',
          ),
          'notifications': OptionalCapabilityStatus(
            id: 'notifications',
            label: 'Reminders',
            phase: OptionalCapabilityPhase.ready,
          ),
        }),
      );
      final text = DiagnosticReport(
        createdAt: now,
        capabilities: capabilities,
      ).toText();
      expect(text, contains('feature: widget degraded type=PlatformException'));
      expect(text, contains('feature: notifications ready'));
      expect(text, isNot(contains('Maria')));
    });
  });
}
