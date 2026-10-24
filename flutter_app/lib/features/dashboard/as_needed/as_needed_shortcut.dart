import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';

/// The small floating "As needed" pill of the Focus deck, tonal so it never
/// competes with the filled "Taken now" of the next dose. It fades and slides
/// in while the As needed section is below the visible area and scrolls it
/// into view when tapped. Lives in the Today scaffold's floating action slot,
/// so it sits above the bottom navigation and moves clear of snackbars. Under
/// Reduce motion it appears and disappears at once.
class AsNeededShortcut extends StatelessWidget {
  const AsNeededShortcut({
    super.key,
    required this.visible,
    required this.onPressed,
  });

  /// True while the section is below the visible area.
  final ValueListenable<bool> visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final duration = AppMotion.quiet(context)
        ? Duration.zero
        : AppMotion.standard;
    return ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (context, shown, _) => IgnorePointer(
        ignoring: !shown,
        child: ExcludeSemantics(
          excluding: !shown,
          child: AnimatedSlide(
            duration: duration,
            curve: AppMotion.curve,
            offset: shown ? Offset.zero : const Offset(0, .6),
            child: AnimatedOpacity(
              duration: duration,
              curve: AppMotion.curve,
              opacity: shown ? 1 : 0,
              child: Semantics(
                button: true,
                label: l.asn_jumpLabel,
                excludeSemantics: true,
                onTap: onPressed,
                child: Material(
                  key: const ValueKey('as-needed-jump'),
                  color: colors.secondaryContainer,
                  shape: const StadiumBorder(),
                  elevation: 3,
                  shadowColor: colors.shadow.withValues(alpha: .5),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: onPressed,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          18,
                          0,
                          14,
                          0,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              l.t08_asNeeded,
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(
                                    color: colors.onSecondaryContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              Icons.arrow_downward_rounded,
                              size: 18,
                              color: colors.onSecondaryContainer,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
