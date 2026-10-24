import 'package:dio/dio.dart';

import '../auth/credential_refresh_coordinator.dart';
import '../auth/scoped_token_service.dart';
import 'scoped_access_error.dart';
import '../utils/safe_diagnostics.dart';

class ScopedAuthInterceptor extends Interceptor {
  ScopedAuthInterceptor({
    required this.dio,
    required this.tokens,
    required this.baseUrl,
    required this.onAuthFailure,
    this.refresh,
    this.onAccountDeleted,
  });
  final Dio dio;
  final ScopedTokenService tokens;
  final String baseUrl;
  final void Function() onAuthFailure;
  final Future<CredentialRefreshCoordinator> Function()? refresh;

  /// Called once when the server answers that the account was deleted. Left
  /// out for background work, which just fails and lets the app handle it.
  final void Function()? onAccountDeleted;
  static const _slotExtra = 'simpastilCredentialSlot';
  static const _retriedExtra = 'simpastilProtectedRetried';
  static const accessUnavailableMessage = scopedAccessUnavailableMessage;
  static const _anonymousRoutes = {
    '/health',
    '/auth/login',
    '/auth/register',
    '/auth/2fa/challenge',
    '/auth/verify-key',
    '/auth/forgot-password',
    '/auth/reset-password',
  };

  bool _allowedUri(Uri uri) {
    final base = Uri.parse(baseUrl);
    final root = base.normalizePath().path.replaceFirst(RegExp(r'/+$'), '');
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.host != base.host ||
        uri.port != base.port) {
      return false;
    }
    if (uri.pathSegments.any(
      (part) =>
          part == '..' ||
          part == '.' ||
          part.contains('/') ||
          part.contains('\\'),
    )) {
      return false;
    }
    final path = uri.normalizePath().path;
    return path == root || path.startsWith('$root/');
  }

  String _route(RequestOptions options) {
    final root = Uri.parse(baseUrl).path.replaceFirst(RegExp(r'/+$'), '');
    return options.uri.path.substring(root.length);
  }

  String? _refreshRefusalReason(CredentialRefreshOutcome outcome) =>
      switch (outcome) {
        CredentialRefreshOutcome.ready => null,
        CredentialRefreshOutcome.stale => 'credential_refresh_stale',
        CredentialRefreshOutcome.busy => 'credential_refresh_busy',
        CredentialRefreshOutcome.uncertain => 'credential_refresh_uncertain',
        CredentialRefreshOutcome.rejected => 'credential_refresh_rejected',
        CredentialRefreshOutcome.installationRequired =>
          'credential_refresh_installation_required',
        CredentialRefreshOutcome.accountDeleted =>
          'credential_refresh_account_deleted',
      };

  DioException _stale(RequestOptions options, String reason) {
    SafeDiagnostics.logConnectionAccessRefusal(
      path: options.path,
      reason: reason,
    );
    return DioException(
      requestOptions: options,
      type: DioExceptionType.cancel,
      message: accessUnavailableMessage,
    );
  }

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      if (!_allowedUri(options.uri)) {
        throw _stale(options, 'endpoint_not_allowed');
      }
      final route = _route(options);
      if (route == '/capabilities') {
        // The server exposes only public, non-user-specific contract metadata
        // here. Keep origin/path validation, but don't require a live account
        // scope or attach credentials just to discover server capabilities.
        options.followRedirects = false;
        options.headers.remove('Authorization');
        options.headers.remove('X-Api-Key');
        handler.next(options);
        return;
      }
      final scopeRefusal = await tokens.scopeRefusalReason();
      if (scopeRefusal != null) throw _stale(options, scopeRefusal);
      if (tokens.capability == null && !_anonymousRoutes.contains(route)) {
        throw _stale(options, 'connection_session_missing');
      }
      options.followRedirects = false;
      options.headers.remove('Authorization');
      if (tokens.capability != null) {
        var current = await tokens.readBundle();
        if (current == null) {
          throw _stale(options, 'credential_bundle_missing');
        }
        if (current.bundle.expiresAtMillis <=
            DateTime.now()
                .add(const Duration(seconds: 30))
                .millisecondsSinceEpoch) {
          final renew = refresh;
          if (renew == null) {
            throw _stale(options, 'credential_refresh_unavailable');
          }
          final outcome = await (await renew()).refresh(tokens.capability!);
          if (outcome == CredentialRefreshOutcome.rejected) {
            onAuthFailure();
          }
          if (outcome == CredentialRefreshOutcome.accountDeleted) {
            onAccountDeleted?.call();
          }
          final refusal = _refreshRefusalReason(outcome);
          if (refusal != null) throw _stale(options, refusal);
          current = await tokens.readBundle();
          if (current == null) {
            throw _stale(options, 'credential_bundle_missing');
          }
        }
        options.headers['Authorization'] =
            'Bearer ${current.bundle.accessToken}';
        options.extra[_slotExtra] = current.credentialId;
      }
      final key = await tokens.getApiKey();
      if (route != '/auth/verify-key') options.headers.remove('X-Api-Key');
      if (key != null && !options.headers.containsKey('X-Api-Key')) {
        options.headers['X-Api-Key'] = key;
      }
      final currentRefusal = await tokens.scopeRefusalReason();
      if (currentRefusal != null) {
        throw _stale(options, 'scope_changed_during_request');
      }
      handler.next(options);
    } catch (error) {
      if (error is DioException &&
          error.type == DioExceptionType.cancel &&
          error.message == accessUnavailableMessage) {
        handler.reject(error);
      } else {
        handler.reject(_stale(options, 'access_check_failed'));
      }
    }
  }

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    try {
      final allowedUri = _allowedUri(response.requestOptions.uri);
      final isPublicCapabilities =
          allowedUri && _route(response.requestOptions) == '/capabilities';
      if (!allowedUri || (!isPublicCapabilities && !await tokens.isCurrent())) {
        handler.reject(
          _stale(
            response.requestOptions,
            allowedUri
                ? 'scope_changed_during_request'
                : 'endpoint_not_allowed',
          ),
        );
      } else {
        handler.next(response);
      }
    } catch (_) {
      handler.reject(_stale(response.requestOptions, 'access_check_failed'));
    }
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final renew = refresh;
    try {
      final body = err.response?.data;
      if (err.response?.statusCode == 401 &&
          body is Map &&
          body['code'] == 'ACCOUNT_DELETED' &&
          tokens.capability != null &&
          await tokens.isCurrent()) {
        // The api-key guard already said it; a refresh would only repeat it.
        onAccountDeleted?.call();
        handler.next(err);
        return;
      }
      if (err.response?.statusCode == 401 &&
          options.extra[_retriedExtra] != true &&
          tokens.capability != null &&
          renew != null &&
          await tokens.isCurrent()) {
        final slot = options.extra[_slotExtra];
        if (slot is! String) {
          handler.next(err);
          return;
        }
        final outcome = await (await renew()).refresh(
          tokens.capability!,
          failedCredentialId: slot,
        );
        if (outcome == CredentialRefreshOutcome.rejected) onAuthFailure();
        if (outcome == CredentialRefreshOutcome.accountDeleted) {
          onAccountDeleted?.call();
        }
        final refusal = _refreshRefusalReason(outcome);
        if (refusal != null) {
          SafeDiagnostics.logConnectionAccessRefusal(
            path: options.path,
            reason: refusal,
          );
        }
        if (outcome == CredentialRefreshOutcome.ready &&
            await tokens.isCurrent()) {
          final response = await dio.fetch<dynamic>(
            options.copyWith(extra: {...options.extra, _retriedExtra: true}),
          );
          if (!await tokens.isCurrent()) {
            throw _stale(options, 'scope_changed_during_request');
          }
          handler.resolve(response);
          return;
        }
      }
    } catch (_) {
      /* Preserve the original failure; never fall back to global credentials. */
    }
    handler.next(err);
  }
}
