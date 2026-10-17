import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/shared/widgets/capsule_mark.dart';
import 'package:simpastil/shared/widgets/empty_state.dart';

Widget _host(Widget child, {bool reduceMotion = false, double scale = 1}) =>
    MaterialApp(
      theme: AppTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          disableAnimations: reduceMotion,
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(body: child),
      ),
    );

double _sceneProgress(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is EmptyStatePainter,
    ),
  );
  return (paint.painter! as EmptyStatePainter).progress;
}

void main() {
  testWidgets('shows the capsule scene, words and action without emoji', (
    tester,
  ) async {
    var tapped = 0;
    await tester.pumpWidget(
      _host(
        EmptyState(
          title: 'No people yet',
          subtitle: 'Add someone you care for.',
          ctaLabel: 'Add person',
          onCta: () => tapped++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CapsuleMark), findsOneWidget);
    expect(find.text('No people yet'), findsOneWidget);
    expect(find.text('Add someone you care for.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('empty-state-cta')));
    expect(tapped, 1);
  });

  testWidgets('rises in once, but reduced motion shows the final frame', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const EmptyState(title: 'Nothing here')));
    expect(_sceneProgress(tester), 0);
    await tester.pumpAndSettle();
    expect(_sceneProgress(tester), 1);

    await tester.pumpWidget(
      _host(const EmptyState(title: 'Quiet'), reduceMotion: true),
    );
    expect(_sceneProgress(tester), 1);
  });

  testWidgets('scrolls instead of overflowing in a short space at 2x text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(
        const EmptyState(
          title: 'Încă nu există persoane în această listă',
          subtitle: 'Adăugați pe cineva de care aveți grijă.',
          ctaLabel: 'Adaugă persoană',
          onCta: _noop,
          art: EmptyStateArt.people,
        ),
        scale: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Scrollable), findsOneWidget);
  });
}

void _noop() {}
