import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_event_provider.dart';
import '../../core/auth/credential_refresh_factory.dart';
import '../../core/auth/installation_key_repository.dart';
import '../../core/auth/protected_credentials_repository.dart';
import '../../core/errors/app_error.dart';
import '../../core/network/http_clients.dart';
import '../../core/network/server_pin_providers.dart';
import '../../core/server/server_config_notifier.dart';
import '../../core/session/session_generation_repository.dart';
import '../../core/session/session_runtime_coordinator.dart';
import '../../core/projections/projection_identity.dart';
import '../../core/storage/shared_preferences_provider.dart';
import '../../core/workspace/workspace_access_repository.dart';
import '../../core/workspace/workspace_context.dart';
import '../../core/workspace/workspace_provider.dart';
import 'auth_repository.dart';

sealed class AuthState {
  const AuthState();
}

final class AuthUnauthenticated extends AuthState {
  const AuthUnauthenticated();
}

final class AuthLoading extends AuthState {
  const AuthLoading();
}

final class AuthRequires2fa extends AuthState {
  const AuthRequires2fa({required this.challengeToken, required this.email});
  final String challengeToken;
  final String email;
  @override
  bool operator ==(Object other) =>
      other is AuthRequires2fa && other.challengeToken == challengeToken;
  @override
  int get hashCode => Object.hash(runtimeType, challengeToken);
}

final class AuthAuthenticated extends AuthState {
  const AuthAuthenticated(
    this.userId, {
    this.capability,
    this.workspaceId,
    this.requiresOriginReview = false,
  });
  final String userId;
  final NetworkCapability? capability;
  final String? workspaceId;
  final bool requiresOriginReview;
  @override
  bool operator ==(Object other) =>
      other is AuthAuthenticated &&
      other.userId == userId &&
      other.capability == capability &&
      other.workspaceId == workspaceId &&
      other.requiresOriginReview == requiresOriginReview;
  @override
  int get hashCode => Object.hash(
    runtimeType,
    userId,
    capability,
    workspaceId,
    requiresOriginReview,
  );
  @override
  String toString() => 'AuthAuthenticated(protected)';
}

class _AuthenticationAttempt {
  const _AuthenticationAttempt(this.operation, this.scope, this.repository);
  final int operation;
  final InstallationCapability scope;
  final AuthRepository repository;
}

final sessionRemoteRevocationProvider =
    Provider<Future<void> Function(CredentialBundle, String?)>(
      (ref) => (bundle, apiKey) async {
        final dio = createServerDio(
          pins: ref.read(serverPinStoreProvider),
          options: BaseOptions(
            baseUrl: '${bundle.endpoint}/api/v1',
            followRedirects: false,
            connectTimeout: const Duration(seconds: 10),
            sendTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 10),
          ),
        );
        try {
          await dio.post<void>(
            '/auth/logout',
            data: {'refreshToken': bundle.refreshToken},
            options: Options(headers: {'X-Api-Key': ?apiKey}),
          );
        } catch (_) {
        } finally {
          dio.close(force: true);
        }
      },
    );

class AuthNotifier extends Notifier<AuthState> {
  int _operation = 0;
  _AuthenticationAttempt? _challenge;
  @override
  AuthState build() => const AuthUnauthenticated();
  WorkspaceAccessRepository get _access =>
      ref.read(workspaceAccessRepositoryProvider);
  ProtectedCredentialsRepository get _credentials =>
      ref.read(protectedCredentialsRepositoryProvider);
  static const _currentUserIdKey = 'current_user_id';

  Future<void> _mirrorIdentity(NetworkCapability capability) async {
    // Compatibility preferences are never authorization. Protected DB state is
    // authoritative for foreground/background work and account transitions.
    if (!await _access.networkIsCurrent(capability)) return;
    try {
      await ref
          .read(sessionGenerationRepositoryProvider)
          .advanceTo(capability.ownerId);
      if (await _access.networkIsCurrent(capability)) {
        await ref
            .read(sharedPreferencesProvider)
            .setString(_currentUserIdKey, capability.ownerId);
      }
    } catch (_) {
      /* Optional compatibility metadata cannot undo publication. */
    }
  }

  Future<void> restoreSession() async {
    if (state is AuthAuthenticated) return;
    final operation = ++_operation;
    final capability = await _access.currentNetworkCapability();
    if (capability == null) return;
    final current = await _credentials.readFor(capability);
    if (current == null || operation != _operation) return;
    final workspace = await _access.workspaces.byOwner(capability.ownerId);
    if (workspace == null || !await _access.networkIsCurrent(capability)) {
      return;
    }
    await _publishSession(
      operation,
      AuthenticatedWorkspace(workspace, capability),
    );
  }

  /// The care replacement has already cleared durable network authority. Retire
  /// only the old in-memory attempt; a new valid login must keep its own state.
  Future<void> refreshAfterCareReplacement(WorkspaceContext local) async {
    await _access.requireCurrent(local);
    if (!local.isLocal || await _access.currentNetworkCapability() != null) {
      return;
    }
    ++_operation;
    _challenge = null;
    state = const AuthUnauthenticated();
  }

  Future<ProjectionIdentity?> _projectionFor(
    NetworkCapability? capability,
  ) async {
    if (capability == null) return null;
    final context = await _access.contextForOwner(capability.ownerId);
    return context?.networkEpoch == capability.epoch &&
            context?.sessionGeneration == capability.generation &&
            context?.endpoint == capability.endpoint
        ? ProjectionIdentity.fromContext(context!)
        : null;
  }

  Future<_AuthenticationAttempt> _begin() async {
    final operation = ++_operation;
    _challenge = null;
    state = const AuthLoading();
    final endpoint = ref.read(serverConfigProvider);
    if (endpoint == null) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.unresolvedOrigin,
      );
    }
    final prior = await _access.currentNetworkCapability();
    final priorProjection = await _projectionFor(prior);
    final epoch = await _access.revokeNetwork();
    try {
      await ref
          .read(sessionRuntimeCoordinatorProvider)
          .invalidate(
            captureActiveIdentity: false,
            identity: prior == null ? null : (prior.ownerId, prior.generation),
            projectionIdentity: priorProjection,
          );
    } catch (_) {
      /* Durable revocation precedes optional platform teardown. */
    }
    final scope = await _access.captureInstallation(endpoint);
    if (operation != _operation ||
        scope == null ||
        scope.networkEpoch != epoch) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.staleNetworkTransition,
      );
    }
    return _AuthenticationAttempt(
      operation,
      scope,
      ref.read(authTransitionRepositoryFactoryProvider)(scope),
    );
  }

  Future<Result<void>> login(String email, String password) async {
    final operation = _operation + 1;
    try {
      final attempt = await _begin();
      return await _receiveLogin(
        attempt,
        await attempt.repository.login(email, password),
        email,
      );
    } catch (_) {
      if (operation == _operation) state = const AuthUnauthenticated();
      return const Err(UnknownError('Unable to establish the local session'));
    }
  }

  Future<Result<void>> register(String email, String password) async {
    final operation = _operation + 1;
    try {
      final attempt = await _begin();
      final result = await attempt.repository.register(email, password);
      if (result case Err(:final error)) {
        if (attempt.operation == _operation) {
          state = const AuthUnauthenticated();
        }
        return Err(error);
      }
      if (!await _attemptIsCurrent(attempt)) {
        return const Err(UnauthorizedError());
      }
      return await _receiveLogin(
        attempt,
        await attempt.repository.login(email, password),
        email,
      );
    } catch (_) {
      if (operation == _operation) state = const AuthUnauthenticated();
      return const Err(UnknownError('Unable to establish the local session'));
    }
  }

  Future<bool> _attemptIsCurrent(_AuthenticationAttempt attempt) async =>
      attempt.operation == _operation &&
      await _access.installationIsCurrent(attempt.scope);

  Future<Result<void>> _receiveLogin(
    _AuthenticationAttempt attempt,
    Result<LoginResult> result,
    String email,
  ) async {
    if (!await _attemptIsCurrent(attempt)) {
      if (result case Ok(value: LoginSuccess(:final credentialId))) {
        if (credentialId != null) {
          await _credentials.discardUnreferenced(credentialId);
        }
      }
      return const Err(UnauthorizedError());
    }
    switch (result) {
      case Err(:final error):
        state = const AuthUnauthenticated();
        return Err(error);
      case Ok(:final value):
        switch (value) {
          case LoginRequires2fa(:final challengeToken):
            _challenge = attempt;
            state = AuthRequires2fa(
              challengeToken: challengeToken,
              email: email,
            );
            return const Ok(null);
          case LoginSuccess():
            return _completeLogin(attempt, value);
        }
    }
  }

  Future<Result<void>> verify2fa(String code) async {
    final challenge = state;
    final attempt = _challenge;
    if (challenge is! AuthRequires2fa ||
        attempt == null ||
        !await _attemptIsCurrent(attempt)) {
      return const Err(UnknownError('Not in 2FA challenge state'));
    }
    state = const AuthLoading();
    final result = await attempt.repository.challenge2fa(
      challenge.challengeToken,
      code,
    );
    switch (result) {
      case Ok(:final value):
        return _completeLogin(attempt, value);
      case Err(:final error):
        if (await _attemptIsCurrent(attempt)) state = challenge;
        return Err(error);
    }
  }

  Future<Result<void>> _completeLogin(
    _AuthenticationAttempt attempt,
    LoginSuccess success,
  ) async {
    final id = success.credentialId;
    if (id == null) {
      if (attempt.operation == _operation) state = const AuthUnauthenticated();
      return const Err(UnknownError('Missing protected credentials'));
    }
    try {
      if (!await _attemptIsCurrent(attempt)) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.staleNetworkTransition,
        );
      }
      final coordinator = createCredentialRefreshCoordinator(
        credentials: _credentials,
        keys: ref.read(installationKeyRepositoryProvider),
        gate: await ref.read(credentialRefreshGateProvider)(),
        endpoint: attempt.scope.endpoint,
        pins: ref.read(serverPinStoreProvider),
      );
      final activated = await coordinator.activateFreshAuthentication(
        credentialId: id,
        expectedTransition: attempt.scope.networkEpoch,
        sessionGeneration: attempt.scope.networkEpoch + 1,
        installation: attempt.scope,
      );
      if (activated.network.ownerId != success.userId) {
        await _access.revokeIfCurrent(activated.network);
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.unavailable,
        );
      }
      await _publishSession(attempt.operation, activated);
      return const Ok(null);
    } catch (_) {
      await _credentials.discardUnreferenced(id);
      if (attempt.operation == _operation) state = const AuthUnauthenticated();
      return const Err(UnknownError('Unable to establish the local session'));
    }
  }

  Future<void> _publishSession(
    int operation,
    AuthenticatedWorkspace activated,
  ) async {
    final capability = activated.network;
    if (operation != _operation ||
        !await _access.networkIsCurrent(capability)) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.staleNetworkTransition,
      );
    }
    await _mirrorIdentity(capability);
    if (operation != _operation ||
        !await _access.networkIsCurrent(capability)) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.staleNetworkTransition,
      );
    }
    _challenge = null;
    state = AuthAuthenticated(
      capability.ownerId,
      capability: capability,
      workspaceId: activated.workspace.id,
      requiresOriginReview: activated.workspace.bindingState != 'bound',
    );
    if (activated.workspace.bindingState == 'bound') {
      // Publishing valid offline access does not depend on optional projections.
      try {
        await ref
            .read(sessionRuntimeCoordinatorProvider)
            .start(capability.ownerId, capability.generation);
      } catch (_) {
        // Best effort: optional projections must not block offline access.
      }
    }
  }

  Future<Result<void>> confirmOriginalServer(String reviewedEndpoint) async {
    final current = state;
    if (current is! AuthAuthenticated ||
        current.capability == null ||
        current.workspaceId == null) {
      return const Err(UnauthorizedError());
    }
    try {
      await _access.confirmOriginalServer(
        workspaceId: current.workspaceId!,
        reviewedOriginalEndpoint: reviewedEndpoint,
        expectedNetworkEpoch: current.capability!.epoch,
      );
      final workspace = (await _access.workspaces.byId(current.workspaceId!))!;
      await _publishSession(
        _operation,
        AuthenticatedWorkspace(workspace, current.capability!),
      );
      return const Ok(null);
    } catch (_) {
      return const Err(
        UnknownError('Original server review could not be completed'),
      );
    }
  }

  /// Networking reports the captured failed capability. A late A event cannot
  /// clear B's credentials or auth state. The UI can skip stale feedback when false.
  Future<bool> clearSession() async {
    final failed = ref.read(authFailureCapabilityProvider);
    if (failed != null) {
      ref.read(authFailureCapabilityProvider.notifier).state = null;
    }
    final current = state;
    final currentCapability = current is AuthAuthenticated
        ? current.capability
        : await _access.currentNetworkCapability();
    if (failed != null &&
        currentCapability != null &&
        failed != currentCapability) {
      return false;
    }
    final capability = failed ?? currentCapability;
    if (capability == null) return false;
    final protectedState = await _access.workspaces.deviceState();
    if (!await _access.networkIsCurrent(capability) &&
        (protectedState.networkOwnerId != null ||
            protectedState.networkEpoch != capability.epoch + 1)) {
      return false;
    }
    final operation = ++_operation;
    _challenge = null;
    final projection = await _projectionFor(capability);
    final revoked = await _access.revokeCurrentSession(capability);
    try {
      await ref
          .read(sessionRuntimeCoordinatorProvider)
          .invalidate(
            captureActiveIdentity: false,
            identity: (capability.ownerId, capability.generation),
            projectionIdentity: projection,
          );
    } catch (_) {
      // Best effort: sign-out continues even if projection teardown fails.
    }
    if (revoked?.credentialId != null) {
      await _credentials.discardUnreferenced(revoked!.credentialId!);
    }
    try {
      await ref.read(sharedPreferencesProvider).remove(_currentUserIdKey);
    } catch (_) {
      // Best effort: a stale preference is cleared on the next sign-in.
    }
    if (operation != _operation ||
        (await _access.currentNetworkCapability()) != null) {
      return false;
    }
    state = const AuthUnauthenticated();
    return true;
  }

  Future<void> logout() async {
    final operation = ++_operation;
    _challenge = null;
    final current = state;
    final capability = current is AuthAuthenticated
        ? current.capability
        : await _access.currentNetworkCapability();
    final projection = await _projectionFor(capability);
    final capturedEpoch = (await _access.workspaces.deviceState()).networkEpoch;
    final revoked = capability == null
        ? null
        : await _access.revokeCurrentSession(
            capability,
            clearInstallationKey: true,
          );
    if (capability == null &&
        await _access.revokeTransition(capturedEpoch) == null) {
      return;
    }
    if (revoked == null && capability != null) return;
    try {
      await ref
          .read(sessionRuntimeCoordinatorProvider)
          .invalidate(
            captureActiveIdentity: false,
            identity: capability == null
                ? null
                : (capability.ownerId, capability.generation),
            projectionIdentity: projection,
          );
    } catch (_) {
      // Best effort: sign-out continues even if projection teardown fails.
    }
    if (operation == _operation) {
      try {
        await ref.read(sharedPreferencesProvider).remove(_currentUserIdKey);
      } catch (_) {
        // Best effort: a stale preference is cleared on the next sign-in.
      }
      state = const AuthUnauthenticated();
    }
    ReadCredentialBundle? prior;
    String? apiKey;
    if (revoked != null && capability != null) {
      try {
        prior = await _credentials.readRevoked(capability, revoked);
      } catch (_) {
        // Best effort: a missing revoked credential just skips cleanup.
      }
      try {
        apiKey = await ref
            .read(installationKeyRepositoryProvider)
            .readRevoked(capability, revoked);
      } catch (_) {
        // Best effort: a missing revoked installation key just skips cleanup.
      }
    }
    if (revoked?.credentialId != null) {
      await _credentials.discardUnreferenced(revoked!.credentialId!);
    }
    if (revoked?.installationKeyId != null) {
      await ref
          .read(installationKeyRepositoryProvider)
          .discardUnreferenced(revoked!.installationKeyId!);
    }
    if (prior != null && capability != null) {
      // Revocation is already durable. A bounded private transport can revoke
      // only the captured old refresh token; it never reads a newer session.
      await ref.read(sessionRemoteRevocationProvider)(prior.bundle, apiKey);
    }
  }
}

final authNotifierProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
