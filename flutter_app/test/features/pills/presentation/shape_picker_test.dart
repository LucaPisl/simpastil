import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/pills/presentation/medication_form_kit.dart';
import 'package:simpastil/features/pills/presentation/medication_identity.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/shared/theme/pill_colors.dart';

Future<void> _pump(
  WidgetTester tester, {
  MedicationShape selected = MedicationShape.round,
  ValueChanged<MedicationShape>? onSelected,
  String? collision,
  bool suggested = false,
  double scale = 1,
  Locale locale = const Locale('en'),
}) => tester.pumpWidget(
  MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ShapePicker(
              selected: selected,
              tint: const Color(0xFF2F80ED),
              imprint: 'M',
              collisionName: collision,
              suggested: suggested,
              onSelected: onSelected ?? (_) {},
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('shows nine labelled options and reports the one tapped', (
    tester,
  ) async {
    MedicationShape? picked;
    await _pump(tester, onSelected: (s) => picked = s);
    for (final shape in MedicationShape.values) {
      expect(find.byKey(ValueKey('shape-${shape.wire}')), findsOneWidget);
    }
    expect(find.bySemanticsLabel('Round shape'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shape-triangle')));
    expect(picked, MedicationShape.triangle);
  });

  testWidgets('warns about a shared shape and letter, and says it is a '
      'suggestion', (tester) async {
    await _pump(tester, collision: 'Magnefar', suggested: true);
    expect(find.byKey(const ValueKey('shape-collision')), findsOneWidget);
    expect(find.textContaining('Magnefar'), findsOneWidget);
    expect(find.byKey(const ValueKey('shape-suggested')), findsOneWidget);
  });

  testWidgets('no warning without a collision', (tester) async {
    await _pump(tester);
    expect(find.byKey(const ValueKey('shape-collision')), findsNothing);
    expect(find.byKey(const ValueKey('shape-suggested')), findsNothing);
  });

  testWidgets('fits at text scale 1.3 in Romanian without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(
      tester,
      collision: 'Magnefar',
      suggested: true,
      scale: 1.3,
      locale: const Locale('ro'),
    );
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('Forma rotundă'), findsOneWidget);
  });

  test('the imprint ink holds 3:1 on every pill colour', () {
    double contrast(Color a, Color b) {
      final x = a.computeLuminance() + .05, y = b.computeLuminance() + .05;
      return x > y ? x / y : y / x;
    }

    for (final pc in kPillColors) {
      final base = colorFromHex(pc.hex);
      expect(
        contrast(medicationImprintInk(base), base),
        greaterThanOrEqualTo(3),
        reason: pc.hex,
      );
    }
  });
}
