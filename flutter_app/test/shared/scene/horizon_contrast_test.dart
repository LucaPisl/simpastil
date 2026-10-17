import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/scene/horizon_painter.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

import 'scene_test_support.dart';

void main() {
  for (final b in Brightness.values) {
    final theme = themeFor(b);
    final scheme = theme.colorScheme;
    final palette = HorizonPalette.from(
      scheme: scheme,
      semantic: theme.extension<AppSemanticColors>()!,
      background: theme.scaffoldBackgroundColor,
      highContrast: false,
    );

    test('${b.name}: sky stops keep their luminance band all day', () {
      for (var minute = 0; minute < 1440; minute += 7) {
        final model = modelFor(at(minute ~/ 60, minute % 60), b);
        for (final stop in model.skyStops) {
          final l = stop.computeLuminance();
          if (b == Brightness.light) {
            expect(l, greaterThanOrEqualTo(.80), reason: 'minute $minute');
          } else {
            expect(l, lessThanOrEqualTo(.03), reason: 'minute $minute');
          }
        }
      }
    });

    test('${b.name}: title 7:1 and secondary text 4.5:1 on sky and ground', () {
      final grounds = [palette.groundTop, palette.groundBottom];
      for (var minute = 0; minute < 1440; minute += 7) {
        final model = modelFor(at(minute ~/ 60, minute % 60), b);
        final backgrounds = [
          for (var y = 0.0; y <= model.horizonY; y += 20) model.skyColorAt(y),
          ...grounds,
        ];
        for (final bg in backgrounds) {
          expect(
            AppTheme.contrast(scheme.onSurface, bg),
            greaterThanOrEqualTo(7),
            reason: 'minute $minute',
          );
          expect(
            AppTheme.contrast(scheme.onSurfaceVariant, bg),
            greaterThanOrEqualTo(4.5),
            reason: 'minute $minute',
          );
        }
      }
    });

    test('${b.name}: marks are at least 3:1 against their local sky', () {
      for (var minute = 0; minute < 1440; minute += 7) {
        final model = modelFor(at(minute ~/ 60, minute % 60), b);
        for (final mark in model.marks) {
          final sky = model.skyColorAt(mark.rect.center.dy);
          final c = AppTheme.contrast(palette.markColor(mark.state), sky);
          expect(
            c,
            greaterThanOrEqualTo(3),
            reason: '${mark.id} at minute $minute',
          );
        }
      }
    });
  }
}
