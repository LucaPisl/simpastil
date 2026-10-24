import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../shared/router/back_policy.dart';
import '../../auth/auth_provider.dart';
import '../../updates/presentation/update_available_card.dart';
import 'settings_overview.dart';
import 'settings_pages.dart';
import 'account_follow_widgets.dart';
import 'settings_pane.dart';

/// The width of the list of settings on a window of [windowClass]. The medium
/// window keeps it narrow: the page beside it needs most of the room.
double settingsListWidth(WindowClass windowClass) =>
    windowClass.isExpanded ? 320 : 256;

/// Settings on a medium or expanded window: the grouped list on the left and
/// the page of the selected row on the right, so changing a choice never leaves
/// the list.
///
/// Back belongs to the whole screen. It leaves Settings (to the page below, or
/// Today when there is none) whichever page is open, except while the page in
/// the pane is busy and asks to stay, such as a backup being written, or is on
/// a later step of its own, which Back then undoes first.
class SettingsMasterDetail extends StatefulWidget {
  const SettingsMasterDetail({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final SettingsSection selected;
  final ValueChanged<SettingsSection> onSelected;

  @override
  State<SettingsMasterDetail> createState() => _SettingsMasterDetailState();
}

class _SettingsMasterDetailState extends State<SettingsMasterDetail> {
  final _leaveBlocked = ValueNotifier<bool>(false);
  final _stepBack = ValueNotifier<VoidCallback?>(null);

  @override
  void dispose() {
    _leaveBlocked.dispose();
    _stepBack.dispose();
    super.dispose();
  }

  void _select(SettingsSection section) {
    if (_leaveBlocked.value || section == widget.selected) return;
    // The page being left takes its steps with it.
    _stepBack.value = null;
    widget.onSelected(section);
  }

  /// Leaves Settings: to the page below, or Today when there is none.
  void _leave() {
    if (_leaveBlocked.value) return;
    if (isOnlyPage(context)) {
      leaveToToday(context);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final windowClass = WindowClass.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([_leaveBlocked, _stepBack]),
      builder: (context, child) {
        final blocked = _leaveBlocked.value;
        final step = _stepBack.value;
        return PopScope(
          canPop: !blocked && step == null && !isOnlyPage(context),
          onPopInvokedWithResult: (didPop, _) {
            if (didPop || blocked) return;
            if (step != null) {
              step();
            } else {
              leaveToToday(context);
            }
          },
          child: child!,
        );
      },
      child: Scaffold(
        body: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: settingsListWidth(windowClass),
                child: _SettingsList(
                  key: const ValueKey('settings-list'),
                  selected: widget.selected,
                  onSelected: _select,
                  onBack: _leave,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(0, 12, 12, 12),
                  child: ScaffoldMessenger(
                    child: SettingsPaneScope(
                      leaveBlocked: _leaveBlocked,
                      stepBack: _stepBack,
                      onSelect: _select,
                      child: Material(
                        key: const ValueKey('settings-pane'),
                        color: theme.scaffoldBackgroundColor,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                          side: BorderSide(
                            color: settingsBorderColor(
                              theme,
                            ).withValues(alpha: .7),
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: KeyedSubtree(
                          key: ValueKey(widget.selected),
                          child: settingsPageFor(widget.selected),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The groups of the overview as one list of flat rows, the selected one
/// filled. The order and the groups are the phone overview's.
class _SettingsList extends ConsumerWidget {
  const _SettingsList({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.onBack,
  });

  final SettingsSection selected;
  final ValueChanged<SettingsSection> onSelected;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final signedIn = ref.watch(authNotifierProvider) is AuthAuthenticated;
    Widget group(String label, List<Widget> rows) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: Semantics(
              header: true,
              child: Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: settingsMutedColor(theme),
                ),
              ),
            ),
          ),
          ...rows,
        ],
      ),
    );
    Widget row(SettingsSection section, {String? label}) => _ListRow(
      key: ValueKey('settings-row-${section.name}'),
      section: section,
      label: label,
      selected: section == selected,
      onTap: () => onSelected(section),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(4, 8, 12, 4),
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('settings-back'),
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const BackButtonIcon(),
                onPressed: onBack,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    l.settings_title,
                    maxLines: 2,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            children: [
              const UpdateAvailableCard(
                margin: EdgeInsets.fromLTRB(0, 4, 0, 8),
              ),
              const AccountFollowsLine(showLine: false),
              group(l.settings_appearance, [
                row(SettingsSection.layout),
                row(SettingsSection.colors),
              ]),
              group(l.t15_everyday, [
                row(SettingsSection.reminders),
                row(SettingsSection.accessibility),
                const _DenseRow(child: ReduceMotionRow(dense: true)),
                row(SettingsSection.language),
              ]),
              group(l.t15_yourData, [
                row(SettingsSection.backups),
                row(SettingsSection.storage),
                row(SettingsSection.account),
              ]),
              if (signedIn)
                group(l.settings_account, [
                  // The group already says "Account": the row says whose.
                  row(SettingsSection.yourAccount, label: l.rva_accountRow),
                ]),
              group(l.t15_privacyAccess, [
                row(SettingsSection.protection),
                row(SettingsSection.people),
                row(SettingsSection.medication),
                row(SettingsSection.data),
                row(SettingsSection.about),
              ]),
              const AccountFollowsLine(showNote: false),
            ],
          ),
        ),
      ],
    );
  }
}

/// Keeps an inline control (the reduce-motion switch) on the list's rounded
/// rows, so its ripple and edges match them.
class _DenseRow extends StatelessWidget {
  const _DenseRow({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Material(
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
  );
}

class _ListRow extends StatelessWidget {
  const _ListRow({
    super.key,
    required this.section,
    this.label,
    required this.selected,
    required this.onTap,
  });

  final SettingsSection section;

  /// Overrides the section's own name on this row.
  final String? label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final ink = selected ? colors.onPrimaryContainer : colors.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? colors.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: [
                  ExcludeSemantics(
                    child: SettingsRowIcon(section.icon, ink, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label ?? section.label(l),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
