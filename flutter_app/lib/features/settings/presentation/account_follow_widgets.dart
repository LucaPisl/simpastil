import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database.dart';
import '../../../core/settings/local_account_settings.dart';
import '../../../core/settings/setting_scope_registry.dart';
import '../../../core/settings/settings_store.dart';
import '../../../core/sync/ledger_mode_hint.dart';
import '../../../l10n/app_localizations.dart';
import '../../profiles/profile_provider.dart';
import 'settings_overview.dart';

/// Whether the server this device uses keeps settings with the account. Until
/// it says so, nothing here promises anything.
final accountSettingsSupportedProvider = FutureProvider.autoDispose<bool>(
  (ref) => LedgerModeHint.readAccountSettings(),
);

/// What the account's settings brought to this device the first time it joined,
/// as the groups the note names. Empty once dismissed.
final accountSettingsNoteProvider = FutureProvider.autoDispose<List<String>>((
  ref,
) async {
  if (!(await ref.watch(accountSettingsSupportedProvider.future))) {
    return const [];
  }
  final db = ref.read(databaseProvider);
  final userId = ref.read(currentUserIdProvider);
  Future<T> write<T>(Future<T> Function() action) => db.transaction(action);
  final store = SettingsStore(
    db: db,
    userId: userId,
    write: write,
    local: LocalAccountSettings(db: db, userId: userId, write: write),
  );
  return store.pendingNote();
});

/// The caption under an account setting that sits beside device-only rows:
/// it follows the account, so the "Only on this device" label above it is not
/// read as belonging to it. Shown only when the server syncs settings.
class AccountFollowsLabel extends ConsumerWidget {
  const AccountFollowsLabel({
    super.key,
    this.textKey = const ValueKey('follows-account-colors'),
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 8),
  });

  /// The caption's key, so a page and a footer showing it together differ.
  final Key textKey;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!(ref.watch(accountSettingsSupportedProvider).value ?? false)) {
      return const SizedBox.shrink();
    }
    final l = AppLocalizations.of(context);
    return Padding(
      padding: padding,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_done_outlined,
              size: 14,
              color: settingsMutedColor(Theme.of(context)),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                l.rvu_colorsAccountHint,
                key: textKey,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: settingsMutedColor(Theme.of(context)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Marks a setting that stays on this device, but only against a server that
/// keeps the rest with the account. Which settings stay is read from the scope
/// registry, so a label can never disagree with what is synced.
class DeviceOnlyLabel extends ConsumerWidget {
  const DeviceOnlyLabel(this.settingId, {super.key});
  final String settingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!SettingScopeRegistry.isDeviceOnly(settingId)) {
      return const SizedBox.shrink();
    }
    if (!(ref.watch(accountSettingsSupportedProvider).value ?? false)) {
      return const SizedBox.shrink();
    }
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.smartphone_outlined,
              size: 14,
              color: settingsMutedColor(Theme.of(context)),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                l.account_deviceOnly,
                key: ValueKey('device-only-$settingId'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: settingsMutedColor(Theme.of(context)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Everything else follows your account." plus the one-time note about what
/// the account brought along. Shown only against a server that keeps settings.
class AccountFollowsLine extends ConsumerWidget {
  const AccountFollowsLine({
    super.key,
    this.showNote = true,
    this.showLine = true,
  });

  /// The one-time note about what the account brought to this device.
  final bool showNote;

  /// The standing sentence that everything else follows the account.
  final bool showLine;

  static String _groupName(AppLocalizations l, String group) => switch (group) {
    'reminders' => l.account_groupReminders,
    'recordedBy' => l.account_groupRecordedBy,
    'medications' => l.account_groupMedications,
    'notices' => l.account_groupNotices,
    'text' => l.account_groupText,
    'colors' => l.account_groupColors,
    'language' => l.account_groupLanguage,
    _ => group,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!(ref.watch(accountSettingsSupportedProvider).value ?? false)) {
      return const SizedBox.shrink();
    }
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final groups = ref.watch(accountSettingsNoteProvider).value ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showNote && groups.isNotEmpty)
          Card(
            key: const ValueKey('account-settings-note'),
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.account_noteTitle, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    l.account_noteBody(
                      groups.map((g) => _groupName(l, g)).join(', '),
                    ),
                    style: theme.textTheme.bodyMedium,
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      onPressed: () async {
                        final db = ref.read(databaseProvider);
                        final userId = ref.read(currentUserIdProvider);
                        Future<T> write<T>(Future<T> Function() a) =>
                            db.transaction(a);
                        await SettingsStore(
                          db: db,
                          userId: userId,
                          write: write,
                          local: LocalAccountSettings(
                            db: db,
                            userId: userId,
                            write: write,
                          ),
                        ).dismissNote();
                        ref.invalidate(accountSettingsNoteProvider);
                      },
                      child: Text(l.account_noteGotIt),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (showLine)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              l.account_followsLine,
              key: const ValueKey('account-follows-line'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: settingsMutedColor(theme),
              ),
            ),
          ),
      ],
    );
  }
}
