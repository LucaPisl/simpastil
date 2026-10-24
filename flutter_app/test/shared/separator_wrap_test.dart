import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/format/clock.dart';

/// The lines [text] wraps to at [width] and [scale].
List<String> _lines(String text, double width, double scale) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: const TextStyle(fontSize: 14, fontFamily: 'Ahem'),
    ),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.linear(scale),
  )..layout(maxWidth: width);
  final out = <String>[];
  var start = 0;
  for (final m in painter.computeLineMetrics()) {
    final end = painter
        .getLineBoundary(
          painter.getPositionForOffset(Offset(1, m.baseline - m.ascent + 1)),
        )
        .end;
    out.add(text.substring(start, end).trimRight());
    start = end;
  }
  return out;
}

void main() {
  final samples = <String>[
    '14:58 · 15:10 · 15:22',
    '2:58 PM · 3:10 PM · 3:22 PM',
    for (final code in ['en', 'ro'])
      lookupAppLocalizations(Locale(code)).t09_legacyDosage,
  ];
  for (final sample in samples) {
    for (final width in [260.0, 300.0, 340.0, 400.0]) {
      test('no line of "$sample" ends in a dot at $width wide, x1.3', () {
        final lines = _lines(
          keepTimesWhole(keepSeparatorsAttached(sample)),
          width,
          1.3,
        );
        for (final line in lines) {
          expect(line.endsWith('·'), isFalse, reason: '$lines');
        }
      });
    }
  }
}
