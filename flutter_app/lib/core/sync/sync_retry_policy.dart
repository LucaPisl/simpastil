import 'package:dio/dio.dart';

/// Shared rules for transient transport failures of idempotent mutations.
///
/// A timeout, a missing response, a 5xx, 408 or 429 says nothing about whether
/// the server applied the request. Every mutation carries a stable
/// `mutationId`/`commandId` and replays with a byte-identical body, so the
/// safe response is to try again later, never to block the edit for good.
abstract final class SyncRetryPolicy {
  /// Attempts (including the first) before the operation is blocked for review.
  static const maxAttempts = 8;

  static const _backoff = [
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(hours: 1),
  ];

  static const retryExhaustedCode = 'SYNC_RETRY_EXHAUSTED';
  static const retryExhaustedIssueCode = 'sync_retry_exhausted';
  static const awaitingReconciliationCode = 'SPLIT_RECONCILIATION_REQUIRED';
  static const bodyChangedCode = 'STABLE_REQUEST_BODY_CHANGED';

  /// Delay before attempt number [attemptCount] + 1.
  static Duration backoffAfter(int attemptCount) =>
      _backoff[(attemptCount < 1 ? 1 : attemptCount).clamp(1, _backoff.length) -
          1];

  /// True when [error] leaves the outcome unknown or asks us to come back.
  static bool isTransient(DioException error) {
    final status = error.response?.statusCode;
    return status == null || status >= 500 || status == 408 || status == 429;
  }

  /// The server's own wish, from `Retry-After` (seconds) or `error.retryAfter`.
  static Duration? retryAfter(DioException error) {
    final header = error.response?.headers.value('retry-after');
    final seconds =
        int.tryParse(header ?? '') ?? _bodyRetryAfter(error.response?.data);
    if (seconds == null || seconds <= 0) return null;
    return Duration(seconds: seconds > 86400 ? 86400 : seconds);
  }

  static int? _bodyRetryAfter(Object? data) {
    if (data is! Map) return null;
    final error = data['error'];
    final value = error is Map ? error['retryAfter'] : data['retryAfter'];
    return value is num ? value.toInt() : null;
  }

  /// The server answered 409 only because a split bridge command it already
  /// holds still awaits reconciliation. That is not a user conflict.
  static bool isAwaitingReconciliation(DioException error) {
    if (error.response?.statusCode != 409) return false;
    final data = error.response?.data;
    final detail = data is Map ? data['error'] : null;
    final message = detail is Map ? detail['message'] : null;
    return message is String &&
        message.toLowerCase().contains('awaiting reconciliation');
  }

  /// First moment a failed-retryable operation may be sent again.
  static DateTime notBefore(DateTime? lastAttemptAt, int attemptCount) =>
      (lastAttemptAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))
          .toUtc()
          .add(backoffAfter(attemptCount));
}
