import '../../l10n/app_localizations.dart';
import 'app_error.dart';

/// The text for [error] in the app's current language.
///
/// [AppError.userMessage] stays English because it is also used for logs and
/// tests; anything shown to a person goes through here instead. A server
/// message in the response is never shown: it is not translated and may
/// carry details the app did not choose to display.
String localizedAppErrorMessage(AppLocalizations l, AppError error) =>
    switch (error) {
      NetworkError() => l.error_noConnection,
      UnauthorizedError() => l.error_sessionExpired,
      ConflictError() => l.error_conflict,
      RateLimitError(:final retryAfterSeconds)
          when retryAfterSeconds != null && retryAfterSeconds > 0 =>
        l.error_rateLimitedMinutes((retryAfterSeconds / 60).ceil()),
      RateLimitError() => l.error_rateLimited,
      NotFoundError() => l.error_itemNotFound,
      ServerCodeError(:final code) => _serverCode(l, code),
      ServerError() => l.error_serverTrouble,
      _ => l.error_unexpected,
    };

String _serverCode(AppLocalizations l, String code) => switch (code) {
  'AUTH_PASSWORD_WEAK' => l.error_passwordWeak,
  'AUTH_PASSWORD_LONG' => l.error_passwordLong,
  'AUTH_EMAIL_TAKEN' => l.error_emailTaken,
  'AUTH_KEY_REVOKED' => l.error_keyRevoked,
  'AUTH_KEY_INVALID' => l.error_keyInvalid,
  'ACCOUNT_DELETED' => l.error_accountDeleted,
  'AUTH_KEY_CLAIMED' => l.error_keyClaimed,
  'AUTH_RESET_INVALID' => l.error_resetInvalid,
  'TOTP_INVALID_CODE' => l.error_totpInvalidCode,
  'TOTP_ALREADY_ENABLED' => l.error_totpAlreadyEnabled,
  'TOTP_NOT_ENABLED' => l.error_totpNotEnabled,
  'TOTP_CHALLENGE_INVALID' => l.error_totpChallengeInvalid,
  'VALIDATION_ERROR' => l.error_validation,
  'CONFLICT_STALE_UPDATE' => l.error_staleUpdate,
  _ => l.shared_somethingWentWrong,
};
