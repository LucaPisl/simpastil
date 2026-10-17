import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/core/auth/token_service.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/features/auth/auth_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'sends the exact device rename contract and caches after success',
    () async {
      SharedPreferences.setMockInitialValues({
        'simpastil_device_name': 'Old device',
      });
      final tokenService = _DeviceTokenService();
      final client = ApiClient(
        baseUrl: 'https://example.invalid/api/v1',
        tokenService: tokenService,
        onAuthFailure: () {},
      );
      final adapter = _ResponseAdapter(200);
      client.dio.httpClientAdapter = adapter;
      Map<String, dynamic>? requestBody;
      client.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestBody = Map<String, dynamic>.from(options.data as Map);
            handler.next(options);
          },
        ),
      );

      final result = await AuthRepositoryImpl(
        client,
        tokenService,
        preferenceGate: SerialProjectionEffectsGate(),
      ).setDeviceName('  New device  ');

      expect(result, isA<Ok<void>>());
      expect(requestBody, {
        'refreshToken': 'refresh-token',
        'deviceName': 'New device',
      });
      expect(
        (await SharedPreferences.getInstance()).getString(
          'simpastil_device_name',
        ),
        'New device',
      );
      client.dio.close(force: true);
    },
  );

  test(
    'does not replace the cached name when the server rejects the request',
    () async {
      SharedPreferences.setMockInitialValues({
        'simpastil_device_name': 'Old device',
      });
      final tokenService = _DeviceTokenService();
      final client = ApiClient(
        baseUrl: 'https://example.invalid/api/v1',
        tokenService: tokenService,
        onAuthFailure: () {},
      );
      client.dio.httpClientAdapter = _ResponseAdapter(500);

      final result = await AuthRepositoryImpl(
        client,
        tokenService,
        preferenceGate: SerialProjectionEffectsGate(),
      ).setDeviceName('New device');

      expect(result, isA<Err<void>>());
      expect(
        (await SharedPreferences.getInstance()).getString(
          'simpastil_device_name',
        ),
        'Old device',
      );
      client.dio.close(force: true);
    },
  );
}

class _DeviceTokenService extends TokenService {
  @override
  Future<String?> getAccessToken() async => 'access-token';

  @override
  Future<String?> getApiKey() async => 'api-key';

  @override
  Future<String?> getRefreshToken() async => 'refresh-token';
}

class _ResponseAdapter implements HttpClientAdapter {
  _ResponseAdapter(this.statusCode);

  final int statusCode;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    '{"ok":true}',
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}
