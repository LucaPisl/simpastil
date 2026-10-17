import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final reviewCaptureKey = GlobalKey();

/// Optional fictional rendering evidence, using the installed real typeface.
Future<void> loadReviewFonts() async {
  final font = Platform.environment['REVIEW_FONT'];
  if (font == null) return;
  final bytes = ByteData.sublistView(await File(font).readAsBytes());
  for (final family in ['Roboto', 'Ahem']) {
    await (FontLoader(family)..addFont(Future.value(bytes))).load();
  }
  final icons = File('${File(font).parent.path}/MaterialIcons-Regular.otf');
  if (await icons.exists()) {
    await (FontLoader('MaterialIcons')..addFont(
          Future.value(ByteData.sublistView(await icons.readAsBytes())),
        ))
        .load();
  }
}

Future<void> captureReview(WidgetTester tester, String name) async {
  final directory = Platform.environment['REVIEW_CAPTURE_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary =
        reviewCaptureKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

ThemeData reviewRenderingTheme(ThemeData theme) {
  if (Platform.environment['REVIEW_FONT'] == null) return theme;
  final label = theme.textTheme.labelLarge!.copyWith(fontFamily: 'Roboto');
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
        fontFamily: 'Roboto',
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: theme.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: theme.outlinedButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: theme.textButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
  );
}
