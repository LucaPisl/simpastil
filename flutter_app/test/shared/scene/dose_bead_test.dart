import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/scene/dose_bead.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

void main() {
  test('the shape follows the record, and a gone-by dose is not recorded', () {
    expect(DoseBead.of('taken'), DoseBead.taken);
    expect(DoseBead.of('skipped'), DoseBead.skipped);
    expect(DoseBead.of('pending'), DoseBead.planned);
    expect(DoseBead.of('pending', passed: true), DoseBead.unrecorded);
    // Only a recorded miss is "missed"; a dose nobody recorded stays
    // "not recorded" however long ago it was due.
    expect(DoseBead.of('missed'), DoseBead.missed);
    expect(DoseBead.of('missed', passed: true), DoseBead.missed);
    expect(DoseBead.of('taken', prn: true), DoseBead.asNeeded);
  });

  test('colour means outcome in both themes', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      final semantic = theme.extension<AppSemanticColors>()!;
      expect(DoseBead.taken.colorIn(theme), semantic.statusTaken);
      expect(DoseBead.skipped.colorIn(theme), semantic.statusSkipped);
      expect(DoseBead.unrecorded.colorIn(theme), semantic.statusUnrecorded);
      expect(DoseBead.missed.colorIn(theme), semantic.statusMissed);
      expect(DoseBead.asNeeded.colorIn(theme), theme.colorScheme.primary);
    }
  });

  test('every bead and a crowded row paint without error', () {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    for (final bead in DoseBead.values) {
      paintDoseBead(
        canvas,
        const Offset(10, 10),
        4.5,
        bead,
        color: Colors.green,
        cut: Colors.white,
      );
    }
    paintBeadRow(canvas, const Size(24, 13), [
      for (var i = 0; i < 12; i++) (bead: DoseBead.taken, color: Colors.green),
    ], cut: Colors.white);
    paintNowPin(canvas, const Offset(20, 20), color: Colors.purple);
    recorder.endRecording().dispose();
  });
}
