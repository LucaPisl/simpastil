import 'account_follow_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/protection/app_lock_controller.dart';
import 'settings_overview.dart';
import 'settings_pane.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';

class ProtectionSettingsSection extends ConsumerStatefulWidget {
  const ProtectionSettingsSection({super.key});
  @override
  ConsumerState<ProtectionSettingsSection> createState() =>
      _ProtectionSettingsSectionState();
}

class _ProtectionSettingsSectionState
    extends ConsumerState<ProtectionSettingsSection> {
  Future<void> _setAppLock(bool enabled) async {
    final l = AppLocalizations.of(context);
    final controller = ref.read(appLockControllerProvider.notifier);
    final saved = await controller.setEnabled(
      enabled,
      enabled
          ? l.t14_settingsLockEnableReason
          : l.t14_settingsLockDisableReason,
      fallbackLabel: l.t14_lockUseDeviceLock,
    );
    if (!mounted || saved) return;
    final message = controller.current.failure == AppLockFailure.cancelled
        ? l.t14_settingsLockCancelled
        : l.t14_settingsLockFailed;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final appLock = ref.watch(appLockControllerProvider);
    return Scaffold(
      appBar: settingsDetailAppBar(
        context,
        SettingsSection.protection.label(l),
      ),
      body: ContentListView(
        maxWidth: settingsContentWidth(context),
        padding: const EdgeInsets.all(16),
        children: [
          Text(l.t15_encryptionBody),
          const SizedBox(height: 16),
          Card(
            child: SwitchListTile(
              key: const ValueKey('settings-app-lock'),
              secondary: const Icon(Icons.lock_outline),
              title: Text(l.t14_settingsLockTitle),
              subtitle: Text(l.t14_settingsLockBody),
              value: appLock.enabled,
              onChanged: appLock.isAuthenticating || appLock.policy == null
                  ? null
                  : _setAppLock,
            ),
          ),
          const DeviceOnlyLabel('appLock'),
          const Divider(height: 32),
          Text(
            l.t15_transferTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(l.t15_transferBody),
          const SizedBox(height: 24),
          Text(l.t15_serverPrivacy),
        ],
      ),
    );
  }
}
