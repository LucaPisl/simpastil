import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/protection/app_lock_controller.dart';
import '../../../core/startup/protection_readiness.dart';
import '../../../core/storage/recovery_copy_service.dart';
import '../../../core/storage/safe_cleanup_service.dart';
import '../../../core/storage/storage_inventory_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../shared/motion/staggered_entrance.dart';
import '../../../shared/widgets/status_chip.dart';
import 'settings_overview.dart';
import 'settings_pane.dart';
import '../../../shared/format/clock.dart';

class StorageSettingsSnapshot {
  const StorageSettingsSnapshot(this.inventory, this.recovery, this.original);
  final StorageInventory inventory;
  final RecoveryCopyCheck recovery, original;
}

final storageSettingsSnapshotProvider =
    FutureProvider.autoDispose<StorageSettingsSnapshot>((ref) async {
      final lease = ref
          .read(appLockControllerProvider.notifier)
          .captureAccess();
      final storage = await ref.watch(localStorageServicesProvider.future);
      lease.requireCurrent();
      final inventory = await storage.inventory.scan();
      final manifest = await storage.files.manifest();
      final recovery = await storage.recovery.check(manifest);
      final original = await storage.recovery.check(manifest, original: true);
      lease.requireCurrent();
      return StorageSettingsSnapshot(inventory, recovery, original);
    });

class StorageSettingsScreen extends ConsumerStatefulWidget {
  const StorageSettingsScreen({super.key});
  @override
  ConsumerState<StorageSettingsScreen> createState() =>
      _StorageSettingsScreenState();
}

class _StorageSettingsScreenState extends ConsumerState<StorageSettingsScreen> {
  bool _busy = false;
  String? _message;
  StatusTone _messageTone = StatusTone.neutral;

  void _say(String message, StatusTone tone) => setState(() {
    _message = message;
    _messageTone = tone;
  });
  Future<void> _cleanup() async {
    final l = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final lease = ref
          .read(appLockControllerProvider.notifier)
          .captureAccess();
      final storage = await ref.read(localStorageServicesProvider.future);
      lease.requireCurrent();
      final plan = await storage.cleanup.plan();
      lease.requireCurrent();
      if (!mounted) return;
      if (plan.generations.isEmpty) {
        _say(l.t15_cleanupNone, StatusTone.neutral);
        return;
      }
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l.t15_cleanupConfirm),
          content: Text(l.t15_cleanupBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.shared_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.t15_cleanup),
            ),
          ],
        ),
      );
      if (accepted != true) return;
      lease.requireCurrent();
      final result = await storage.cleanup.execute(plan);
      lease.requireCurrent();
      if (!mounted) return;
      if (result.state == CleanupState.complete) {
        _say(l.t15_cleanupDone, StatusTone.good);
      } else {
        _say(l.t15_cleanupRefused, StatusTone.attention);
      }
      ref.invalidate(storageSettingsSnapshotProvider);
    } on AppLockRequired {
      if (mounted) _say(l.t15_accessExpired, StatusTone.attention);
    } on Object {
      if (mounted) _say(l.t15_cleanupRefused, StatusTone.attention);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _size(int? bytes, AppLocalizations l) {
    if (bytes == null) return l.t15_unknownSize;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _when(DateTime value) => clockDateTime(context, value.toLocal());

  Widget _recovery(RecoveryCopyCheck copy, AppLocalizations l) {
    final theme = Theme.of(context);
    final tone = recoveryTone(copy.state);
    final details = copy.state == RecoveryCopyState.checked
        ? [
            _size(copy.bytes, l),
            if (copy.savedAt != null)
              '${l.t15_savedAt}: ${_when(copy.savedAt!)}',
            if (copy.checkedAt != null)
              '${l.t15_checkedAt}: ${_when(copy.checkedAt!)}',
          ].join('\n')
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            switch (copy.state) {
              RecoveryCopyState.absent => l.t15_noRecovery,
              RecoveryCopyState.unavailable => l.t15_recoveryUnavailable,
              RecoveryCopyState.checked => l.t15_checkedRecovery,
            },
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (details != null) ...[
            const SizedBox(height: 4),
            Text(
              details,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 10),
          StatusChip(
            label: switch (copy.state) {
              RecoveryCopyState.absent => l.r4_recoveryNone,
              RecoveryCopyState.unavailable => l.r4_recoveryUnchecked,
              RecoveryCopyState.checked => l.r4_recoveryChecked,
            },
            tone: tone,
            icon: switch (copy.state) {
              RecoveryCopyState.absent => Icons.radio_button_unchecked_rounded,
              RecoveryCopyState.unavailable => Icons.help_outline_rounded,
              RecoveryCopyState.checked => Icons.verified_outlined,
            },
            dense: true,
          ),
        ],
      ),
    );
  }

  Widget _sizeRow(String label, int? bytes, int largest, AppLocalizations l) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final known = bytes != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 12,
            runSpacing: 2,
            children: [
              Text(label, style: theme.textTheme.bodyLarge),
              Text(
                _size(bytes, l),
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: known ? FontWeight.w700 : FontWeight.w400,
                  color: known ? cs.onSurface : cs.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          // A quiet share bar only for sizes we know to be above zero: an
          // unknown size never draws as an empty bar, and zero draws nothing.
          if (known && bytes > 0 && largest > 0) ...[
            const SizedBox(height: 8),
            ExcludeSemantics(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: (bytes / largest).clamp(.02, 1.0),
                  minHeight: 4,
                  backgroundColor: cs.outlineVariant.withValues(alpha: .35),
                  color: cs.primary.withValues(alpha: .65),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final data = ref.watch(storageSettingsSnapshotProvider);
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );
    return Scaffold(
      appBar: settingsDetailAppBar(context, l.t15_storageRecovery),
      body: ContentListView(
        maxWidth: settingsContentWidth(context),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              l.t15_inventoryScope,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 20),
          data.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, _) => Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CalmNotice(
                    text: l.t15_loadFailed,
                    icon: Icons.cloud_off_outlined,
                    tone: StatusTone.problem,
                  ),
                  TextButton(
                    onPressed: () =>
                        ref.invalidate(storageSettingsSnapshotProvider),
                    child: Text(l.shared_retry),
                  ),
                ],
              ),
            ),
            data: (snapshot) {
              final sizes = [
                for (final category in StorageCategory.values)
                  snapshot.inventory.sizes[category],
              ].whereType<int>();
              final largest = sizes.isEmpty
                  ? 0
                  : sizes.reduce((a, b) => a > b ? a : b);
              return Column(
                children: [
                  SettingsGroup(
                    label: l.r4_spaceUsed,
                    index: 0,
                    identity: 'storage-space',
                    children: [
                      for (final category in StorageCategory.values)
                        _sizeRow(
                          switch (category) {
                            StorageCategory.care => l.t15_careFiles,
                            StorageCategory.recovery => l.t15_recoveryCopies,
                            StorageCategory.unfinished => l.t15_unfinishedFiles,
                            StorageCategory.legacyPlaintext =>
                              l.t15_legacyFiles,
                            StorageCategory.otherPrivate => l.t15_otherFiles,
                          },
                          snapshot.inventory.sizes[category],
                          largest,
                          l,
                        ),
                      _sizeRow(
                        l.t15_availableSpace,
                        snapshot.inventory.availableBytes,
                        0,
                        l,
                      ),
                    ],
                  ),
                  SettingsGroup(
                    label: l.t15_recoveryCopies,
                    index: 1,
                    identity: 'storage-recovery',
                    children: [
                      _recovery(snapshot.recovery, l),
                      if (snapshot.original.state != RecoveryCopyState.absent)
                        _recovery(snapshot.original, l),
                    ],
                  ),
                ],
              );
            },
          ),
          StaggeredEntrance(
            index: 2,
            identity: 'storage-transfer',
            child: CalmNotice(
              text: l.t15_transferBody,
              icon: Icons.phonelink_lock_outlined,
              tone: StatusTone.neutral,
            ),
          ),
          const SizedBox(height: 24),
          SettingsGroup(
            label: l.r4_cleanupGroup,
            index: 3,
            identity: 'storage-cleanup',
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l.t15_cleanupBody,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 52),
                        shape: buttonShape,
                      ),
                      onPressed: _busy ? null : _cleanup,
                      icon: _busy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cleaning_services_outlined),
                      label: Text(l.t15_cleanup, textAlign: TextAlign.center),
                    ),
                    if (_message != null) ...[
                      const SizedBox(height: 12),
                      CalmNotice(
                        text: _message!,
                        tone: _messageTone,
                        icon: statusToneIcon(_messageTone),
                        live: true,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// How each recovery-copy state should look: only a checked copy is
/// good; a copy that could not be checked is a problem, never "none".
@visibleForTesting
StatusTone recoveryTone(RecoveryCopyState state) => switch (state) {
  RecoveryCopyState.checked => StatusTone.good,
  RecoveryCopyState.absent => StatusTone.neutral,
  RecoveryCopyState.unavailable => StatusTone.problem,
};
