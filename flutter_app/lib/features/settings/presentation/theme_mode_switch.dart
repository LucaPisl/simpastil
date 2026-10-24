import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/appearance_preferences.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/motion/theme_reveal.dart';

/// Light, automatic or dark in one touch from Settings. When the choice
/// changes what is on screen, the new look spreads out from the segment.
class ThemeModeRow extends ConsumerWidget {
  const ThemeModeRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final mode =
        ref.watch(appearanceNotifierProvider).value?.mode ??
        AppearanceMode.system;
    final title = Row(
      children: [
        ExcludeSemantics(
          child: Icon(
            Icons.contrast,
            size: 26,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(width: 18),
        Flexible(
          child: Text(
            l.settings_theme,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
    final control = ThemeModeSwitch(
      mode: mode,
      onChanged: (from, next) => _choose(context, ref, from, next),
    );
    final stacked = MediaQuery.textScalerOf(context).scale(14) > 18;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, const SizedBox(height: 10), control],
            )
          : Row(
              children: [
                Expanded(child: title),
                const SizedBox(width: 8),
                control,
              ],
            ),
    );
  }

  Future<void> _choose(
    BuildContext context,
    WidgetRef ref,
    BuildContext from,
    AppearanceMode next,
  ) async {
    HapticFeedback.selectionClick();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failed = AppLocalizations.of(context).t11_saveError;
    final shown = Theme.of(context).brightness;
    final coming = switch (next) {
      AppearanceMode.dark => Brightness.dark,
      AppearanceMode.light => Brightness.light,
      AppearanceMode.system => MediaQuery.platformBrightnessOf(context),
    };
    Future<void> change() => ref
        .read(themeModeNotifierProvider.notifier)
        .setThemeMode(AppThemeMode.values.byName(next.name));
    final reveal = ThemeReveal.maybeOf(context);
    try {
      if (reveal != null && shown != coming) {
        await reveal.reveal(from: from, change: change);
      } else {
        await change();
      }
    } on Object {
      messenger?.showSnackBar(SnackBar(content: Text(failed)));
    }
  }
}

/// Three segments, sun, automatic and moon, on a track; a thumb glides to the
/// chosen one.
class ThemeModeSwitch extends StatelessWidget {
  const ThemeModeSwitch({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final AppearanceMode mode;

  /// Called with the tapped segment's context, so a reveal can start there.
  final void Function(BuildContext from, AppearanceMode mode) onChanged;

  static const order = [
    AppearanceMode.light,
    AppearanceMode.system,
    AppearanceMode.dark,
  ];
  static const _segment = Size(48, 48);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final index = order.indexOf(mode);
    final duration = AppMotion.duration(context, milliseconds: 380);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: SizedBox(
        width: _segment.width * order.length,
        height: _segment.height,
        child: Stack(
          children: [
            AnimatedAlign(
              duration: duration,
              curve: Curves.easeOutBack,
              alignment: AlignmentDirectional(index - 1.0, 0),
              child: Container(
                key: const ValueKey('theme-mode-thumb'),
                width: _segment.width,
                height: _segment.height,
                decoration: BoxDecoration(
                  color: cs.primary,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: cs.primary.withValues(alpha: .35),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
            Row(
              children: [
                for (final option in order)
                  Builder(
                    builder: (segment) {
                      final selected = option == mode;
                      return Semantics(
                        button: true,
                        selected: selected,
                        inMutuallyExclusiveGroup: true,
                        label: switch (option) {
                          AppearanceMode.light => l.settings_themeLight,
                          AppearanceMode.system => l.settings_themeAuto,
                          AppearanceMode.dark => l.settings_themeDark,
                        },
                        child: InkResponse(
                          key: ValueKey('theme-mode-${option.name}'),
                          radius: 24,
                          onTap: selected
                              ? null
                              : () => onChanged(segment, option),
                          child: SizedBox.fromSize(
                            size: _segment,
                            child: TweenAnimationBuilder<Color?>(
                              duration: duration,
                              tween: ColorTween(
                                end: selected
                                    ? cs.onPrimary
                                    : cs.onSurfaceVariant,
                              ),
                              builder: (context, color, _) => Icon(
                                switch (option) {
                                  AppearanceMode.light =>
                                    Icons.light_mode_outlined,
                                  AppearanceMode.system =>
                                    Icons.brightness_auto_outlined,
                                  AppearanceMode.dark =>
                                    Icons.dark_mode_outlined,
                                },
                                size: 21,
                                color: color,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
