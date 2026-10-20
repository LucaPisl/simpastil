import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/network/http_clients.dart';
import 'package:simpastil/core/network/pinned_connection.dart';
import 'package:simpastil/core/network/server_pin_store.dart';
import 'package:simpastil/features/auth/auth_repository.dart';

import '../../helpers/tls_test_server.dart';

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
    TlsTestServer? server;
    tearDown(() async {
      await server?.close();
      server = null;
      ServerPinEvents.resetRejections();
    });

    Future<DioException> failedLogin(String baseUrl) async {
      final dio = createServerDio(
        options: BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
        pins: SecureServerPinStore(MemorySlots()),
      );
      try {
        await dio.post<dynamic>('/api/v1/auth/login', data: {'email': 'a'});
      } on DioException catch (e) {
        return e;
      }
      fail('the request was expected to fail');
    }

    test(
      'a real refused handshake is marked, whatever type Dio gives it',
      () async {
        server = await TlsTestServer.start(
          chainFiles: ['ec_self.pem'],
          keyFile: 'ec_self.key.pem',
        );
        final failure = await failedLogin(server!.baseUrl);

        final error = AuthRepositoryImpl.mapDioError(failure);
        expect(error, isA<NetworkError>());
        expect((error as NetworkError).certificateRejected, isTrue);
        expect(server!.bytesReceived, 0);
      },
    );

    test('a server that is simply down is not', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();

      final error = AuthRepositoryImpl.mapDioError(
        await failedLogin('https://127.0.0.1:$port'),
      );
      expect(error, isA<NetworkError>());
      expect((error as NetworkError).certificateRejected, isFalse);
    });
  });
}
