import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/sync/sync_models.dart';
import '../../../core/sync/sync_status_notifier.dart';
import '../../../l10n/app_localizations.dart';

enum SyncHeadlineState {
  notYetSynced,
  synced,
  partiallySynced,
  needsReview,
  couldNotSync,
  offline,
  updateRequired,
  syncing,
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

SyncHeadlineState syncHeadlineState(SyncStatus status, {int reviewCount = 0}) {
  if (status.phase == SyncPhase.syncing) return SyncHeadlineState.syncing;
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
  if (status.lastError == 'You appear to be offline' ||
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
  if (state == SyncHeadlineState.synced) return l.settings_synced;
  if (state == SyncHeadlineState.syncing) return l.settings_syncing;
  final isRomanian = Localizations.localeOf(context).languageCode == 'ro';
  return switch ((state, isRomanian)) {
    (SyncHeadlineState.notYetSynced, false) => 'Not synced yet',
    (SyncHeadlineState.notYetSynced, true) => 'Încă nesincronizat',
    (SyncHeadlineState.needsReview, false) => 'Review needed',
    (SyncHeadlineState.needsReview, true) => 'Este necesară revizuirea',
    (SyncHeadlineState.partiallySynced, false) => 'Partially synced',
    (SyncHeadlineState.partiallySynced, true) => 'Sincronizat parțial',
    (SyncHeadlineState.couldNotSync, false) => "Couldn't sync",
    (SyncHeadlineState.couldNotSync, true) => 'Nu s-a putut sincroniza',
    (SyncHeadlineState.offline, false) => 'Offline',
    (SyncHeadlineState.offline, true) => 'Fără conexiune',
    (SyncHeadlineState.updateRequired, false) => 'Update required',
    (SyncHeadlineState.updateRequired, true) => 'Este necesară actualizarea',
    _ => l.settings_syncFailing,
  };
}

Future<void> showSyncDiagnosticsSheet({
  required BuildContext context,
  required SyncStatus status,
  int reviewCount = 0,
  Future<void> Function()? onRetry,
  Future<void> Function()? onReconnect,
  Future<void> Function()? onFix,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => SyncDiagnosticsSheet(
    status: status,
    reviewCount: reviewCount,
    onRetry: onRetry,
    onReconnect: onReconnect,
    onFix: onFix,
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
  });

  final SyncStatus status;
  final int reviewCount;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onReconnect;

  /// Opens "Fix sync problems"; offered only while changes need a person.
  final Future<void> Function()? onFix;

  @override
  Widget build(BuildContext context) {
    final languageCode = Localizations.localeOf(context).languageCode;
    final isRomanian = languageCode == 'ro';
    final stages = status.lastRun?.stages ?? const <SyncStageResult>[];
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
              isRomanian ? 'Detalii sincronizare' : 'Sync details',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              syncHeadlineLabel(
                context,
                syncHeadlineState(status, reviewCount: reviewCount),
              ),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (safeStatusMessage != null) ...[
              const SizedBox(height: 6),
              Text(safeStatusMessage),
            ],
            if (lastSuccess != null) ...[
              const SizedBox(height: 6),
              Text(
                '${isRomanian ? 'Ultima conexiune reușită' : 'Last successful sync connection'}: '
                '${DateFormat('yyyy-MM-dd HH:mm:ss', languageCode).format(lastSuccess.toLocal())}',
              ),
            ],
            const SizedBox(height: 12),
            if (stages.isEmpty)
              Text(
                isRomanian
                    ? 'Detaliile componentelor nu sunt disponibile încă.'
                    : 'Component details are not available yet.',
              )
            else
              ...stages.map(
                (stage) => _StageDisclosure(
                  stage: stage,
                  isRomanian: isRomanian,
                  languageCode: languageCode,
                ),
              ),
            if (_requiresConnectionSignIn(status) && onReconnect != null) ...[
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
                  label: Text(isRomanian ? 'Încearcă din nou' : 'Retry sync'),
                ),
              ],
            ] else if (onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => onRetry!.call(),
                icon: const Icon(Icons.sync),
                label: Text(isRomanian ? 'Încearcă din nou' : 'Retry sync'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StageDisclosure extends StatelessWidget {
  const _StageDisclosure({
    required this.stage,
    required this.isRomanian,
    required this.languageCode,
  });

  final SyncStageResult stage;
  final bool isRomanian;
  final String languageCode;

  @override
  Widget build(BuildContext context) {
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
            isRomanian ? 'Cauză' : 'Cause',
            code == 'SCHEDULE_TIMEZONE_REVIEW_REQUIRED'
                ? AppLocalizations.of(
                    context,
                  ).sync_scheduleTimezoneReviewRequired
                : code == 'CLIENT_CONNECTION_ACCESS_UNAVAILABLE'
                ? AppLocalizations.of(context).sync_connectionAccessUnavailable
                : code,
          ),
        if (outcome.httpStatusCode != null)
          _detailRow(
            isRomanian ? 'Cod HTTP' : 'HTTP status',
            '${outcome.httpStatusCode}',
          ),
        if (completedAt != null)
          _detailRow(
            isRomanian ? 'Finalizat' : 'Completed',
            DateFormat(
              'yyyy-MM-dd HH:mm:ss',
              languageCode,
            ).format(completedAt.toLocal()),
          ),
        if (outcome.duration != null)
          _detailRow(
            isRomanian ? 'Durată' : 'Duration',
            '${outcome.duration!.inMilliseconds.clamp(0, 3600000)} ms',
          ),
        _detailRow(
          isRomanian ? 'Reîncercări' : 'Retries',
          outcome.retryCount == null
              ? (isRomanian ? 'Neraportate' : 'Not reported')
              : '${outcome.retryCount}',
        ),
        if (correlationId != null &&
            RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
              caseSensitive: false,
            ).hasMatch(correlationId))
          _detailRow(
            isRomanian ? 'Identificator corelare' : 'Correlation ID',
            correlationId,
            selectable: true,
          ),
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

String? localizedSyncErrorMessage(BuildContext context, String? message) {
  final isRomanian = Localizations.localeOf(context).languageCode == 'ro';
  return switch (message) {
    'CLIENT_CONNECTION_ACCESS_UNAVAILABLE' => AppLocalizations.of(
      context,
    ).sync_connectionAccessUnavailable,
    'You appear to be offline' =>
      isRomanian ? 'Fără conexiune la internet' : 'You appear to be offline',
    'Connection timed out' =>
      isRomanian ? 'Conexiunea a expirat' : 'Connection timed out',
    'Server error' => isRomanian ? 'Eroare de server' : 'Server error',
    'Sync failed' => isRomanian ? 'Sincronizare eșuată' : 'Sync failed',
    "Couldn't reach the server" =>
      isRomanian
          ? 'Serverul nu a putut fi contactat'
          : "Couldn't reach the server",
    _ => null,
  };
}
