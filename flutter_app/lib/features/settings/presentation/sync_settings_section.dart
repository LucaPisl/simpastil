import 'dart:async';

import '../../../core/medication/care_sharing_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/errors/app_error.dart';
import '../../../core/db/database.dart';

import '../../../shared/layouts/window_size.dart';
import '../../../shared/widgets/review_failure_message.dart';
import '../../../core/network/server_pin_controller.dart';
import '../../../core/sync/auto_sync_service.dart';
import '../../../core/sync/schedule_review_target.dart';
import '../../../core/sync/sync_status_notifier.dart';
import 'settings_overview.dart';
import 'settings_pane.dart';
import '../../../l10n/app_localizations.dart';
import '../../dashboard/care_record_form.dart';
import '../../profiles/profile_provider.dart';
import '../migration_issue_provider.dart';
import 'sync_diagnostics_sheet.dart';
import 'sync_recovery_screen.dart';
import 'legacy_routine_review_screen.dart';
import 'medication_amount_review_screen.dart';
import '../../pills/presentation/add_edit_schedule_sheet.dart';

import '../../../shared/motion/app_motion.dart';
import '../../../shared/format/clock.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/motion/staggered_entrance.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/status_chip.dart';
import '../../../core/server/server_config_notifier.dart';
import '../../auth/presentation/server_certificate_review.dart';
import '../../auth/presentation/server_key_changed_screen.dart';

class SyncSettingsSection extends ConsumerStatefulWidget {
  const SyncSettingsSection({super.key, this.now});

  /// The current time for "Last synced"; tests pass a controllable one.
  final DateTime Function()? now;
  @override
  ConsumerState<SyncSettingsSection> createState() =>
      _SyncSettingsSectionState();
}

class _SyncSettingsSectionState extends ConsumerState<SyncSettingsSection>
    with WidgetsBindingObserver {
  String? _lastSyncAt;
  bool _syncInProgress = false;

  /// Rebuilds once a minute so "Last synced" keeps counting while the page is
  /// open. Only runs while the app is in the foreground.
  Timer? _ticker;

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTicker();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadPrefs();
      // A background sync may have met a different server key while the app
      // was away; the stored record is the only place it left a trace.
      ref.read(serverPinControllerProvider.notifier).refresh();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  /// A sync that finished while the app was in the background left its time
  /// only in the stored preferences.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startTicker();
      _loadPrefs();
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      // The background task writes from another isolate; this copy would not
      // show it otherwise.
      await prefs.reload();
    } on Object {
      // An older "last synced" until the next sync is the worst outcome.
    }
    if (!mounted) return;
    setState(() {
      _lastSyncAt = prefs.getString('last_sync_at');
    });
  }

  /// The newest finished sync, whichever isolate recorded it.
  String? _latestSyncAt(SyncStatus status) {
    final live = status.lastSuccessAt;
    final stored = DateTime.tryParse(_lastSyncAt ?? '');
    if (live == null) return _lastSyncAt;
    if (stored != null && stored.isAfter(live)) return _lastSyncAt;
    return live.toIso8601String();
  }

  Future<void> _syncNow() async {
    setState(() => _syncInProgress = true);
    try {
      final userId = ref.read(currentUserIdProvider);
      await ref.read(autoSyncServiceProvider).syncNow(userId);
      if (!mounted) return;
      // Invalidate providers to reflect fresh data
      ref.invalidate(profileListProvider);
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() => _lastSyncAt = prefs.getString('last_sync_at'));
      final l = AppLocalizations.of(context);
      final status = ref.read(syncStatusProvider);
      final errorMessage =
          localizedSyncErrorMessage(context, status.lastError) ??
          status.lastError ??
          '';
      final text = switch (status.phase) {
        SyncPhase.syncing => l.settings_syncAlreadyInProgress,
        SyncPhase.failure => l.settings_syncFailedError(errorMessage),
        SyncPhase.idle => l.settings_syncComplete,
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    } catch (_) {
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.shared_syncFailed)));
    } finally {
      if (mounted) setState(() => _syncInProgress = false);
    }
  }

  bool get _serverKeyChanged =>
      ref.read(serverPinControllerProvider).value?.hasMismatch ?? false;

  bool get _certificateRejected {
    final state = ref.read(serverPinControllerProvider).value;
    return (state?.certificateRejected ?? false) &&
        !(state?.hasMismatch ?? false);
  }

  /// A server that was never pinned and now fails certificate checking: the
  /// same fingerprint check as the first connect, then a sync.
  Future<void> _reviewCertificate() async {
    final url = ref.read(serverConfigProvider);
    if (url == null) return;
    await reviewServerCertificate(context, ref, url, syncAfter: true);
    if (mounted) ref.read(serverPinControllerProvider.notifier).refresh();
  }

  Future<void> _openServerKey() async {
    await openServerKeyReview(context);
    if (mounted) ref.read(serverPinControllerProvider.notifier).refresh();
  }

  Future<void> _showSyncDiagnostics(SyncStatus status) async {
    final reviewState = ref.read(migrationIssuesProvider);
    await showSyncDiagnosticsSheet(
      context: context,
      status: status,
      reviewCount: !reviewState.isLoading && !reviewState.hasError
          ? reviewState.asData?.value
                    .where((issue) => issue.asksForReview)
                    .length ??
                0
          : 0,
      onRetry: () async {
        Navigator.of(context).pop();
        await _syncNow();
      },
      onReconnect: () async {
        Navigator.of(context).pop();
        if (mounted) await context.push<void>('/login');
      },
      serverKeyChanged: _serverKeyChanged,
      certificateRejected: _certificateRejected,
      onReviewServerKey: () async {
        Navigator.of(context).pop();
        if (!mounted) return;
        if (_serverKeyChanged) {
          await _openServerKey();
        } else {
          await _reviewCertificate();
        }
      },
      onFix: status.needsAttention
          ? () async {
              Navigator.of(context).pop();
              if (mounted) await openSyncRecovery(context);
            }
          : null,
    );
  }

  String _reviewIssueTitle(MigrationIssueSummary issue) {
    final isRomanian = Localizations.localeOf(context).languageCode == 'ro';
    if (issue.localDose != null) return issue.localDose!.medicationName;
    return switch (issue.kind) {
      MigrationIssueKind.schedule =>
        isRomanian
            ? 'Un program necesită revizuire'
            : 'A schedule needs review',
      MigrationIssueKind.medication =>
        isRomanian
            ? 'O actualizare a medicamentului necesită revizuire'
            : 'A medication update needs review',
      MigrationIssueKind.other =>
        isRomanian
            ? 'O modificare necesită revizuire'
            : 'A change needs review',
    };
  }

  Future<void> _openScheduleRepair(MigrationIssueSummary issue) async {
    final db = ref.read(databaseProvider);
    final target = await scheduleReviewTarget(
      db,
      issue.entityId,
      ref.read(currentUserIdProvider),
    );
    if (!mounted) return;
    if (target == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            reviewFailureMessage(
              AppLocalizations.of(context),
              const NotFoundError(),
            ),
          ),
        ),
      );
      return;
    }
    final schedule = target.schedule;
    await showAddEditScheduleSheet(
      context: context,
      pillId: schedule.pillId,
      pillIsPrn: target.pill.isPrn,
      schedule: schedule,
      repairIssueId: issue.id,
      repairIssueRevision: issue.revision,
      repairIssueCode: issue.issueCode,
    );
  }

  Future<void> _reviewMedicationIssue(MigrationIssueSummary issue) async {
    final isRomanian = Localizations.localeOf(context).languageCode == 'ro';
    final disposition = await showDialog<MedicationIssueDisposition>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_reviewIssueTitle(issue)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (issue.localDose case final dose?) ...[
                Text(
                  isRomanian
                      ? 'Înregistrare pe acest dispozitiv'
                      : 'Record on this device',
                  style: Theme.of(dialogContext).textTheme.titleSmall,
                ),
                Text(clockDateTime(context, dose.scheduledAt.toLocal())),
                Text(
                  careOutcomeLabel(
                    AppLocalizations.of(context),
                    dose.localState,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  isRomanian
                      ? 'Această înregistrare locală nu dovedește că vechea trimitere a ajuns la server.'
                      : 'This local record does not prove that the older submission reached the server.',
                ),
              ] else if (issue.sourceKind == 'pill_stock') ...[
                Text(
                  isRomanian
                      ? 'Ultima stare sincronizată'
                      : 'Most recently synced state',
                ),
                Text(
                  issue.verifiedCurrentStock == null
                      ? (isRomanian
                            ? 'Stoc sincronizat: indisponibil'
                            : 'Synced stock: unavailable')
                      : (isRomanian
                            ? 'Stoc sincronizat: ${issue.verifiedCurrentStock}'
                            : 'Synced stock: ${issue.verifiedCurrentStock}'),
                ),
              ] else
                Text(
                  isRomanian
                      ? 'Rezultatul acestei trimiteri vechi nu poate fi stabilit din dovezile disponibile.'
                      : 'The result of this older submission cannot be established from the available evidence.',
                ),
              const SizedBox(height: 12),
              Text(
                isRomanian
                    ? 'Păstrarea stării serverului închide această revizuire fără a înregistra o doză sau a modifica stocul pe server. Istoricul partajat va urma starea serverului. Intenția salvată și dovezile originale sunt păstrate.'
                    : 'Keeping the server state closes this review without recording a dose or changing server stock. Shared history will follow the server state. Your saved intent and original evidence are retained.',
              ),
              if (issue.savedTargetStock != null) ...[
                const SizedBox(height: 12),
                Text(isRomanian ? 'Modificarea salvată' : 'Saved change'),
                Text(
                  isRomanian
                      ? 'Stoc țintă: ${issue.savedTargetStock}'
                      : 'Target stock: ${issue.savedTargetStock}',
                ),
              ],
              const SizedBox(height: 12),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  isRomanian ? 'Detalii tehnice' : 'Technical details',
                ),
                children: [
                  _issueDetailRow(isRomanian ? 'Cod' : 'Code', issue.issueCode),
                  _issueDetailRow(
                    isRomanian ? 'Revizie' : 'Revision',
                    '${issue.revision}',
                  ),
                  if (issue.checkpointReason != null)
                    _issueDetailRow(
                      isRomanian ? 'Motiv' : 'Reason',
                      issue.checkpointReason!,
                    ),
                  if (issue.observedBaseStock != null)
                    _issueDetailRow(
                      isRomanian
                          ? 'Stoc observat la bază'
                          : 'Observed base stock',
                      '${issue.observedBaseStock}',
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(AppLocalizations.of(dialogContext).shared_cancel),
          ),
          TextButton(
            onPressed: issue.canKeepServerState
                ? () => Navigator.of(
                    dialogContext,
                  ).pop(MedicationIssueDisposition.keepServerState)
                : null,
            child: Text(
              isRomanian ? 'Păstrează starea serverului' : 'Keep server state',
            ),
          ),
          if (issue.canApplySavedChange)
            FilledButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(MedicationIssueDisposition.applySavedChange),
              child: Text(
                isRomanian ? 'Aplică modificarea' : 'Apply saved change',
              ),
            ),
        ],
      ),
    );
    if (disposition == null || !mounted) return;
    try {
      await ref
          .read(migrationIssueResolutionRepositoryProvider)
          .resolveMedicationIssue(issue, disposition);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              reviewFailureMessage(AppLocalizations.of(context), error),
            ),
          ),
        );
      }
      return;
    }
    try {
      await ref
          .read(autoSyncServiceProvider)
          .syncNow(ref.read(currentUserIdProvider));
    } catch (_) {
      // The server accepted the choice; its acknowledgement still needs a pull.
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).review_choiceAccepted),
        ),
      );
    }
  }

  Widget _issueDetailRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 130, child: Text(label)),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );

  String _formatLastSync(String? isoString, AppLocalizations l) {
    if (isoString == null) return l.settings_never;
    try {
      final dt = DateTime.parse(isoString);
      final diff = (widget.now ?? DateTime.now)().difference(dt);
      if (diff.inMinutes < 1) return l.settings_justNow;
      if (diff.inMinutes < 60) return l.settings_minutesAgo(diff.inMinutes);
      if (diff.inHours < 24) return l.settings_hoursAgo(diff.inHours);
      return DateFormat(
        'd MMM yyyy, HH:mm',
        Localizations.localeOf(context).languageCode,
      ).format(dt);
    } catch (_) {
      return l.shared_unknown;
    }
  }

  String _syncStatusSubtitle(
    SyncStatus status,
    AppLocalizations l, {
    bool keyChanged = false,
  }) {
    final lines = <String>[];
    if (keyChanged) {
      lines.add(l.sync_errorKeyChanged);
      return lines.join('\n');
    }
    final errorMessage =
        localizedSyncErrorMessage(context, status.lastError) ??
        status.lastError ??
        '';
    switch (status.phase) {
      case SyncPhase.failure:
        final since = status.failingSince;
        final sinceText = since == null
            ? ''
            : clockAt(context, since.toLocal());
        lines.add(l.settings_failingSince(sinceText, errorMessage));
      case SyncPhase.syncing:
        lines.add(
          status.failingSince != null
              ? l.settings_retrying(errorMessage)
              : l.settings_syncInProgress,
        );
      case SyncPhase.idle:
        lines.add(_formatLastSync(_latestSyncAt(status), l));
    }
    final attention = status.counts.needsAttention;
    final retrying = status.counts.retrying;
    final waiting = status.counts.total > 0
        ? status.counts.queued
        : status.pendingCount;
    if (waiting > 0) lines.add(l.settings_changesWaiting(waiting));
    if (retrying > 0) lines.add(l.settings_changesRetrying(retrying));
    if (attention > 0) lines.add(l.settings_changesNeedAttention(attention));
    if (status.counts.awaitingLedger > 0) lines.add(l.sync_stockStaysOnPhone);
    return lines.join('\n');
  }

  Widget _reviewIssueTile(MigrationIssueSummary issue, AppLocalizations l) {
    final isRomanian = Localizations.localeOf(context).languageCode == 'ro';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(
            Icons.error_outline_rounded,
            color: statusToneColor(Theme.of(context), StatusTone.attention),
          ),
          title: Text(_reviewIssueTitle(issue)),
          subtitle: Text(
            issue.localDose != null
                ? '${clockDateTime(context, issue.localDose!.scheduledAt.toLocal())} · ${careOutcomeLabel(l, issue.localDose!.localState)}'
                : issue.canRepairSchedule || issue.canKeepServerState
                ? (isRomanian
                      ? 'Deschide pentru opțiunile de revizuire'
                      : 'Open to review the available choices')
                : issue.kind == MigrationIssueKind.other
                ? l.review_openRecovery
                : l.review_incompleteDetails,
          ),
          trailing:
              issue.canRepairSchedule ||
                  issue.canKeepServerState ||
                  issue.kind == MigrationIssueKind.other
              ? const Icon(Icons.chevron_right)
              : null,
          onTap: switch (issue.kind) {
            MigrationIssueKind.schedule when issue.canRepairSchedule =>
              () => _openScheduleRepair(issue),
            MigrationIssueKind.schedule => null,
            MigrationIssueKind.medication =>
              issue.canKeepServerState
                  ? () => _reviewMedicationIssue(issue)
                  : null,
            MigrationIssueKind.other => () => openSyncRecovery(context),
          },
        ),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            title: Text(isRomanian ? 'Detalii' : 'Details'),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            children: [
              _issueDetailRow(isRomanian ? 'Cod' : 'Code', issue.issueCode),
              _issueDetailRow(
                isRomanian ? 'Revizie' : 'Revision',
                '${issue.revision}',
              ),
              _issueDetailRow(
                isRomanian ? 'Semnalat' : 'Detected',
                DateFormat(
                  'yyyy-MM-dd HH:mm:ss',
                ).format(issue.createdAt.toLocal()),
              ),
              if (issue.checkpointReason != null)
                _issueDetailRow(
                  isRomanian ? 'Motiv' : 'Reason',
                  issue.checkpointReason!,
                ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final syncStatus = ref.watch(syncStatusProvider);
    // Any finished sync, here or in the background, moves "Last synced".
    ref.listen<SyncStatus>(syncStatusProvider, (previous, next) {
      if (previous?.lastSuccessAt != next.lastSuccessAt ||
          previous?.phase != next.phase) {
        _loadPrefs();
      }
    });
    final reviewState = ref.watch(migrationIssuesProvider);
    final reviewsReady = !reviewState.isLoading && !reviewState.hasError;
    final retainedIssues = reviewsReady
        ? reviewState.asData?.value ?? const <MigrationIssueSummary>[]
        : const <MigrationIssueSummary>[];
    final migrationIssues = retainedIssues
        .where((issue) => !issue.isHistoricalInformation)
        .toList();
    final historicalCount = retainedIssues
        .where(
          (issue) =>
              issue.retainedInformation ==
              RetainedSyncInformation.legacyHistory,
        )
        .length;
    final removedRecordCount = retainedIssues
        .where(
          (issue) => const {
            RetainedSyncInformation.retiredRoutine,
            RetainedSyncInformation.retiredStock,
            RetainedSyncInformation.missingRoutine,
          }.contains(issue.retainedInformation),
        )
        .length;
    final pinState = ref.watch(serverPinControllerProvider).value;
    final keyChanged = pinState?.hasMismatch ?? false;
    final certificateRejected =
        (pinState?.certificateRejected ?? false) && !keyChanged;
    final syncHeadline = syncHeadlineState(
      syncStatus,
      reviewCount: migrationIssues.where((i) => i.asksForReview).length,
      serverKeyChanged: keyChanged,
    );
    // Kept notes are listed in Fix sync problems, so its entry counts them.
    // Read-only: opening this page must not run the repair.
    final keptNotes = ref.watch(keptNotesCountProvider);
    final notesCount = keptNotes.asData?.value;
    final recoveryChecking =
        notesCount == null && syncStatus.counts.needsAttention == 0;
    final cs = Theme.of(context).colorScheme;
    // Only an established local-only workspace is "not connected"; while the
    // status is still loading we keep the normal control.
    final notConnected =
        ref.watch(careSharingStatusProvider).asData?.value.isLocalOnly == true;
    // Medicines carrying unreviewed original dosage text are review work like
    // any other, so they belong in this group rather than one medicine at a
    // time in Medications.
    final amountReviewCount = ref.watch(medicationAmountReviewCountProvider);
    final hasReviewGroup = migrationIssues.isNotEmpty || amountReviewCount > 0;
    return Scaffold(
      appBar: settingsDetailAppBar(context, SettingsSection.data.label(l)),
      body: ContentListView(
        maxWidth: settingsContentWidth(context),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          StaggeredEntrance(
            index: 0,
            identity: 'sync-hero',
            child: _SyncStatusHero(
              state: syncHeadline,
              label: syncHeadlineLabel(context, syncHeadline),
              detail: _syncStatusSubtitle(
                syncStatus,
                l,
                keyChanged: keyChanged,
              ),
              hint: l.r4_syncDetails,
              onTap: () => _showSyncDiagnostics(syncStatus),
            ),
          ),
          const SizedBox(height: 12),
          StaggeredEntrance(
            index: 1,
            identity: 'sync-now',
            child: FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: _syncInProgress || notConnected ? null : _syncNow,
              icon: _syncInProgress
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded),
              label: Text(l.settings_syncNow, textAlign: TextAlign.center),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 20),
            child: Text(
              notConnected ? l.r8_syncNotConnected : l.settings_syncNowSubtitle,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          if (keyChanged)
            SettingsGroup(
              label: l.pin_changedTitle,
              index: 1,
              identity: 'sync-server-key',
              children: [
                SettingsNavigationRow(
                  key: const ValueKey('sync-server-key-entry'),
                  icon: Icons.gpp_maybe_outlined,
                  title: l.pin_reviewAction,
                  onTap: _openServerKey,
                ),
              ],
            ),
          if (certificateRejected)
            SettingsGroup(
              label: l.pin_certRejectedTitle,
              index: 1,
              identity: 'sync-server-certificate',
              children: [
                CalmNotice(
                  key: const ValueKey('sync-server-certificate-note'),
                  tone: StatusTone.attention,
                  icon: Icons.gpp_maybe_outlined,
                  text: l.pin_certRejectedBody(
                    Uri.tryParse(ref.watch(serverConfigProvider) ?? '')?.host ??
                        '',
                  ),
                ),
                const SizedBox(height: 8),
                SettingsNavigationRow(
                  key: const ValueKey('sync-server-certificate-entry'),
                  icon: Icons.gpp_maybe_outlined,
                  title: l.pin_reviewAction,
                  onTap: _reviewCertificate,
                ),
              ],
            ),
          SettingsGroup(
            label: l.recovery_title,
            index: 1,
            identity: 'sync-recovery',
            children: [
              SettingsNavigationRow(
                key: const ValueKey('sync-recovery-entry'),
                icon: recoveryChecking
                    ? Icons.build_circle_outlined
                    : (syncStatus.counts.needsAttention > 0 ||
                          (notesCount ?? 0) > 0)
                    ? Icons.build_circle_outlined
                    : Icons.check_circle_outline_rounded,
                title: syncStatus.counts.needsAttention > 0
                    ? l.recovery_entryHint(syncStatus.counts.needsAttention)
                    : notesCount == null
                    ? l.recovery_entryChecking
                    : notesCount > 0
                    ? l.recovery_entryNotes(notesCount)
                    : l.recovery_entryHintNone,
                onTap: () => openSyncRecovery(context),
              ),
            ],
          ),
          const CareSharingSummary(detailed: true),
          if (!reviewsReady)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Material(
                color: cs.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  key: const ValueKey('sync-review-unavailable'),
                  leading: Icon(
                    reviewState.isLoading
                        ? Icons.hourglass_empty
                        : Icons.info_outline,
                  ),
                  title: Text(
                    reviewState.isLoading ? l.shared_loading : l.t15_loadFailed,
                  ),
                  subtitle: reviewState.hasError && !reviewState.isLoading
                      ? Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: TextButton(
                            onPressed: () =>
                                ref.invalidate(migrationIssuesProvider),
                            child: Text(l.shared_retry),
                          ),
                        )
                      : null,
                ),
              ),
            ),
          if (historicalCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: CalmNotice(
                text: l.sync_retainedHistory(historicalCount),
                icon: Icons.history_rounded,
                tone: StatusTone.neutral,
              ),
            ),
          if (removedRecordCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: CalmNotice(
                text: l.sync_retainedRemovedRecords(removedRecordCount),
                icon: Icons.inventory_2_outlined,
                tone: StatusTone.neutral,
              ),
            ),
          if (hasReviewGroup)
            SettingsGroup(
              label: l.r4_syncReviewGroup,
              index: 2,
              identity: 'sync-review',
              children: [
                if (amountReviewCount > 0)
                  ListTile(
                    key: const ValueKey('medication-amount-review-entry'),
                    leading: const Icon(Icons.straighten_rounded),
                    title: Text(l.amountReview_entry),
                    subtitle: Text(l.amountReview_entryHint(amountReviewCount)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const MedicationAmountReviewScreen(),
                      ),
                    ),
                  ),
                if (migrationIssues.any(
                  (issue) =>
                      issue.issueCode == 'schedule_timezone_review_required',
                ))
                  ListTile(
                    key: const ValueKey('legacy-routine-review-entry'),
                    leading: const Icon(Icons.schedule_outlined),
                    title: Text(l.legacyReview_entry),
                    subtitle: Text(l.legacyReview_entryHint),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const LegacyRoutineReviewScreen(),
                      ),
                    ),
                  ),
                for (final issue in migrationIssues) _reviewIssueTile(issue, l),
              ],
            ),
        ],
      ),
    );
  }
}

/// How each sync headline should feel. Waiting work (offline, review) asks
/// for attention, never alarm; only a real failure reads as a problem.
@visibleForTesting
StatusTone syncHeadlineTone(SyncHeadlineState state) => switch (state) {
  SyncHeadlineState.synced => StatusTone.good,
  SyncHeadlineState.syncing => StatusTone.working,
  SyncHeadlineState.notYetSynced => StatusTone.neutral,
  SyncHeadlineState.partiallySynced ||
  SyncHeadlineState.needsReview ||
  SyncHeadlineState.offline => StatusTone.attention,
  SyncHeadlineState.couldNotSync ||
  SyncHeadlineState.serverKeyChanged ||
  SyncHeadlineState.updateRequired => StatusTone.problem,
};

IconData _syncHeadlineIcon(SyncHeadlineState state) => switch (state) {
  SyncHeadlineState.notYetSynced => Icons.cloud_queue_rounded,
  SyncHeadlineState.syncing => Icons.cloud_sync_outlined,
  SyncHeadlineState.synced => Icons.cloud_done_outlined,
  SyncHeadlineState.needsReview ||
  SyncHeadlineState.partiallySynced => Icons.rule_rounded,
  SyncHeadlineState.updateRequired => Icons.system_update_outlined,
  SyncHeadlineState.serverKeyChanged => Icons.gpp_maybe_outlined,
  _ => Icons.cloud_off_outlined,
};

/// The calm status card at the top of Data: one headline in its tone, the
/// detail lines, and a tap through to the diagnostics sheet.
class _SyncStatusHero extends StatelessWidget {
  const _SyncStatusHero({
    required this.state,
    required this.label,
    required this.detail,
    required this.hint,
    required this.onTap,
  });

  final SyncHeadlineState state;
  final String label, detail, hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final neutral = syncHeadlineTone(state) == StatusTone.neutral;
    // A neutral state wears the plain grouped surface and the brand accent,
    // so "not synced yet" reads as a calm fact rather than a greyed warning.
    final tone = neutral
        ? cs.primary
        : statusToneColor(theme, syncHeadlineTone(state));
    final surface = neutral
        ? cs.surfaceContainerLow
        : Color.alphaBlend(
            tone.withValues(alpha: dark ? .14 : .08),
            cs.surfaceContainerLow,
          );
    final ink = AppTheme.readable(tone, [surface], minimum: 4.5);
    final shape = BorderRadius.circular(24);
    return Semantics(
      button: true,
      hint: hint,
      child: Pressable(
        radius: shape,
        child: Material(
          color: surface,
          shape: RoundedRectangleBorder(
            borderRadius: shape,
            side: BorderSide(
              color: neutral
                  ? cs.outlineVariant.withValues(alpha: .6)
                  : tone.withValues(alpha: .28),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: AnimatedSize(
              duration: AppMotion.duration(context, milliseconds: 220),
              curve: AppMotion.curve,
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 12, 18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExcludeSemantics(
                      child: AnimatedSwitcher(
                        duration: AppMotion.duration(
                          context,
                          milliseconds: 200,
                        ),
                        child: Container(
                          key: ValueKey(state),
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: tone.withValues(alpha: dark ? .22 : .14),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            _syncHeadlineIcon(state),
                            color: ink,
                            size: 26,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              // A neutral fact reads in plain ink, not grey.
                              color: neutral ? cs.onSurface : ink,
                            ),
                          ),
                          if (detail.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              detail,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Icon(
                          Icons.chevron_right,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
