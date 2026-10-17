import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/widgets/clock_text.dart';

Widget _host(String text) => MaterialApp(
  home: Scaffold(body: ClockText(text, style: const TextStyle(fontSize: 48))),
);

void main() {
  testWidgets('a 12-hour time sets its AM/PM mark small beside the digits', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host('9:00 PM'));
    expect(find.text('9:00 PM'), findsOneWidget, reason: 'plain text kept');
    expect(find.bySemanticsLabel('9:00 PM'), findsOneWidget);
    final spans = (tester.widget<Text>(find.byType(Text)).textSpan! as TextSpan)
        .children!
        .cast<TextSpan>();
    expect([for (final s in spans) s.text], ['9:00', ' ', 'PM']);
    expect(spans.last.style!.fontSize, 48 * ClockText.markScale);
    handle.dispose();
  });

  testWidgets('a 24-hour time is shown as it is', (tester) async {
    await tester.pumpWidget(_host('21:00'));
    final text = tester.widget<Text>(find.byType(Text));
    expect(text.data, '21:00');
    expect(text.textSpan, isNull);
  });
}
