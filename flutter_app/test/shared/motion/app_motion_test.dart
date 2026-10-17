import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/motion/app_motion.dart';

void main() {
  testWidgets('old and new care forms never paint readable text together', (
    tester,
  ) async {
    final next = ValueNotifier(false);
    addTearDown(next.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: next,
          builder: (context, value, _) => CareTransition(
            child: Text(
              value ? 'Add a medication' : 'Who are we caring for?',
              key: ValueKey(value),
            ),
          ),
        ),
      ),
    );
    double opacityOf(String label) {
      double? opacity;
      tester.element(find.text(label)).visitAncestorElements((element) {
        if (element.widget case FadeTransition(opacity: final animation)) {
          opacity = animation.value;
          return false;
        }
        return true;
      });
      return opacity!;
    }

    next.value = true;
    await tester.pump();
    for (var frame = 0; frame < 7; frame++) {
      await tester.pump(const Duration(milliseconds: 30));
      expect(
        opacityOf('Who are we caring for?') > .01 &&
            opacityOf('Add a medication') > .01,
        isFalse,
      );
    }
    await tester.pumpAndSettle();
    expect(find.text('Who are we caring for?'), findsNothing);
    expect(find.text('Add a medication'), findsOneWidget);
  });

  testWidgets('an outgoing care action cannot be tapped after saved state', (
    tester,
  ) async {
    final saved = ValueNotifier(false);
    addTearDown(saved.dispose);
    var extraRecords = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: saved,
            builder: (context, value, _) => CareTransition(
              child: value
                  ? const Text('Saved', key: ValueKey('saved'))
                  : Padding(
                      key: const ValueKey('pending'),
                      padding: const EdgeInsets.only(top: 60),
                      child: TextButton(
                        onPressed: () => extraRecords++,
                        child: const Text('Taken now'),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
    final oldActionPosition = tester.getCenter(find.text('Taken now'));
    saved.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.text('Taken now'), findsOneWidget);
    await tester.tapAt(oldActionPosition);
    expect(extraRecords, 0);
    await tester.pumpAndSettle();
    expect(find.text('Taken now'), findsNothing);
  });

  testWidgets(
    'an incoming care action cannot be tapped while still invisible',
    (tester) async {
      final pending = ValueNotifier(false);
      addTearDown(pending.dispose);
      var records = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: pending,
              builder: (context, value, _) => CareTransition(
                child: value
                    ? TextButton(
                        key: const ValueKey('pending'),
                        onPressed: () => records++,
                        child: const Text('Taken now'),
                      )
                    : const Text('Recorded', key: ValueKey('recorded')),
              ),
            ),
          ),
        ),
      );
      pending.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tapAt(tester.getCenter(find.text('Taken now')));
      expect(records, 0);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Taken now'));
      expect(records, 1);
    },
  );

  for (final accessibleNavigation in [false, true]) {
    testWidgets(
      'reduced motion ${accessibleNavigation ? 'off with' : 'on without'} '
      'accessible navigation '
      '${accessibleNavigation ? 'still fades' : 'replaces care state on the first frame'}',
      (tester) async {
        final saved = ValueNotifier(false);
        addTearDown(saved.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                disableAnimations: !accessibleNavigation,
                accessibleNavigation: accessibleNavigation,
              ),
              child: ValueListenableBuilder<bool>(
                valueListenable: saved,
                builder: (context, value, _) => CareTransition(
                  child: Text(
                    value ? 'Saved' : 'Pending',
                    key: ValueKey(value),
                  ),
                ),
              ),
            ),
          ),
        );
        saved.value = true;
        await tester.pump();
        if (accessibleNavigation) {
          // Accessible navigation alone (any accessibility service) is not a
          // request for stillness: the fade-through still runs.
          expect(find.text('Pending'), findsOneWidget);
          expect(find.text('Saved'), findsOneWidget);
          expect(tester.binding.hasScheduledFrame, isTrue);
          await tester.pumpAndSettle();
          expect(find.text('Pending'), findsNothing);
          return;
        }
        expect(find.text('Pending'), findsNothing);
        expect(find.text('Saved'), findsOneWidget);
        expect(tester.binding.hasScheduledFrame, isFalse);
      },
    );
  }

  testWidgets(
    'enabling reduced motion drops all outgoing forms on the first frame',
    (tester) async {
      final state = ValueNotifier((reduced: false, label: 'Edit record'));
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<({bool reduced, String label})>(
            valueListenable: state,
            builder: (context, value, _) => MediaQuery(
              data: MediaQueryData(disableAnimations: value.reduced),
              child: CareTransition(
                child: Text(value.label, key: ValueKey(value.label)),
              ),
            ),
          ),
        ),
      );
      state.value = (reduced: false, label: 'Review record');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      state.value = (reduced: true, label: 'Saved');
      await tester.pump();
      expect(find.text('Edit record'), findsNothing);
      expect(find.text('Review record'), findsNothing);
      expect(find.text('Saved'), findsOneWidget);
      expect(find.byType(AnimatedSwitcher), findsNothing);
      // A frame already queued by the disposed normal-motion ticker can drain,
      // but no outgoing content or animation remains on the replacement frame.
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );
}
