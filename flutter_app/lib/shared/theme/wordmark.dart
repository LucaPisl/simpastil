import 'package:flutter/material.dart';

import '../scene/horizon_model.dart';
import 'app_theme.dart';

/// The brand ink for the "Simpastil" wordmark: the theme's primary, darkened
/// (or lightened, in a dark theme) toward the text color only as far as it
/// takes to read at [minimum] against the page and every sky, a sky leaning
/// toward a chosen accent included.
@visibleForTesting
Color wordmarkInk(ThemeData theme, {double minimum = 4.5}) {
  final colors = theme.colorScheme;
  final skies = HorizonModel.skyColors(colors.brightness);
  final backgrounds = [
    theme.scaffoldBackgroundColor,
    colors.surface,
    for (final sky in skies) ...[sky, Color.lerp(sky, colors.primary, .10)!],
  ];
  double worst(Color ink) => backgrounds
      .map((b) => AppTheme.contrast(ink, b))
      .reduce((a, b) => a < b ? a : b);
  for (var step = 0; step <= 20; step++) {
    final ink = Color.lerp(colors.primary, colors.onSurface, step / 20)!;
    if (worst(ink) >= minimum) return ink;
  }
  return colors.onSurface;
}

/// "Simpastil" at the start of a page's app bar.
class Wordmark extends StatelessWidget {
  const Wordmark(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.titleLarge?.copyWith(
        color: wordmarkInk(theme),
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}
