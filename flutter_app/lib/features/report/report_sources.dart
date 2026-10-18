import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/diagnostics/report/data_report_source.dart';
import '../../core/diagnostics/report/diagnostic_report.dart';
import '../../core/diagnostics/report/platform_report_sources.dart';
import '../../core/diagnostics/report/report_collector.dart';
import '../../core/medication/care_sharing_provider.dart';
import '../../core/startup/optional_capability.dart';
import '../../core/sync/sync_models.dart';
import '../../core/sync/sync_status_notifier.dart';
import '../settings/presentation/sync_diagnostics_sheet.dart';

/// Turns the app's sync status into the few safe facts the report keeps:
/// a state word, rough ages and counts, and each step of the last run with its
/// error code and request identifier. The server address and the account are
/// never part of [SyncStatus], and are not read here.
ReportSync reportSyncFrom(
  SyncStatus status, {
  required bool connected,
  DateTime? now,
}) {
  if (!connected) return ReportSync(connected: false);
  final lastSuccess = status.lastSuccessAt;
  return ReportSync(
    connected: true,
    state: syncHeadlineState(status).name,
    sinceSuccess: lastSuccess == null
        ? null
        : (now ?? DateTime.now()).difference(lastSuccess),
    pending: status.pendingCount,
    needAttention: status.counts.needsAttention,
    stages: [
      for (final stage in status.lastRun?.stages ?? const <SyncStageResult>[])
        ReportSyncStage(
          id: stage.stageId,
          status: stage.outcome.status.name,
          code: stage.outcome.safeErrorCode,
          httpStatus: stage.outcome.httpStatusCode,
          retries: stage.outcome.retryCount,
          took: stage.outcome.duration,
          correlationId: stage.outcome.safeCorrelationId,
        ),
    ],
  );
}

/// The optional features and whether each one started, without their labels
/// (which are text for people, not facts for a maintainer).
List<ReportCapability> reportCapabilitiesFrom(OptionalCapabilityState state) =>
    [
      for (final capability in state.capabilities.values)
        ReportCapability(
          id: capability.id,
          phase: capability.phase.name,
          failureType: capability.failureType,
        ),
    ];

/// Every report source the running app can offer: the phone's own facts plus
/// what the database and the sync and capability state know.
///
/// Reads happen through [container] when the report is built, so the screen
/// shows the state at that moment and a provider that fails costs only its
/// own section.
ReportSources appReportSources(
  ProviderContainer container, {
  required ReportScreen screen,
  required String language,
}) {
  return platformReportSources(screen: screen, language: language).merge(
    ReportSources(
      data: () => readDataFacts(container.read(databaseProvider)),
      sync: () async {
        // The provider disposes itself when nobody listens, so hold it while
        // the first value loads.
        final subscription = container.listen(
          careSharingStatusProvider,
          (_, _) {},
        );
        try {
          final care = await container.read(careSharingStatusProvider.future);
          return reportSyncFrom(
            container.read(syncStatusProvider),
            connected: !care.isLocalOnly,
          );
        } finally {
          subscription.close();
        }
      },
      capabilities: () async =>
          reportCapabilitiesFrom(container.read(optionalCapabilityProvider)),
    ),
  );
}
