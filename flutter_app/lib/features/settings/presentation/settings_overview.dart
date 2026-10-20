import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/locale_provider.dart';
import '../../../core/server/server_config_notifier.dart';
import '../../../core/storage/layout_family_preference.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/motion/staggered_entrance.dart';
import '../../../shared/theme/focus_tokens.dart';
import '../../dashboard/today_layout/layout_preview.dart';
import '../../updates/presentation/update_available_card.dart';
import '../../dashboard/today_layout/today_layouts.dart';
import 'layout_chooser_screen.dart';
import 'settings_pane.dart';
import 'settings_section.dart';
import 'theme_mode_switch.dart';

export 'settings_pane.dart' show settingsDetailAppBar;
export 'settings_section.dart';

/// The quiet text colour of settings rows, readable on the group surface.
Color settingsMutedColor(ThemeData theme) =>
    theme.brightness == Brightness.light &&
        (theme.colorScheme.primary == const Color(0xFF685FEA) ||
            theme.colorScheme.primary == const Color(0xFF6E66FA))
    ? const Color(0xFF595D82)
    : theme.colorScheme.onSurfaceVariant;

/// The hairline colour of settings groups and dividers.
Color settingsBorderColor(ThemeData theme) =>
    theme.brightness == Brightness.light &&
        (theme.colorScheme.primary == const Color(0xFF685FEA) ||
            theme.colorScheme.primary == const Color(0xFF6E66FA))
    ? const Color(0xFFD5D8EB)
    : theme.colorScheme.outlineVariant;

/// The approved Settings reference's quiet grouped overview. Long explanations
/// and editable controls remain in their reachable detail pages.
class SettingsOverview extends ConsumerWidget {
  const SettingsOverview({
    super.key,
    required this.onSection,
    required this.onLanguage,
  });
  final ValueChanged<SettingsSection> onSection;
  final VoidCallback onLanguage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final language = ref.watch(localeOverrideProvider);
    final appearance = ref.watch(appearanceNotifierProvider).value;
    final server = ref.watch(serverConfigProvider);
    void editAppearance() => context.push('/appearance');
    return Scaffold(
      appBar: settingsDetailAppBar(context, l.settings_title),
      body: ContentListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          const UpdateAvailableCard(margin: EdgeInsets.only(bottom: 16)),
          Text(
            l.t15_intro,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: settingsMutedColor(Theme.of(context)),
            ),
          ),
          const SizedBox(height: 20),
          SettingsGroup(
            label: l.settings_appearance,
            index: 0,
            identity: 'settings-0',
            children: [
              SettingsNavigationRow(
                key: const ValueKey('layout-entry'),
                icon: Icons.layers_outlined,
                title: l.t15_layout,
                subtitle: layoutFamilyName(
                  l,
                  effectiveLayoutFamily(ref.watch(layoutFamilyProvider)),
                ),
                onTap: () => openLayoutChooser(context),
              ),
              const ThemeModeRow(),
              SettingsNavigationRow(
                key: const ValueKey('appearance-entry'),
                icon: Icons.palette_outlined,
                title: l.t15_colors,
                subtitle:
                    appearance == null ||
                        (appearance.lightColors.isEmpty &&
                            appearance.darkColors.isEmpty &&
                            !appearance.dynamicColor)
                    ? l.t15_defaultPalette
                    : l.t15_customPalette,
                accessory: ExcludeSemantics(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final color in [
                        cs.primary,
                        cs.surface,
                        appearance?.lightColors.isNotEmpty == true ||
                                appearance?.darkColors.isNotEmpty == true
                            ? cs.tertiary
                            : FocusTokens.sage,
                        appearance?.lightColors.isNotEmpty == true ||
                                appearance?.darkColors.isNotEmpty == true
                            ? cs.surfaceContainerHigh
                            : FocusTokens.lavender,
                      ])
                        Container(
                          width: 14,
                          height: 14,
                          margin: const EdgeInsets.only(right: 4),
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: color == cs.surface
                                ? Border.all(color: cs.onSurface)
                                : null,
                          ),
                        ),
                    ],
                  ),
                ),
                onTap: editAppearance,
              ),
            ],
          ),
          SettingsGroup(
            label: l.t15_everyday,
            index: 1,
            identity: 'settings-1',
            children: [
              SettingsNavigationRow(
                icon: Icons.notifications_none_outlined,
                title: l.t15_reminders,
                subtitle: l.t15_remindersSubtitle,
                onTap: () => onSection(SettingsSection.reminders),
              ),
              SettingsNavigationRow(
                icon: Icons.accessibility_new_outlined,
                title: l.t15_accessibility,
                subtitle: l.t15_accessibilitySubtitle,
                onTap: editAppearance,
              ),
              const ReduceMotionRow(),
              SettingsNavigationRow(
                icon: Icons.language_outlined,
                title: l.settings_language,
                subtitle: language == null
                    ? l.settings_languageSystem
                    : language.languageCode == 'ro'
                    ? l.settings_languageRomanian
                    : l.settings_languageEnglish,
                onTap: onLanguage,
              ),
            ],
          ),
          SettingsGroup(
            label: l.t15_yourData,
            index: 2,
            identity: 'settings-2',
            children: [
              SettingsNavigationRow(
                icon: Icons.file_download_outlined,
                title: l.t15_backups,
                subtitle: l.t15_backupsSubtitle,
                onTap: () => onSection(SettingsSection.backups),
              ),
              SettingsNavigationRow(
                icon: Icons.storage_outlined,
                title: l.t15_storageRecovery,
                subtitle: l.t15_storageSubtitle,
                onTap: () => onSection(SettingsSection.storage),
              ),
              SettingsNavigationRow(
                icon: Icons.dns_outlined,
                title: l.t15_serverConnection,
                subtitle: server == null
                    ? l.t15_notConnected
                    : Uri.tryParse(server)?.host ?? l.t15_notConnected,
                onTap: () => onSection(SettingsSection.account),
              ),
            ],
          ),
          SettingsGroup(
            label: l.t15_privacyAccess,
            index: 3,
            identity: 'settings-3',
            children: [
              SettingsNavigationRow(
                icon: Icons.lock_outline,
                title: l.t15_protection,
                subtitle: l.t15_protectionSubtitle,
                onTap: () => onSection(SettingsSection.protection),
              ),
              SettingsNavigationRow(
                icon: Icons.people_outline,
                title: l.t08_people,
                subtitle: l.t15_peopleSubtitle,
                onTap: () => onSection(SettingsSection.people),
              ),
              SettingsNavigationRow(
                icon: Icons.medication_outlined,
                title: l.settings_pillEditing,
                subtitle: l.t15_medicationSubtitle,
                onTap: () => onSection(SettingsSection.medication),
              ),
              SettingsNavigationRow(
                icon: Icons.sync_outlined,
                title: l.settings_data,
                subtitle: l.t15_dataSubtitle,
                onTap: () => onSection(SettingsSection.data),
              ),
              SettingsNavigationRow(
                icon: Icons.info_outline,
                title: l.settings_about,
                onTap: () => onSection(SettingsSection.about),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A titled group of settings rows on one soft rounded surface, matching the
/// medication form sections. When [index] and [identity] are given the group
/// rises in once with the other groups of that screen.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.label,
    required this.children,
    this.index,
    this.identity,
    this.trailing,
  });
  final String label;
  final List<Widget> children;
  final int? index;
  final Object? identity;

  /// Optional widget after the label, such as a status chip.
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final group = Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, end: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: settingsMutedColor(theme),
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          const SizedBox(height: 9),
          Material(
            color: theme.colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: settingsBorderColor(theme).withValues(alpha: .7),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i != 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      indent: 16,
                      endIndent: 16,
                      color: settingsBorderColor(theme).withValues(alpha: .7),
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
    if (index == null || identity == null) return group;
    return StaggeredEntrance(index: index!, identity: identity!, child: group);
  }
}

class SettingsNavigationRow extends StatelessWidget {
  const SettingsNavigationRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.accessory,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? accessory;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A wrapping text column keeps long/Romanian labels and system large text
    // readable. Height grows instead of truncating the referenced proportions.
    // The press physics read raw pointers (no onTap), so the InkWell keeps the
    // tap, its semantics and keyboard activation.
    return Pressable(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              ExcludeSemantics(
                child: SettingsRowIcon(icon, theme.colorScheme.onSurface),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: settingsMutedColor(theme),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (accessory != null &&
                  MediaQuery.textScalerOf(context).scale(14) <= 18) ...[
                const SizedBox(width: 8),
                accessory!,
              ],
              const SizedBox(width: 8),
              ExcludeSemantics(
                child: Icon(
                  Icons.chevron_right,
                  size: 22,
                  color: settingsMutedColor(theme),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// This app's own reduced-motion choice, saved at once. When the phone already
/// removes animations the switch shows on and locked, and says why. Accessible
/// navigation (any accessibility service) never locks it.
///
/// In the wide Settings' list ([dense]) the row is as narrow as the others: it
/// drops the hint, except to say that the phone has already chosen.
class ReduceMotionRow extends ConsumerWidget {
  const ReduceMotionRow({super.key, this.dense = false});

  /// Fits a narrow list: tighter padding, a smaller icon and no hint.
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final byPhone = AppMotion.quietByPhone(context);
    final chosen = ref.watch(reduceMotionProvider);
    final saved = ref.watch(appearanceNotifierProvider).hasValue;
    final onChanged = byPhone || !saved
        ? null
        : (bool value) => _choose(context, ref, value);
    return MergeSemantics(
      child: InkWell(
        key: const ValueKey('reduce-motion'),
        onTap: onChanged == null ? null : () => onChanged(!chosen),
        // In the list the row is as tall as its neighbours, whatever its
        // switch and label.
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: dense ? 52 : 0),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: dense ? 12 : 16,
              vertical: dense ? 6 : 12,
            ),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: Icon(
                    Icons.animation,
                    size: dense ? 24 : 28,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                SizedBox(width: dense ? 12 : 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.settings_reduceMotion,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (!dense || byPhone) ...[
                        const SizedBox(height: 3),
                        Text(
                          byPhone
                              ? l.settings_reduceMotionByPhone
                              : l.settings_reduceMotionHint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: settingsMutedColor(theme),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(width: dense ? 4 : 8),
                if (dense)
                  // The list is narrow: a slightly smaller switch leaves the
                  // label room to stay on one line. The whole row still taps.
                  SizedBox(
                    width: 42,
                    height: 32,
                    child: FittedBox(
                      child: Switch(
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        value: byPhone || chosen,
                        onChanged: onChanged,
                      ),
                    ),
                  )
                else
                  Switch(value: byPhone || chosen, onChanged: onChanged),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _choose(BuildContext context, WidgetRef ref, bool value) async {
    HapticFeedback.selectionClick();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failed = AppLocalizations.of(context).t11_saveError;
    try {
      await ref
          .read(appearanceNotifierProvider.notifier)
          .change((applied) => applied.copyWith(reduceMotion: value));
    } on Object {
      messenger?.showSnackBar(SnackBar(content: Text(failed)));
    }
  }
}

/// Thin outline symbols retain the distinctive reference shapes where Material
/// glyphs use a different silhouette (deck, person, file and server cylinder).
class SettingsRowIcon extends StatelessWidget {
  const SettingsRowIcon(this.icon, this.color, {super.key, this.size = 28});
  final IconData icon;
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) {
    if (![
      Icons.layers_outlined,
      Icons.accessibility_new_outlined,
      Icons.file_download_outlined,
      Icons.dns_outlined,
    ].contains(icon)) {
      return Icon(icon, size: size, color: color);
    }
    return CustomPaint(
      size: Size.square(size),
      painter: _SettingsSymbolPainter(icon, color),
    );
  }
}

class _SettingsSymbolPainter extends CustomPainter {
  const _SettingsSymbolPainter(this.icon, this.color);
  final IconData icon;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final ink = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    if (icon == Icons.layers_outlined) {
      path
        ..moveTo(2, 7)
        ..lineTo(12, 1)
        ..lineTo(22, 7)
        ..lineTo(12, 13)
        ..close();
      path
        ..moveTo(2, 12)
        ..lineTo(12, 18)
        ..lineTo(22, 12)
        ..moveTo(2, 17)
        ..lineTo(12, 23)
        ..lineTo(22, 17);
    } else if (icon == Icons.accessibility_new_outlined) {
      canvas.drawCircle(const Offset(12, 3), 2, ink);
      path
        ..moveTo(2, 8)
        ..lineTo(12, 10)
        ..lineTo(22, 8)
        ..moveTo(12, 10)
        ..lineTo(12, 16)
        ..lineTo(7, 23)
        ..moveTo(12, 16)
        ..lineTo(17, 23);
    } else if (icon == Icons.file_download_outlined) {
      path
        ..moveTo(4, 1)
        ..lineTo(14, 1)
        ..lineTo(21, 8)
        ..lineTo(21, 23)
        ..lineTo(4, 23)
        ..close();
      path
        ..moveTo(14, 1)
        ..lineTo(14, 8)
        ..lineTo(21, 8)
        ..moveTo(12, 11)
        ..lineTo(12, 19)
        ..moveTo(8, 15)
        ..lineTo(12, 19)
        ..lineTo(16, 15);
    } else {
      canvas.drawOval(const Rect.fromLTRB(2, 2, 22, 8), ink);
      path
        ..moveTo(2, 5)
        ..lineTo(2, 20)
        ..cubicTo(2, 24, 22, 24, 22, 20)
        ..lineTo(22, 5)
        ..moveTo(2, 12)
        ..cubicTo(2, 16, 22, 16, 22, 12);
    }
    canvas.drawPath(path, ink);
  }

  @override
  bool shouldRepaint(_SettingsSymbolPainter old) =>
      old.icon != icon || old.color != color;
}
