import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/setup/presentation/setup_hand_off.dart';
import 'package:simpastil/features/setup/presentation/setup_organiser.dart';
import 'package:simpastil/shared/layouts/tab_hand_off.dart';
import 'package:simpastil/shared/scene/horizon_scene.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

final _light = AppTheme.light();

/// Today's sky as the hand-off sees it: an arc that shows up when told.
class _Sky extends HorizonMarkLocator {
  HorizonArc? shown;

  @override
  HorizonArc? arc() => shown;
}

const _arc = HorizonArc(
  points: [Offset(0, 120), Offset(200, 40), Offset(400, 120)],
  line: Color(0x6B6750A4),
  now: .5,
  sunColor: Color(0xFFFFC27A),
);

const SetupOrganiserLine _line = (
  from: Offset(60, 300),
  to: Offset(340, 300),
  color: Color(0xFF6750A4),
);

void main() {
  late _Sky sky;
  late ProviderContainer container;

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sky = _Sky();
    container = ProviderContainer(
      overrides: [todaySkyLocatorProvider.overrideWithValue(sky)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: _light,
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: TextButton(
                onPressed: () => startSetupHandOff(
                  Overlay.of(context, rootOverlay: true),
                  ref.read(todaySunriseHoldProvider),
                  _line,
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  SetupHandOffPainter? painter(WidgetTester tester) {
    final found = find.byKey(const ValueKey('setup-hand-off'));
    if (found.evaluate().isEmpty) return null;
    return tester.widget<CustomPaint>(found).painter as SetupHandOffPainter;
  }

  bool held() => container.read(todaySunriseHoldProvider).value;

  testWidgets('the line bends onto the arc, then lets the sun rise', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('go'));
    expect(held(), isTrue, reason: 'held before Today can build');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(painter(tester)!.arc, isNull, reason: 'Today is not there yet');
    sky.shown = _arc;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(SetupHandOff.flight * .4);
    expect(painter(tester)!.arc, same(_arc));
    expect(painter(tester)!.t, inExclusiveRange(0, 1));
    expect(held(), isTrue);
    await tester.pump(SetupHandOff.flight * .4);
    expect(held(), isFalse, reason: 'the real path rises as the line fades');
    await tester.pumpAndSettle();
    expect(painter(tester), isNull);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('without an arc the line fades and lets go', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(SetupHandOff.wait * .9);
    expect(held(), isTrue, reason: 'still waiting for Today');
    await tester.pump(SetupHandOff.wait * .2);
    expect(held(), isFalse);
    await tester.pump(SetupHandOff.fade ~/ 2);
    expect(painter(tester)!.shown, inExclusiveRange(0, 1));
    expect(held(), isFalse);
    await tester.pumpAndSettle();
    expect(painter(tester), isNull);
  });

  test('each point of the line goes to its share of the day on the arc', () {
    Offset at(double s, double k) =>
        SetupHandOffPainter.pointAt(_line, _arc, s, k);
    expect(at(0, 0), _line.from);
    expect(at(1, 0), _line.to);
    expect(at(.5, 0), const Offset(200, 300));
    expect(at(0, 1), _arc.at(0));
    expect(at(.5, 1), _arc.at(.5));
    expect(at(1, 1), _arc.at(1));
    expect(at(.5, .5), const Offset(200, 170));
    expect(SetupHandOffPainter.pointAt(_line, null, .5, 1), at(.5, 0));
  });
}
