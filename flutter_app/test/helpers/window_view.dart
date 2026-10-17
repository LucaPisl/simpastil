import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Gives the test window [size] logical pixels at a pixel ratio of 1.
///
/// Unlike `binding.setSurfaceSize`, this changes what `MediaQuery` reports,
/// so the window class (compact, medium, expanded) follows the size the way
/// it does on a device. Resets itself when the test ends.
void useWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}
