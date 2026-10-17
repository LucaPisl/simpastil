import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

double _ratio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  for (final entry in {
    'light': AppTheme.light(),
    'dark': AppTheme.dark(),
  }.entries) {
    test('choice chips read as enabled options in ${entry.key}', () {
      final chip = entry.value.chipTheme;
      final off = chip.labelStyle!;
      Color inkFor(Set<WidgetState> states) =>
          WidgetStateProperty.resolveAs<Color?>(off.color, states)!;
      final offInk = inkFor(<WidgetState>{});
      final onInk = inkFor({WidgetState.selected});
      final disabledInk = inkFor({WidgetState.disabled});
      final surface = entry.value.colorScheme.surface;

      expect(_ratio(offInk, chip.backgroundColor!), greaterThanOrEqualTo(4.5));
      expect(_ratio(onInk, chip.selectedColor!), greaterThanOrEqualTo(4.5));
      // Selected is visibly different from unselected, and a firm border
      // separates a chip from the page (3:1 non-text contrast).
      expect(chip.selectedColor, isNot(chip.backgroundColor));
      final border = chip.side as WidgetStateBorderSide;
      expect(
        _ratio(border.resolve(<WidgetState>{})!.color, surface),
        greaterThanOrEqualTo(3),
      );
      // A real disabled chip is still quieter than an enabled one.
      expect(
        _ratio(Color.alphaBlend(disabledInk, surface), surface),
        lessThan(_ratio(offInk, surface)),
      );
    });
  }

  // The label ink that actually reaches the screen, not just the theme data.
  for (final entry in {
    'light': AppTheme.light(),
    'dark': AppTheme.dark(),
  }.entries) {
    testWidgets('rendered chip labels are legible in ${entry.key}', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: entry.value,
          home: Scaffold(
            body: Column(
              children: [
                ChoiceChip(
                  label: const Text('On'),
                  selected: false,
                  onSelected: (_) {},
                ),
                ChoiceChip(
                  label: const Text('Sel'),
                  selected: true,
                  onSelected: (_) {},
                ),
                const ChoiceChip(
                  label: Text('Off'),
                  selected: false,
                  onSelected: null,
                ),
              ],
            ),
          ),
        ),
      );
      final scheme = entry.value.colorScheme;
      Color ink(String t) =>
          tester.renderObject<RenderParagraph>(find.text(t)).text.style!.color!;
      expect(ink('On'), scheme.onSurface);
      expect(ink('Sel'), scheme.onPrimaryContainer);
      // Disabled is quieter but is not the unstyled default.
      expect(ink('Off').a, lessThan(1));
      expect(ink('Off').a, greaterThan(0.3));
    });
  }
}
