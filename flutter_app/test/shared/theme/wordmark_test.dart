import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/scene/horizon_model.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/shared/theme/wordmark.dart';

void main() {
  for (final (name, theme) in [
    ('light', AppTheme.light()),
    ('dark', AppTheme.dark()),
  ]) {
    test('the $name wordmark reads at 4.5:1 on the page and every sky', () {
      final ink = wordmarkInk(theme);
      final backgrounds = [
        theme.scaffoldBackgroundColor,
        theme.colorScheme.surface,
        ...HorizonModel.skyColors(theme.brightness),
      ];
      for (final background in backgrounds) {
        expect(
          AppTheme.contrast(ink, background),
          greaterThanOrEqualTo(4.5),
          reason: '$background',
        );
      }
    });
  }

  test('a dark theme keeps its brand ink when it already reads', () {
    final theme = AppTheme.dark();
    expect(wordmarkInk(theme), theme.colorScheme.primary);
  });
}
