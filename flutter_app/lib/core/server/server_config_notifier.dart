import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/server_pin_providers.dart';
import '../network/server_pin_store.dart';
import '../network/http_clients.dart';
import '../network/pinned_connection.dart';
import '../storage/shared_preferences_provider.dart';
import '../workspace/workspace_context.dart';
import '../workspace/workspace_provider.dart';
import '../session/session_runtime_coordinator.dart';
import '../projections/projection_identity.dart';

// ── Health check ──────────────────────────────────────────────────────────────

/// Default health check: GETs `<url>/api/v1/health`, returns true on HTTP 200.
///
/// Uses a temporary Dio with a 10-second timeout, discarded after the check
/// so a failed check has no side-effects on the live [apiClientProvider].
Future<bool> _performHealthCheck(String url, ServerPinStore pins) async {
  final dio = createServerDio(
    pins: pins,
    options: BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      followRedirects: false,
    ),
  );
  try {
    final canonical = canonicalServerEndpoint(url);
    final response = await dio.get<void>('$canonical/api/v1/health');
    return response.statusCode == 200;
  } on Object {
    return false;
  } finally {
    dio.close(force: true);
  }
}

/// Injectable health check function — override in tests to avoid real HTTP.
final serverHealthCheckProvider = Provider<Future<bool> Function(String)>((
  ref,
) {
  final pins = ref.watch(serverPinStoreProvider);
  return (url) => _performHealthCheck(url, pins);
});

// ── ServerConfigNotifier ──────────────────────────────────────────────────────

const _kServerUrlKey = 'server_url';

class ServerConfigNotifier extends Notifier<String?> {
  @override
  String? build() {
    // Synchronous: sharedPreferencesProvider holds a pre-loaded instance.
    final prefs = ref.read(sharedPreferencesProvider);
    final value = prefs.getString(_kServerUrlKey);
    if (value == null) return null;
    try {
      return canonicalServerEndpoint(value);
    } on ArgumentError {
      return null;
    }
  }

  /// Validates the URL scheme and persists it.
  ///
  /// Throws [ArgumentError] if [url] does not start with `https://`.
  Future<void> setUrl(String url) async {
    final canonical = canonicalServerEndpoint(url);
    final access = ref.read(workspaceAccessRepositoryProvider);
    await access.workspaces.ensureLocal();
    final prior = await access.workspaces.deviceState();
    final retiredContext = prior.networkOwnerId == null
        ? null
        : await access.contextForOwner(prior.networkOwnerId!);
    final epoch = await access.configureEndpoint(canonical);
    if (prior.configuredEndpoint != canonical) {
      try {
        await ref
            .read(sessionRuntimeCoordinatorProvider)
            .invalidate(
              captureActiveIdentity: false,
              identity:
                  prior.networkOwnerId != null &&
                      prior.networkGeneration != null
                  ? (prior.networkOwnerId!, prior.networkGeneration!)
                  : null,
              projectionIdentity: retiredContext == null
                  ? null
                  : ProjectionIdentity.fromContext(retiredContext),
            );
      } catch (_) {
        // Best effort: the server switch itself must not fail on projection cleanup.
      }
    }
    final current = await access.workspaces.deviceState();
    if (current.networkEpoch != epoch ||
        current.configuredEndpoint != canonical) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.staleNetworkTransition,
      );
    }
    final prefs = ref.read(sharedPreferencesProvider);
    if (!await prefs.setString(_kServerUrlKey, canonical)) {
      throw StateError('Server preference could not be saved');
    }
    final after = await access.workspaces.deviceState();
    if (after.networkEpoch != epoch || after.configuredEndpoint != canonical) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.staleNetworkTransition,
      );
    }
    state = canonical;
    // Removing a server (switching to another) forgets its pin. Signing out
    // keeps it: the same server must not silently become unpinned.
    final previous = prior.configuredEndpoint;
    if (previous != null && previous != canonical) {
      try {
        final old = ServerAuthority.parse(previous);
        if (old != ServerAuthority.parse(canonical)) {
          await ref.read(serverPinStoreProvider).remove(old);
          PinningConnector.closeConnectionsTo(old);
        }
      } on Object {
        // A stale pin for a server that is no longer configured is harmless.
      }
    }
  }

  /// Stops using a server that was set up but never signed in to. Returns
  /// false, changing nothing, once a session is signed in (Log out ends
  /// that). The server's pin goes with it, as when switching servers.
  Future<bool> forget() async {
    final current = state;
    if (current == null) return true;
    final access = ref.read(workspaceAccessRepositoryProvider);
    if (!await access.forgetEndpoint(current)) return false;
    final prefs = ref.read(sharedPreferencesProvider);
    if (!await prefs.remove(_kServerUrlKey)) {
      throw StateError('Server preference could not be removed');
    }
    state = null;
    try {
      final old = ServerAuthority.parse(current);
      await ref.read(serverPinStoreProvider).remove(old);
      PinningConnector.closeConnectionsTo(old);
    } on Object {
      // A stale pin for a server that is no longer configured is harmless.
    }
    return true;
  }
}

final serverConfigProvider = NotifierProvider<ServerConfigNotifier, String?>(
  ServerConfigNotifier.new,
);
