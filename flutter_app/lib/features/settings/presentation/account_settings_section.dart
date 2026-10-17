import 'two_factor_sheet.dart';
import 'change_password_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/errors/app_error.dart';
import '../../auth/auth_repository.dart';

import '../../../core/server/server_config_notifier.dart';
import '../../../core/sync/auto_sync_service.dart';
import '../../../core/sync/sync_service.dart';
import 'settings_overview.dart';
import 'settings_pane.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../auth/auth_provider.dart';

import 'settings_widgets.dart';

class AccountSettingsSection extends ConsumerStatefulWidget {
  const AccountSettingsSection({super.key});
  @override
  ConsumerState<AccountSettingsSection> createState() =>
      _AccountSettingsSectionState();
}

class _AccountSettingsSectionState
    extends ConsumerState<AccountSettingsSection> {
  String _deviceName = '';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadPrefs();
    });
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _deviceName = prefs.getString('simpastil_device_name') ?? '';
    });
  }

  Future<void> _editDeviceName() async {
    final controller = TextEditingController(text: _deviceName);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dl = AppLocalizations.of(ctx);
        return AlertDialog(
          title: Text(dl.settings_deviceName),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(hintText: dl.settings_deviceNameHint),
            onSubmitted: (_) => Navigator.of(ctx).pop(true),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(dl.shared_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(dl.shared_save),
            ),
          ],
        );
      },
    );
    final newName = controller.text.trim();
    controller.dispose();
    if (confirmed != true || !mounted) return;
    if (newName.isEmpty) return;
    final result = await ref
        .read(authRepositoryProvider)
        .setDeviceName(newName);
    if (!mounted) return;
    switch (result) {
      case Ok():
        setState(() => _deviceName = newName);
      case Err():
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).shared_syncFailed),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final serverUrl = ref.watch(serverConfigProvider);
    final serverHostname = serverUrl != null ? Uri.parse(serverUrl).host : null;
    return Scaffold(
      appBar: settingsDetailAppBar(context, SettingsSection.account.label(l)),
      body: ContentListView(
        maxWidth: settingsContentWidth(context),
        padding: const EdgeInsets.all(16),
        children: [
          if (serverHostname == null) ...[
            Text(l.t15_serverPrivacy),
            const SizedBox(height: 24),
            SettingsGroup(
              label: l.t15_serverConnection,
              children: [
                SettingsNavigationRow(
                  icon: Icons.dns_outlined,
                  title: l.r08_connect,
                  subtitle: l.t15_notConnected,
                  onTap: () => context.push('/login'),
                ),
              ],
            ),
          ],
          if (serverHostname != null) ...[
            // ── Account ─────────────────────────────────────────────────────────
            SettingsSectionHeader(l.settings_account),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: SettingsIcon(
                      icon: Icons.lock_outline,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    title: Text(l.settings_changePassword),
                    onTap: () {
                      showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        builder: (ctx) => const ChangePasswordSheet(),
                      );
                    },
                  ),
                  ListTile(
                    leading: SettingsIcon(
                      icon: Icons.security,
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                    title: Text(l.settings_2faTitle),
                    subtitle: Text(l.settings_2faSubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        builder: (ctx) => const TwoFactorSheet(),
                      );
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 32),
          ],
          // ── Server ──────────────────────────────────────────────────────────
          if (serverHostname != null) ...[
            SettingsSectionHeader(l.settings_server),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.dns_outlined),
                    title: Text(l.settings_connectedServer),
                    subtitle: Text(
                      serverHostname,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    trailing: const Icon(Icons.lock_outlined, size: 16),
                  ),
                  ListTile(
                    leading: const Icon(Icons.devices_outlined),
                    title: Text(l.settings_deviceName),
                    subtitle: Text(
                      _deviceName.isEmpty ? l.settings_notSet : _deviceName,
                    ),
                    trailing: const Icon(Icons.edit_outlined, size: 18),
                    onTap: _editDeviceName,
                  ),
                ],
              ),
            ),
            const Divider(height: 32),
          ],
          if (serverHostname != null) ...[
            // ── Session ─────────────────────────────────────────────────────────
            SettingsSectionHeader(l.settings_session),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: SettingsIcon(
                  icon: Icons.logout,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(l.settings_logOut),
                subtitle: Text(l.settings_logOutSubtitle),
                onTap: () async {
                  final pending = await ref
                      .read(syncServiceProvider)
                      .countPending();
                  if (pending > 0 && context.mounted) {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(l.settings_logOut),
                        content: Text(
                          'You have $pending unsynced change${pending == 1 ? '' : 's'}. '
                          'Logging out will attempt to sync them first, but any '
                          'remaining changes will be lost.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: Text(l.shared_cancel),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            child: Text(l.settings_logOut),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true) return;
                  }
                  ref.read(autoSyncServiceProvider).stop();
                  await ref.read(authNotifierProvider.notifier).logout();
                  if (context.mounted) context.go('/login');
                },
              ),
            ),
            const Divider(height: 32),
          ],
        ],
      ),
    );
  }
}
