import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/account/account_client.dart';

DioException _error(int status, Object? data, {Map<String, List<String>>? h}) =>
    DioException(
      requestOptions: RequestOptions(path: '/x'),
      response: Response<Object?>(
        requestOptions: RequestOptions(path: '/x'),
        statusCode: status,
        data: data,
        headers: Headers.fromMap(h ?? {}),
      ),
    );

void main() {
  test('the summary reads counts and tolerates missing fields', () {
    final full = AccountSummary.fromJson({
      'email': 'a@example.test',
      'twoFactorEnabled': true,
      'counts': {
        'people': 2,
        'medications': 3,
        'routines': 4,
        'doses': 5,
        'devices': 1,
      },
    });
    expect(full.email, 'a@example.test');
    expect(full.twoFactorEnabled, isTrue);
    expect(
      [full.people, full.medications, full.routines, full.doses],
      [2, 3, 4, 5],
    );
    final bare = AccountSummary.fromJson({});
    expect(bare.email, '');
    expect(bare.twoFactorEnabled, isFalse);
    expect(bare.people, 0);
  });

  group('AccountCallFailure', () {
    test('reads the nested error shape', () {
      final f = AccountCallFailure.from(
        _error(400, {
          'error': {'code': 'AUTH_INVALID_CREDENTIALS', 'message': 'no'},
        }),
      );
      expect(f.code, 'AUTH_INVALID_CREDENTIALS');
      expect(f.statusCode, 400);
    });

    test('reads the flat guard shape', () {
      final f = AccountCallFailure.from(
        _error(401, {'error': 'Unauthorized', 'code': 'ACCOUNT_DELETED'}),
      );
      expect(f.code, 'ACCOUNT_DELETED');
    });

    test('a rate limit carries its wait; no response means offline', () {
      final limited = AccountCallFailure.from(
        _error(
          429,
          {},
          h: {
            'retry-after': ['30'],
          },
        ),
      );
      expect(limited.isRateLimited, isTrue);
      expect(limited.retryAfter, 30);
      final offline = AccountCallFailure.from(
        DioException(requestOptions: RequestOptions(path: '/x')),
      );
      expect(offline.isOffline, isTrue);
    });
  });

  group('AccountClient', () {
    Dio dioWith(void Function(RequestOptions, RequestInterceptorHandler) h) {
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: h));
      return dio;
    }

    test('changeEmail maps the status and omits an absent code', () async {
      late Map<String, dynamic> sent;
      final client = AccountClient(
        dioWith((o, handler) {
          sent = o.data as Map<String, dynamic>;
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: o,
              statusCode: 200,
              data: {'status': 'changed'},
            ),
          );
        }),
      );
      final outcome = await client.changeEmail(
        password: 'p',
        newEmail: 'n@example.test',
      );
      expect(outcome, EmailChangeOutcome.changed);
      expect(sent.containsKey('code'), isFalse);
    });

    test('a failed call surfaces as AccountCallFailure', () async {
      final client = AccountClient(
        dioWith(
          (o, handler) => handler.reject(
            DioException(
              requestOptions: o,
              response: Response<Object?>(
                requestOptions: o,
                statusCode: 400,
                data: {
                  'error': {'code': 'TOTP_REQUIRED'},
                },
              ),
            ),
          ),
        ),
      );
      await expectLater(
        client.deleteAccount(password: 'p'),
        throwsA(
          isA<AccountCallFailure>().having(
            (f) => f.code,
            'code',
            'TOTP_REQUIRED',
          ),
        ),
      );
    });
  });
}
