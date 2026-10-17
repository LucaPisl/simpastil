import 'dart:convert';

import 'app_logger.dart';

/// Shared JWT utilities used by both the foreground AuthInterceptor and the
/// WorkManager background isolate.
class JwtUtils {
  JwtUtils._();

  static const int defaultExpiresInSeconds = 900;

  /// Extracts seconds-until-expiry from the JWT [token]'s `exp` claim.
  /// Falls back to [defaultExpiresInSeconds] (15 min) if the token is malformed.
  static int parseExpiresIn(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return defaultExpiresInSeconds;
      final normalized = base64Url.normalize(parts[1]);
      final payload =
          jsonDecode(utf8.decode(base64Url.decode(normalized)))
              as Map<String, dynamic>;
      final exp = (payload['exp'] as num?)?.toInt();
      if (exp == null) return defaultExpiresInSeconds;
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return (exp - nowSeconds).clamp(0, 3600);
    } catch (e) {
      AppLogger.warning(
        'JwtUtils',
        'Could not parse JWT exp claim; defaulting expiresIn to $defaultExpiresInSeconds s. Error: $e',
      );
      return defaultExpiresInSeconds;
    }
  }

  /// Returns `true` if the JWT [token]'s `exp` claim is in the past.
  /// Returns `true` (expired) if the token cannot be parsed.
  static bool isExpired(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return true;
      final normalized = base64Url.normalize(parts[1]);
      final payload =
          jsonDecode(utf8.decode(base64Url.decode(normalized)))
              as Map<String, dynamic>;
      final exp = (payload['exp'] as num?)?.toInt();
      if (exp == null) return true;
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return nowSeconds >= exp;
    } catch (_) {
      return true;
    }
  }
}
