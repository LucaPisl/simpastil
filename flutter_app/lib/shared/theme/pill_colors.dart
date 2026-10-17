import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

class PillColor {
  const PillColor(this.hex, this.label);
  final String hex;
  final String label;
}

const kPillColors = [
  PillColor('#E57373', 'Coral'),
  PillColor('#FFB74D', 'Amber'),
  PillColor('#FFD54F', 'Yellow'),
  PillColor('#81C784', 'Green'),
  PillColor('#4DD0E1', 'Teal'),
  PillColor('#64B5F6', 'Blue'),
  PillColor('#BA68C8', 'Lavender'),
  PillColor('#90A4AE', 'Grey'),
  PillColor('#EC407A', 'Rose'),
  PillColor('#FF8A65', 'Peach'),
  PillColor('#66BB6A', 'Mint'),
  PillColor('#5C6BC0', 'Indigo'),
];

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
    'Mint' => l.colors_mint,
    'Indigo' => l.colors_indigo,
    _ => englishLabel,
  };
}
