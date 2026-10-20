import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../server/server_config_notifier.dart';
import '../workspace/workspace_context.dart';
import '../workspace/workspace_provider.dart';
import 'installation_key_repository.dart';
import 'protected_credentials_repository.dart';
import 'token_service.dart';

/// A retained service has one fixed account capability. It can never obtain
/// another account's tokens, even on the same installation address.
class ScopedTokenService extends TokenService {
  ScopedTokenService({
    required this.credentials,
    required this.keys,
    required this.endpoint,
    required this.capability,
    required this.installation,
  });
  final ProtectedCredentialsRepository credentials;
  final InstallationKeyRepository keys;
  final String? endpoint;
  final NetworkCapability? capability;
  final Future<InstallationCapability?> installation;

  Future<ReadCredentialBundle?> readBundle() async {
    final captured = capability;
    if (captured == null || captured.endpoint != endpoint) return null;
    return credentials.readFor(captured);
  }

  Future<bool> isCurrent() async {
    return await scopeRefusalReason() == null;
  }

  /// Returns a bounded reason when this client's frozen scope is no longer
  /// usable. The reason contains no account, endpoint, or credential data.
  Future<String?> scopeRefusalReason() async {
    final captured = capability;
    if (captured != null &&
        !await credentials.access.networkIsCurrent(captured)) {
      return 'network_scope_stale';
    }
    final scope = await installation;
    if (scope == null) return 'installation_scope_missing';
    if (scope.endpoint != endpoint) return 'installation_endpoint_mismatch';
    if (!await credentials.access.installationIsCurrent(scope)) {
      return 'installation_scope_stale';
    }
    return null;
  }

  @override
  Future<String?> getAccessToken() async =>
      (await readBundle())?.bundle.accessToken;
  @override
  Future<String?> getRefreshToken() async =>
      (await readBundle())?.bundle.refreshToken;
  @override
  Future<String?> getUserId() async => (await readBundle())?.bundle.ownerId;
  @override
  Future<bool> hasSession() async => await readBundle() != null;
  @override
  Future<bool> isAuthenticated() async =>
      ((await readBundle())?.bundle.expiresAtMillis ?? 0) >
      DateTime.now().add(const Duration(seconds: 30)).millisecondsSinceEpoch;
  @override
  Future<String?> getApiKey() async {
    if (!await isCurrent()) return null;
    final scope = await installation;
    return scope == null ? null : keys.readFor(scope);
  }

  @override
  Future<void> saveApiKey(String key) async {
    final scope = await installation;
    if (scope == null || !await isCurrent()) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.staleNetworkTransition,
      );
    }
    await keys.saveFor(scope, key);
  }

  @override
  Future<void> clearApiKey() async {
    final scope = await installation;
    if (scope != null && await isCurrent()) await keys.clearFor(scope);
  }

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    required int expiresIn,
  }) async {
    throw const WorkspaceAccessFailure(WorkspaceAccessFailureCode.unavailable);
  }

  @override
  Future<void> clearSessionTokens() async {
    final captured = capability;
    if (captured == null) return;
    final revoked = await credentials.access.revokeCurrentSession(captured);
    if (revoked?.credentialId != null) {
      await credentials.discardUnreferenced(revoked!.credentialId!);
    }
  }

  @override
  Future<void> clearTokens() async {
    await clearApiKey();
    await clearSessionTokens();
  }
}

ScopedTokenService createScopedTokenService(Ref ref) {
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final row = ref.watch(connectionDeviceStateProvider).value;
  final url = ref.watch(serverConfigProvider);
  final endpoint = url == null ? null : canonicalServerEndpoint(url);
  final capability = row == null
      ? ref.watch(networkCapabilityProvider).value
      : networkCapabilityFromState(row);
  final InstallationCapability? scope =
      row != null && row.configuredEndpoint == endpoint && endpoint != null
      ? InstallationCapability(
          endpoint: endpoint,
          epoch: row.installationEpoch,
          networkEpoch: row.networkEpoch,
        )
      : null;
  return ScopedTokenService(
    credentials: ref.watch(protectedCredentialsRepositoryProvider),
    keys: ref.watch(installationKeyRepositoryProvider),
    endpoint: endpoint,
    capability: capability,
    installation: scope != null
        ? Future.value(scope)
        : endpoint == null
        ? Future.value(null)
        : access.captureInstallation(endpoint),
  );
}

final scopedTokenServiceProvider = Provider<ScopedTokenService>(
  createScopedTokenService,
);
