import 'account_actions_section.dart';
import 'account_follow_widgets.dart';

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
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _DeviceNameDialog(initialName: _deviceName),
    );
    if (newName == null || newName.isEmpty || !mounted) return;
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

  Future<void> _stopUsingServer(String host) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t15_stopUsingServer),
        content: Text(l.t15_stopUsingServerConfirm(host)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.shared_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.t15_stopUsingServerAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final forgotten = await ref.read(serverConfigProvider.notifier).forget();
    if (forgotten || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.t15_stopUsingServerSignedIn)));
  }

  Future<void> _logOut() async {
    // The dialog opens at once; the unsynced count arrives inside it, so a
    // slow database never leaves the tap looking dead. The count is asked for
    // once, here: the dialog rebuilds and must not start another.
    final pending = ref
        .read(syncServiceProvider)
        .countPending()
        .timeout(const Duration(seconds: 2));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _LogOutDialog(pending: pending),
    );
    if (confirmed != true || !mounted) return;
    ref.read(autoSyncServiceProvider).stop();
    await ref.read(authNotifierProvider.notifier).logout();
    if (mounted) context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final serverUrl = ref.watch(serverConfigProvider);
    final serverHostname = serverUrl != null ? Uri.parse(serverUrl).host : null;
    // Account and session options belong to a finished sign-in. A server that
    // is only set up offers to finish signing in or to stop using it.
    final auth = ref.watch(authNotifierProvider);
    final signedIn = auth is AuthAuthenticated;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: settingsDetailAppBar(context, SettingsSection.account.label(l)),
      body: ContentListView(
        maxWidth: settingsContentWidth(context),
        padding: const EdgeInsets.all(16),
        children: [
          if (auth is AuthLoading && serverHostname != null)
            // The sign-in is still being read: say nothing about it yet.
            const SignInCheckingIndicator()
          else if (serverHostname == null) ...[
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
          ] else if (!signedIn) ...[
            Semantics(
              header: true,
              child: Text(
                l.t15_notSignedInYet,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 8),
            Text(l.t15_notSignedInBody(serverHostname)),
            const SizedBox(height: 24),
            SettingsGroup(
              label: l.t15_serverConnection,
              children: [
                SettingsNavigationRow(
                  key: const ValueKey('finish-signing-in'),
                  icon: Icons.login,
                  title: l.t15_finishSigningIn,
                  subtitle: serverHostname,
                  onTap: () => context.push('/login'),
                ),
                SettingsNavigationRow(
                  key: const ValueKey('stop-using-server'),
                  icon: Icons.link_off,
                  title: l.t15_stopUsingServer,
                  subtitle: l.t15_stopUsingServerSubtitle,
                  onTap: () => _stopUsingServer(serverHostname),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(l.t15_serverPrivacy),
          ] else ...[
            // ── Server ──────────────────────────────────────────────────────────
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
                  const DeviceOnlyLabel('deviceName'),
                ],
              ),
            ),
            const Divider(height: 32),
            // ── Session ─────────────────────────────────────────────────────────
            SettingsSectionHeader(l.settings_session),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                key: const ValueKey('log-out'),
                leading: SettingsIcon(icon: Icons.logout, color: colors.error),
                title: Text(l.settings_logOut),
                subtitle: Text(l.settings_logOutSubtitle),
                onTap: _logOut,
              ),
            ),
            const Divider(height: 32),
          ],
        ],
      ),
    );
  }
}

/// Confirms Log out. Unsynced changes get their own, stronger warning; every
/// other logout still asks once, so a stray tap cannot end the session. Log
/// out stays off until the count is known, or until checking gives up and the
/// dialog says changes may be lost.
class _LogOutDialog extends StatelessWidget {
  const _LogOutDialog({required this.pending});

  final Future<int> pending;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return FutureBuilder<int>(
      future: pending,
      builder: (context, snapshot) {
        final settled = snapshot.connectionState == ConnectionState.done;
        final count = snapshot.data;
        final message = !settled
            ? l.t15_logOutChecking
            : count == null
            ? l.t15_logOutUnknown
            : count > 0
            ? l.settings_logOutUnsynced(count)
            : l.settings_logOutConfirm;
        return AlertDialog(
          title: Text(l.settings_logOut),
          content: Semantics(liveRegion: true, child: Text(message)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l.shared_cancel),
            ),
            TextButton(
              key: const ValueKey('log-out-confirm'),
              onPressed: settled ? () => Navigator.of(context).pop(true) : null,
              child: Text(l.settings_logOut),
            ),
          ],
        );
      },
    );
  }
}

/// Asks for the device name. It owns its text controller, so the controller
/// outlives the dialog's closing animation instead of being disposed while the
/// field is still on screen.
class _DeviceNameDialog extends StatefulWidget {
  const _DeviceNameDialog({required this.initialName});

  final String? initialName;

  @override
  State<_DeviceNameDialog> createState() => _DeviceNameDialogState();
}

class _DeviceNameDialogState extends State<_DeviceNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final dl = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(dl.settings_deviceName),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: dl.settings_deviceNameHint),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(dl.shared_cancel),
        ),
        FilledButton(onPressed: _save, child: Text(dl.shared_save)),
      ],
    );
  }
}
