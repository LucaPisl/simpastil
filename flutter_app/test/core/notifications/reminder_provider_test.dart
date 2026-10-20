import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/notifications/reminder_preferences.dart';
import 'package:simpastil/core/notifications/reminder_provider.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/protection/app_lock_controller.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';

import '../../helpers/protected_workspace_fixture.dart';
import '../../helpers/held_provider_read.dart';

class _Policy implements AppLockPolicyStorage {
  String value = const AppLockPolicy(
    enabled: true,
    revision: 'fixture',
  ).encode();

  @override
  Object? get policyValue => value;
  @override
  Object? get legacyValue => null;
  @override
  Future<void> reload() async {}
  @override
  Future<bool> write(String next) async {
    value = next;
    return true;
  }
}

class _Authentication implements DeviceAuthenticator {
  @override
  void Function(String)? onCredentialPromptPaused;
  @override
  void Function(String)? onCredentialPromptResumed;
  @override
  Future<bool> isSupported() async => true;
  @override
  Future<bool> authenticate(
    String reason, {
    required String attemptId,
    String fallbackLabel = 'Use device lock',
  }) async => true;
  @override
  Future<DeviceAuthenticationContext> context() async =>
      const DeviceAuthenticationContext(leaveGeneration: 0, foreground: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'privacy setting requires unlock and writes under its captured lease',
    () async {
      final fixture = await ProtectedWorkspaceFixture.create();
      addTearDown(fixture.db.close);
      final lock = AppLockController(
        AppLockPolicyStore(_Policy(), gate: SerialProjectionEffectsGate()),
        _Authentication(),
      );
      final container = ProviderContainer(
        overrides: [
          ...fixture.overrides,
          appLockControllerProvider.overrideWith((_) => lock),
        ],
      );
      addTearDown(container.dispose);
      container.listen(workspaceContextProvider, (_, _) {});
      await container.readHeld(workspaceContextProvider);
      final repository = ReminderPreferencesRepository(
        database: fixture.db,
        access: fixture.access,
        context: fixture.context,
      );
      final setFullDetails = container.read(setReminderFullDetailsProvider);

      await expectLater(setFullDetails(false), throwsA(isA<AppLockRequired>()));
      expect((await repository.load()).fullDetails, isTrue);

      expect(await lock.unlock('Fictional test'), isTrue);
      await setFullDetails(false);
      expect((await repository.load()).fullDetails, isFalse);
    },
  );
}
