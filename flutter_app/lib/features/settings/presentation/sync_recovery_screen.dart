import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/api/api_client.dart';
import '../../../core/sync/auto_sync_service.dart';
import '../../../core/sync/capabilities_client.dart';
import '../../../core/sync/sync_recovery_service.dart';
import '../../../core/sync/sync_retry_policy.dart';
import '../../../core/sync/sync_status_notifier.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/format/clock.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../shared/widgets/status_chip.dart';
import '../../profiles/profile_provider.dart';
import '../migration_issue_provider.dart';
import 'reminder_reset_action.dart';
import 'settings_overview.dart';

/// The number of kept notes Fix sync problems lists, read without running the
/// repair. The Sync page uses it for its entry row.
final keptNotesCountProvider = FutureProvider.autoDispose<int>((ref) {
  ref.watch(migrationIssuesProvider);
  ref.watch(syncStatusProvider.select((status) => status.counts));
  return ref
      .watch(syncRecoveryServiceProvider)
      .countNotes(ref.watch(currentUserIdProvider));
});

/// The recovery report for the signed-in user. It is rebuilt whenever the
/// unsent-change tally or the stored issues move, so it never shows a stale list after a sync.
final syncRecoveryReportProvider = FutureProvider.autoDispose<RecoveryReport>((
  ref,
) {
  ref.watch(syncStatusProvider.select((status) => status.counts));
  // Kept notes come and go with the stored issues, not with the unsent tally.
  ref.watch(migrationIssuesProvider);
  return ref
      .watch(syncRecoveryServiceProvider)
      .diagnose(ref.watch(currentUserIdProvider));
});

/// Reads the server's capability flags for the copied diagnostics. Replaceable
/// so tests never reach the network.
final recoveryCapabilitiesLoaderProvider =
    Provider<Future<ServerCapabilities?> Function()>(
      (ref) =>
          () async => (await CapabilitiesClient(
            ref.read(apiClientProvider).dio,
          ).refresh()).capabilities,
    );

/// Pushes the "Fix sync problems" screen under [syncRecoveryRouteName].
Future<void> openSyncRecovery(BuildContext context) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: syncRecoveryRouteName),
        builder: (_) => const SyncRecoveryScreen(),
      ),
    );

class SyncRecoveryScreen extends ConsumerStatefulWidget {
  const SyncRecoveryScreen({super.key});

  @override
  ConsumerState<SyncRecoveryScreen> createState() => _SyncRecoveryScreenState();
}

class _SyncRecoveryScreenState extends ConsumerState<SyncRecoveryScreen> {
  bool _busy = false;

  String get _userId => ref.read(currentUserIdProvider);

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Runs one recovery action: shows progress, reports the result in plain
  /// words, and refreshes the list and the status everywhere.
  Future<void> _run(
    Future<RecoveryOutcome> Function(SyncRecoveryService service) action,
    String doneText,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    final l = AppLocalizations.of(context);
    final userId = _userId;
    String message;
    try {
      final outcome = await action(ref.read(syncRecoveryServiceProvider));
      message = switch (outcome) {
        RecoveryOutcome(refusal: RecoveryRefusal.sending) =>
          l.recovery_refusedSending,
        RecoveryOutcome(refusal: RecoveryRefusal.nothingToDo) =>
          l.recovery_refusedGone,
        RecoveryOutcome(refusal: RecoveryRefusal.hasDoseHistory) =>
          l.recovery_discardHistory,
        RecoveryOutcome(refusal: RecoveryRefusal.notDiscardable) =>
          l.recovery_refusedNotDiscardable,
        RecoveryOutcome(refusal: RecoveryRefusal.serverDeleted) =>
          l.recovery_reasonConflictDeleted,
        RecoveryOutcome(refusal: RecoveryRefusal.offline) =>
          l.recovery_refusedOffline,
        RecoveryOutcome(serverCopyPending: true) =>
          l.recovery_serverCopyPending,
        RecoveryOutcome(busy: true) => l.recovery_busy,
        _ => doneText,
      };
    } on Object {
      message = l.recovery_failed;
    }
    try {
      await ref.read(autoSyncServiceProvider).refreshCounts(userId);
    } on Object {
      // The list below is rebuilt from the database either way.
    }
    ref.invalidate(syncRecoveryReportProvider);
    ref.invalidate(profileListProvider);
    if (!mounted) return;
    setState(() => _busy = false);
    _say(message);
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async {
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l.shared_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  String _name(RecoveryItem item, AppLocalizations l) =>
      item.name ?? _kindLabel(item.kind, l);

  Future<void> _useServer(RecoveryItem item) async {
    final l = AppLocalizations.of(context);
    final ok = await _confirm(
      title: l.recovery_useServerTitle,
      body: item.isCreate
          ? l.recovery_useServerCreateBody(_name(item, l))
          : l.recovery_useServerBody(_name(item, l)),
      action: l.recovery_useServer,
    );
    if (!ok || !mounted) return;
    await _run(
      (service) => service.useServerVersion(_userId, item.key),
      l.recovery_doneServer,
    );
  }

  Future<void> _keepMine(RecoveryItem item) async {
    final l = AppLocalizations.of(context);
    final ok = await _confirm(
      title: l.recovery_keepMineTitle,
      body: l.recovery_keepMineBody(_name(item, l)),
      action: l.recovery_keepMine,
    );
    if (!ok || !mounted) return;
    await _run(
      (service) => service.keepMyChange(_userId, item.key),
      l.recovery_doneKeep,
    );
  }

  Future<void> _tryAgain(RecoveryItem item) {
    final l = AppLocalizations.of(context);
    return _run(
      (service) => service.tryAgain(_userId, item.key),
      l.recovery_doneTryAgain,
    );
  }

  Future<void> _discard(RecoveryItem item) async {
    final l = AppLocalizations.of(context);
    final name = _name(item, l);
    final changes = {for (final op in item.operations) op.change};
    final ok = await _confirm(
      title: l.recovery_discardTitle,
      body: [
        changes.contains(RecoveryChange.stock)
            ? l.recovery_discardStockBody(name)
            : changes.contains(RecoveryChange.dose)
            ? l.recovery_discardDoseBody(name)
            : l.recovery_discardOtherBody(name),
        if (item.discardCount > 1) l.recovery_discardCount(item.discardCount),
      ].join(' '),
      action: l.recovery_discard,
    );
    if (!ok || !mounted) return;
    await _run(
      (service) => service.discardItem(_userId, item.key),
      l.recovery_doneDiscard,
    );
  }

  Future<void> _redownload() async {
    final l = AppLocalizations.of(context);
    final ok = await _confirm(
      title: l.recovery_redownloadTitle,
      body: l.recovery_redownloadBody,
      action: l.recovery_redownload,
    );
    if (!ok || !mounted) return;
    await _run(
      (service) => service.redownload(_userId),
      l.recovery_doneRedownload,
    );
  }

  Future<void> _copyDiagnostics() async {
    final l = AppLocalizations.of(context);
    try {
      ServerCapabilities? capabilities;
      try {
        capabilities = await ref.read(recoveryCapabilitiesLoaderProvider)();
      } on Object {
        // Offline or signed out: the report says capabilities are unavailable.
      }
      String? version;
      try {
        final info = await PackageInfo.fromPlatform();
        version = info.version;
      } on Object {
        // The build number is always included.
      }
      final text = await ref
          .read(syncRecoveryServiceProvider)
          .buildDiagnostics(
            _userId,
            capabilities: capabilities,
            appVersion: version,
          );
      await Clipboard.setData(ClipboardData(text: text));
      _say(l.recovery_copied);
    } on Object {
      _say(l.recovery_failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final report = ref.watch(syncRecoveryReportProvider);
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: settingsDetailAppBar(context, l.recovery_title),
        body: ContentListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            if (_busy) const LinearProgressIndicator(),
            ...switch (report) {
              AsyncData(:final value) => _content(context, value, l),
              AsyncError() => [
                CalmNotice(
                  key: const ValueKey('recovery-load-failed'),
                  text: l.recovery_loadFailed,
                  icon: Icons.info_outline_rounded,
                  tone: StatusTone.attention,
                ),
                TextButton(
                  onPressed: () => ref.invalidate(syncRecoveryReportProvider),
                  child: Text(l.shared_retry),
                ),
              ],
              _ => [
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
            },
            const SizedBox(height: 8),
            SettingsGroup(
              label: l.recovery_groupTools,
              index: 2,
              identity: 'recovery-tools',
              children: [
                SettingsNavigationRow(
                  key: const ValueKey('recovery-redownload'),
                  icon: Icons.cloud_download_outlined,
                  title: l.recovery_redownload,
                  subtitle: l.recovery_redownloadHint,
                  onTap: () {
                    if (!_busy) _redownload();
                  },
                ),
                SettingsNavigationRow(
                  key: const ValueKey('recovery-copy'),
                  icon: Icons.copy_all_outlined,
                  title: l.recovery_copyDiagnostics,
                  subtitle: l.recovery_copyDiagnosticsHint,
                  onTap: _copyDiagnostics,
                ),
                const ResetRemindersRow(
                  key: ValueKey('recovery-reset-reminders'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _content(
    BuildContext context,
    RecoveryReport report,
    AppLocalizations l,
  ) {
    final stockNote = report.counts.awaitingLedger > 0
        ? [
            CalmNotice(
              key: const ValueKey('recovery-stock-stays'),
              text: l.sync_stockStaysOnPhone,
              icon: Icons.info_outline_rounded,
              tone: StatusTone.neutral,
            ),
            const SizedBox(height: 12),
          ]
        : const <Widget>[];
    if (report.isEmpty) {
      return [
        ...stockNote,
        CalmNotice(
          key: const ValueKey('recovery-nothing'),
          text: '${l.recovery_nothingTitle}. ${l.recovery_nothingBody}',
          icon: Icons.check_circle_outline_rounded,
          tone: StatusTone.good,
        ),
        const SizedBox(height: 16),
      ];
    }
    final onlyWaiting = report.items.every(
      (item) =>
          item.reason == RecoveryReason.queued ||
          item.reason == RecoveryReason.retrying,
    );
    return [
      ...stockNote,
      Text(l.recovery_intro, style: Theme.of(context).textTheme.bodyMedium),
      const SizedBox(height: 12),
      if (onlyWaiting)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: CalmNotice(
            key: const ValueKey('recovery-waiting-only'),
            text: l.recovery_waitingOnly,
            icon: Icons.schedule_rounded,
            tone: StatusTone.neutral,
          ),
        ),
      if (report.hasRetryable) ...[
        FilledButton.tonalIcon(
          key: const ValueKey('recovery-retry-all'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          onPressed: _busy
              ? null
              : () => _run(
                  (service) => service.retryAll(_userId),
                  l.recovery_doneRetry,
                ),
          icon: const Icon(Icons.replay_rounded),
          label: Text(l.recovery_retryAll),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 16),
          child: Text(
            l.recovery_retryAllHint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
      SettingsGroup(
        label: l.recovery_groupChanges,
        index: 1,
        identity: 'recovery-items',
        children: [
          for (final item in report.items)
            _RecoveryItemTile(
              key: ValueKey('recovery-item-${item.key}'),
              item: item,
              busy: _busy,
              onUseServer: () => _useServer(item),
              onKeepMine: () => _keepMine(item),
              onDismiss: () => _run(
                (service) => service.dismiss(_userId, item.key),
                l.recovery_doneDismiss,
              ),
              onTryAgain: () => _tryAgain(item),
              onDiscard: () => _discard(item),
            ),
        ],
      ),
      if (report.notes.isNotEmpty)
        SettingsGroup(
          label: l.recovery_groupNotes,
          index: 3,
          identity: 'recovery-notes',
          children: [
            for (final note in report.notes)
              _RecoveryNoteTile(
                key: ValueKey('recovery-note-${note.issueId}'),
                note: note,
                busy: _busy,
                onDismiss: () => _run(
                  (service) => service.dismissNote(_userId, note.issueId),
                  l.recovery_doneDismiss,
                ),
              ),
          ],
        ),
    ];
  }
}

String _kindLabel(RecoveryItemKind kind, AppLocalizations l) => switch (kind) {
  RecoveryItemKind.person => l.recovery_kindPerson,
  RecoveryItemKind.medication => l.recovery_kindMedication,
  RecoveryItemKind.schedule => l.recovery_kindSchedule,
  RecoveryItemKind.dose => l.recovery_kindDose,
  RecoveryItemKind.other => l.recovery_kindOther,
};

String _changeLabel(RecoveryChange change, AppLocalizations l) =>
    switch (change) {
      RecoveryChange.added => l.recovery_changeAdded,
      RecoveryChange.edited => l.recovery_changeEdited,
      RecoveryChange.removed => l.recovery_changeRemoved,
      RecoveryChange.dose => l.recovery_changeDose,
      RecoveryChange.stock => l.recovery_changeStock,
      RecoveryChange.other => l.recovery_changeOther,
    };

StatusTone _reasonTone(RecoveryReason reason) => switch (reason) {
  RecoveryReason.queued => StatusTone.working,
  RecoveryReason.retrying => StatusTone.neutral,
  RecoveryReason.blocked ||
  RecoveryReason.conflict ||
  RecoveryReason.stranded => StatusTone.attention,
};

class _RecoveryItemTile extends StatelessWidget {
  const _RecoveryItemTile({
    super.key,
    required this.item,
    required this.busy,
    required this.onUseServer,
    required this.onKeepMine,
    required this.onDismiss,
    required this.onTryAgain,
    required this.onDiscard,
  });

  final RecoveryItem item;
  final bool busy;
  final VoidCallback onUseServer, onKeepMine, onDismiss, onTryAgain, onDiscard;

  String _reasonText(BuildContext context, AppLocalizations l) {
    final settled = item.operations.any((op) => op.serverAlreadyWon);
    if (item.needsMedicationReview && item.reason != RecoveryReason.conflict) {
      return l.recovery_reasonReview;
    }
    if (item.operations.any((op) => op.waitingForStart) &&
        (item.reason == RecoveryReason.queued ||
            item.reason == RecoveryReason.retrying ||
            item.reason == RecoveryReason.stranded)) {
      return item.reason == RecoveryReason.stranded
          ? l.recovery_reasonStartStuck
          : l.recovery_reasonWaitingForStart;
    }
    return switch (item.reason) {
      RecoveryReason.queued => l.recovery_reasonQueued,
      RecoveryReason.retrying =>
        item.nextAttemptAt == null ||
                !item.nextAttemptAt!.isAfter(DateTime.now().toUtc())
            ? l.recovery_reasonRetryingSoon
            : l.recovery_reasonRetrying(
                clockAt(context, item.nextAttemptAt!.toLocal()),
              ),
      RecoveryReason.blocked => l.recovery_reasonBlocked,
      RecoveryReason.conflict =>
        item.serverDeleted
            ? l.recovery_reasonConflictDeleted
            : settled
            ? l.recovery_reasonConflictSettled
            : l.recovery_reasonConflict,
      RecoveryReason.stranded => l.recovery_reasonStranded,
    };
  }

  String? _cause(AppLocalizations l) {
    if (item.reason != RecoveryReason.blocked) return null;
    return switch (item.safeErrorCode) {
      final code when code == SyncRetryPolicy.bodyChangedCode =>
        l.recovery_blockedBodyChanged,
      final code when code == SyncRetryPolicy.retryExhaustedCode =>
        l.recovery_blockedExhausted,
      'BRIDGE_UNDO_UNSUPPORTED' => l.recovery_blockedUndo,
      _ => l.recovery_blockedGeneric,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final changes = {
      for (final op in item.operations) _changeLabel(op.change, l),
    }.join(' · ');
    final cause = _cause(l);
    final title = item.detail == null
        ? (item.name ?? _kindLabel(item.kind, l))
        : '${item.name ?? _kindLabel(item.kind, l)} · ${item.detail}';
    final actions = <Widget>[
      if (item.canUseServerVersion)
        OutlinedButton(
          key: const ValueKey('recovery-use-server'),
          onPressed: busy ? null : onUseServer,
          child: Text(l.recovery_useServer),
        ),
      if (item.canKeepMine)
        OutlinedButton(
          key: const ValueKey('recovery-keep-mine'),
          onPressed: busy ? null : onKeepMine,
          child: Text(l.recovery_keepMine),
        ),
      if (item.canDismiss)
        FilledButton.tonal(
          key: const ValueKey('recovery-dismiss'),
          onPressed: busy ? null : onDismiss,
          child: Text(l.recovery_dismiss),
        ),
      if (item.canTryAgain)
        OutlinedButton(
          key: const ValueKey('recovery-try-again'),
          onPressed: busy ? null : onTryAgain,
          child: Text(l.recovery_tryAgain),
        ),
      if (item.canDiscard)
        OutlinedButton(
          key: const ValueKey('recovery-discard'),
          onPressed: busy ? null : onDiscard,
          child: Text(l.recovery_discard),
        ),
      if (item.discardBlockedByHistory)
        // Shown disabled, with the reason below, rather than hidden.
        OutlinedButton(
          key: const ValueKey('recovery-use-server-disabled'),
          onPressed: null,
          child: Text(l.recovery_useServer),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusChip(
                label: _kindLabel(item.kind, l),
                tone: _reasonTone(item.reason),
                dense: true,
              ),
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(changes, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 2),
          Text(
            _reasonText(context, l),
            key: const ValueKey('recovery-reason'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          if (cause != null)
            Text(
              cause,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          if (item.discardBlockedByHistory)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                l.recovery_discardHistory,
                key: const ValueKey('recovery-history-note'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }
}

/// A kept review note nothing waits behind: the only thing to do is close it.
class _RecoveryNoteTile extends StatelessWidget {
  const _RecoveryNoteTile({
    super.key,
    required this.note,
    required this.busy,
    required this.onDismiss,
  });

  final RecoveryNote note;
  final bool busy;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.recovery_noteTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${clockDateTime(context, note.createdAt.toLocal())} · ${l.recovery_noteBody}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.tonal(
            key: const ValueKey('recovery-note-dismiss'),
            onPressed: busy ? null : onDismiss,
            child: Text(l.recovery_dismiss),
          ),
        ],
      ),
    );
  }
}
