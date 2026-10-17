import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/schedules/presentation/day_lid.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

void main() {
  Widget app(bool open, {bool quiet = false}) => MaterialApp(
    theme: AppTheme.light(),
    builder: (context, page) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: quiet),
      child: page!,
    ),
    home: Scaffold(
      body: Center(
        child: FilterChip(
          showCheckmark: false,
          avatar: DayLid(open: open),
          label: const Text('Mon'),
          selected: open,
          onSelected: (_) {},
        ),
      ),
    ),
  );

  double openness(WidgetTester tester) =>
      (tester
                  .widget<CustomPaint>(
                    find.descendant(
                      of: find.byType(DayLid),
                      matching: find.byType(CustomPaint),
                    ),
                  )
                  .painter!
              as DayLidPainter)
          .open;

  testWidgets('a picked day opens its lid, then rests', (tester) async {
    await tester.pumpWidget(app(false));
    expect(openness(tester), 0);
    await tester.pumpWidget(app(true));
    await tester.pump(DayLid.duration ~/ 2);
    expect(openness(tester), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(openness(tester), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('quiet mode opens the lid at once', (tester) async {
    await tester.pumpWidget(app(false, quiet: true));
    await tester.pumpWidget(app(true, quiet: true));
    await tester.pump();
    expect(openness(tester), 1);
  });

  testWidgets('the glyph adds nothing for a screen reader', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(app(true));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.byType(FilterChip)),
      matchesSemantics(
        label: 'Mon',
        isSelected: true,
        hasSelectedState: true,
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    handle.dispose();
  });
}
