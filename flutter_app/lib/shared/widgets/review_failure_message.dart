import 'package:dio/dio.dart';

import '../../core/errors/app_error.dart';
import '../../l10n/app_localizations.dart';

/// Only known classifications leave the review boundary. Server messages,
/// request bodies and transport exception text may contain private data.
String reviewFailureMessage(AppLocalizations l, Object error) {
  int? status;
  String? code;
  switch (error) {
    case UnauthorizedError():
      return l.review_errorSignIn;
    case ConflictError():
      return l.review_errorChanged;
    case NotFoundError():
      return l.review_errorMissing;
    case NetworkError():
      return l.review_errorConnection;
    case RateLimitError():
      return l.review_errorRateLimit;
    case ServerError(:final statusCode):
      status = statusCode;
    case ServerCodeError(:final statusCode, code: final serverCode):
      status = statusCode;
      code = serverCode;
    case DioException():
      status = error.response?.statusCode;
      final data = error.response?.data;
      final detail = data is Map ? data['error'] : null;
      code = detail is Map && detail['code'] is String
          ? detail['code'] as String
          : null;
      if (status == null &&
          const {
            DioExceptionType.connectionError,
            DioExceptionType.connectionTimeout,
            DioExceptionType.sendTimeout,
            DioExceptionType.receiveTimeout,
          }.contains(error.type)) {
        return l.review_errorConnection;
      }
  }
  if (status == 401) return l.review_errorSignIn;
  if (status == 409 ||
      const {'CONFLICT_STALE_UPDATE', 'CONFLICT_REVISION'}.contains(code)) {
    return l.review_errorChanged;
  }
  if (status == 404) return l.review_errorMissing;
  if (status == 400 || status == 422 || code == 'VALIDATION_ERROR') {
    return l.review_errorValidation;
  }
  if (status == 429) return l.review_errorRateLimit;
  if (status != null && status >= 500) return l.review_errorServer;
  return l.review_errorUnknown;
}
