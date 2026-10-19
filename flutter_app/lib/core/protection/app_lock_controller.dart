import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../projections/projection_effects_gate.dart';
import '../projections/projection_reconciler.dart';
import '../storage/shared_preferences_provider.dart';
import '../utils/app_logger.dart';

const appLockPolicyKey = 'app_lock_policy_v1';
const legacyAppLockKey = 'biometric_lock_enabled';

class AppLockRequired implements Exception {
  const AppLockRequired();
}

class AppLockUnavailable implements Exception {
  const AppLockUnavailable();
}

class AppLockPolicy {
  const AppLockPolicy({required this.enabled, required this.revision});
  final bool enabled;
  final String revision;
  String encode() =>
      jsonEncode({'version': 1, 'enabled': enabled, 'revision': revision});
}

abstract interface class AppLockPolicyStorage {
  Object? get policyValue;
  Object? get legacyValue;
  Future<void> reload();
  Future<bool> write(String value);
}

class SharedAppLockPolicyStorage implements AppLockPolicyStorage {
  const SharedAppLockPolicyStorage(this.preferences);
  final SharedPreferences preferences;
  @override
  Object? get policyValue => preferences.get(appLockPolicyKey);
  @override
  Object? get legacyValue => preferences.get(legacyAppLockKey);
  @override
  Future<void> reload() => preferences.reload();
  @override
  Future<bool> write(String value) =>
      preferences.setString(appLockPolicyKey, value);
}

/// Whether app lock is on in the stored policy. An unreadable policy counts as
/// on, so every caller errs towards opening the app for review.
bool appLockEnabledNow(SharedPreferences preferences) {
  try {
    return AppLockPolicyStore(
      SharedAppLockPolicyStorage(preferences),
    ).snapshot().enabled;
  } on Object {
    return true;
  }
}

final ProjectionEffectsGate privateAppLockGate = PrivateProjectionEffectsGate(
  subdirectory: 'app-lock',
);

/// Independent of care opening and portable restore. Only a durable policy is
/// shared by engines; a foreground unlock is never written here.
class AppLockPolicyStore {
  AppLockPolicyStore(this.storage, {ProjectionEffectsGate? gate})
    : gate = gate ?? privateAppLockGate;
  final AppLockPolicyStorage storage;
  final ProjectionEffectsGate gate;

  AppLockPolicy snapshot() {
    try {
      final raw = storage.policyValue;
      if (raw == null) {
        final legacy = storage.legacyValue;
        if (legacy != null && legacy is! bool) {
          throw const AppLockUnavailable();
        }
        return AppLockPolicy(
          enabled: legacy == true,
          revision: legacy == true ? 'legacy-enabled' : 'initial-off',
        );
      }
      if (raw is! String || raw.length > 8192) {
        throw const AppLockUnavailable();
      }
      final json = jsonDecode(raw);
      if (json is! Map ||
          json.length != 3 ||
          json['version'] != 1 ||
          json['enabled'] is! bool ||
          json['revision'] is! String ||
          (json['revision'] as String).trim().isEmpty ||
          (json['revision'] as String).length > 128) {
        throw const AppLockUnavailable();
      }
      return AppLockPolicy(
        enabled: json['enabled'] as bool,
        revision: json['revision'] as String,
      );
    } on Object {
      throw const AppLockUnavailable();
    }
  }

  /// Caller holds [gate], including through an external recording transaction.
  Future<AppLockPolicy> loadInsideGate() async {
    try {
      await storage.reload();
      return snapshot();
    } on Object {
      throw const AppLockUnavailable();
    }
  }

  Future<AppLockPolicy> load() => gate.run(loadInsideGate);

  Future<AppLockPolicy> replace({
    required AppLockPolicy expected,
    required bool enabled,
    required void Function() requireCurrent,
  }) => gate.run(() async {
    final current = await loadInsideGate();
    requireCurrent();
    if (current.revision != expected.revision ||
        current.enabled != expected.enabled) {
      throw const AppLockRequired();
    }
    final next = AppLockPolicy(enabled: enabled, revision: const Uuid().v4());
    try {
      if (!await storage.write(next.encode())) {
        throw const AppLockUnavailable();
      }
      final persisted = await loadInsideGate();
      if (persisted.revision != next.revision ||
          persisted.enabled != next.enabled) {
        throw const AppLockUnavailable();
      }
      return persisted;
    } catch (_) {
      await storage.reload();
      rethrow;
    }
  });
}

class DeviceAuthenticationContext {
  const DeviceAuthenticationContext({
    required this.leaveGeneration,
    required this.foreground,
    this.credentialPromptAttemptId,
  });
  final int leaveGeneration;
  final bool foreground;
  final String? credentialPromptAttemptId;
}

abstract interface class DeviceAuthenticator {
  Future<bool> isSupported();
  Future<bool> authenticate(
    String reason, {
    required String attemptId,
    String fallbackLabel = 'Use device lock',
  });
  Future<DeviceAuthenticationContext> context();
  void Function(String)? onCredentialPromptPaused;
  void Function(String)? onCredentialPromptResumed;
}

class LocalDeviceAuthenticator implements DeviceAuthenticator {
  LocalDeviceAuthenticator();
  static const channel = MethodChannel('com.simpastil/app_lock');
  final LocalAuthentication _authentication = LocalAuthentication();
  void Function()? onInvalidated;
  @override
  void Function(String)? onCredentialPromptPaused;
  @override
  void Function(String)? onCredentialPromptResumed;

  void bind() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'accessInvalidated') {
        onInvalidated?.call();
      } else if (call.method == 'credentialPromptPaused' &&
          call.arguments is Map &&
          (call.arguments as Map)['attemptId'] is String) {
        onCredentialPromptPaused?.call(
          (call.arguments as Map)['attemptId'] as String,
        );
      } else if (call.method == 'credentialPromptResumed' &&
          call.arguments is Map &&
          (call.arguments as Map)['attemptId'] is String) {
        onCredentialPromptResumed?.call(
          (call.arguments as Map)['attemptId'] as String,
        );
      }
    });
  }

  void close() {
    onInvalidated = null;
    onCredentialPromptPaused = null;
    onCredentialPromptResumed = null;
    channel.setMethodCallHandler(null);
  }

  Future<void> synchronizePolicy() => channel.invokeMethod('refreshPolicy');
  @override
  Future<bool> isSupported() => _authentication.isDeviceSupported();
  @override
  Future<bool> authenticate(
    String reason, {
    required String attemptId,
    String fallbackLabel = 'Use device lock',
  }) async {
    if (Platform.isAndroid) {
      final response = await channel.invokeMapMethod<String, dynamic>(
        'authenticate',
        {
          'attemptId': attemptId,
          'reason': reason,
          'fallbackLabel': fallbackLabel,
        },
      );
      return response?['attemptId'] == attemptId &&
          response?['authenticated'] == true;
    }
    return _authentication.authenticate(
      localizedReason: reason,
      biometricOnly: false,
      persistAcrossBackgrounding: false,
    );
  }

  @override
  Future<DeviceAuthenticationContext> context() async {
    if (!Platform.isAndroid) {
      return const DeviceAuthenticationContext(
        leaveGeneration: 0,
        foreground: true,
      );
    }
    final data = await channel.invokeMapMethod<String, dynamic>('context');
    if (data == null ||
        data['leaveGeneration'] is! int ||
        data['foreground'] is! bool ||
        (data['credentialPromptAttemptId'] != null &&
            data['credentialPromptAttemptId'] is! String)) {
      throw const AppLockUnavailable();
    }
    return DeviceAuthenticationContext(
      leaveGeneration: data['leaveGeneration'] as int,
      foreground: data['foreground'] as bool,
      credentialPromptAttemptId: data['credentialPromptAttemptId'] as String?,
    );
  }
}

enum AppLockPhase { unlocked, locked, authenticating, unavailable }

enum AppLockFailure { none, cancelled, unavailable, writeFailed, stale }

class AppLockState {
  const AppLockState(
    this.policy,
    this.phase, {
    this.failure = AppLockFailure.none,
  });
  final AppLockPolicy? policy;
  final AppLockPhase phase;
  final AppLockFailure failure;
  bool get enabled => policy?.enabled ?? true;
  bool get canAccess => phase == AppLockPhase.unlocked;
  bool get isAuthenticating => phase == AppLockPhase.authenticating;
}

class AppLockLease {
  AppLockLease._(this._controller, this._generation, this._revision);
  final AppLockController _controller;
  final int _generation;
  final String _revision;
  void requireCurrent() => _controller._requireLease(_generation, _revision);
}

class AppLockController extends StateNotifier<AppLockState> {
  AppLockController(this.store, this.authenticator, {this.onPolicyChanged})
    : super(_initial(store)) {
    authenticator.onCredentialPromptPaused = credentialPromptPaused;
    authenticator.onCredentialPromptResumed = credentialPromptResumed;
  }
  final AppLockPolicyStore store;
  final DeviceAuthenticator authenticator;
  final Future<void> Function()? onPolicyChanged;
  int _generation = 0;
  int _attempt = 0;
  bool _foreground = true;
  String? _activeAuthenticationId;
  String? _credentialPromptTransitionId;
  String? _uncertainPolicyPublicationId;
  String? _policyRecoveryId;
  Future<void>? _policyRecovery;

  AppLockState get current => state;

  void _requireLease(int generation, String revision) {
    if (!mounted ||
        !state.canAccess ||
        _generation != generation ||
        state.policy?.revision != revision) {
      throw const AppLockRequired();
    }
  }

  static AppLockState _initial(AppLockPolicyStore store) {
    try {
      final policy = store.snapshot();
      return AppLockState(
        policy,
        policy.enabled ? AppLockPhase.locked : AppLockPhase.unlocked,
      );
    } on Object {
      return const AppLockState(
        null,
        AppLockPhase.unavailable,
        failure: AppLockFailure.unavailable,
      );
    }
  }

  AppLockLease captureAccess() {
    if (!state.canAccess || state.policy == null) throw const AppLockRequired();
    return AppLockLease._(this, _generation, state.policy!.revision);
  }

  void suspend() {
    _foreground = false;
    if (state.isAuthenticating &&
        _activeAuthenticationId != null &&
        _credentialPromptTransitionId == _activeAuthenticationId) {
      // Consume a native-confirmed device-credential transition once.
      _credentialPromptTransitionId = null;
      _generation++;
      state = AppLockState(state.policy, AppLockPhase.authenticating);
      return;
    }
    _revokeForBackground();
  }

  void credentialPromptPaused(String attemptId) {
    if (state.isAuthenticating &&
        _activeAuthenticationId == attemptId &&
        _foreground) {
      _credentialPromptTransitionId = attemptId;
    }
  }

  void credentialPromptResumed(String attemptId) {
    if (state.isAuthenticating && _activeAuthenticationId == attemptId) {
      _foreground = true;
      _credentialPromptTransitionId = null;
    }
  }

  void _revokeForBackground() {
    _foreground = false;
    if (state.enabled || state.isAuthenticating) _generation++;
    _attempt++;
    _activeAuthenticationId = null;
    _credentialPromptTransitionId = null;
    if (_uncertainPolicyPublicationId != null) {
      state = const AppLockState(
        null,
        AppLockPhase.unavailable,
        failure: AppLockFailure.writeFailed,
      );
      return;
    }
    state = AppLockState(
      state.policy,
      state.enabled || state.isAuthenticating
          ? AppLockPhase.locked
          : AppLockPhase.unlocked,
    );
  }

  void userLeft() => _revokeForBackground();

  void resume() {
    _foreground = true;
    _credentialPromptTransitionId = null;
    final uncertainPublication = _uncertainPolicyPublicationId;
    if (uncertainPublication != null) {
      state = const AppLockState(
        null,
        AppLockPhase.unavailable,
        failure: AppLockFailure.writeFailed,
      );
      unawaited(
        _reconcilePolicyPublication(
          uncertainPublication,
          failure: AppLockFailure.stale,
        ),
      );
      return;
    }
    if (state.isAuthenticating) return;
    // Native device-credential completion and Flutter's lifecycle channel can
    // resume in either order. A late duplicate foreground resume must not
    // revoke the lease that the matching authentication just published.
    // Any genuine background transition already revoked access before this
    // callback, and uncertain policy publication was handled above.
    if (state.canAccess) return;
    state = AppLockState(
      state.policy,
      state.policy == null
          ? AppLockPhase.unavailable
          : state.enabled
          ? AppLockPhase.locked
          : AppLockPhase.unlocked,
    );
  }

  Future<bool> unlock(
    String reason, {
    String fallbackLabel = 'Use device lock',
  }) => _authenticate(reason, fallbackLabel: fallbackLabel);
  Future<bool> setEnabled(
    bool enabled,
    String reason, {
    String fallbackLabel = 'Use device lock',
  }) => _authenticate(
    reason,
    requestedPolicy: enabled,
    fallbackLabel: fallbackLabel,
  );

  Future<bool> _authenticate(
    String reason, {
    bool? requestedPolicy,
    required String fallbackLabel,
  }) async {
    if (state.isAuthenticating || !_foreground || state.policy == null) {
      return false;
    }
    final previous = state.policy!;
    final attempt = ++_attempt;
    final authenticationId = const Uuid().v4();
    var policyWriteAttempted = false;
    var policyPublicationCommitted = false;
    String? policyPublicationId;
    _generation++;
    _activeAuthenticationId = authenticationId;
    _credentialPromptTransitionId = null;
    state = AppLockState(previous, AppLockPhase.authenticating);
    try {
      if (!await authenticator.isSupported()) {
        throw const AppLockUnavailable();
      }
      final before = await authenticator.context();
      if (!before.foreground) throw const AppLockRequired();
      final authenticated = await authenticator.authenticate(
        reason,
        attemptId: authenticationId,
        fallbackLabel: fallbackLabel,
      );
      final after = await authenticator.context();
      if (!mounted) return false;
      if (attempt != _attempt ||
          !_foreground ||
          !after.foreground ||
          before.leaveGeneration != after.leaveGeneration) {
        throw const AppLockRequired();
      }
      if (!authenticated) {
        await _finishFailure(
          AppLockFailure.cancelled,
          knownPolicy: previous,
          attempt: attempt,
        );
        return false;
      }
      var policy = previous;
      if (requestedPolicy != null) {
        policyWriteAttempted = true;
        policyPublicationId = const Uuid().v4();
        _uncertainPolicyPublicationId = policyPublicationId;
        policy = await store.replace(
          expected: previous,
          enabled: requestedPolicy,
          requireCurrent: () {
            if (!mounted || attempt != _attempt || !_foreground) {
              throw const AppLockRequired();
            }
          },
        );
        policyPublicationCommitted = true;
        if (_uncertainPolicyPublicationId == policyPublicationId) {
          _uncertainPolicyPublicationId = null;
        }
        if (!mounted) return false;
        // The checked write has committed. Adopt its actual policy before any
        // optional native call, even if Home revoked the authentication attempt.
        _generation++;
        state = AppLockState(
          policy,
          attempt == _attempt && _foreground
              ? AppLockPhase.authenticating
              : policy.enabled || !_foreground
              ? AppLockPhase.locked
              : AppLockPhase.unlocked,
        );
        await onPolicyChanged?.call();
      } else {
        final current = await store.load();
        if (current.revision != previous.revision ||
            current.enabled != previous.enabled) {
          throw const AppLockRequired();
        }
      }
      if (!mounted || attempt != _attempt || !_foreground) return false;
      _generation++;
      state = AppLockState(policy, AppLockPhase.unlocked);
      return true;
    } on AppLockRequired {
      if (policyPublicationId != null &&
          !policyPublicationCommitted &&
          _uncertainPolicyPublicationId == policyPublicationId) {
        await _reconcilePolicyPublication(
          policyPublicationId,
          failure: attempt == _attempt
              ? AppLockFailure.stale
              : AppLockFailure.writeFailed,
        );
      } else if (mounted && attempt == _attempt) {
        await _finishFailure(
          AppLockFailure.stale,
          knownPolicy: previous,
          reloadPolicy: policyWriteAttempted,
          attempt: attempt,
        );
      }
      return false;
    } on Object {
      if (policyPublicationId != null &&
          !policyPublicationCommitted &&
          _uncertainPolicyPublicationId == policyPublicationId) {
        await _reconcilePolicyPublication(
          policyPublicationId,
          failure: attempt == _attempt
              ? AppLockFailure.writeFailed
              : AppLockFailure.stale,
        );
      } else if (mounted && attempt == _attempt) {
        await _finishFailure(
          policyWriteAttempted
              ? AppLockFailure.writeFailed
              : AppLockFailure.unavailable,
          knownPolicy: previous,
          reloadPolicy: policyWriteAttempted,
          attempt: attempt,
        );
      }
      return false;
    } finally {
      if (attempt == _attempt) {
        _activeAuthenticationId = null;
        _credentialPromptTransitionId = null;
      }
    }
  }

  Future<void> _reconcilePolicyPublication(
    String publicationId, {
    required AppLockFailure failure,
  }) async {
    if (!mounted || _uncertainPolicyPublicationId != publicationId) return;
    if (_policyRecoveryId == publicationId && _policyRecovery != null) {
      await _policyRecovery;
      return;
    }

    _policyRecoveryId = publicationId;
    final recovery = _loadPublishedPolicy(publicationId, failure);
    _policyRecovery = recovery;
    try {
      await recovery;
    } finally {
      if (_policyRecoveryId == publicationId &&
          identical(_policyRecovery, recovery)) {
        _policyRecoveryId = null;
        _policyRecovery = null;
      }
    }
  }

  Future<void> _loadPublishedPolicy(
    String publicationId,
    AppLockFailure failure,
  ) async {
    AppLockPolicy? verifiedPolicy;
    try {
      verifiedPolicy = await store.load();
    } on Object {
      // Keep the publication uncertain and access closed until a later
      // foreground reconciliation can verify the durable policy.
    }
    if (!mounted || _uncertainPolicyPublicationId != publicationId) return;
    if (verifiedPolicy == null) {
      state = AppLockState(null, AppLockPhase.unavailable, failure: failure);
      return;
    }

    _uncertainPolicyPublicationId = null;
    _generation++;
    state = AppLockState(
      verifiedPolicy,
      verifiedPolicy.enabled || !_foreground
          ? AppLockPhase.locked
          : AppLockPhase.unlocked,
      failure: failure,
    );
  }

  Future<void> _finishFailure(
    AppLockFailure failure, {
    required AppLockPolicy? knownPolicy,
    required int attempt,
    bool reloadPolicy = false,
  }) async {
    var verifiedPolicy = knownPolicy;
    if (reloadPolicy) {
      try {
        verifiedPolicy = await store.load();
      } on Object {
        // A cache value is not evidence of the durable policy after a write.
        verifiedPolicy = null;
      }
    }
    if (!mounted || attempt != _attempt) return;
    state = AppLockState(
      verifiedPolicy,
      verifiedPolicy == null
          ? AppLockPhase.unavailable
          : verifiedPolicy.enabled || !_foreground
          ? AppLockPhase.locked
          : AppLockPhase.unlocked,
      failure: failure,
    );
  }
}

final appLockPolicyStoreProvider = Provider<AppLockPolicyStore>(
  (ref) => AppLockPolicyStore(
    SharedAppLockPolicyStorage(ref.watch(sharedPreferencesProvider)),
  ),
);
final appLockControllerProvider =
    StateNotifierProvider<AppLockController, AppLockState>((ref) {
      final authentication = LocalDeviceAuthenticator();
      final controller = AppLockController(
        ref.watch(appLockPolicyStoreProvider),
        authentication,
        onPolicyChanged: () async {
          await authentication.synchronizePolicy();
          // Both directions matter: turning lock on moves reminders to the
          // open-the-app buttons, turning it off moves them to silent ones.
          unawaited(() async {
            try {
              await ref
                  .read(projectionReconcilerProvider)
                  .reconcileAll(refreshActiveActions: true);
            } on Object catch (error) {
              AppLogger.warning(
                'AppLock',
                'Optional notification action refresh failed: ${error.runtimeType}',
              );
            }
          }());
        },
      );
      authentication.onInvalidated = controller.userLeft;
      authentication.bind();
      ref.onDispose(authentication.close);
      return controller;
    });
