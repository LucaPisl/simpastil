import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/http_clients.dart';
import '../network/server_pin_store.dart';
import '../workspace/workspace_context.dart';
import '../auth/auth_event_provider.dart';
import '../auth/token_service.dart';
import '../auth/scoped_token_service.dart';
import '../auth/credential_refresh_coordinator.dart';
import '../auth/credential_refresh_factory.dart';
import 'scoped_auth_interceptor.dart';
import '../server/server_config_notifier.dart';
import '../network/server_pin_providers.dart';
import '../session/session_generation_repository.dart';
import '../utils/app_logger.dart';
import '../utils/jwt_utils.dart';
import '../utils/safe_diagnostics.dart';

// ── ApiClient ────────────────────────────────────────────────────────────────

const int simpastilClientBuild = 8;

/// The app's primary HTTP client.
///
/// Manages Dio configuration, auth interceptor, and debug-only logging.
/// Obtain via [apiClientProvider].
class ApiClient {
  ApiClient({
    required String baseUrl,
    required TokenService tokenService,
    required void Function() onAuthFailure,
    void Function()? onAccountDeleted,
    Future<SessionIdentity?> Function()? readSessionIdentity,
    Future<CredentialRefreshCoordinator> Function()? scopedRefresh,
    ServerPinStore? pins,
  }) : scopedTokens = tokenService is ScopedTokenService ? tokenService : null,
       networkCapability = tokenService is ScopedTokenService
           ? tokenService.capability
           : null {
    _dio = createServerDio(
      pins: pins,
      options: BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        followRedirects: false,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'X-Simpastil-Client-Build': '$simpastilClientBuild',
        },
      ),
    );
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.data == null) {
            options.headers.remove('Content-Type');
            options.contentType = null;
          }
          handler.next(options);
        },
      ),
    );
    if (tokenService is ScopedTokenService) {
      _dio.interceptors.add(
        ScopedAuthInterceptor(
          dio: _dio,
          tokens: tokenService,
          baseUrl: baseUrl,
          onAuthFailure: onAuthFailure,
          refresh: scopedRefresh,
          onAccountDeleted: onAccountDeleted,
        ),
      );
    } else {
      _dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            final apiKey = await tokenService.getApiKey();
            if (apiKey != null) {
              options.headers['X-Api-Key'] = apiKey;
            }
            handler.next(options);
          },
        ),
      );
      _dio.interceptors.add(
        AuthInterceptor(
          baseUrl: baseUrl,
          tokenService: tokenService,
          onAuthFailure: onAuthFailure,
          readSessionIdentity: readSessionIdentity,
          pins: pins,
        ),
      );
    }
    if (kDebugMode) {
      _dio.interceptors.add(_buildLoggingInterceptor());
    }
  }

  final ScopedTokenService? scopedTokens;
  final NetworkCapability? networkCapability;
  late final Dio _dio;

  Dio get dio => _dio;

  /// Verify and save using the same client's frozen installation capability.
  /// The returned scope is the newly published key epoch, for UI feedback only.
  Future<VerifiedInstallationKey> verifyAndSaveInstallationKey(
    String key,
  ) async {
    final tokens = scopedTokens;
    final scope = await tokens?.installation;
    if (tokens == null || scope == null || !await tokens.isCurrent()) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.staleNetworkTransition,
      );
    }
    final response = await dio.get<dynamic>(
      '/auth/verify-key',
      options: Options(headers: {'X-Api-Key': key}, followRedirects: false),
    );
    if (!await tokens.isCurrent()) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.staleNetworkTransition,
      );
    }
    final data = response.data;
    final status = data is Map<String, dynamic> ? data['status'] : null;
    if (status == 'revoked') throw const InstallationKeyRevoked();
    if (response.statusCode != 200 ||
        !const {'owned', 'unclaimed'}.contains(status)) {
      throw const FormatException('Unrecognized installation verification');
    }
    final published = await tokens.keys.saveFor(
      scope,
      key,
      verifiedStatus: status as String,
    );
    if (!await tokens.credentials.access.installationIsCurrent(published) ||
        (tokens.capability != null &&
            !await tokens.credentials.access.networkIsCurrent(
              tokens.capability!,
            ))) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.staleNetworkTransition,
      );
    }
    return VerifiedInstallationKey(status: status, installation: published);
  }

  // ── Logging interceptor (debug builds only) ───────────────────────────────

  Interceptor _buildLoggingInterceptor() {
    return InterceptorsWrapper(
      onRequest: (options, handler) {
        options.extra['safeDiagnosticsStartedAtMs'] =
            DateTime.now().millisecondsSinceEpoch;
        SafeDiagnostics.logHttpEvent(
          SafeDiagnostics.httpEvent(
            event: 'http_started',
            path: options.path,
            statusCode: null,
            duration: Duration.zero,
            retryCount: _retryCount(options),
            clientBuild: _clientBuild(options),
          ),
        );
        handler.next(options);
      },
      onResponse: (response, handler) {
        SafeDiagnostics.logHttpEvent(
          SafeDiagnostics.httpEvent(
            event: 'http_succeeded',
            path: response.requestOptions.path,
            statusCode: response.statusCode,
            duration: _elapsed(response.requestOptions),
            retryCount: _retryCount(response.requestOptions),
            clientBuild: _clientBuild(response.requestOptions),
          ),
        );
        handler.next(response);
      },
      onError: (err, handler) {
        SafeDiagnostics.logHttpEvent(
          SafeDiagnostics.httpEvent(
            event: 'http_failed',
            path: err.requestOptions.path,
            statusCode: err.response?.statusCode,
            duration: _elapsed(err.requestOptions),
            correlationId: SafeDiagnostics.correlationIdFrom(err),
            retryCount: _retryCount(err.requestOptions),
            clientBuild: _clientBuild(err.requestOptions),
          ),
        );
        handler.next(err);
      },
    );
  }

  Duration _elapsed(RequestOptions options) {
    final startedAt = options.extra['safeDiagnosticsStartedAtMs'];
    if (startedAt is! int) return Duration.zero;
    final elapsed = DateTime.now().millisecondsSinceEpoch - startedAt;
    return Duration(milliseconds: elapsed.clamp(0, 60000));
  }

  int? _retryCount(RequestOptions options) {
    final value = options.extra['retryCount'];
    return value is int ? value : null;
  }

  int? _clientBuild(RequestOptions options) {
    final value = options.headers['X-Simpastil-Client-Build'];
    return value is int ? value : int.tryParse('$value');
  }

  /// Strips Authorization header from logs to prevent accidental token leakage.
  Map<String, dynamic> _sanitizeHeaders(Map<String, dynamic> headers) =>
      Map.of(headers)
        ..remove('Authorization')
        ..remove('X-Api-Key');

  @visibleForTesting
  Map<String, dynamic> sanitizeHeadersForTest(Map<String, dynamic> h) =>
      _sanitizeHeaders(h);
}

class VerifiedInstallationKey {
  const VerifiedInstallationKey({
    required this.status,
    required this.installation,
  });
  final String status;
  final InstallationCapability installation;
}

class InstallationKeyRevoked implements Exception {
  const InstallationKeyRevoked();
}

// ── Auth interceptor ──────────────────────────────────────────────────────────

/// Outcome of an attempt to refresh the access token.
///
/// Used by [AuthInterceptor] to distinguish a genuine server rejection
/// (hard failure → logout) from a network error (soft failure → pass through).
enum _RefreshOutcome {
  /// New tokens saved — original request can be retried.
  success,

  /// Refresh endpoint returned any HTTP response — server was reached and rejected the token.
  hardFailure,

  /// Network or timeout error — server was not reached; do not log the user out.
  softFailure,
}

typedef _RefreshResult = ({_RefreshOutcome outcome, SessionIdentity? session});

/// Attaches Bearer tokens to every request and handles 401 with a single
/// refresh attempt before logging the user out.
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required String baseUrl,
    required TokenService tokenService,
    required void Function() onAuthFailure,
    Future<SessionIdentity?> Function()? readSessionIdentity,
    ServerPinStore? pins,
  }) : _tokenService = tokenService,
       _onAuthFailure = onAuthFailure,
       _readSessionIdentity = readSessionIdentity {
    // Separate Dio for the refresh call so it never enters this interceptor,
    // preventing infinite retry loops.
    _refreshDio = createServerDio(
      pins: pins,
      options: BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
  }

  final TokenService _tokenService;
  final void Function() _onAuthFailure;
  final Future<SessionIdentity?> Function()? _readSessionIdentity;
  late final Dio _refreshDio;

  static const _sessionIdentityExtraKey = 'simpastilSessionIdentity';

  // Guard against concurrent refresh calls (e.g. parallel 401 responses).
  Completer<_RefreshResult>? _refreshCompleter;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _tokenService.getAccessToken();
    if (token != null) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    try {
      final identity = await _readSessionIdentity?.call();
      if (identity != null) {
        options.extra[_sessionIdentityExtraKey] = identity;
      }
    } catch (_) {
      // Identity tagging is a safety guard; the request can still be sent.
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final isUnauthorized = err.response?.statusCode == 401;
    final path = err.requestOptions.path;
    final isAuthRoute =
        path.endsWith('/auth/login') ||
        path.endsWith('/auth/register') ||
        path.endsWith('/auth/refresh');
    final rawIdentity = err.requestOptions.extra[_sessionIdentityExtraKey];
    final requestIdentity = rawIdentity is SessionIdentity ? rawIdentity : null;

    if (isUnauthorized && !isAuthRoute) {
      try {
        final refreshResult = await _refreshOrAwait(
          expectedSession: requestIdentity,
        );
        final outcome = refreshResult.outcome;

        if (outcome == _RefreshOutcome.success) {
          if (refreshResult.session != requestIdentity ||
              !await _isSessionCurrent(requestIdentity)) {
            handler.next(err);
            return;
          }
          try {
            final newToken = await _tokenService.getAccessToken();
            final response = await _refreshDio.request<dynamic>(
              err.requestOptions.path,
              data: err.requestOptions.data,
              queryParameters: err.requestOptions.queryParameters,
              options: Options(
                method: err.requestOptions.method,
                headers: {
                  ...err.requestOptions.headers,
                  'Authorization': 'Bearer $newToken',
                },
                responseType: err.requestOptions.responseType,
                contentType: err.requestOptions.contentType,
              ),
            );
            handler.resolve(response);
            return;
          } on DioException catch (retryErr) {
            handler.next(retryErr);
            return;
          }
        }

        if (outcome == _RefreshOutcome.hardFailure) {
          if (refreshResult.session != requestIdentity ||
              !await _isSessionCurrent(requestIdentity)) {
            handler.next(err);
            return;
          }
          // Refresh token is genuinely invalid — clear session and redirect to login.
          // clearSessionTokens() intentionally preserves the API key so the user
          // only needs to re-enter their email/password, not redo full setup.
          AppLogger.error(
            'AuthInterceptor',
            'Refresh token rejected — clearing session tokens and logging out',
          );
          await _tokenService.clearSessionTokens();
          _onAuthFailure();
        }
        // softFailure: server was not reachable — propagate original error,
        // do not log the user out.
      } on Object {
        AppLogger.error('AuthInterceptor', 'Retry after refresh failed');
      }
    }

    handler.next(err);
  }

  /// Calls POST /auth/refresh with the stored refresh token.
  ///
  /// Returns [_RefreshOutcome.success] if new tokens were saved.
  /// Returns [_RefreshOutcome.hardFailure] if the server rejected the token (401/403).
  /// Returns [_RefreshOutcome.softFailure] on network/timeout errors.
  Future<_RefreshOutcome> _attemptTokenRefresh({
    required SessionIdentity? expectedSession,
  }) async {
    final storedRefreshToken = await _tokenService.getRefreshToken();
    if (storedRefreshToken == null || storedRefreshToken.trim().isEmpty) {
      return _RefreshOutcome.softFailure;
    }
    if (!await _isSessionCurrent(expectedSession)) {
      return _RefreshOutcome.softFailure;
    }

    try {
      final apiKey = await _tokenService.getApiKey();
      final response = await _refreshDio.post<Map<String, dynamic>>(
        '/auth/refresh',
        data: {'refreshToken': storedRefreshToken},
        options: Options(headers: {'X-Api-Key': ?apiKey}),
      );

      final data = response.data;
      if (data == null) return _RefreshOutcome.softFailure;
      final accessTokenRaw = data['accessToken'];
      final refreshTokenRaw = data['refreshToken'];
      if (accessTokenRaw is! String || refreshTokenRaw is! String) {
        AppLogger.warning(
          'AuthInterceptor',
          'Unexpected refresh response shape',
        );
        return _RefreshOutcome.softFailure;
      }
      if (!await _isSessionCurrent(expectedSession)) {
        return _RefreshOutcome.softFailure;
      }
      final expiresIn = JwtUtils.parseExpiresIn(accessTokenRaw);
      await _tokenService.saveTokens(
        accessToken: accessTokenRaw,
        refreshToken: refreshTokenRaw,
        expiresIn: expiresIn,
      );
      AppLogger.debug('AuthInterceptor', 'Token refresh succeeded.');
      return _RefreshOutcome.success;
    } on DioException catch (e) {
      if (e.response != null) {
        final status = e.response!.statusCode ?? 0;
        if (status == 401 || status == 403) {
          AppLogger.error(
            'AuthInterceptor',
            'Token refresh rejected by server ($status) — hard failure',
          );
          return _RefreshOutcome.hardFailure;
        }
        // 429, 5xx, and all other HTTP errors are soft failures — the token
        // may still be valid; do not log the user out.
        AppLogger.warning(
          'AuthInterceptor',
          'Token refresh failed ($status) — soft failure, not logging out',
        );
        return _RefreshOutcome.softFailure;
      }
      AppLogger.warning(
        'AuthInterceptor',
        'Token refresh network error — soft failure, not logging out',
      );
      return _RefreshOutcome.softFailure;
    }
  }

  Future<_RefreshResult> _refreshOrAwait({
    required SessionIdentity? expectedSession,
  }) async {
    final current = _refreshCompleter;
    if (current != null) {
      return current.future;
    }

    final completer = Completer<_RefreshResult>();
    _refreshCompleter = completer;
    try {
      final outcome = await _attemptTokenRefresh(
        expectedSession: expectedSession,
      );
      final result = (outcome: outcome, session: expectedSession);
      completer.complete(result);
      return result;
    } catch (e) {
      if (!completer.isCompleted) {
        completer.complete((
          outcome: _RefreshOutcome.softFailure,
          session: expectedSession,
        ));
      }
      return (outcome: _RefreshOutcome.softFailure, session: expectedSession);
    } finally {
      // Defer clearing until all awaiters of the completed future have been
      // scheduled, preventing a new refresh attempt from firing in the
      // microtask gap between complete() and the awaiters resuming.
      scheduleMicrotask(() => _refreshCompleter = null);
    }
  }

  Future<bool> _isSessionCurrent(SessionIdentity? expectedSession) async {
    final readCurrent = _readSessionIdentity;
    if (readCurrent == null) return true;
    if (expectedSession == null) return false;
    try {
      return await readCurrent() == expectedSession;
    } catch (_) {
      return false;
    }
  }
}

// ── Riverpod provider ─────────────────────────────────────────────────────────

/// Rebuilds whenever the server URL changes (e.g. user picks a different server).
///
/// On auth failure the interceptor writes [AuthEvent.sessionExpired] to
/// [authEventProvider]. [SimpastilApp] listens and navigates to login.
/// The networking layer never touches routing directly.
final apiClientProvider = Provider<ApiClient>((ref) {
  final url = ref.watch(serverConfigProvider);
  final tokenService = ref.watch(scopedTokenServiceProvider);
  final createGate = ref.watch(credentialRefreshGateProvider);
  final eventNotifier = ref.read(authEventProvider.notifier);
  final failureNotifier = ref.read(authFailureCapabilityProvider.notifier);
  // url is always non-null in foreground: the router redirect ensures
  // no authenticated screen is reached before a server URL is confirmed.
  // The '' fallback covers the WorkManager background path which has
  // its own early-return guard.
  return ApiClient(
    baseUrl: url != null ? '$url/api/v1' : '',
    tokenService: tokenService,
    pins: ref.watch(serverPinStoreProvider),
    onAuthFailure: () {
      failureNotifier.state = tokenService.capability;
      eventNotifier.state = AuthEvent.sessionExpired;
    },
    onAccountDeleted: () {
      failureNotifier.state = tokenService.capability;
      eventNotifier.state = AuthEvent.accountDeleted;
    },
    scopedRefresh: () async => createCredentialRefreshCoordinator(
      credentials: tokenService.credentials,
      keys: tokenService.keys,
      gate: await createGate(),
      endpoint: tokenService.endpoint!,
      capability: tokenService.capability,
      pins: ref.read(serverPinStoreProvider),
    ),
  );
});
