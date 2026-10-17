import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:simpastil/core/auth/token_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TokenService API key', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('getApiKey returns null when nothing stored', () async {
      const sut = TokenService();
      expect(await sut.getApiKey(), isNull);
    });

    test('saveApiKey persists; getApiKey retrieves it', () async {
      const sut = TokenService();
      await sut.saveApiKey('abc123');
      expect(await sut.getApiKey(), 'abc123');
    });

    test('clearApiKey removes key', () async {
      const sut = TokenService();
      await sut.saveApiKey('abc123');
      await sut.clearApiKey();
      expect(await sut.getApiKey(), isNull);
    });

    test('clearTokens also clears API key', () async {
      const sut = TokenService();
      await sut.saveApiKey('abc123');
      await sut.clearTokens();
      expect(await sut.getApiKey(), isNull);
    });
  });

  group('TokenService clearSessionTokens', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('clearSessionTokens removes access/refresh/expiry tokens', () async {
      const sut = TokenService();
      await sut.saveTokens(
        accessToken: 'acc',
        refreshToken: 'ref',
        expiresIn: 900,
      );
      await sut.clearSessionTokens();
      expect(await sut.getAccessToken(), isNull);
      expect(await sut.getRefreshToken(), isNull);
    });

    test('clearSessionTokens preserves the API key', () async {
      const sut = TokenService();
      await sut.saveApiKey('admin-key-xyz');
      await sut.saveTokens(
        accessToken: 'acc',
        refreshToken: 'ref',
        expiresIn: 900,
      );
      await sut.clearSessionTokens();
      expect(await sut.getApiKey(), 'admin-key-xyz');
    });
  });

  test(
    'hasSession accepts an opaque refresh token after access expiry',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      const sut = TokenService();
      await sut.saveTokens(
        accessToken: 'expired-access-token',
        refreshToken: 'opaque-rolling-refresh-token',
        expiresIn: -60,
      );

      expect(await sut.isAuthenticated(), isFalse);
      expect(await sut.hasSession(), isTrue);
    },
  );
}
