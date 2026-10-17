import 'app_lock_controller.dart';

/// Headless engines have no foreground unlock. The policy gate is held only
/// through the short care transaction, never through authentication or OS
/// projection publication. Enabling lock waits for an admitted transaction.
class AccessGate {
  const AccessGate(this.policy);
  final AppLockPolicyStore policy;
  Future<void> requireHeadlessAdmission() => policy.gate.run(() async {
    final current = await policy.loadInsideGate();
    if (current.enabled) throw const AppLockRequired();
  });

  Future<T> runHeadless<T>(Future<T> Function() publish) =>
      policy.gate.run(() async {
        final current = await policy.loadInsideGate();
        if (current.enabled) throw const AppLockRequired();
        return publish();
      });
}
