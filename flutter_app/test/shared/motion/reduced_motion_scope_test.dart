import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/motion/app_motion.dart';

class _Probe extends StatefulWidget {
  const _Probe({super.key});
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  int taps = 0;
  bool? quiet;
  bool? quietByPhone;
  int builds = 0;

  @override
  Widget build(BuildContext context) {
    builds++;
    quiet = AppMotion.quiet(context);
    quietByPhone = AppMotion.quietByPhone(context);
    return GestureDetector(
      onTap: () => setState(() => taps++),
      child: Text('taps $taps', textDirection: TextDirection.ltr),
    );
  }
}

void main() {
  final probeKey = GlobalKey<_ProbeState>();

  Widget mount({
    required bool reduce,
    bool phoneDisablesAnimations = false,
    bool phoneAccessibleNavigation = false,
  }) => MediaQuery(
    data: MediaQueryData(
      disableAnimations: phoneDisablesAnimations,
      accessibleNavigation: phoneAccessibleNavigation,
    ),
    child: ReducedMotionScope(
      reduce: reduce,
      child: _Probe(key: probeKey),
    ),
  );

  testWidgets('reduce on makes motion quiet but not because of the phone', (
    tester,
  ) async {
    await tester.pumpWidget(mount(reduce: true));
    expect(probeKey.currentState!.quiet, isTrue);
    expect(probeKey.currentState!.quietByPhone, isFalse);
    expect(AppMotion.duration(probeKey.currentContext!), Duration.zero);
  });

  testWidgets('reduce off leaves motion as the phone had it', (tester) async {
    await tester.pumpWidget(mount(reduce: false));
    expect(probeKey.currentState!.quiet, isFalse);
    expect(probeKey.currentState!.quietByPhone, isFalse);
    expect(AppMotion.duration(probeKey.currentContext!), isNot(Duration.zero));
  });

  testWidgets('a phone that disables animations counts whatever the choice', (
    tester,
  ) async {
    for (final reduce in [false, true]) {
      await tester.pumpWidget(
        mount(reduce: reduce, phoneDisablesAnimations: true),
      );
      expect(probeKey.currentState!.quiet, isTrue, reason: 'reduce $reduce');
      expect(
        probeKey.currentState!.quietByPhone,
        isTrue,
        reason: 'reduce $reduce',
      );
    }
  });

  testWidgets(
    'accessible navigation alone neither quiets motion nor locks the choice',
    (tester) async {
      // Android reports accessible navigation for any accessibility service
      // (password managers, automation apps), not only screen readers.
      await tester.pumpWidget(
        mount(reduce: false, phoneAccessibleNavigation: true),
      );
      expect(probeKey.currentState!.quiet, isFalse);
      expect(probeKey.currentState!.quietByPhone, isFalse);

      await tester.pumpWidget(
        mount(reduce: true, phoneAccessibleNavigation: true),
      );
      expect(probeKey.currentState!.quiet, isTrue);
      expect(probeKey.currentState!.quietByPhone, isFalse);
    },
  );

  testWidgets('flipping the choice keeps the state below and updates readers', (
    tester,
  ) async {
    await tester.pumpWidget(mount(reduce: false));
    final state = probeKey.currentState!;
    await tester.tap(find.byType(GestureDetector));
    await tester.pump();
    expect(state.taps, 1);
    expect(state.quiet, isFalse);

    await tester.pumpWidget(mount(reduce: true));
    expect(identical(probeKey.currentState, state), isTrue);
    expect(state.taps, 1);
    expect(find.text('taps 1'), findsOneWidget);
    expect(state.quiet, isTrue);
    expect(state.quietByPhone, isFalse);

    await tester.pumpWidget(mount(reduce: false));
    expect(identical(probeKey.currentState, state), isTrue);
    expect(state.taps, 1);
    expect(state.quiet, isFalse);
  });

  testWidgets('flipping the phone setting under the scope updates readers', (
    tester,
  ) async {
    await tester.pumpWidget(mount(reduce: false));
    expect(probeKey.currentState!.quietByPhone, isFalse);
    await tester.pumpWidget(
      mount(reduce: false, phoneDisablesAnimations: true),
    );
    expect(probeKey.currentState!.quietByPhone, isTrue);
    await tester.pumpWidget(mount(reduce: false));
    expect(probeKey.currentState!.quietByPhone, isFalse);
  });

  testWidgets('outside the scope quietByPhone follows quiet', (tester) async {
    late BuildContext context;
    Widget outside(bool disable) => MediaQuery(
      data: MediaQueryData(disableAnimations: disable),
      child: Builder(
        builder: (c) {
          context = c;
          return const SizedBox();
        },
      ),
    );
    await tester.pumpWidget(outside(false));
    expect(AppMotion.quietByPhone(context), isFalse);
    await tester.pumpWidget(outside(true));
    expect(AppMotion.quietByPhone(context), isTrue);
  });
}
