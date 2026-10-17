import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/auth/token_service.dart';
import 'package:simpastil/core/api/api_client.dart';

class MockTokenService extends Mock implements TokenService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ApiClient X-Api-Key', () {
    late MockTokenService tokenService;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      tokenService = MockTokenService();
      when(
        () => tokenService.getApiKey(),
      ).thenAnswer((_) async => 'test-key-abc');
      when(() => tokenService.getAccessToken()).thenAnswer((_) async => null);
      when(() => tokenService.hasSession()).thenAnswer((_) async => false);
    });

    test('outgoing requests include X-Api-Key header', () async {
      final client = ApiClient(
        baseUrl: 'http://localhost:3000/api/v1',
        tokenService: tokenService,
        onAuthFailure: () {},
      );

      final List<RequestOptions> captured = [];
      client.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured.add(options);
            handler.reject(DioException(requestOptions: options));
          },
        ),
      );

      try {
        await client.dio.get('/health');
      } catch (_) {}
      expect(captured.first.headers['X-Api-Key'], 'test-key-abc');
    });

    test('_sanitizeHeaders strips X-Api-Key and Authorization', () {
      final client = ApiClient(
        baseUrl: 'http://localhost:3000/api/v1',
        tokenService: tokenService,
        onAuthFailure: () {},
      );
      final sanitized = client.sanitizeHeadersForTest({
        'Authorization': 'Bearer tok',
        'X-Api-Key': 'secret',
        'Content-Type': 'application/json',
      });
      expect(sanitized.containsKey('X-Api-Key'), isFalse);
      expect(sanitized.containsKey('Authorization'), isFalse);
      expect(sanitized['Content-Type'], 'application/json');
    });
  });

  group('AuthInterceptor — session stability', () {
    late MockTokenService tokenService;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      tokenService = MockTokenService();
      when(() => tokenService.getApiKey()).thenAnswer((_) async => 'api-key');
      when(
        () => tokenService.getAccessToken(),
      ).thenAnswer((_) async => 'access-token');
      when(
        () => tokenService.getRefreshToken(),
      ).thenAnswer((_) async => 'refresh-token');
      when(() => tokenService.clearSessionTokens()).thenAnswer((_) async {});
    });

    test(
      'network failure during refresh does NOT trigger onAuthFailure',
      () async {
        // baseUrl points to a port with nothing listening → refresh call
        // fails with a connection error (soft failure).
        final authFailureCalled = <bool>[];
        final client = ApiClient(
          baseUrl: 'http://localhost:19999/api/v1',
          tokenService: tokenService,
          onAuthFailure: () => authFailureCalled.add(true),
        );

        // Simulate a 401 on the original request.
        client.dio.interceptors.insert(
          0,
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(requestOptions: options, statusCode: 401),
                  type: DioExceptionType.badResponse,
                ),
              );
            },
          ),
        );

        try {
          await client.dio.get('/protected');
        } catch (_) {}

        // Soft failure: onAuthFailure must NOT have been called.
        expect(
          authFailureCalled,
          isEmpty,
          reason: 'A network error on the refresh call must not trigger logout',
        );
        verifyNever(() => tokenService.clearSessionTokens());
      },
    );

    test(
      'missing refresh token does not clear the session without server rejection',
      () async {
        when(
          () => tokenService.getRefreshToken(),
        ).thenAnswer((_) async => null);
        final authFailureCalled = <bool>[];
        final client = ApiClient(
          baseUrl: 'http://localhost:19999/api/v1',
          tokenService: tokenService,
          onAuthFailure: () => authFailureCalled.add(true),
        );
        client.dio.interceptors.insert(
          0,
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(requestOptions: options, statusCode: 401),
                  type: DioExceptionType.badResponse,
                ),
              );
            },
          ),
        );

        try {
          await client.dio.get('/protected');
        } catch (_) {}

        expect(authFailureCalled, isEmpty);
        verifyNever(() => tokenService.clearSessionTokens());
      },
    );
  });
}
