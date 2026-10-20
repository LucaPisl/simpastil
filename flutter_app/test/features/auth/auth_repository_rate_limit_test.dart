import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/features/auth/auth_repository.dart';

void main() {
  group('M-4 fix: 429 → RateLimitError (not ServerCodeError)', () {
    test('429 with RATE_LIMIT_EXCEEDED code maps to RateLimitError', () {
      final exception = DioException(
        requestOptions: RequestOptions(path: '/auth/login'),
        response: Response(
          requestOptions: RequestOptions(path: '/auth/login'),
          statusCode: 429,
          data: {
            'code': 'RATE_LIMIT_EXCEEDED',
            'error': 'Too Many Requests',
            'retryAfter': 42,
          },
        ),
      );

      final error = AuthRepositoryImpl.mapDioError(exception);
      expect(error, isA<RateLimitError>());
      expect((error as RateLimitError).retryAfterSeconds, 42);
    });

    test('429 without structured body still maps to RateLimitError', () {
      final exception = DioException(
        requestOptions: RequestOptions(path: '/auth/login'),
        response: Response(
          requestOptions: RequestOptions(path: '/auth/login'),
          statusCode: 429,
          data: 'Too Many Requests',
        ),
      );

      final error = AuthRepositoryImpl.mapDioError(exception);
      expect(error, isA<RateLimitError>());
      expect((error as RateLimitError).retryAfterSeconds, isNull);
    });

    test('401 maps to UnauthorizedError (not RateLimitError)', () {
      final exception = DioException(
        requestOptions: RequestOptions(path: '/auth/login'),
        response: Response(
          requestOptions: RequestOptions(path: '/auth/login'),
          statusCode: 401,
          data: {'code': 'UNAUTHORIZED', 'error': 'Unauthorized'},
        ),
      );

      final error = AuthRepositoryImpl.mapDioError(exception);
      expect(error, isA<ServerCodeError>());
    });
  });

  group('certificate refusal reaches the sign-in error', () {
    DioException connectionError(Object cause) => DioException.connectionError(
      requestOptions: RequestOptions(path: '/auth/login'),
      reason: 'tls',
      error: cause,
    );

    test('a failed certificate check is marked as such', () {
      final error = AuthRepositoryImpl.mapDioError(
        connectionError(
          const HandshakeException('CERTIFICATE_VERIFY_FAILED: self signed'),
        ),
      );
      expect(error, isA<NetworkError>());
      expect((error as NetworkError).certificateRejected, isTrue);
    });

    test('an unreachable server is not', () {
      final error = AuthRepositoryImpl.mapDioError(
        connectionError(const SocketException('down')),
      );
      expect((error as NetworkError).certificateRejected, isFalse);
    });
  });
}
