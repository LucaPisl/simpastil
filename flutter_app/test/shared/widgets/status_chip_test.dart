import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/shared/widgets/status_chip.dart';

void main() {
  test('every tone reads at 4.5:1 on its own chip in both themes', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      for (final tone in StatusTone.values) {
        final base = statusToneColor(theme, tone);
        final surface = Color.alphaBlend(
          base.withValues(
            alpha: theme.brightness == Brightness.dark ? .18 : .12,
          ),
          theme.colorScheme.surface,
        );
        final ink = AppTheme.readable(base, [surface], minimum: 4.5);
        expect(
          AppTheme.contrast(ink, surface),
          greaterThanOrEqualTo(4.5),
          reason: '$tone on ${theme.brightness}',
        );
      }
    }
  });

  testWidgets('long labels wrap instead of overflowing at 2x text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StatusChip(
                    label: 'Ultima copie verificată nu mai este disponibilă',
                    tone: StatusTone.problem,
                  ),
                  SizedBox(height: 12),
                  CalmNotice(
                    text: 'Nothing changes on this phone until you apply.',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      find.text('Ultima copie verificată nu mai este disponibilă'),
      findsOneWidget,
    );
  });
}
