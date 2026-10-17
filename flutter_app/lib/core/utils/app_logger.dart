import 'package:flutter/foundation.dart';

/// A compile-time-safe logger that is a complete no-op in release builds.
///
/// All log calls are behind [kDebugMode] — a `const bool` — so the Dart
/// compiler fully tree-shakes every branch in release mode. No tokens,
/// passwords, or PII should ever be passed to these methods.
///
/// Usage:
///   AppLogger.debug('ApiClient', 'Request sent to /auth/login');  // ✓
///   AppLogger.debug('Auth', 'Token: $accessToken');               // ✗ NEVER
abstract class AppLogger {
  static void debug(String tag, String message) {
    if (kDebugMode) {
      debugPrint('[DBG][$tag] $message');
    }
  }

  static void info(String tag, String message) {
    if (kDebugMode) {
      debugPrint('[INF][$tag] $message');
    }
  }

  static void warning(String tag, String message) {
    if (kDebugMode) {
      debugPrint('[WRN][$tag] $message');
    }
  }

  static void error(
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    if (kDebugMode) {
      debugPrint('[ERR][$tag] $message');
      if (error != null) debugPrint('  └─ $error');
      if (stackTrace != null) debugPrint('  └─ $stackTrace');
    }
  }
}
