import 'package:dio/dio.dart';

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

/// Maps a sync exception to a short user-facing message.
///
/// Auth failures never reach this — the AuthInterceptor's logout gate
/// handles confirmed 401s before the sync layer sees them.
String classifySyncError(Object error) {
  if (error is SyncFailedException) return "Couldn't reach the server";
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
        return 'You appear to be offline';
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Connection timed out';
      case DioExceptionType.badResponse:
        final code = error.response?.statusCode ?? 0;
        return code >= 500 ? 'Server error' : 'Sync failed';
      default:
        return 'Sync failed';
    }
  }
  return 'Sync failed';
}
