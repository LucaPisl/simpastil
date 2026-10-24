import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/pills/presentation/medication_identity.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/shared/theme/pill_colors.dart';

/// The smallest mark that carries a letter (see [kImprintMinSize]): the size
/// the nine silhouettes must still tell apart at.
const _minimum = kImprintMinSize;

/// The test font draws every glyph as a box; load Roboto from the SDK so the
/// goldens show the letter the device draws.
Future<void> _loadRoboto() async {
  final root =
      Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  for (final file in ['Roboto-Regular.ttf', 'Roboto-Bold.ttf']) {
    final font = File('$dir/$file');
    if (!font.existsSync()) continue;
    final bytes = ByteData.sublistView(font.readAsBytesSync());
    await (FontLoader('Roboto')..addFont(Future.value(bytes))).load();
  }
}

const _imprints = {
  MedicationShape.round: 'M',
  MedicationShape.caplet: 'A',
  MedicationShape.oval: 'B',
  MedicationShape.softgel: 'O',
  MedicationShape.capsule: 'V',
  MedicationShape.triangle: 'T',
  MedicationShape.square: 'K',
  MedicationShape.diamond: 'D',
  MedicationShape.drop: 'L',
};

/// [shape] rasterised on [cut] at [size] dp, reduced to luminance.
Future<Uint8List> _gray(
  MedicationShape shape, {
  required Color tint,
  required Color cut,
  required ThemeData theme,
  double size = _minimum,
  bool imprint = false,
  double scale = 4,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(scale);
  const cell = 30.0;
  canvas.drawRect(const Rect.fromLTWH(0, 0, cell, cell), Paint()..color = cut);
  canvas.translate((cell - size) / 2, (cell - size) / 2);
  MedicationMarkPainter(
    base: tint,
    light: Color.lerp(tint, cut, .55)!,
    outline: pillOutlineColor(tint),
    shape: shape,
    imprint: imprint ? _imprints[shape]! : '',
    fontFamily: theme.textTheme.labelLarge?.fontFamily,
  ).paint(canvas, Size.square(size));
  final side = (cell * scale).round();
  final image = await recorder.endRecording().toImage(side, side);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  final rgba = data!.buffer.asUint8List();
  final gray = Uint8List(side * side);
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
  setUpAll(_loadRoboto);

  testWidgets('the letter is hidden under 22 px and drawn from 22 px up', (
    tester,
  ) async {
    final theme = AppTheme.light();
    final cut = theme.colorScheme.surface;
    final tint = Colors.teal.shade700;
    Future<int> letterPixels(double size) async {
      final plain = await tester.runAsync(
        () => _gray(
          MedicationShape.round,
          tint: tint,
          cut: cut,
          theme: theme,
          size: size,
        ),
      );
      final marked = await tester.runAsync(
        () => _gray(
          MedicationShape.round,
          tint: tint,
          cut: cut,
          theme: theme,
          size: size,
          imprint: true,
        ),
      );
      return _differing(plain!, marked!);
    }

    expect(await letterPixels(kImprintMinSize - 1), 0);
    expect(await letterPixels(kImprintMinSize), greaterThan(0));
  });

  for (final brightness in Brightness.values) {
    final theme = brightness == Brightness.light
        ? AppTheme.light()
        : AppTheme.dark();
    final cut = theme.colorScheme.surface;
    // One ink for every shape: grey cannot lean on colour, so only the
    // silhouette (and the letter) is left to tell the pills apart.
    final tint = Color.alphaBlend(
      theme.colorScheme.onSurface.withValues(alpha: .55),
      cut,
    );

    testWidgets('every pair of silhouettes differs in grayscale at the '
        'smallest lettered size (${brightness.name})', (tester) async {
      await tester.runAsync(() async {
        final images = {
          for (final shape in MedicationShape.values)
            shape: await _gray(shape, tint: tint, cut: cut, theme: theme),
        };
        final values = MedicationShape.values;
        for (var i = 0; i < values.length; i++) {
          for (var j = i + 1; j < values.length; j++) {
            final d = _differing(images[values[i]]!, images[values[j]]!);
            expect(
              d,
              greaterThanOrEqualTo(120),
              reason: '${values[i].name} vs ${values[j].name}: $d pixels',
            );
          }
        }
      });
    });

    testWidgets('the nine shapes with their imprint in grayscale, at the '
        'smallest size and enlarged (${brightness.name})', (tester) async {
      tester.view.physicalSize = const Size(9 * 64, 2 * 80);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Widget row(double size, double cellWidth, double cellHeight) => Row(
        children: [
          for (final shape in MedicationShape.values)
            SizedBox(
              width: cellWidth,
              height: cellHeight,
              child: Center(
                child: MedicationMark(
                  color: tint,
                  shape: shape,
                  imprint: _imprints[shape]!,
                  size: size,
                ),
              ),
            ),
        ],
      );
      const zoom = 2.5;
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('shapes'),
              child: ColoredBox(
                color: cut,
                child: ColorFiltered(
                  colorFilter: const ColorFilter.matrix(<double>[
                    .2126, .7152, .0722, 0, 0, //
                    .2126, .7152, .0722, 0, 0,
                    .2126, .7152, .0722, 0, 0,
                    0, 0, 0, 1, 0,
                  ]),
                  child: Column(
                    children: [
                      // The smallest size that still carries a letter, scaled
                      // up as vectors so the golden shows what it draws.
                      SizedBox(
                        width: 9 * 64,
                        height: 80,
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Transform.scale(
                            scale: zoom,
                            alignment: Alignment.topLeft,
                            child: row(_minimum, 64 / zoom, 80 / zoom),
                          ),
                        ),
                      ),
                      row(40, 64, 80),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(const ValueKey('shapes')),
        matchesGoldenFile(
          'goldens/medication_shapes_gray_${brightness.name}.png',
        ),
      );
    });
  }
}
