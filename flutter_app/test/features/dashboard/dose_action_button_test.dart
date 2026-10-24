import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/dashboard/today_layout/dose_morph.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

const _shape = DoseButtonShape(
  height: 54,
  radius: 15,
  iconSize: 18,
  expand: true,
  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
);

Widget _button(ThemeData theme, {required bool done}) => MaterialApp(
  theme: theme,
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: DoseActionButton(
        done: done,
        skipped: false,
        filled: true,
        takeLabel: 'Taken now',
        doneLabel: 'Taken 8:02',
        undoLabel: 'Undo',
        savingLabel: 'Saving…',
        saving: false,
        onPressed: () {},
        moment: done ? (occurrenceId: 'o1', token: 't1', undo: false) : null,
        claim: (_) => true,
        takeShape: _shape,
      ),
    ),
  ),
);

void main() {
  for (final (name, theme) in [
    ('light', AppTheme.light()),
    ('dark', AppTheme.dark()),
  ]) {
    testWidgets('the words stay readable through the whole moment ($name)', (
      tester,
    ) async {
      await tester.pumpWidget(_button(theme, done: false));
      await tester.pumpWidget(_button(theme, done: true));
      final surface = theme.colorScheme.surface;
      final fills = <int, Color>{};
      var frames = 0;
      for (var ms = 0; ms <= 1200; ms += 8) {
        final style = tester
            .widget<OutlinedButton>(find.byType(OutlinedButton))
            .style!;
        final behind = Color.alphaBlend(
          style.backgroundColor!.resolve({})!,
          surface,
        );
        final ink = style.foregroundColor!.resolve({})!;
        fills[ms] = behind;
        expect(
          AppTheme.contrast(ink, behind),
          greaterThanOrEqualTo(4.5),
          reason: 'at $ms ms',
        );
        // One label carries the receipt's words, never two faded copies.
        expect(
          find.text('Taken 8:02').evaluate().length,
          lessThanOrEqualTo(1),
          reason: 'at $ms ms',
        );
        frames++;
        await tester.pump(const Duration(milliseconds: 8));
      }
      expect(frames, greaterThan(100));
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsOneWidget);

      // The settle fades the green out to the bare surface; no frame on the
      // way borrows a hue from either end's clear fill.
      final green = fills[800]!;
      for (final MapEntry(key: ms, value: fill) in fills.entries) {
        if (ms < 800) continue;
        for (final (x, a, b) in [
          (fill.r, green.r, surface.r),
          (fill.g, green.g, surface.g),
          (fill.b, green.b, surface.b),
        ]) {
          expect(
            x,
            inInclusiveRange((a < b ? a : b) - .01, (a > b ? a : b) + .01),
            reason: 'at $ms ms',
          );
        }
      }
    });
  }
}
