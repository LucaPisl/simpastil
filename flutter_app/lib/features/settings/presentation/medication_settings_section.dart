import 'account_follow_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings_overview.dart';
import 'settings_pane.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../core/widget/widget_snapshot.dart';
import '../../pills/pill_provider.dart'; // for SiblingDetectionMode, siblingDetectionModeProvider

import 'settings_widgets.dart';

class MedicationSettingsSection extends ConsumerWidget {
  const MedicationSettingsSection({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: settingsDetailAppBar(
        context,
        SettingsSection.medication.label(l),
      ),
      body: ContentListView(
        maxWidth: settingsContentWidth(context),
        padding: const EdgeInsets.all(16),
        children: [
          // ── Pill Editing ────────────────────────────────────────────────────
          SettingsSectionHeader(l.settings_pillEditing),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.settings_siblingDetection,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l.settings_siblingDetectionSubtitle,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<SiblingDetectionMode>(
                    segments: [
                      ButtonSegment(
                        value: SiblingDetectionMode.nameOnly,
                        label: Text(l.settings_siblingName),
                      ),
                      ButtonSegment(
                        value: SiblingDetectionMode.nameAndDosage,
                        label: Text(l.settings_siblingNameDosage),
                      ),
                      ButtonSegment(
                        value: SiblingDetectionMode.perPill,
                        label: Text(l.settings_siblingAlwaysAsk),
                      ),
                    ],
                    selected: {ref.watch(siblingDetectionModeProvider)},
                    onSelectionChanged: (selected) => ref
                        .read(siblingDetectionModeProvider.notifier)
                        .setMode(selected.first),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 32),
          // ── PRN Stats ──────────────────────────────────────────────────────
          SettingsSectionHeader(l.settings_asNeededMeds),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: Text(l.settings_includeInStats),
                  subtitle: Text(l.settings_includeInStatsSubtitle),
                  value: ref.watch(prnInStatsProvider),
                  onChanged: (v) =>
                      ref.read(prnInStatsProvider.notifier).toggle(v),
                ),
                SwitchListTile(
                  title: Text(l.settings_showPrnInWidget),
                  subtitle: Text(l.settings_showPrnInWidgetSubtitle),
                  value: ref.watch(prnInWidgetProvider),
                  onChanged: (v) async {
                    await ref.read(prnInWidgetProvider.notifier).toggle(v);
                    publishWidgetSnapshot();
                  },
                ),
                const DeviceOnlyLabel('asNeededInWidget'),
              ],
            ),
          ),
          const Divider(height: 32),
        ],
      ),
    );
  }
}
