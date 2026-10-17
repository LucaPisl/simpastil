import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/scene/horizon_model.dart';
import 'package:simpastil/shared/scene/horizon_scene.dart';

import 'scene_test_support.dart';

/// The test font draws every glyph as a box, which hid whether the stack
/// numeral was real text. Load Roboto from the Flutter SDK so the goldens
/// show the digit the device draws.
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

Widget _sheet(ThemeData theme, Brightness b, {required bool hc}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    home: Scaffold(
      body: RepaintBoundary(
        key: const ValueKey('sheet'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final t in phaseTimes.values)
              sceneOf(modelFor(at(t.$1, t.$2), b, highContrast: hc)),
          ],
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(_loadRoboto);

  Future<void> shoot(
    WidgetTester tester,
    ThemeData theme,
    Brightness b,
    bool hc,
    String name,
  ) async {
    tester.view.physicalSize = const Size(390, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_sheet(theme, b, hc: hc));
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('sheet')),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  for (final b in Brightness.values) {
    for (final hc in [false, true]) {
      final name = '${b.name}${hc ? '_high_contrast' : ''}';
      testWidgets('horizon golden $name', (tester) async {
        await shoot(tester, themeFor(b, highContrast: hc), b, hc, name);
      });
    }
  }

  testWidgets('horizon golden custom theme', (tester) async {
    final base = themeFor(Brightness.light);
    final custom = base.copyWith(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF00897B),
        brightness: Brightness.light,
      ),
    );
    await shoot(tester, custom, Brightness.light, false, 'custom_theme');
  });

  // Marks at device scale (3x), one light and one dark row: taken, pending
  // with focus, skipped, a stack of four, and the celebration mid-flight.
  for (final b in Brightness.values) {
    testWidgets('horizon golden marks ${b.name}', (tester) async {
      tester.view.physicalSize = const Size(1170, 510);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final model = modelFor(at(12, 30), b);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(b),
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('marks'),
              child: SizedBox(
                width: 1170,
                height: 510,
                child: FittedBox(
                  child: SizedBox.fromSize(
                    size: model.size,
                    child: HorizonScene(
                      model: model,
                      semanticsLabel: 'Day sky',
                      focusedId: 'f',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(b),
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('marks'),
              child: SizedBox(
                width: 1170,
                height: 510,
                child: FittedBox(
                  child: SizedBox.fromSize(
                    size: model.size,
                    child: HorizonScene(
                      model: model,
                      semanticsLabel: 'Day sky',
                      focusedId: 'f',
                      celebrateId: 'e',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 220));
      await expectLater(
        find.byKey(const ValueKey('marks')),
        matchesGoldenFile('goldens/marks_${b.name}.png'),
      );
      await tester.pumpAndSettle();
      expect(model.marks.where((m) => !m.hidden), isNotEmpty);
      expect(HorizonModel.markBounds.height, greaterThan(16));
    });
  }
}
