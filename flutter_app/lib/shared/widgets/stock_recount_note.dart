import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// "Needs a recount": a count that did not move for a dose it cannot subtract
/// exactly (a third of a tablet). A warning icon and words, never colour
/// alone; [explain] adds the sentence that says why and what to do.
class StockRecountNote extends StatelessWidget {
  const StockRecountNote({
    super.key,
    this.explain = false,
    this.style,
    this.center = false,
  });

  final bool explain;
  final TextStyle? style;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final warning =
        theme.extension<AppSemanticColors>()?.statusWarning ??
        theme.colorScheme.tertiary;
    final base = style ?? theme.textTheme.labelMedium;
    return Semantics(
      container: true,
      label: explain
          ? '${l.stock_needsRecount}. ${l.stock_needsRecountExplain}'
          : l.stock_needsRecount,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: center
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: warning),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    l.stock_needsRecount,
                    style: base?.copyWith(
                      color: warning,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (explain) ...[
              const SizedBox(height: 4),
              Text(
                l.stock_needsRecountExplain,
                textAlign: center ? TextAlign.center : TextAlign.start,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
