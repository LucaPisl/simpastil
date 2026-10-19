import 'package:dio/dio.dart';

import '../network/pinned_connection.dart';

/// Thrown by AutoSyncService when pullFromServer reports total failure
/// (returned false) without surfacing a DioException.
class SyncFailedException implements Exception {
  const SyncFailedException();
}

/// Thrown by SyncService when another isolate in this process (the
/// foreground app or the WorkManager task) is already running sync. It is not
/// a failure: the other run does the work, so callers skip and try later.
class SyncBusyException implements Exception {
  const SyncBusyException();
}

/// Stable, locale-independent codes for the last sync failure. They are what
/// is stored and compared; screens turn them into words in the current
/// language (`localizedSyncErrorMessage`).
abstract final class SyncErrorCode {
  static const offline = 'SYNC_OFFLINE';
  static const timedOut = 'SYNC_TIMEOUT';
  static const serverError = 'SYNC_SERVER_ERROR';
  static const failed = 'SYNC_FAILED';
  static const serverUnreachable = 'SYNC_SERVER_UNREACHABLE';

  /// The server presented a different key than the pinned one.
  static const serverKeyChanged = 'SERVER_KEY_CHANGED';
}

/// Maps a stored value to its stable code. Releases before this one stored the
/// English sentence itself, so those sentences still read as their code.
String? normalizeSyncErrorCode(String? stored) => switch (stored) {
  'You appear to be offline' => SyncErrorCode.offline,
  'Connection timed out' => SyncErrorCode.timedOut,
  'Server error' => SyncErrorCode.serverError,
  'Sync failed' => SyncErrorCode.failed,
  "Couldn't reach the server" => SyncErrorCode.serverUnreachable,
  _ => stored,
};

/// Maps a sync exception to a stable failure code.
///
/// Auth failures never reach this: the AuthInterceptor's logout gate handles
/// confirmed 401s before the sync layer sees them.
String classifySyncError(Object error) {
  if (pinMismatchOf(error) != null) return SyncErrorCode.serverKeyChanged;
  if (error is SyncFailedException) return SyncErrorCode.serverUnreachable;
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
        return SyncErrorCode.offline;
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return SyncErrorCode.timedOut;
      case DioExceptionType.badResponse:
        final code = error.response?.statusCode ?? 0;
        return code >= 500 ? SyncErrorCode.serverError : SyncErrorCode.failed;
      default:
        return SyncErrorCode.failed;
    }
  }
  return SyncErrorCode.failed;
}
