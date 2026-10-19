import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/sync/sync_error_classifier.dart';
import '../../../core/sync/sync_models.dart';
import '../../../core/sync/sync_status_notifier.dart';
import '../../../l10n/app_localizations.dart';
import '../../report/report_screen.dart';

enum SyncHeadlineState {
  notYetSynced,
  synced,
  partiallySynced,
  needsReview,
  couldNotSync,
  offline,
  updateRequired,
  syncing,

  /// A connection met a different server key than the pinned one.
  serverKeyChanged,
}

const _safeSyncErrorCodes = {
  'AUTH_REQUIRED',
  'BRIDGE_CANNOT_REPRESENT_PENDING_STATE',
  'CLIENT_UPGRADE_REQUIRED',
  'CLIENT_CONNECTION_ACCESS_UNAVAILABLE',
  'CONFLICT_REVISION',
  'CONFLICT_STALE_UPDATE',
  'CONTRACT_NOT_ACTIVE',
  'INVENTORY_COMMAND_REQUIRES_ACTIVE_LEDGER',
  'MEDICATION_AUTHORITY_UNAVAILABLE',
  'MEDICATION_BRIDGE_REQUIRED',
  'MEDICATION_BRIDGE_RESULT_UNCERTAIN',
  'MEDICATION_BRIDGE_REQUEST_IDENTITY_MISMATCH',
  'MEDICATION_BRIDGE_REQUEST_EVIDENCE_REQUIRED',
  'MEDICATION_PARENT_NOT_MAPPED',
  'MEDICATION_RECONCILIATION_REQUIRED',
  'SCHEDULE_MIGRATION_REVIEW_REQUIRED',
  'SCHEDULE_TIMEZONE_REVIEW_REQUIRED',
  'SPLIT_EFFECT_REQUIRES_RECONCILIATION',
  'SPLIT_RECONCILIATION_REQUIRED',
  'SPLIT_RECONCILIATION_RECEIPT_MISMATCH',
  'SPLIT_REVIEW_REQUIRED',
  'STABLE_MUTATION_AUTHORITY_UNAVAILABLE',
  'SYNC_DEPENDENCY_FAILED',
  'SYNC_OFFLINE',
  'SYNC_STAGE_FAILED',
  'SERVER_CAPABILITIES_UNAVAILABLE',
};

bool _requiresConnectionSignIn(SyncStatus status) =>
    status.lastError == 'CLIENT_CONNECTION_ACCESS_UNAVAILABLE' ||
    status.lastRun?.stages.any(
          (stage) =>
              stage.outcome.safeErrorCode ==
              'CLIENT_CONNECTION_ACCESS_UNAVAILABLE',
        ) ==
        true;

SyncHeadlineState syncHeadlineState(
  SyncStatus status, {
  int reviewCount = 0,
  bool serverKeyChanged = false,
}) {
  if (status.phase == SyncPhase.syncing) return SyncHeadlineState.syncing;
  // Nothing can sync while the server's key is wrong, whatever else is true.
  if (serverKeyChanged ||
      normalizeSyncErrorCode(status.lastError) ==
          SyncErrorCode.serverKeyChanged) {
    return SyncHeadlineState.serverKeyChanged;
  }
  final outcomes = status.lastRun?.stages
      .map((stage) => stage.outcome)
      .toList(growable: false);
  if (outcomes?.any(
        (outcome) =>
            outcome.httpStatusCode == 426 ||
            outcome.safeErrorCode == 'CLIENT_UPGRADE_REQUIRED',
      ) ??
      false) {
    return SyncHeadlineState.updateRequired;
  }
  if (normalizeSyncErrorCode(status.lastError) == SyncErrorCode.offline ||
      outcomes?.any((outcome) => outcome.safeErrorCode == 'SYNC_OFFLINE') ==
          true) {
    return SyncHeadlineState.offline;
  }
  // Changes that cannot go out without a person are never "synced", whatever
  // the last run said.
  if (status.needsAttention) return SyncHeadlineState.needsReview;
  if (status.lastRun?.status == SyncRunStatus.partiallySynced ||
      outcomes?.any(
            (outcome) =>
                outcome.status == SyncComponentStatus.partiallySynced ||
                outcome.status == SyncComponentStatus.blocked,
          ) ==
          true) {
    return SyncHeadlineState.partiallySynced;
  }
  if (status.phase == SyncPhase.failure ||
      status.lastRun?.status == SyncRunStatus.failed) {
    return SyncHeadlineState.couldNotSync;
  }
  if (reviewCount > 0) return SyncHeadlineState.needsReview;
  if (status.pendingCount > 0) return SyncHeadlineState.partiallySynced;
  if (status.lastSuccessAt == null &&
      status.lastRun?.status != SyncRunStatus.succeeded) {
    return SyncHeadlineState.notYetSynced;
  }
  return SyncHeadlineState.synced;
}

String syncHeadlineLabel(BuildContext context, SyncHeadlineState state) {
  final l = AppLocalizations.of(context);
  return switch (state) {
    SyncHeadlineState.notYetSynced => l.sync_headlineNotYet,
    SyncHeadlineState.needsReview => l.sync_headlineReview,
    SyncHeadlineState.partiallySynced => l.sync_headlinePartial,
    SyncHeadlineState.couldNotSync => l.sync_headlineCouldNot,
    SyncHeadlineState.offline => l.sync_headlineOffline,
    SyncHeadlineState.updateRequired => l.sync_headlineUpdate,
    SyncHeadlineState.serverKeyChanged => l.pin_changedTitle,
    SyncHeadlineState.synced || SyncHeadlineState.syncing =>
      state == SyncHeadlineState.synced
          ? l.settings_synced
          : l.settings_syncing,
  };
}

Future<void> showSyncDiagnosticsSheet({
  required BuildContext context,
  required SyncStatus status,
  int reviewCount = 0,
  Future<void> Function()? onRetry,
  Future<void> Function()? onReconnect,
  Future<void> Function()? onFix,
  bool serverKeyChanged = false,
  Future<void> Function()? onReviewServerKey,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (sheetContext) => SyncDiagnosticsSheet(
    status: status,
    reviewCount: reviewCount,
    onRetry: onRetry,
    onReconnect: onReconnect,
    onFix: onFix,
    serverKeyChanged: serverKeyChanged,
    onReviewServerKey: onReviewServerKey,
    // The report opens above the sheet, so going back returns to the details.
    onReport: () => unawaited(openReportProblem(sheetContext)),
  ),
);

class SyncDiagnosticsSheet extends StatelessWidget {
  const SyncDiagnosticsSheet({
    super.key,
    required this.status,
    this.reviewCount = 0,
    this.onRetry,
    this.onReconnect,
    this.onFix,
    this.onReport,
    this.serverKeyChanged = false,
    this.onReviewServerKey,
  });

  final SyncStatus status;
  final int reviewCount;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onReconnect;

  /// Opens "Fix sync problems"; offered only while changes need a person.
  final Future<void> Function()? onFix;

  /// The server presented a different key than the pinned one.
  final bool serverKeyChanged;

  /// Opens the key-changed screen; offered only while the key is wrong.
  final Future<void> Function()? onReviewServerKey;

  /// Opens the problem report; offered only while something is wrong.
  final VoidCallback? onReport;

  @override
  Widget build(BuildContext context) {
    final languageCode = Localizations.localeOf(context).languageCode;
    final l = AppLocalizations.of(context);
    final stages = status.lastRun?.stages ?? const <SyncStageResult>[];
    final headline = syncHeadlineState(
      status,
      reviewCount: reviewCount,
      serverKeyChanged: serverKeyChanged,
    );
    final lastSuccess = status.lastSuccessAt;
    final safeStatusMessage = localizedSyncErrorMessage(
      context,
      status.lastError,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l.sync_detailsTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              syncHeadlineLabel(context, headline),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (safeStatusMessage != null) ...[
              const SizedBox(height: 6),
              Text(safeStatusMessage),
            ],
            if (lastSuccess != null) ...[
              const SizedBox(height: 6),
              Text(
                '${l.sync_lastConnection}: '
                '${DateFormat('yyyy-MM-dd HH:mm:ss', languageCode).format(lastSuccess.toLocal())}',
              ),
            ],
            const SizedBox(height: 12),
            if (stages.isEmpty)
              Text(l.sync_noStageDetails)
            else
              ...stages.map(
                (stage) =>
                    _StageDisclosure(stage: stage, languageCode: languageCode),
              ),
            if (headline == SyncHeadlineState.serverKeyChanged &&
                onReviewServerKey != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const ValueKey('sync-sheet-review-key'),
                onPressed: () => onReviewServerKey!.call(),
                icon: const Icon(Icons.gpp_maybe_outlined),
                label: Text(l.pin_reviewAction),
              ),
            ] else if (_requiresConnectionSignIn(status) &&
                onReconnect != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => onReconnect!.call(),
                icon: const Icon(Icons.login),
                label: Text(AppLocalizations.of(context).sync_reviewConnection),
              ),
            ] else if (onFix != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const ValueKey('sync-sheet-fix'),
                onPressed: () => onFix!.call(),
                icon: const Icon(Icons.build_circle_outlined),
                label: Text(AppLocalizations.of(context).recovery_title),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => onRetry!.call(),
                  icon: const Icon(Icons.sync),
                  label: Text(l.sync_retry),
                ),
              ],
            ] else if (onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => onRetry!.call(),
                icon: const Icon(Icons.sync),
                label: Text(l.sync_retry),
              ),
            ],
            if (onReport != null && _isProblem(headline)) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                key: const ValueKey('sync-sheet-report'),
                onPressed: onReport,
                icon: const Icon(Icons.bug_report_outlined),
                label: Text(AppLocalizations.of(context).report_syncAction),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// A problem worth reporting: not just offline, not yet synced or waiting
  /// for an app update, which the person can fix without a maintainer.
  static bool _isProblem(SyncHeadlineState state) =>
      state == SyncHeadlineState.partiallySynced ||
      state == SyncHeadlineState.needsReview ||
      state == SyncHeadlineState.couldNotSync;
}

class _StageDisclosure extends StatelessWidget {
  const _StageDisclosure({required this.stage, required this.languageCode});

  final SyncStageResult stage;
  final String languageCode;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final outcome = stage.outcome;
    final completedAt = outcome.completedAt;
    final rawCode = outcome.safeErrorCode;
    final code = rawCode == null
        ? null
        : _safeSyncErrorCodes.contains(rawCode)
        ? rawCode
        : 'SYNC_STAGE_FAILED';
    final correlationId = outcome.safeCorrelationId;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text('${stage.stageId} · ${outcome.status.name}'),
      childrenPadding: const EdgeInsets.only(left: 16, bottom: 12),
      children: [
        if (code != null && RegExp(r'^[A-Z][A-Z0-9_]{0,63}$').hasMatch(code))
          _detailRow(
            l.sync_detailCause,
            code == 'SCHEDULE_TIMEZONE_REVIEW_REQUIRED'
                ? AppLocalizations.of(
                    context,
                  ).sync_scheduleTimezoneReviewRequired
                : code == 'CLIENT_CONNECTION_ACCESS_UNAVAILABLE'
                ? AppLocalizations.of(context).sync_connectionAccessUnavailable
                : code,
          ),
        if (outcome.httpStatusCode != null)
          _detailRow(l.sync_detailHttp, '${outcome.httpStatusCode}'),
        if (completedAt != null)
          _detailRow(
            l.sync_detailCompleted,
            DateFormat(
              'yyyy-MM-dd HH:mm:ss',
              languageCode,
            ).format(completedAt.toLocal()),
          ),
        if (outcome.duration != null)
          _detailRow(
            l.sync_detailDuration,
            '${outcome.duration!.inMilliseconds.clamp(0, 3600000)} ms',
          ),
        _detailRow(
          l.sync_detailRetries,
          outcome.retryCount == null
              ? l.sync_detailNotReported
              : '${outcome.retryCount}',
        ),
        if (correlationId != null &&
            RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
              caseSensitive: false,
            ).hasMatch(correlationId))
          _detailRow(l.sync_detailCorrelation, correlationId, selectable: true),
      ],
    );
  }

  Widget _detailRow(String label, String value, {bool selectable = false}) =>
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 130, child: Text(label)),
            Expanded(child: selectable ? SelectableText(value) : Text(value)),
          ],
        ),
      );
}

/// The words for a stored sync failure code, in the current language. Values
/// stored by earlier releases (English sentences) read as their code.
String? localizedSyncErrorMessage(BuildContext context, String? message) {
  final l = AppLocalizations.of(context);
  return switch (normalizeSyncErrorCode(message)) {
    'CLIENT_CONNECTION_ACCESS_UNAVAILABLE' =>
      l.sync_connectionAccessUnavailable,
    SyncErrorCode.offline => l.sync_errorOffline,
    SyncErrorCode.timedOut => l.sync_errorTimeout,
    SyncErrorCode.serverError => l.sync_errorServer,
    SyncErrorCode.failed => l.sync_errorFailed,
    SyncErrorCode.serverUnreachable => l.sync_errorUnreachable,
    SyncErrorCode.serverKeyChanged => l.sync_errorKeyChanged,
    _ => null,
  };
}
