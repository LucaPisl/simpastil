import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/server/server_config_notifier.dart';
import '../../../core/storage/shared_preferences_provider.dart';
import '../../report/report_screen.dart';
import '../../updates/data/github_release_check.dart';
import '../../updates/data/update_hint.dart';
import '../../updates/presentation/update_available_card.dart';
import 'settings_overview.dart';
import 'settings_pane.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';

import 'settings_widgets.dart';

/// Where donations go. Opens outside the app.
final _koFiPage = Uri.parse('https://ko-fi.com/lucapisl');

class AboutSettingsSection extends ConsumerStatefulWidget {
  const AboutSettingsSection({super.key});
  @override
  ConsumerState<AboutSettingsSection> createState() =>
      _AboutSettingsSectionState();
}

class _AboutSettingsSectionState extends ConsumerState<AboutSettingsSection> {
  PackageInfo? _packageInfo;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadPrefs();
    });
  }

  Future<void> _loadPrefs() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _packageInfo = info);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: settingsDetailAppBar(context, SettingsSection.about.label(l)),
      body: ContentListView(
        maxWidth: settingsContentWidth(context),
        padding: const EdgeInsets.all(16),
        children: [
          // ── About ───────────────────────────────────────────────────────────
          SettingsSectionHeader(l.settings_about),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: SettingsIcon(
                icon: Icons.info_outline,
                color: Theme.of(context).colorScheme.tertiary,
              ),
              title: Text(l.settings_appVersion),
              subtitle: _packageInfo != null
                  ? Text(
                      'v${_packageInfo!.version}+${_packageInfo!.buildNumber}',
                    )
                  : Text(l.shared_loading),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              key: const ValueKey('report-problem-row'),
              leading: SettingsIcon(
                icon: Icons.bug_report_outlined,
                color: Theme.of(context).colorScheme.tertiary,
              ),
              title: Text(l.report_title),
              subtitle: Text(l.report_settingsRowSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openReportProblem(context),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              key: const ValueKey('support-project-row'),
              leading: SettingsIcon(
                icon: Icons.favorite_border,
                color: Theme.of(context).colorScheme.tertiary,
              ),
              title: Text(l.supportRowTitle),
              subtitle: Text(l.supportRowSubtitle),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => ref.read(updateLauncherProvider)(_koFiPage),
            ),
          ),
          // Phones with a server hear about releases from the server; only a
          // phone without one asks GitHub itself, so only it gets the switch.
          if (ref.watch(serverConfigProvider) == null) ...[
            const SizedBox(height: 8),
            Card(
              child: SwitchListTile(
                key: const ValueKey('update-check-switch'),
                secondary: SettingsIcon(
                  icon: Icons.system_update_outlined,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
                title: Text(l.updateCheckSwitchTitle),
                subtitle: Text(l.updateCheckSwitchBody),
                value:
                    ref
                        .watch(sharedPreferencesProvider)
                        .getBool(updateCheckEnabledKey) ??
                    true,
                onChanged: (enabled) async {
                  await ref
                      .read(sharedPreferencesProvider)
                      .setBool(updateCheckEnabledKey, enabled);
                  // Rebuilds this row and rereads the update status.
                  UpdateHint.changes.value++;
                  if (enabled) {
                    // Ask now; runIfDue still skips a check made within a day.
                    unawaited(
                      ref
                          .read(gitHubReleaseCheckProvider)
                          .runIfDue(ref.read(sharedPreferencesProvider)),
                    );
                  }
                  if (mounted) setState(() {});
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}
