import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/app/startup_splash.dart';
import 'package:simpastil/shared/widgets/capsule_mark.dart';

void main() {
  testWidgets('first frame shows the brand and accessible loading status', (
    tester,
  ) async {
    tester.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    final semantics = tester.ensureSemantics();

    try {
      // Startup can render before providers, preferences, and app l10n exist.
      await tester.pumpWidget(const StartupSplash());

      expect(find.text('Simpastil'), findsOneWidget);
      expect(find.byType(CapsuleMark), findsOneWidget);
      expect(find.bySemanticsLabel('Loading Simpastil'), findsOneWidget);
      final progress = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(progress.value, isNull);
      expect(find.byType(TextButton), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('loading status uses the Romanian device language before l10n', (
    tester,
  ) async {
    tester.platformDispatcher.localeTestValue = const Locale('ro');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    final semantics = tester.ensureSemantics();

    try {
      await tester.pumpWidget(const StartupSplash());

      expect(find.text('Simpastil'), findsOneWidget);
      expect(find.bySemanticsLabel('Se încarcă Simpastil'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  for (final entry in const [
    (language: 'en', message: 'Simpastil couldn’t open.', retry: 'Try again'),
    (
      language: 'ro',
      message: 'Simpastil nu s-a putut deschide.',
      retry: 'Încearcă din nou',
    ),
  ]) {
    testWidgets('startup failure offers retry in ${entry.language}', (
      tester,
    ) async {
      tester.platformDispatcher.localeTestValue = Locale(entry.language);
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      final semantics = tester.ensureSemantics();
      var retries = 0;
      try {
        await tester.pumpWidget(
          StartupSplash(failed: true, onRetry: () => retries++),
        );
        await tester.pumpAndSettle();

        expect(find.text('Simpastil'), findsOneWidget);
        expect(find.bySemanticsLabel(entry.message), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(retries, 0);
        await tester.tap(find.widgetWithText(FilledButton, entry.retry));
        expect(retries, 1);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }

  testWidgets('large-text failure keeps retry reachable on a small screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.localeTestValue = const Locale('ro');
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    var retries = 0;
    await tester.pumpWidget(
      StartupSplash(failed: true, onRetry: () => retries++),
    );
    await tester.pumpAndSettle();

    final retry = find.widgetWithText(FilledButton, 'Încearcă din nou');
    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();
    await tester.tap(retry);
    expect(retries, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final accessibleNavigation in [false, true]) {
    testWidgets('system dark mode and large text stay calm with reduced motion '
        '(accessible navigation: $accessibleNavigation)', (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(
            disableAnimations: true,
            accessibleNavigation: accessibleNavigation,
          );
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      await tester.pumpWidget(const StartupSplash());
      await tester.pump();

      final brandContext = tester.element(find.text('Simpastil'));
      expect(Theme.of(brandContext).brightness, Brightness.dark);
      expect(MediaQuery.textScalerOf(brandContext).scale(10), 20);
      final bounds = tester.getRect(find.text('Simpastil'));
      expect(bounds.left, greaterThanOrEqualTo(0));
      expect(bounds.right, lessThanOrEqualTo(320));
      expect(bounds.top, greaterThanOrEqualTo(0));
      expect(bounds.bottom, lessThanOrEqualTo(480));
      expect(tester.takeException(), isNull);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('accessible navigation alone keeps the loader turning', (
    tester,
  ) async {
    // Android reports accessible navigation for any accessibility service
    // (password managers, automation apps); only "Remove animations" quiets.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    await tester.pumpWidget(const StartupSplash());
    await tester.pump();

    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
