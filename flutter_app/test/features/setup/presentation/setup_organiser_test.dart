import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/setup/presentation/setup_organiser.dart';
import 'package:simpastil/features/setup/presentation/setup_screen.dart';
import 'package:simpastil/features/setup/setup_controller.dart'
    show SetupRequest;
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/protected_workspace_fixture.dart';

final _light = AppTheme.light();

Widget _host(Widget child, {bool quiet = false, double textScale = 1}) =>
    MaterialApp(
      theme: _light,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: quiet,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(body: child),
        ),
      ),
    );

OrganiserPainter _painter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.descendant(
                of: find.byType(SetupOrganiser),
                matching: find.byType(CustomPaint),
              ),
            )
            .painter!
        as OrganiserPainter;

List<double> _fills(WidgetTester tester) => [
  for (final f in _painter(tester).fill) f.value,
];

List<String> _hapticsOf(WidgetTester tester) {
  final haptics = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return haptics;
}

void main() {
  group('organiser steps', () {
    test('fills one compartment per saved step', () {
      expect(
        [for (final s in SetupStep.values) setupOrganiserFilled(s)],
        [
          for (final s in SetupStep.values)
            switch (s) {
              SetupStep.start || SetupStep.person => 0,
              SetupStep.medication => 1,
              SetupStep.routine => 2,
              SetupStep.reminders => 3,
              SetupStep.ready || SetupStep.complete => 4,
            },
        ],
      );
    });

    test('outlines the compartment the open form fills', () {
      expect(setupOrganiserCurrent(SetupStep.start), isNull);
      expect(setupOrganiserCurrent(SetupStep.person), 0);
      expect(setupOrganiserCurrent(SetupStep.reminders), 3);
      expect(setupOrganiserCurrent(SetupStep.ready), isNull);
      expect(setupOrganiserCurrent(SetupStep.complete), isNull);
    });

    test('remembers what a draft showed, and only for that draft', () {
      final memory = SetupOrganiserMemory();
      expect(memory.swap('a', (filled: 0, current: 0)), isNull);
      expect(memory.swap('a', (filled: 1, current: 1)), (
        filled: 0,
        current: 0,
      ));
      expect(
        memory.swap('b', (filled: 2, current: 2)),
        isNull,
        reason: 'another draft starts at rest',
      );
      expect(memory.swap('b', (filled: 2, current: 2)), (
        filled: 2,
        current: 2,
      ));
    });

    test('lids stand open when empty and shut when full', () {
      expect(OrganiserPainter.lidAt(0), OrganiserPainter.open);
      expect(
        OrganiserPainter.lidAt(OrganiserPainter.shutStart),
        OrganiserPainter.open,
      );
      expect(OrganiserPainter.lidAt(1), 0);
    });

    test('the ripple passes and the organiser lies flat at the end', () {
      for (var i = 0; i < SetupOrganiser.count; i++) {
        expect(OrganiserPainter.rippleAt(i, 0), closeTo(0, 1e-9));
        expect(
          OrganiserPainter.rippleAt(i, OrganiserPainter.rippleEnd),
          closeTo(0, 1e-9),
        );
      }
      expect(OrganiserPainter.rippleAt(0, .15), greaterThan(0));
      expect(OrganiserPainter.flatAt(.5), 0);
      expect(OrganiserPainter.flatAt(1), 1);
    });
  });

  group('SetupOrganiser', () {
    testWidgets('appears at rest with its saved capsules', (tester) async {
      await tester.pumpWidget(
        _host(const SetupOrganiser(filled: 2, current: 2)),
      );
      expect(_fills(tester), [1, 1, 0, 0]);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a saved step drops a capsule and clicks the lid shut', (
      tester,
    ) async {
      final haptics = _hapticsOf(tester);
      await tester.pumpWidget(
        _host(const SetupOrganiser(filled: 1, current: 1)),
      );
      await tester.pumpWidget(
        _host(const SetupOrganiser(filled: 2, current: 2)),
      );
      await tester.pump(SetupOrganiser.drop ~/ 2);
      expect(_fills(tester)[1], inExclusiveRange(0, 1));
      expect(haptics, isEmpty, reason: 'the lid is not shut yet');
      await tester.pumpAndSettle();
      expect(_fills(tester), [1, 1, 0, 0]);
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('going back opens the lid and lifts the capsule out', (
      tester,
    ) async {
      final haptics = _hapticsOf(tester);
      await tester.pumpWidget(
        _host(const SetupOrganiser(filled: 2, current: 2)),
      );
      await tester.pumpWidget(
        _host(const SetupOrganiser(filled: 1, current: 1)),
      );
      await tester.pump(SetupOrganiser.lift ~/ 2);
      expect(_fills(tester)[1], inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(_fills(tester), [1, 0, 0, 0]);
      expect(haptics, isEmpty);
    });

    testWidgets('a new organiser moves on from what the last one showed', (
      tester,
    ) async {
      final haptics = _hapticsOf(tester);
      await tester.pumpWidget(
        _host(
          const SetupOrganiser(
            filled: 2,
            current: 2,
            from: (filled: 1, current: 1),
          ),
        ),
      );
      expect(_fills(tester), [1, 0, 0, 0]);
      expect(_painter(tester).focus, 1);
      await tester.pump(const Duration(milliseconds: 100));
      expect(_fills(tester)[1], inExclusiveRange(0, 1));
      expect(_painter(tester).focus, inExclusiveRange(1, 2));
      await tester.pumpAndSettle();
      expect(_fills(tester), [1, 1, 0, 0]);
      expect(_painter(tester).focus, 2);
      expect(haptics, ['HapticFeedbackType.lightImpact']);
    });

    testWidgets('quiet mode shows each state at once', (tester) async {
      await tester.pumpWidget(
        _host(const SetupOrganiser(filled: 1, current: 1), quiet: true),
      );
      await tester.pumpWidget(
        _host(const SetupOrganiser(filled: 3, current: 3), quiet: true),
      );
      expect(_fills(tester), [1, 1, 1, 0]);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('finishing ripples the lids and lays a line', (tester) async {
      final haptics = _hapticsOf(tester);
      final key = GlobalKey<SetupOrganiserState>();
      await tester.pumpWidget(
        _host(Center(child: SetupOrganiser(key: key, filled: 4))),
      );
      SetupOrganiserLine? line;
      key.currentState!.finish().then((l) => line = l);
      await tester.pump();
      await tester.pump(SetupOrganiser.finishing ~/ 4);
      expect(_painter(tester).finish.value, inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(_painter(tester).finish.value, 1);
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      final box = tester.getRect(find.byType(SetupOrganiser));
      expect(line, isNotNull);
      expect(line!.from.dy, line!.to.dy);
      expect(line!.from.dy, inInclusiveRange(box.top, box.bottom));
      expect(line!.from.dx, greaterThan(box.left));
      expect(line!.to.dx, lessThan(box.right));
      expect((line!.from.dx + line!.to.dx) / 2, closeTo(box.center.dx, 1e-6));
      expect(line!.color, _light.colorScheme.primary);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('quiet mode finishes at once with no line', (tester) async {
      final key = GlobalKey<SetupOrganiserState>();
      await tester.pumpWidget(
        _host(SetupOrganiser(key: key, filled: 4), quiet: true),
      );
      expect(await key.currentState!.finish(), isNull);
      expect(_painter(tester).finish.value, 0);
    });

    testWidgets('adds nothing for a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const SetupOrganiser(filled: 2)));
      expect(
        find.descendant(
          of: find.byType(SetupOrganiser),
          matching: find.byType(ExcludeSemantics),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('SetupScreen', () {
    setUpAll(tzdata.initializeTimeZones);

    Future<void> pumpSetup(
      WidgetTester tester,
      SetupRequest request, {
      double textScale = 1,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = await ProtectedWorkspaceFixture.create();
      final container = await fixture.createContainer();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: _light,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: SetupScreen(request: request),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('first run shows the organiser above the form', (tester) async {
      await pumpSetup(tester, const SetupRequest());
      expect(find.byType(SetupOrganiser), findsOneWidget);
      expect(tester.getSize(find.byType(SetupOrganiser)).height, 96);
    });

    testWidgets('large text keeps the organiser to a slim band', (
      tester,
    ) async {
      await pumpSetup(tester, const SetupRequest(), textScale: 2);
      expect(tester.getSize(find.byType(SetupOrganiser)).height, 60);
    });

    testWidgets('adding a person later has no organiser', (tester) async {
      await pumpSetup(tester, const SetupRequest(purpose: SetupPurpose.person));
      expect(find.byType(SetupOrganiser), findsNothing);
    });
  });
}
