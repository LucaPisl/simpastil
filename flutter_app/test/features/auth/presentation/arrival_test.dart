import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/auth/presentation/arrival.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

Widget _host(Widget child, {bool quiet = false, ThemeData? theme}) =>
    MaterialApp(
      theme: theme,
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: quiet),
        child: Scaffold(body: child),
      ),
    );

void main() {
  group('ConnectionPath', () {
    testWidgets('walks to the next station, then rests', (tester) async {
      await tester.pumpWidget(_host(const ConnectionPath(reached: 0)));
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);

      await tester.pumpWidget(_host(const ConnectionPath(reached: 1)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.binding.hasScheduledFrame, isTrue);
      final painter =
          tester
                  .widget<CustomPaint>(
                    find.descendant(
                      of: find.byType(ConnectionPath),
                      matching: find.byType(CustomPaint),
                    ),
                  )
                  .painter!
              as ConnectionPathPainter;
      expect(painter.reach.value, inExclusiveRange(0, 1));

      await tester.pumpAndSettle();
      expect(painter.reach.value, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('quiet motion arrives at once', (tester) async {
      await tester.pumpWidget(
        _host(const ConnectionPath(reached: 0), quiet: true),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        _host(const ConnectionPath(reached: 2), quiet: true),
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('ArrivalStepSwitcher', () {
    Future<void> step(
      WidgetTester tester,
      String id, {
      bool forward = true,
      VoidCallback? onTap,
    }) => tester.pumpWidget(
      _host(
        Center(
          child: SizedBox(
            width: 300,
            child: ArrivalStepSwitcher(
              step: id,
              forward: forward,
              child: TextButton(
                onPressed: onTap ?? () {},
                child: Text(id, key: ValueKey('label-$id')),
              ),
            ),
          ),
        ),
      ),
    );

    double x(WidgetTester tester, String id) =>
        tester.getCenter(find.byKey(ValueKey('label-$id'))).dx;

    testWidgets('forward slides the next step in from the end', (tester) async {
      var oldTaps = 0;
      await step(tester, 'server', onTap: () => oldTaps++);
      final rest = x(tester, 'server');
      await step(tester, 'key');
      await tester.pump(const Duration(milliseconds: 120));
      expect(x(tester, 'key'), greaterThan(rest));
      expect(x(tester, 'server'), lessThan(rest));

      // The outgoing step is inert while it leaves.
      await tester.tap(find.text('server'), warnIfMissed: false);
      expect(oldTaps, 0);
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('server'), findsNothing);
      semantics.dispose();

      await tester.pumpAndSettle();
      expect(find.text('server'), findsNothing);
      expect(x(tester, 'key'), moreOrLessEquals(rest));
    });

    testWidgets('back slides the earlier step in from the start', (
      tester,
    ) async {
      await step(tester, 'key');
      final rest = x(tester, 'key');
      await step(tester, 'server', forward: false);
      await tester.pump(const Duration(milliseconds: 120));
      expect(x(tester, 'server'), lessThan(rest));
      expect(x(tester, 'key'), greaterThan(rest));
      await tester.pumpAndSettle();
    });
  });

  testWidgets('the backdrop follows the theme instead of a fixed tint', (
    tester,
  ) async {
    final dark = AppTheme.dark();
    await tester.pumpWidget(
      _host(const ArrivalBackdrop(child: SizedBox()), theme: dark),
    );
    final box = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(ArrivalBackdrop),
        matching: find.byType(DecoratedBox),
      ),
    );
    final gradient = (box.decoration as BoxDecoration).gradient!;
    expect(gradient.colors.last, dark.colorScheme.surface);
    // It fills the screen, so no band of another colour shows below it.
    expect(
      tester.getSize(find.byType(ArrivalBackdrop)),
      tester.getSize(find.byType(Scaffold)),
    );
  });

  test('the verification step is said in both languages', () {
    expect(
      lookupAppLocalizations(const Locale('en')).auth_stepVerification,
      'STEP 4 — VERIFICATION',
    );
    expect(
      lookupAppLocalizations(const Locale('ro')).auth_stepVerification,
      'PASUL 4 — VERIFICARE',
    );
  });
}
