import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/features/auth/presentation/biometric_guard.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/protection/app_lock_controller.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/l10n/app_localizations.dart';

class _LabelAuthenticator implements DeviceAuthenticator {
  String? fallbackLabel;
  bool authenticated = false;
  @override
  void Function(String)? onCredentialPromptPaused;
  @override
  void Function(String)? onCredentialPromptResumed;
  @override
  Future<bool> isSupported() async => true;
  @override
  Future<DeviceAuthenticationContext> context() async =>
      const DeviceAuthenticationContext(leaveGeneration: 0, foreground: true);
  @override
  Future<bool> authenticate(
    String reason, {
    required String attemptId,
    String? fallbackLabel,
  }) async {
    this.fallbackLabel = fallbackLabel;
    return authenticated;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'lock-off external autofill activity retains the input connection',
    (tester) async {
      SharedPreferences.setMockInitialValues({legacyAppLockKey: false});
      final prefs = await SharedPreferences.getInstance();
      final controller = AppLockController(
        AppLockPolicyStore(
          SharedAppLockPolicyStorage(prefs),
          gate: SerialProjectionEffectsGate(),
        ),
        _LabelAuthenticator(),
      );
      final focus = FocusNode();
      final text = TextEditingController();
      addTearDown(focus.dispose);
      addTearDown(text.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLockControllerProvider.overrideWith((_) => controller),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BiometricGuard(
              child: Scaffold(
                body: AutofillGroup(
                  child: TextField(
                    controller: text,
                    focusNode: focus,
                    autofocus: true,
                    autofillHints: const [AutofillHints.username],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      final retained = focus.hasFocus;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(retained, isTrue);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(text: 'fictional@example.test'),
      );
      await tester.pump();
      expect(text.text, 'fictional@example.test');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final language in ['en', 'ro']) {
    testWidgets('fallback label follows app locale $language', (tester) async {
      SharedPreferences.setMockInitialValues({legacyAppLockKey: true});
      final prefs = await SharedPreferences.getInstance();
      final authenticator = _LabelAuthenticator();
      final controller = AppLockController(
        AppLockPolicyStore(
          SharedAppLockPolicyStorage(prefs),
          gate: SerialProjectionEffectsGate(),
        ),
        authenticator,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLockControllerProvider.overrideWith((_) => controller),
          ],
          child: MaterialApp(
            locale: Locale(language),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const BiometricGuard(child: Text('Private care')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Private care'), findsNothing);
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(
        authenticator.fallbackLabel,
        language == 'ro'
            ? 'Folosește blocarea dispozitivului'
            : 'Use device lock',
      );
      expect(find.text('Private care'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'transient inactive lifecycle obscures care and keeps text focus',
    (tester) async {
      SharedPreferences.setMockInitialValues({legacyAppLockKey: true});
      final preferences = await SharedPreferences.getInstance();
      final authenticator = _LabelAuthenticator()..authenticated = true;
      final controller = AppLockController(
        AppLockPolicyStore(
          SharedAppLockPolicyStorage(preferences),
          gate: SerialProjectionEffectsGate(),
        ),
        authenticator,
      );
      expect(await controller.unlock('Unlock'), isTrue);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            appLockControllerProvider.overrideWith((_) => controller),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BiometricGuard(
              child: Scaffold(
                body: Column(
                  children: [
                    const Text('Private care'),
                    TextField(focusNode: focusNode, autofocus: true),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(focusNode.hasFocus, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      final focusSurvivedInactive = focusNode.hasFocus;
      final contentWasObscured = find.text('Private care').evaluate().isEmpty;
      final lockWasVisible = find
          .byKey(const Key('app-lock-screen'))
          .evaluate()
          .isNotEmpty;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(contentWasObscured, isTrue);
      expect(lockWasVisible, isTrue);
      expect(focusSurvivedInactive, isTrue);
      expect(find.text('Private care'), findsOneWidget);
      expect(focusNode.hasFocus, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(controller.state.canAccess, isFalse);
      expect(focusNode.hasFocus, isFalse);
      expect(find.text('Private care'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Private care'), findsNothing);
    },
  );

  testWidgets('shows child when biometric_lock_enabled is false', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'biometric_lock_enabled': false});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BiometricGuard(child: Scaffold(body: Text('App Content'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('App Content'), findsOneWidget);
    // BiometricGuard's overlay barrier has a specific dark color; Navigator
    // also inserts ModalBarrier widgets so we can't use findsNothing on the type.
    expect(
      find.byWidgetPredicate(
        (w) => w is ModalBarrier && w.color == const Color(0xCC000000),
      ),
      findsNothing,
    );
  });
}
