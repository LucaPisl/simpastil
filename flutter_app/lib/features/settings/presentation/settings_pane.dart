import 'package:flutter/material.dart';

import 'settings_section.dart';

/// Marks a page as shown in the right-hand pane of the wide Settings (medium
/// and expanded windows) instead of as a page of its own.
///
/// A page inside the pane has no back arrow, leaves Back to the Settings
/// screen around it, and fills the pane's width. A page that must not be left
/// while it works (a backup being written or restored) raises [leaveBlocked]
/// for that time: the screen then ignores Back and a tap on another row. A page
/// with steps of its own (the backup flow) sets [stepBack] while it is on a
/// later step, so Back goes one step back before it leaves Settings.
class SettingsPaneScope extends InheritedWidget {
  const SettingsPaneScope({
    super.key,
    required this.leaveBlocked,
    required this.stepBack,
    required this.onSelect,
    required super.child,
  });

  /// True while the page in the pane is busy and must stay.
  final ValueNotifier<bool> leaveBlocked;

  /// What Back does for the page in the pane before the screen is left: null
  /// when the page is on its first step.
  final ValueNotifier<VoidCallback?> stepBack;

  /// Opens another page in the pane, as a tap on its row in the list does.
  final ValueChanged<SettingsSection> onSelect;

  static SettingsPaneScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsPaneScope>();

  /// Whether [context] is inside the pane.
  static bool isEmbedded(BuildContext context) => maybeOf(context) != null;

  @override
  bool updateShouldNotify(SettingsPaneScope old) =>
      leaveBlocked != old.leaveBlocked ||
      stepBack != old.stepBack ||
      onSelect != old.onSelect;
}

/// The widest a settings page's column may grow: the whole pane when it sits
/// in one (the pane is already narrower than the window), otherwise null, which
/// keeps the window class's content width.
double? settingsContentWidth(BuildContext context) =>
    SettingsPaneScope.isEmbedded(context) ? double.infinity : null;

/// The pane width from which a settings page lays its content out in two
/// columns (options beside a preview) instead of one.
const settingsTwoColumnFrom = 700.0;

/// The app bar of a settings page. Inside the wide Settings' pane it becomes
/// the pane's header instead: no back arrow (Back belongs to the whole screen),
/// the title in line with the page's content, and room for [actions].
AppBar settingsDetailAppBar(
  BuildContext context,
  String title, {
  Widget? leading,
  List<Widget>? actions,
}) {
  final scaledTitle = MediaQuery.textScalerOf(context).scale(22);
  final tall = scaledTitle > 30;
  if (SettingsPaneScope.isEmbedded(context)) {
    final theme = Theme.of(context);
    return AppBar(
      automaticallyImplyLeading: false,
      // Only a page with steps of its own has an arrow, to its previous step.
      leading: leading,
      leadingWidth: leading == null ? null : 64,
      titleSpacing: leading == null ? 16 : 0,
      toolbarHeight: tall ? scaledTitle * 2.54 + 16 : 64,
      backgroundColor: theme.scaffoldBackgroundColor,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      title: Text(title, maxLines: 2),
      titleTextStyle: theme.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        color: theme.colorScheme.onSurface,
      ),
      actions: actions == null ? null : [...actions, const SizedBox(width: 16)],
    );
  }
  return AppBar(
    leading: leading,
    leadingWidth: 64,
    titleSpacing: 0,
    toolbarHeight: tall ? scaledTitle * 2.54 + 16 : 56,
    title: Text(title, maxLines: 2),
    actions: actions,
  );
}
