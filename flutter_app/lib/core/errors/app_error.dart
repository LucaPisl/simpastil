/// Typed error hierarchy for all application failures.
///
/// Every error case is represented as a concrete subtype of [AppError].
/// Use an exhaustive [switch] to handle all cases without fallthrough risk.
sealed class AppError {
  const AppError();

  /// A user-safe string describing this error. Never includes internal details.
  String get userMessage;
}

/// A network-level failure: DNS, timeout, no connectivity.
final class NetworkError extends AppError {
  final String message;

  /// The failure was a certificate the device could not verify, so the
  /// person can review the server's key instead of just retrying.
  final bool certificateRejected;

  /// The server presented a different key than the one pinned, so nothing
  /// was sent. The person can review the key.
  final bool serverKeyChanged;
  const NetworkError(
    this.message, {
    this.certificateRejected = false,
    this.serverKeyChanged = false,
  });

  @override
  bool operator ==(Object other) =>
      other is NetworkError &&
      other.message == message &&
      other.certificateRejected == certificateRejected &&
      other.serverKeyChanged == serverKeyChanged;

  @override
  int get hashCode =>
      Object.hash(runtimeType, message, certificateRejected, serverKeyChanged);

  @override
  String toString() => 'NetworkError($message)';

  @override
  String get userMessage =>
      'No internet connection. Check your network and try again.';
}

// No fields — equality is identity via const canonicalisation.

/// The server returned 401 — credentials are invalid or token is expired.
final class UnauthorizedError extends AppError {
  const UnauthorizedError();

  @override
  String toString() => 'UnauthorizedError()';

  @override
  String get userMessage => 'Your session has expired. Please log in again.';
}

/// The server returned 409 — a unique constraint was violated (e.g. email taken).
final class ConflictError extends AppError {
  const ConflictError();

  @override
  String toString() => 'ConflictError()';

  @override
  String get userMessage => 'That item already exists.';
}

/// The server returned 429 — the client has been rate-limited.
final class RateLimitError extends AppError {
  final int? retryAfterSeconds;
  const RateLimitError([this.retryAfterSeconds]);

  @override
  bool operator ==(Object other) =>
      other is RateLimitError && other.retryAfterSeconds == retryAfterSeconds;

  @override
  int get hashCode => Object.hash(runtimeType, retryAfterSeconds);

  @override
  String toString() => 'RateLimitError($retryAfterSeconds)';

  @override
  String get userMessage {
    if (retryAfterSeconds != null && retryAfterSeconds! > 0) {
      final minutes = (retryAfterSeconds! / 60).ceil();
      return 'Too many requests. Try again in $minutes minute${minutes == 1 ? '' : 's'}.';
    }
    return 'Too many requests. Please wait a moment.';
  }
}

/// The server returned 404 — the requested resource does not exist.
final class NotFoundError extends AppError {
  const NotFoundError();

  @override
  String toString() => 'NotFoundError()';

  @override
  String get userMessage => 'The item could not be found.';
}

/// The server returned a structured error code alongside an HTTP status.
final class ServerCodeError extends AppError {
  final int statusCode;
  final String code;
  final String? serverMessage;
  const ServerCodeError(this.statusCode, this.code, [this.serverMessage]);

  @override
  bool operator ==(Object other) =>
      other is ServerCodeError &&
      other.statusCode == statusCode &&
      other.code == code;

  @override
  int get hashCode => Object.hash(runtimeType, statusCode, code);

  @override
  String toString() => 'ServerCodeError($statusCode, $code)';

  @override
  String get userMessage => switch (code) {
    'AUTH_PASSWORD_WEAK' => 'Password is too weak. Use at least 10 characters.',
    'AUTH_PASSWORD_LONG' => 'Password is too long.',
    'AUTH_EMAIL_TAKEN' => 'An account with that email already exists.',
    'AUTH_KEY_REVOKED' =>
      'Your API key has been revoked. Contact the administrator.',
    'AUTH_KEY_INVALID' => 'Invalid API key. Check your key and try again.',
    'ACCOUNT_DELETED' => 'This account was deleted.',
    'AUTH_KEY_CLAIMED' => 'This API key is already in use.',
    'AUTH_RESET_INVALID' => 'This reset link is invalid or has expired.',
    'TOTP_INVALID_CODE' => 'Invalid verification code. Please try again.',
    'TOTP_ALREADY_ENABLED' => 'Two-factor authentication is already enabled.',
    'TOTP_NOT_ENABLED' => 'Two-factor authentication is not enabled.',
    'TOTP_CHALLENGE_INVALID' =>
      'Invalid or expired challenge. Please log in again.',
    'VALIDATION_ERROR' =>
      serverMessage ?? 'Invalid input. Please check your data.',
    'CONFLICT_STALE_UPDATE' =>
      'This item was modified on another device. Pull to refresh.',
    _ => serverMessage ?? 'Something went wrong. Please try again.',
  };
}

/// The server returned an unexpected HTTP error status.
final class ServerError extends AppError {
  final int statusCode;
  const ServerError(this.statusCode);

  @override
  bool operator ==(Object other) =>
      other is ServerError && other.statusCode == statusCode;

  @override
  int get hashCode => Object.hash(runtimeType, statusCode);

  @override
  String toString() => 'ServerError($statusCode)';

  @override
  String get userMessage =>
      'Something went wrong on our end. Please try again later.';
}

/// An unexpected error that does not fit any typed category.
final class UnknownError extends AppError {
  final Object? cause;
  const UnknownError([this.cause]);

  @override
  bool operator ==(Object other) =>
      other is UnknownError && other.cause == cause;

  @override
  int get hashCode => Object.hash(runtimeType, cause);

  @override
  String toString() => 'UnknownError($cause)';

  @override
  String get userMessage => 'An unexpected error occurred.';
}

// ── Result<T> ─────────────────────────────────────────────────────────────────

/// A typed result that is either a success ([Ok]) or a failure ([Err]).
///
/// Never throw — return [Err] instead. Pattern-match with an exhaustive
/// [switch] expression:
///
/// ```dart
/// switch (result) {
///   case Ok(:final value) => use(value);
///   case Err(:final error) => handle(error);
/// }
/// ```
sealed class Result<T> {
  const Result();
}

/// A successful result carrying a [value].
final class Ok<T> extends Result<T> {
  final T value;
  const Ok(this.value);

  @override
  bool operator ==(Object other) => other is Ok<T> && other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => 'Ok($value)';
}

/// A failed result carrying an [error].
final class Err<T> extends Result<T> {
  final AppError error;
  const Err(this.error);

  @override
  bool operator ==(Object other) => other is Err<T> && other.error == error;

  @override
  int get hashCode => Object.hash(runtimeType, error);

  @override
  String toString() => 'Err($error)';
}
