import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// Transitive dependency of local_auth; the test replaces its platform
// implementation to observe exactly what the app asks the system for.
// ignore: depend_on_referenced_packages
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';
import 'package:simpastil/core/protection/app_lock_controller.dart';

class _RecordingPlatform extends LocalAuthPlatform {
  String? reason;
  AuthenticationOptions? options;
  bool result = true;
  bool supported = true;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required Iterable<AuthMessages> authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    reason = localizedReason;
    this.options = options;
    return result;
  }

  @override
  Future<bool> isDeviceSupported() async => supported;
}

void main() {
  late LocalAuthPlatform previous;
  late _RecordingPlatform platform;

  setUp(() {
    previous = LocalAuthPlatform.instance;
    platform = _RecordingPlatform();
    LocalAuthPlatform.instance = platform;
  });

  tearDown(() => LocalAuthPlatform.instance = previous);

  // Android authenticates through the app's own channel; the plugin is the
  // path for every other platform.
  final hostUsesPlugin = !Platform.isAndroid;

  test(
    'unlock asks for biometrics or the device credential, never sticky',
    () async {
      final authenticator = LocalDeviceAuthenticator();
      final unlocked = await authenticator.authenticate(
        'Unlock Simpastil',
        attemptId: 'attempt-1',
      );

      expect(unlocked, isTrue);
      expect(platform.reason, 'Unlock Simpastil');
      expect(
        platform.options,
        const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: false,
          useErrorDialogs: false,
        ),
      );
    },
    skip: !hostUsesPlugin,
  );

  test('a failed challenge is reported as not authenticated', () async {
    platform.result = false;
    expect(
      await LocalDeviceAuthenticator().authenticate(
        'Unlock Simpastil',
        attemptId: 'attempt-2',
      ),
      isFalse,
    );
  }, skip: !hostUsesPlugin);

  test('device support is read from the plugin', () async {
    final authenticator = LocalDeviceAuthenticator();
    expect(await authenticator.isSupported(), isTrue);
    platform.supported = false;
    expect(await authenticator.isSupported(), isFalse);
  });
}
