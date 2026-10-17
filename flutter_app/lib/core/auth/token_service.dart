import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'scoped_token_service.dart';

// ── Storage keys ────────────────────────────────────────────────────────────
// Not exported — prevents accidental direct storage access from other modules.
const _kAccessToken = 'access_token';
const _kRefreshToken = 'refresh_token';
const _kAccessTokenExpiry = 'access_token_expiry_ms';
const _kApiKey = 'api_key';

// ── Android options ──────────────────────────────────────────────────────────
// encryptedSharedPreferences: true → keys backed by Android Keystore (AES-256).
// keyCipherAlgorithm + storageCipherAlgorithm → strongest available on API 23+.
const _androidOptions = AndroidOptions(
  encryptedSharedPreferences: true,
  keyCipherAlgorithm: KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
  storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
);

// ── iOS options ──────────────────────────────────────────────────────────────
// first_unlock_this_device: tokens survive reboot but are inaccessible while
// the device is locked, matching the security posture of Android Keystore.
const _iosOptions = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);

/// Manages access and refresh tokens in hardware-backed secure storage.
///
/// Thread-safe: [FlutterSecureStorage] serialises all reads/writes internally.
/// Never logs token values — pass only non-sensitive status to [AppLogger].
class TokenService {
  const TokenService();

  static const _storage = FlutterSecureStorage(
    aOptions: _androidOptions,
    iOptions: _iosOptions,
  );

  Future<String?> getAccessToken() => _storage.read(key: _kAccessToken);

  Future<String?> getRefreshToken() => _storage.read(key: _kRefreshToken);

  /// Persists both tokens and stores the expiry as an absolute epoch-ms
  /// timestamp so [isAuthenticated] can check expiry without decoding the JWT.
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    required int expiresIn, // seconds until access token expires
  }) async {
    final expiryMs = DateTime.now()
        .add(Duration(seconds: expiresIn))
        .millisecondsSinceEpoch
        .toString();

    await Future.wait([
      _storage.write(key: _kAccessToken, value: accessToken),
      _storage.write(key: _kRefreshToken, value: refreshToken),
      _storage.write(key: _kAccessTokenExpiry, value: expiryMs),
    ]);
  }

  /// Removes all auth tokens. Called on logout or when refresh fails.
  Future<void> clearTokens() async {
    await Future.wait([
      _storage.delete(key: _kAccessToken),
      _storage.delete(key: _kRefreshToken),
      _storage.delete(key: _kAccessTokenExpiry),
      _storage.delete(key: _kApiKey),
    ]);
  }

  /// Removes session tokens only — access token, refresh token, and expiry.
  ///
  /// The API key is intentionally preserved: it is an installation credential,
  /// not a session credential. Losing it would force the user through the
  /// full three-phase setup again.
  ///
  /// Called by [AuthInterceptor] on a confirmed 401 from the refresh endpoint.
  /// Use [clearTokens] for explicit logout (which must also clear the API key).
  Future<void> clearSessionTokens() async {
    await Future.wait([
      _storage.delete(key: _kAccessToken),
      _storage.delete(key: _kRefreshToken),
      _storage.delete(key: _kAccessTokenExpiry),
    ]);
  }

  /// Returns true if a non-expired access token is stored.
  ///
  /// Uses a 30-second buffer so tokens are proactively refreshed before
  /// a request is actually sent with a near-expired token.
  Future<bool> isAuthenticated() async {
    try {
      final token = await _storage.read(key: _kAccessToken);
      if (token == null) return false;

      final expiryStr = await _storage.read(key: _kAccessTokenExpiry);
      if (expiryStr == null) return false;

      final expiryMs = int.tryParse(expiryStr);
      if (expiryMs == null) return false;

      final expiry = DateTime.fromMillisecondsSinceEpoch(expiryMs);
      return DateTime.now().isBefore(
        expiry.subtract(const Duration(seconds: 30)),
      );
    } catch (_) {
      return false;
    }
  }

  /// Decodes the stored access token (JWT) and returns the `sub` claim (user ID).
  ///
  /// Does NOT verify the signature — signature verification is the server's job.
  /// Returns null if no token is stored or the payload cannot be parsed.
  Future<String?> getUserId() async {
    try {
      final token = await getAccessToken();
      if (token == null) return null;
      final parts = token.split('.');
      if (parts.length != 3) return null;
      // JWT payload is base64url-encoded without padding.
      final normalized = base64Url.normalize(parts[1]);
      final payload = utf8.decode(base64Url.decode(normalized));
      final map = jsonDecode(payload) as Map<String, dynamic>;
      return map['sub'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<String?> getApiKey() => _storage.read(key: _kApiKey);

  Future<void> saveApiKey(String key) =>
      _storage.write(key: _kApiKey, value: key);

  Future<void> clearApiKey() => _storage.delete(key: _kApiKey);

  /// Returns true when a session can still be resumed via refresh token,
  /// even if the current access token has expired.
  ///
  /// This prevents premature navigation to the login screen while the
  /// interceptor can still refresh in the background.
  Future<bool> hasSession() async {
    if (await isAuthenticated()) return true;
    final refresh = await _storage.read(key: _kRefreshToken);
    // Refresh tokens are opaque rolling credentials, not necessarily JWTs.
    return refresh != null && refresh.trim().isNotEmpty;
  }
}

/// Riverpod provider — singleton for the app lifetime.
final tokenServiceProvider = Provider<TokenService>(
  (ref) => ref.watch(scopedTokenServiceProvider),
);
