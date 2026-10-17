import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simpastil/core/storage/layout_family_preference.dart';
import 'package:simpastil/features/dashboard/today_layout/layout_reveal.dart';

final _family = ValueNotifier(LayoutFamily.focusDeck);

Widget _layout() => ValueListenableBuilder(
  valueListenable: _family,
  builder: (context, family, _) => LayoutReveal(
    family: family,
    child: SizedBox(height: 400, child: Text(family.name)),
  ),
);

Finder _wipe({bool skipOffstage = true}) => find.byKey(
  const ValueKey('layout-reveal-wipe'),
  skipOffstage: skipOffstage,
);

Widget _bare({bool quiet = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: quiet),
    child: Scaffold(body: _layout()),
  ),
);

void main() {
  setUp(() {
    _family.value = LayoutFamily.focusDeck;
    LayoutReveal.resetForTesting();
  });

  testWidgets('the first layout appears as it is', (tester) async {
    await tester.pumpWidget(_bare());
    expect(_wipe(), findsNothing);
  });

  testWidgets('a new layout is laid on from the top', (tester) async {
    await tester.pumpWidget(_bare());
    _family.value = LayoutFamily.timeline;
    await tester.pump();
    await tester.pump();
    expect(_wipe(), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(_wipe(), findsOneWidget);
    expect(find.text('timeline'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(_wipe(), findsNothing);
  });

  testWidgets('quiet motion swaps without a wipe', (tester) async {
    await tester.pumpWidget(_bare(quiet: true));
    _family.value = LayoutFamily.dailyJournal;
    await tester.pump();
    await tester.pump();
    expect(_wipe(), findsNothing);
    expect(find.text('dailyJournal'), findsOneWidget);
  });

  testWidgets('a rebuilt day view carries on the reveal', (tester) async {
    await tester.pumpWidget(_bare());
    _family.value = LayoutFamily.timeline;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_wipe(), findsOneWidget);
    // The day reloads: a fresh element, same family, mid-reveal.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LayoutReveal(
            key: ValueKey('reloaded'),
            family: LayoutFamily.timeline,
            child: SizedBox(height: 400, child: Text('timeline')),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(_wipe(), findsOneWidget);
    await tester.pumpAndSettle();
    expect(_wipe(), findsNothing);
  });

  testWidgets('a layout chosen in Settings waits for Today to show', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(body: _layout()),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, _) => const Scaffold(body: Text('settings')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.push('/settings');
    await tester.pumpAndSettle();

    _family.value = LayoutFamily.peopleLanes;
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    // Out of sight the new layout stands as it is, waiting.
    expect(_wipe(skipOffstage: false), findsNothing);

    router.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_wipe(), findsOneWidget);
    await tester.pumpAndSettle();
    expect(_wipe(), findsNothing);
    expect(find.text('peopleLanes'), findsOneWidget);
  });
}
