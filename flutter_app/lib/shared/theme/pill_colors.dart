import 'package:flutter/material.dart';

import '../../core/medication/pill_color_display.dart';
import '../../l10n/app_localizations.dart';

export '../../core/medication/pill_color_display.dart' show displayHexFor;

class PillColor {
  const PillColor(this.hex, this.label);
  final String hex;
  final String label;
}

/// The palette the picker offers, in picker order. A medication stores one of
/// these hex strings; colours stored by earlier versions are mapped to their
/// display equivalent by [displayHexFor], never rewritten in the database.
const kPillColors = [
  PillColor('#FD2B35', 'Coral'),
  PillColor('#FB8B21', 'Amber'),
  PillColor('#FFDF2E', 'Yellow'),
  PillColor('#54882D', 'Green'),
  PillColor('#30ECF8', 'Teal'),
  PillColor('#2DA2DE', 'Blue'),
  PillColor('#C14BF7', 'Lavender'),
  PillColor('#AAA9B4', 'Grey'),
  PillColor('#E0157D', 'Rose'),
  PillColor('#FFA070', 'Peach'),
  PillColor('#B2349B', 'Magenta'),
  PillColor('#0E3DA7', 'Indigo'),
];

/// Whether two stored colours are the same palette colour once displayed, so
/// an old hex and its new equivalent count as one.
bool isSamePillColor(String? a, String? b) {
  if (a == null || b == null) return false;
  return displayHexFor(a).toUpperCase() == displayHexFor(b).toUpperCase();
}

/// A medication's colour as it is drawn: [tryColorFromHex] after the palette
/// mapping. Null when [hex] is missing or unparseable.
Color? displayColorFromHex(String? hex) {
  if (hex == null) return null;
  return tryColorFromHex(displayHexFor(hex));
}

/// A darker shade of [color] for the 1 px outline every medication mark wears,
/// so a pale colour keeps an edge on a light surface and a dark one on a dark
/// surface.
Color pillOutlineColor(Color color) {
  final hsl = HSLColor.fromColor(color);
  return hsl.withLightness((hsl.lightness * .62).clamp(0.0, 1.0)).toColor();
}

/// A round swatch in a medication's colour with the 1 px darker outline every
/// medication mark wears. Decorative: the medication's name is printed beside
/// it.
class PillColorDot extends StatelessWidget {
  const PillColorDot({super.key, required this.color, this.size = 12});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: pillOutlineColor(color), width: 1),
    ),
  );
}

Color colorFromHex(String hex) {
  final code = hex.replaceAll('#', '');
  return Color(int.parse('FF$code', radix: 16));
}

Color? tryColorFromHex(String? hex) {
  if (hex == null) return null;
  try {
    return colorFromHex(hex);
  } catch (_) {
    return null;
  }
}

String? labelForHex(String? hex) {
  if (hex == null) return null;
  final normalized = hex.toUpperCase();
  for (final pc in kPillColors) {
    if (pc.hex.toUpperCase() == normalized) return pc.label;
  }
  final shown = displayHexFor(hex).toUpperCase();
  for (final pc in kPillColors) {
    if (pc.hex.toUpperCase() == shown) return pc.label;
  }
  return null;
}

String localizedColorLabel(AppLocalizations l, String englishLabel) {
  return switch (englishLabel) {
    'Coral' => l.colors_coral,
    'Amber' => l.colors_amber,
    'Yellow' => l.colors_yellow,
    'Green' => l.colors_green,
    'Teal' => l.colors_teal,
    'Blue' => l.colors_blue,
    'Lavender' => l.colors_lavender,
    'Grey' => l.colors_grey,
    'Rose' => l.colors_rose,
    'Peach' => l.colors_peach,
    'Magenta' => l.colors_magenta,
    'Indigo' => l.colors_indigo,
    _ => englishLabel,
  };
}
