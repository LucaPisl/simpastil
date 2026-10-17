import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_activity.dart';
import 'package:simpastil/core/storage/appearance_preferences.dart';
import 'package:simpastil/features/pills/presentation/medication_compact_list.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/shared/widgets/status_chip.dart';

/// "Running low" has one colour, in the theme, in every palette; a screen
/// must not pick its own amber.
void main() {
  final themes = {
    'light': AppTheme.light(),
    'dark': AppTheme.dark(),
    'light high contrast': AppTheme.appearance(
      AppearancePreferences(highContrast: true),
      Brightness.light,
    ),
    'dark high contrast': AppTheme.appearance(
      AppearancePreferences(highContrast: true),
      Brightness.dark,
    ),
  };

  for (final entry in themes.entries) {
    test('the warning colour reads as text on a surface in ${entry.key}', () {
      final theme = entry.value;
      final warning = theme.extension<AppSemanticColors>()!.statusWarning;
      expect(
        AppTheme.contrast(warning, theme.colorScheme.surface),
        greaterThanOrEqualTo(4.5),
      );
      // The attention tone of status chips is the same colour.
      expect(statusToneColor(theme, StatusTone.attention), warning);
    });
  }

  test('high contrast is stronger than the standard palette', () {
    double ratio(ThemeData t) => AppTheme.contrast(
      t.extension<AppSemanticColors>()!.statusWarning,
      t.colorScheme.surface,
    );
    expect(ratio(themes['light high contrast']!), greaterThan(7));
    expect(ratio(themes['dark high contrast']!), greaterThan(7));
  });

  test('it blends between palettes and survives copyWith', () {
    final mid = AppSemanticColors.light.lerp(AppSemanticColors.dark, .5);
    expect(
      mid.statusWarning,
      Color.lerp(
        AppSemanticColors.light.statusWarning,
        AppSemanticColors.dark.statusWarning,
        .5,
      ),
    );
    const own = Color(0xFF123456);
    expect(
      AppSemanticColors.light.copyWith(statusWarning: own).statusWarning,
      own,
    );
    expect(
      AppSemanticColors.light.copyWith(statusMissed: own).statusWarning,
      AppSemanticColors.light.statusWarning,
    );
  });

  testWidgets('the stock strip marks "running low" with the theme warning', (
    tester,
  ) async {
    const own = Color(0xFF123456);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light().copyWith(
          extensions: [AppSemanticColors.light.copyWith(statusWarning: own)],
        ),
        home: const Scaffold(
          body: MedicationStockStrip(
            summary: MedicationListSummary(
              status: StockStatus.soon,
              attention: ['Fictional'],
              scheduled: 1,
              asNeeded: 0,
            ),
          ),
        ),
      ),
    );
    final dots = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byKey(const ValueKey('medication-stock-strip')),
            matching: find.byType(Container),
          ),
        )
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.shape == BoxShape.circle)
        .map((d) => d.color);
    expect(dots, [own]);
  });
}
