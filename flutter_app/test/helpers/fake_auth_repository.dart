import 'package:simpastil/features/auth/auth_repository.dart';
import 'package:simpastil/core/errors/app_error.dart';

class FakeAuthRepository implements AuthRepository {
  Future<Result<LoginResult>> loginFuture = Future.value(
    const Ok(LoginSuccess('user-uuid-123')),
  );
  Future<Result<void>> registerFuture = Future.value(const Ok(null));
  Future<Result<void>> logoutFuture = Future.value(const Ok(null));
  Future<Result<void>> setDeviceNameFuture = Future.value(const Ok(null));
  final deviceNameAttempts = <String>[];

  @override
  Future<Result<LoginResult>> login(String email, String password) =>
      loginFuture;

  @override
  Future<Result<void>> register(String email, String password) =>
      registerFuture;

  @override
  Future<Result<void>> logout(String refreshToken) => logoutFuture;

  @override
  Future<Result<void>> changePassword(
    String currentPassword,
    String newPassword,
  ) => Future.value(const Ok(null));

  @override
  Future<Result<void>> setDeviceName(String deviceName) =>
      _setDeviceName(deviceName);

  Future<Result<void>> _setDeviceName(String deviceName) {
    deviceNameAttempts.add(deviceName);
    return setDeviceNameFuture;
  }

  @override
  Future<Result<LoginSuccess>> challenge2fa(
    String challengeToken,
    String code,
  ) => Future.value(const Ok(LoginSuccess('user-uuid-123')));

  @override
  Future<Result<TotpSetupResult>> setup2fa() => Future.value(
    const Ok(TotpSetupResult(secret: 'test', otpauthUri: 'otpauth://test')),
  );

  @override
  Future<Result<List<String>>> enable2fa(String code) =>
      Future.value(const Ok(['code1', 'code2']));

  @override
  Future<Result<void>> disable2fa(String code) => Future.value(const Ok(null));

  @override
  Future<Result<List<String>>> regenerateBackupCodes(String code) =>
      Future.value(const Ok(['code1', 'code2']));
}
