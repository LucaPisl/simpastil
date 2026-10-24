import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/scene/dose_bead.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

/// The smallest radius a bead is drawn at: History's calendar days shrink
/// beads to this when a day holds eight.
const _calendarMinRadius = 2.6;

const _order = [
  DoseBead.taken,
  DoseBead.missed,
  DoseBead.skipped,
  DoseBead.planned,
  DoseBead.unrecorded,
  DoseBead.asNeeded,
];

/// One bead at calendar minimum radius in a 12 x 12 dp cell, rasterised at
/// [scale] and reduced to gray: the only thing left is shape and luminance.
Future<Uint8List> _gray(
  DoseBead bead, {
  required Color color,
  required Color cut,
  double scale = 3,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(scale);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 12, 12), Paint()..color = cut);
  paintDoseBead(
    canvas,
    const Offset(6, 6),
    _calendarMinRadius,
    bead,
    color: color,
    cut: cut,
  );
  final size = (12 * scale).round();
  final image = await recorder.endRecording().toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  final rgba = data!.buffer.asUint8List();
  final gray = Uint8List(size * size);
  for (var i = 0; i < gray.length; i++) {
    gray[i] =
        (.2126 * rgba[i * 4] +
                .7152 * rgba[i * 4 + 1] +
                .0722 * rgba[i * 4 + 2])
            .round();
  }
  return gray;
}

int _differing(Uint8List a, Uint8List b) {
  var n = 0;
  for (var i = 0; i < a.length; i++) {
    if ((a[i] - b[i]).abs() > 40) n++;
  }
  return n;
}

void main() {
  for (final brightness in Brightness.values) {
    final theme = brightness == Brightness.light
        ? AppTheme.light()
        : AppTheme.dark();
    final cut = theme.colorScheme.surface;

    testWidgets('every pair of beads differs in grayscale at calendar size '
        '(${brightness.name})', (tester) async {
      await tester.runAsync(() async {
        // Same ink for every bead: only the shape can tell them apart.
        final ink = theme.colorScheme.onSurface;
        final images = {
          for (final bead in _order)
            bead: await _gray(bead, color: ink, cut: cut),
        };
        for (var i = 0; i < _order.length; i++) {
          for (var j = i + 1; j < _order.length; j++) {
            final d = _differing(images[_order[i]]!, images[_order[j]]!);
            expect(
              d,
              greaterThanOrEqualTo(30),
              reason: '${_order[i].name} vs ${_order[j].name}: $d pixels',
            );
          }
        }
      });
    });

    testWidgets('bead forms in grayscale golden (${brightness.name})', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(96 * 4, 20 * 4);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: const ValueKey('beads'),
                child: SizedBox(
                  width: 96 * 4,
                  height: 20 * 4,
                  // The row is drawn at 96 x 20 dp and scaled 4x as vectors, so
                  // the golden shows what a calendar day draws.
                  child: FittedBox(
                    fit: BoxFit.fill,
                    child: ColorFiltered(
                      colorFilter: const ColorFilter.matrix(<double>[
                        .2126, .7152, .0722, 0, 0, //
                        .2126, .7152, .0722, 0, 0,
                        .2126, .7152, .0722, 0, 0,
                        0, 0, 0, 1, 0,
                      ]),
                      child: ColoredBox(
                        color: cut,
                        child: SizedBox(
                          width: 96,
                          height: 20,
                          child: Row(
                            children: [
                              for (final bead in _order)
                                Expanded(
                                  child: Builder(
                                    builder: (context) => CustomPaint(
                                      painter: _BeadRow(
                                        bead,
                                        bead.colorIn(theme),
                                        cut,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await expectLater(
        find.byKey(const ValueKey('beads')),
        matchesGoldenFile('goldens/dose_beads_gray_${brightness.name}.png'),
      );
    });
  }
}

class _BeadRow extends CustomPainter {
  const _BeadRow(this.bead, this.color, this.cut);
  final DoseBead bead;
  final Color color, cut;

  @override
  void paint(Canvas canvas, Size size) => paintDoseBead(
    canvas,
    size.center(Offset.zero),
    _calendarMinRadius,
    bead,
    color: color,
    cut: cut,
  );

  @override
  bool shouldRepaint(_BeadRow old) => true;
}
