import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/protection/access_gate.dart';
import 'package:simpastil/core/protection/app_lock_controller.dart';

class _Storage implements AppLockPolicyStorage {
  _Storage({this.legacyValue, String? encoded}) : persisted = encoded;
  String? persisted;
  Object? cached;
  bool failWrite = false;
  bool failReloadAfterWrite = false;
  bool writeAttempted = false;
  int reloadCount = 0;
  int? holdReloadAt;
  Completer<void>? reloadEntered;
  Completer<void>? releaseReload;
  @override
  Object? legacyValue;
  @override
  Object? get policyValue => cached ?? persisted;
  @override
  Future<void> reload() async {
    reloadCount++;
    if (reloadCount == holdReloadAt) {
      reloadEntered?.complete();
      await releaseReload?.future;
    }
    if (writeAttempted && failReloadAfterWrite) {
      throw StateError('Policy persistence could not be reloaded');
    }
    cached = persisted;
  }

  @override
  Future<bool> write(String value) async {
    writeAttempted = true;
    cached = value;
    if (failWrite) return false;
    persisted = value;
    return true;
  }
}

class _Authenticator implements DeviceAuthenticator {
  bool supported = true;
  bool result = true;
  Completer<bool>? held;
  int leaveGeneration = 0;
  bool foreground = true;
  bool deviceCredentialPromptPaused = false;
  String? activeAttemptId;
  String? lastFallbackLabel;
  @override
  void Function(String)? onCredentialPromptPaused;
  @override
  void Function(String)? onCredentialPromptResumed;
  @override
  Future<bool> isSupported() async => supported;
  @override
  Future<bool> authenticate(
    String reason, {
    required String attemptId,
    String? fallbackLabel,
  }) async {
    lastFallbackLabel = fallbackLabel;
    activeAttemptId = attemptId;
    final authenticated = held == null ? result : await held!.future;
    if (activeAttemptId == attemptId) activeAttemptId = null;
    return authenticated;
  }

  @override
  Future<DeviceAuthenticationContext> context() async =>
      DeviceAuthenticationContext(
        leaveGeneration: leaveGeneration,
        foreground: foreground,
        credentialPromptAttemptId: deviceCredentialPromptPaused
            ? activeAttemptId
            : null,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppLockPolicyStore store(_Storage storage, {ProjectionEffectsGate? gate}) =>
      AppLockPolicyStore(storage, gate: gate ?? SerialProjectionEffectsGate());

  test(
    'unlock and policy change retain the caller localized fallback',
    () async {
      final authenticator = _Authenticator();
      final controller = AppLockController(
        store(_Storage(legacyValue: true)),
        authenticator,
      );
      addTearDown(controller.dispose);
      expect(
        await controller.unlock(
          'Deblochează',
          fallbackLabel: 'Folosește blocarea dispozitivului',
        ),
        isTrue,
      );
      expect(
        authenticator.lastFallbackLabel,
        'Folosește blocarea dispozitivului',
      );
      expect(
        await controller.setEnabled(
          false,
          'Turn off app lock',
          fallbackLabel: 'Use device lock',
        ),
        isTrue,
      );
      expect(authenticator.lastFallbackLabel, 'Use device lock');
    },
  );

  test('fresh absence is off; legacy enabled is cold locked', () {
    final off = AppLockController(store(_Storage()), _Authenticator());
    final legacy = AppLockController(
      store(_Storage(legacyValue: true)),
      _Authenticator(),
    );
    addTearDown(off.dispose);
    addTearDown(legacy.dispose);
    expect(off.state.canAccess, isTrue);
    expect(legacy.state.canAccess, isFalse);
    expect(legacy.state.enabled, isTrue);
  });

  test('malformed policy does not fall back to legacy off', () {
    final controller = AppLockController(
      store(_Storage(encoded: '{damaged', legacyValue: false)),
      _Authenticator(),
    );
    addTearDown(controller.dispose);
    expect(controller.state.canAccess, isFalse);
    expect(controller.state.phase, AppLockPhase.unavailable);
  });

  test('new enabled policy takes precedence over legacy off', () {
    final controller = AppLockController(
      store(
        _Storage(
          encoded: jsonEncode({
            'version': 1,
            'enabled': true,
            'revision': 'reviewed-device-policy',
          }),
          legacyValue: false,
        ),
      ),
      _Authenticator(),
    );
    addTearDown(controller.dispose);
    expect(controller.state.enabled, isTrue);
    expect(controller.state.canAccess, isFalse);
  });

  test('cancellation and unavailable device never unlock', () async {
    final auth = _Authenticator()..result = false;
    final controller = AppLockController(
      store(_Storage(legacyValue: true)),
      auth,
    );
    addTearDown(controller.dispose);
    expect(await controller.unlock('Unlock'), isFalse);
    expect(controller.state.canAccess, isFalse);
    auth.supported = false;
    expect(await controller.unlock('Unlock'), isFalse);
    expect(controller.state.phase, AppLockPhase.locked);
    expect(controller.state.failure, AppLockFailure.unavailable);
  });

  test(
    'unsupported enabling preserves verified lock-off care access',
    () async {
      final auth = _Authenticator()..supported = false;
      final controller = AppLockController(store(_Storage()), auth);
      addTearDown(controller.dispose);
      expect(await controller.setEnabled(true, 'Enable lock'), isFalse);
      expect(controller.current.canAccess, isTrue);
      expect(controller.current.failure, AppLockFailure.unavailable);
      expect(controller.captureAccess, returnsNormally);
    },
  );

  test('failed disable and failed persistence reload remain locked', () async {
    final storage = _Storage(legacyValue: true)
      ..failWrite = true
      ..failReloadAfterWrite = true;
    final controller = AppLockController(store(storage), _Authenticator());
    addTearDown(controller.dispose);
    expect(await controller.setEnabled(false, 'Disable lock'), isFalse);
    expect(controller.current.policy, isNull);
    expect(controller.current.phase, AppLockPhase.unavailable);
    expect(controller.current.canAccess, isFalse);
    expect(controller.current.enabled, isTrue);
  });

  test(
    'policy uncertainty stays closed until its gated reload completes',
    () async {
      final storage = _Storage()
        ..failWrite = true
        ..holdReloadAt = 3
        ..reloadEntered = Completer<void>()
        ..releaseReload = Completer<void>();
      final auth = _Authenticator();
      final controller = AppLockController(store(storage), auth);
      addTearDown(controller.dispose);

      final failedEnable = controller.setEnabled(true, 'Enable lock');
      await storage.reloadEntered!.future;
      controller.userLeft();
      controller.resume();
      expect(controller.current.phase, AppLockPhase.unavailable);
      expect(controller.captureAccess, throwsA(isA<AppLockRequired>()));
      expect(await controller.unlock('Unlock'), isFalse);
      storage.releaseReload!.complete();

      expect(await failedEnable, isFalse);
      expect(controller.current.enabled, isFalse);
      expect(controller.current.canAccess, isTrue);
      expect(controller.current.failure, AppLockFailure.writeFailed);
    },
  );

  test(
    'failed setting write keeps previous policy and reloads cache',
    () async {
      final storage = _Storage()..failWrite = true;
      final controller = AppLockController(store(storage), _Authenticator());
      addTearDown(controller.dispose);
      expect(await controller.setEnabled(true, 'Enable lock'), isFalse);
      expect(storage.persisted, isNull);
      expect(controller.state.enabled, isFalse);
      expect(controller.state.canAccess, isTrue);
    },
  );

  test(
    'unlock and checked policy persist without a transferable unlock',
    () async {
      final storage = _Storage();
      final controller = AppLockController(store(storage), _Authenticator());
      addTearDown(controller.dispose);
      expect(await controller.setEnabled(true, 'Enable lock'), isTrue);
      expect(controller.state.canAccess, isTrue);
      final persisted = jsonDecode(storage.persisted!) as Map;
      expect(
        persisted.keys,
        unorderedEquals(['version', 'enabled', 'revision']),
      );
      final restarted = AppLockController(store(storage), _Authenticator());
      addTearDown(restarted.dispose);
      expect(restarted.state.canAccess, isFalse);
      expect(await restarted.unlock('Unlock'), isTrue);
    },
  );

  test(
    'background revokes an operation lease and resume does not restore it',
    () async {
      final controller = AppLockController(
        store(_Storage(legacyValue: true)),
        _Authenticator(),
      );
      addTearDown(controller.dispose);
      expect(await controller.unlock('Unlock'), isTrue);
      final lease = controller.captureAccess();
      controller.suspend();
      expect(controller.state.canAccess, isFalse);
      expect(lease.requireCurrent, throwsA(isA<AppLockRequired>()));
      controller.resume();
      expect(controller.state.canAccess, isFalse);
      expect(await controller.unlock('Unlock'), isTrue);
      expect(lease.requireCurrent, throwsA(isA<AppLockRequired>()));
    },
  );

  test(
    'background after policy commit cannot expose the old off state',
    () async {
      final storage = _Storage();
      final entered = Completer<void>();
      final release = Completer<void>();
      final controller = AppLockController(
        store(storage),
        _Authenticator(),
        onPolicyChanged: () async {
          entered.complete();
          await release.future;
        },
      );
      addTearDown(controller.dispose);
      final enabling = controller.setEnabled(true, 'Enable lock');
      await entered.future;
      expect((jsonDecode(storage.persisted!) as Map)['enabled'], isTrue);
      controller.userLeft();
      controller.resume();
      release.complete();
      expect(await enabling, isFalse);
      expect(controller.state.enabled, isTrue);
      expect(controller.state.canAccess, isFalse);
    },
  );

  test(
    'interrupted policy verification stays closed until durable reload succeeds',
    () async {
      final storage = _Storage()
        ..failReloadAfterWrite = true
        ..holdReloadAt = 2
        ..reloadEntered = Completer<void>()
        ..releaseReload = Completer<void>();
      final controller = AppLockController(store(storage), _Authenticator());
      addTearDown(controller.dispose);

      final enabling = controller.setEnabled(true, 'Enable lock');
      await storage.reloadEntered!.future;
      expect((jsonDecode(storage.persisted!) as Map)['enabled'], isTrue);
      controller.userLeft();
      expect(controller.current.phase, AppLockPhase.unavailable);
      expect(controller.captureAccess, throwsA(isA<AppLockRequired>()));
      controller.resume();
      expect(controller.current.phase, AppLockPhase.unavailable);
      expect(controller.captureAccess, throwsA(isA<AppLockRequired>()));

      storage.releaseReload!.complete();
      expect(await enabling, isFalse);
      expect(controller.current.policy, isNull);
      expect(controller.current.phase, AppLockPhase.unavailable);
      expect(controller.captureAccess, throwsA(isA<AppLockRequired>()));

      final recovered = Completer<void>();
      final removeListener = controller.addListener((state) {
        if (state.policy?.enabled == true &&
            state.phase == AppLockPhase.locked) {
          recovered.complete();
        }
      }, fireImmediately: false);
      storage.failReloadAfterWrite = false;
      controller.resume();
      expect(controller.captureAccess, throwsA(isA<AppLockRequired>()));
      await recovered.future.timeout(const Duration(seconds: 1));
      removeListener();

      expect(controller.current.enabled, isTrue);
      expect(controller.current.phase, AppLockPhase.locked);
      expect(controller.captureAccess, throwsA(isA<AppLockRequired>()));
    },
  );

  test(
    'delayed authentication success after genuine Home stays locked',
    () async {
      final auth = _Authenticator()..held = Completer<bool>();
      final controller = AppLockController(
        store(_Storage(legacyValue: true)),
        auth,
      );
      addTearDown(controller.dispose);
      final result = controller.unlock('Unlock');
      await Future<void>.delayed(Duration.zero);
      controller.userLeft();
      auth.leaveGeneration++;
      controller.resume();
      auth.held!.complete(true);
      expect(await result, isFalse);
      expect(controller.state.canAccess, isFalse);
    },
  );

  test(
    'only a matching device-credential pause preserves its auth attempt',
    () async {
      final auth = _Authenticator()..held = Completer<bool>();
      final controller = AppLockController(
        store(_Storage(legacyValue: true)),
        auth,
      );
      addTearDown(controller.dispose);
      final result = controller.unlock('Unlock');
      await Future<void>.delayed(Duration.zero);
      final attemptId = auth.activeAttemptId!;
      auth.deviceCredentialPromptPaused = true;
      auth.onCredentialPromptPaused!(attemptId);
      controller.suspend();
      expect(controller.state.canAccess, isFalse);
      auth.onCredentialPromptResumed!(attemptId);
      controller.resume();
      auth.held!.complete(true);
      expect(await result, isTrue);
      expect(controller.state.canAccess, isTrue);
    },
  );

  test(
    'late framework resume preserves a PIN unlock but a later Home revokes it',
    () async {
      final auth = _Authenticator()..held = Completer<bool>();
      final controller = AppLockController(
        store(_Storage(legacyValue: true)),
        auth,
      );
      addTearDown(controller.dispose);
      final result = controller.unlock('Unlock');
      await Future<void>.delayed(Duration.zero);
      final attemptId = auth.activeAttemptId!;
      auth.deviceCredentialPromptPaused = true;
      auth.onCredentialPromptPaused!(attemptId);
      controller.suspend();
      auth.onCredentialPromptResumed!(attemptId);
      auth.held!.complete(true);

      expect(await result, isTrue);
      final lease = controller.captureAccess();
      controller.resume();
      expect(controller.state.canAccess, isTrue);
      expect(lease.requireCurrent, returnsNormally);

      controller.suspend();
      controller.resume();
      expect(controller.state.canAccess, isFalse);
      expect(lease.requireCurrent, throwsA(isA<AppLockRequired>()));
    },
  );

  test(
    'an unrelated pause invalidates a pending authentication success',
    () async {
      final auth = _Authenticator()..held = Completer<bool>();
      final controller = AppLockController(
        store(_Storage(legacyValue: true)),
        auth,
      );
      addTearDown(controller.dispose);
      final result = controller.unlock('Unlock');
      await Future<void>.delayed(Duration.zero);
      auth.foreground = false;
      controller.suspend();
      auth.foreground = true;
      controller.resume();
      auth.held!.complete(true);
      expect(await result, isFalse);
      expect(controller.state.canAccess, isFalse);
    },
  );

  test(
    'policy publication waits for an off-state external transaction',
    () async {
      final storage = _Storage();
      final policy = store(storage);
      final controller = AppLockController(policy, _Authenticator());
      addTearDown(controller.dispose);
      final release = Completer<void>();
      final entered = Completer<void>();
      final recording = AccessGate(policy).runHeadless(() async {
        entered.complete();
        await release.future;
        return 'saved before lock was enabled';
      });
      await entered.future;
      final enabling = controller.setEnabled(true, 'Enable lock');
      await Future<void>.delayed(Duration.zero);
      expect(storage.persisted, isNull);
      release.complete();
      expect(await recording, 'saved before lock was enabled');
      expect(await enabling, isTrue);
      var laterMutation = false;
      await expectLater(
        AccessGate(policy).runHeadless(() async => laterMutation = true),
        throwsA(isA<AppLockRequired>()),
      );
      expect(laterMutation, isFalse);
    },
  );
}
