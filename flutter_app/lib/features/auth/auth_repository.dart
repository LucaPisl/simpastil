import '../../core/storage/portable_preference_writer.dart';
import '../../core/projections/projection_effects_gate.dart';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/api_client.dart';
import '../../core/network/server_pin_providers.dart';
import '../../core/network/pinned_connection.dart' show isCertificateRejection;
import '../../core/auth/token_service.dart';
import '../../core/auth/protected_credentials_repository.dart';
import '../../core/auth/scoped_token_service.dart';
import '../../core/auth/installation_key_repository.dart';
import '../../core/workspace/workspace_context.dart';
import '../../core/errors/app_error.dart';

// ── Login result types ────────────────────────────────────────────────────────

sealed class LoginResult {
  const LoginResult();
}

final class LoginSuccess extends LoginResult {
  final String userId;
  final String? credentialId;
  const LoginSuccess(this.userId, {this.credentialId});
}

final class LoginRequires2fa extends LoginResult {
  final String challengeToken;
  const LoginRequires2fa(this.challengeToken);
}

// ── 2FA setup result ─────────────────────────────────────────────────────────

class TotpSetupResult {
  final String secret;
  final String otpauthUri;
  const TotpSetupResult({required this.secret, required this.otpauthUri});
}

// ── Abstract interface (enables fake implementations in tests) ────────────────

abstract class AuthRepository {
  Future<Result<LoginResult>> login(String email, String password);
  Future<Result<void>> register(String email, String password);
  Future<Result<void>> logout(String refreshToken);
  Future<Result<void>> changePassword(
    String currentPassword,
    String newPassword,
  );
  Future<Result<void>> setDeviceName(String deviceName);
  Future<Result<LoginSuccess>> challenge2fa(String challengeToken, String code);
  Future<Result<TotpSetupResult>> setup2fa();
  Future<Result<List<String>>> enable2fa(String code);
  Future<Result<void>> disable2fa(String code);
  Future<Result<List<String>>> regenerateBackupCodes(String code);
}

// ── Concrete implementation ───────────────────────────────────────────────────

class AuthRepositoryImpl implements AuthRepository {
  const AuthRepositoryImpl(
    this._client,
    this._tokenService, {
    this.credentials,
    this.installation,
    this.preferenceGate,
  });

  final ApiClient _client;
  final TokenService _tokenService;
  final ProtectedCredentialsRepository? credentials;
  final InstallationCapability? installation;
  final ProjectionEffectsGate? preferenceGate;

  // ── login ──────────────────────────────────────────────────────────────────

  /// Authenticates the user and persists tokens.
  ///
  /// Returns [Ok] with the user's UUID on success.
  /// Server response shape: `{ "accessToken": "...", "refreshToken": "..." }`
  @override
  Future<Result<LoginResult>> login(String email, String password) async {
    try {
      final response = await _client.dio.post<Map<String, dynamic>>(
        '/auth/login',
        data: {'email': email, 'password': password},
      );

      final data = response.data!;

      if (data['requires2fa'] == true) {
        final challengeToken = data['challengeToken'] as String?;
        if (challengeToken == null) {
          return const Err(UnknownError('Missing challengeToken'));
        }
        return Ok(LoginRequires2fa(challengeToken));
      }

      final success = await _saveTokensFromResponse(data);
      if (success == null) {
        return const Err(UnknownError('Unexpected login response shape'));
      }

      return Ok(success);
    } on DioException catch (e) {
      return Err(mapDioError(e));
    } catch (e) {
      return Err(UnknownError(e));
    }
  }

  @override
  Future<Result<LoginSuccess>> challenge2fa(
    String challengeToken,
    String code,
  ) async {
    try {
      final response = await _client.dio.post<Map<String, dynamic>>(
        '/auth/2fa/challenge',
        data: {'challengeToken': challengeToken, 'code': code},
      );

      final success = await _saveTokensFromResponse(response.data!);
      if (success == null) {
        return const Err(UnknownError('Unexpected challenge response shape'));
      }
      return Ok(success);
    } on DioException catch (e) {
      return Err(mapDioError(e));
    } catch (e) {
      return Err(UnknownError(e));
    }
  }

  @override
  Future<Result<TotpSetupResult>> setup2fa() async {
    try {
      final response = await _client.dio.post<Map<String, dynamic>>(
        '/auth/2fa/setup',
      );
      final data = response.data!;
      return Ok(
        TotpSetupResult(
          secret: data['secret'] as String,
          otpauthUri: data['otpauthUri'] as String,
        ),
      );
    } on DioException catch (e) {
      return Err(mapDioError(e));
    } catch (e) {
      return Err(UnknownError(e));
    }
  }

  @override
  Future<Result<List<String>>> enable2fa(String code) async {
    try {
      final response = await _client.dio.post<Map<String, dynamic>>(
        '/auth/2fa/enable',
        data: {'code': code},
      );
      final codes = (response.data!['backupCodes'] as List).cast<String>();
      return Ok(codes);
    } on DioException catch (e) {
      return Err(mapDioError(e));
    } catch (e) {
      return Err(UnknownError(e));
    }
  }

  @override
  Future<Result<void>> disable2fa(String code) async {
    try {
      await _client.dio.post<Map<String, dynamic>>(
        '/auth/2fa/disable',
        data: {'code': code},
      );
      return const Ok(null);
    } on DioException catch (e) {
      return Err(mapDioError(e));
    } catch (e) {
      return Err(UnknownError(e));
    }
  }

  @override
  Future<Result<List<String>>> regenerateBackupCodes(String code) async {
    try {
      final response = await _client.dio.post<Map<String, dynamic>>(
        '/auth/2fa/backup-codes',
        data: {'code': code},
      );
      final codes = (response.data!['backupCodes'] as List).cast<String>();
      return Ok(codes);
    } on DioException catch (e) {
      return Err(mapDioError(e));
    } catch (e) {
      return Err(UnknownError(e));
    }
  }

  // ── register ───────────────────────────────────────────────────────────────

  /// Registers a new account. Caller is responsible for calling [login]
  /// afterwards (auto-login pattern).
  ///
  /// Server response: 201 `{ "userId": "..." }` — not used by the client.
  @override
  Future<Result<void>> register(String email, String password) async {
    try {
      await _client.dio.post<Map<String, dynamic>>(
        '/auth/register',
        data: {'email': email, 'password': password},
      );
      return const Ok(null);
    } on DioException catch (e) {
      return Err(mapDioError(e));
    } catch (e) {
      return Err(UnknownError(e));
    }
  }

  // ── changePassword ─────────────────────────────────────────────────────────

  /// Changes the authenticated user's password.
  ///
  /// Returns [Ok] on success. Returns [Err] with a [ServerError] carrying
  /// the server's error message on 400, or other typed errors for network
  /// and unexpected failures.
  @override
  Future<Result<void>> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    try {
      await _client.dio.post<void>(
        '/auth/change-password',
        data: {'currentPassword': currentPassword, 'newPassword': newPassword},
      );
      return const Ok(null);
    } on DioException catch (e) {
      return Err(mapDioError(e));
    } catch (e) {
      return Err(UnknownError(e));
    }
  }

  /// Updates the server-side session label and mirrors it locally only after
  /// the server accepts the exact device-name request contract.
  @override
  Future<Result<void>> setDeviceName(String deviceName) async {
    final name = deviceName.trim();
    if (name.isEmpty || name.length > 100) {
      return const Err(UnknownError('Invalid device name'));
    }
    try {
      final refreshToken = await _tokenService.getRefreshToken();
      if (refreshToken == null || refreshToken.isEmpty) {
        return const Err(UnauthorizedError());
      }
      await _client.dio.patch<void>(
        '/auth/device',
        data: {'refreshToken': refreshToken, 'deviceName': name},
      );
      final prefs = await SharedPreferences.getInstance();
      await PortablePreferenceWriter(
        prefs,
        gate: preferenceGate,
      ).write('simpastil_device_name', name);
      return const Ok(null);
    } on DioException catch (e) {
      return Err(mapDioError(e));
    } catch (e) {
      return Err(UnknownError(e));
    }
  }

  // ── logout ─────────────────────────────────────────────────────────────────

  /// Revokes the refresh token on the server (best-effort) and clears
  /// all locally stored tokens regardless of the server response.
  @override
  Future<Result<void>> logout(String refreshToken) async {
    try {
      await _client.dio.post<void>(
        '/auth/logout',
        data: {'refreshToken': refreshToken},
      );
    } on DioException catch (_) {
      // Best-effort — always clear tokens locally even if the request fails.
    } catch (_) {
      // Best-effort — absorb all errors, not just Dio ones.
    } finally {
      if (_tokenService is! ScopedTokenService) {
        await _tokenService.clearTokens();
      }
    }
    return const Ok(null);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<LoginSuccess?> _saveTokensFromResponse(
    Map<String, dynamic> data,
  ) async {
    final protected = credentials;
    final scope = installation;
    if (protected != null && scope != null) {
      if (!await protected.access.installationIsCurrent(scope)) return null;
      final bundle = CredentialBundle.fromResponse(data, scope.endpoint);
      final id = await protected.stage(bundle);
      if (!await protected.access.installationIsCurrent(scope)) {
        await protected.discardUnreferenced(id);
        return null;
      }
      return LoginSuccess(bundle.ownerId, credentialId: id);
    }
    if (_tokenService is ScopedTokenService) return null;
    final accessToken = data['accessToken'] as String?;
    final refreshToken = data['refreshToken'] as String?;
    if (accessToken == null || refreshToken == null) return null;

    final payload = _decodeJwtPayload(accessToken);
    final userId = payload?['sub'] as String?;
    if (userId == null) return null;

    final expRaw = payload?['exp'];
    final exp = expRaw is int
        ? expRaw
        : (expRaw is num ? expRaw.toInt() : null);
    if (exp == null) return null;
    final expiresIn = (exp - DateTime.now().millisecondsSinceEpoch ~/ 1000)
        .clamp(0, 86400)
        .toInt();

    await _tokenService.saveTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresIn: expiresIn,
    );

    return LoginSuccess(userId);
  }

  /// Decodes the Base64Url-encoded payload segment of a JWT.
  /// Returns null if the token is malformed.
  static Map<String, dynamic>? _decodeJwtPayload(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final normalized = base64Url.normalize(parts[1]);
      return jsonDecode(utf8.decode(base64Url.decode(normalized)))
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Maps a [DioException] to a typed [AppError].
  ///
  /// Parses the server's structured `code` field when available, falling back
  /// to HTTP status code mapping.
  @visibleForTesting
  static AppError mapDioError(DioException e) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    final serverCode = data is Map<String, dynamic>
        ? data['code'] as String?
        : null;
    final serverMessage = data is Map<String, dynamic>
        ? data['error'] as String?
        : null;

    if (status == 429) {
      final retryAfter = data is Map<String, dynamic>
          ? (data['retryAfter'] as num?)?.toInt()
          : null;
      return RateLimitError(retryAfter);
    }

    if (serverCode != null && status != null) {
      return ServerCodeError(status, serverCode, serverMessage);
    }

    if (status == 401) return const UnauthorizedError();
    if (status == 404) return const NotFoundError();
    if (status == 409) return const ConflictError();
    if (status != null) return ServerError(status);
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.connectionTimeout) {
      return NetworkError(
        e.message ?? 'Network error',
        certificateRejected: isCertificateRejection(e),
      );
    }
    return UnknownError(e);
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepositoryImpl(
    ref.watch(apiClientProvider),
    ref.watch(tokenServiceProvider),
    preferenceGate: ref.watch(portablePreferenceGateProvider),
  );
});

final authTransitionRepositoryFactoryProvider =
    Provider<AuthRepository Function(InstallationCapability)>((ref) {
      final credentials = ref.watch(protectedCredentialsRepositoryProvider);
      final keys = ref.watch(installationKeyRepositoryProvider);
      final preferenceGate = ref.watch(portablePreferenceGateProvider);
      final pins = ref.watch(serverPinStoreProvider);
      return (scope) {
        final tokens = ScopedTokenService(
          credentials: credentials,
          keys: keys,
          endpoint: scope.endpoint,
          capability: null,
          installation: Future.value(scope),
        );
        final client = ApiClient(
          baseUrl: '${scope.endpoint}/api/v1',
          tokenService: tokens,
          onAuthFailure: () {},
          pins: pins,
        );
        return AuthRepositoryImpl(
          client,
          tokens,
          credentials: credentials,
          installation: scope,
          preferenceGate: preferenceGate,
        );
      };
    });
