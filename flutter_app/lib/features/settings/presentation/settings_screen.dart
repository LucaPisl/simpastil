import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/window_size.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/router/back_policy.dart';
import 'language_settings.dart';
import 'settings_master_detail.dart';
import 'settings_overview.dart';
import 'settings_pages.dart';
import '../../../l10n/app_localizations.dart';

/// Settings owns navigation only; each detail owns its reads and form state.
///
/// A phone shows the overview and pushes each page over it. A medium or
/// expanded window shows the list and the selected page side by side, with
/// Reminders open first; the choice survives turning the tablet.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.section});
  final SettingsSection? section;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  SettingsSection _selected = SettingsSection.reminders;

  void _showLanguagePicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final dl = AppLocalizations.of(ctx);
        final theme = Theme.of(ctx);
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
                  child: Semantics(
                    header: true,
                    child: Text(
                      dl.settings_language,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                LanguageChoiceList(onChosen: () => Navigator.of(ctx).pop()),
              ],
            ),
          ),
        );
      },
    );
  }

  Route<void> _pageRoute(SettingsSection section) => PageRouteBuilder<void>(
    transitionDuration: AppMotion.duration(context),
    reverseTransitionDuration: AppMotion.duration(context),
    pageBuilder: (_, _, _) => SettingsScreen(section: section),
    transitionsBuilder: (context, animation, secondary, child) {
      if (AppMotion.duration(context) == Duration.zero) return child;
      return AnimatedBuilder(
        animation: Listenable.merge([animation, secondary]),
        child: child,
        builder: (context, child) {
          final entering = const Interval(
            .5,
            1,
            curve: AppMotion.curve,
          ).transform(animation.value);
          final leaving =
              1 -
              const Interval(
                0,
                .5,
                curve: AppMotion.curve,
              ).transform(secondary.value);
          final inactive =
              entering * leaving == 0 ||
              !(ModalRoute.isCurrentOf(context) ?? false);
          return IgnorePointer(
            ignoring: inactive,
            child: ExcludeSemantics(
              excluding: inactive,
              child: Opacity(opacity: entering * leaving, child: child),
            ),
          );
        },
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    // A page pushed over the overview: the page alone, on any window.
    if (section != null) return settingsPageFor(section);
    if (WindowClass.of(context) != WindowClass.compact) {
      return SettingsMasterDetail(
        selected: _selected,
        onSelected: (next) => setState(() => _selected = next),
      );
    }
    // Back from the overview falls to Today when nothing is beneath it.
    return HomeFallbackPop(
      child: SettingsOverview(
        onSection: (section) =>
            Navigator.of(context).push<void>(_pageRoute(section)),
        onLanguage: () => _showLanguagePicker(context),
      ),
    );
  }
}
