import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/dashboard/today_layout/receipt_moment.dart';

/// Counts how often it is built afresh.
class _Probe extends StatefulWidget {
  const _Probe();

  static int created = 0;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.created++;
  }

  @override
  Widget build(BuildContext context) => const Text('pressed');
}

void main() {
  testWidgets('a part keeps its state when it starts leaving', (tester) async {
    _Probe.created = 0;
    Widget swap(String receipt, Widget child) => MaterialApp(
      home: Scaffold(
        body: ReceiptSwap(receipt: receipt, child: child),
      ),
    );
    await tester.pumpWidget(swap('pending/1', const _Probe()));
    expect(_Probe.created, 1);

    await tester.pumpWidget(swap('taken/2', const Text('done')));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('pressed'), findsOneWidget, reason: 'still fading out');
    expect(_Probe.created, 1, reason: 'the leaving part was not rebuilt');
    // The leaving part takes no taps and is not read; the new one is both.
    Iterable<T> above<T extends Widget>(String text) => tester.widgetList<T>(
      find.ancestor(of: find.text(text), matching: find.byType(T)),
    );
    expect(above<ExcludeSemantics>('pressed').any((w) => w.excluding), isTrue);
    expect(above<IgnorePointer>('pressed').any((w) => w.ignoring), isTrue);
    expect(above<ExcludeSemantics>('done').any((w) => w.excluding), isFalse);

    await tester.pumpAndSettle();
    expect(find.text('pressed'), findsNothing);
    expect(find.text('done'), findsOneWidget);
  });
}
