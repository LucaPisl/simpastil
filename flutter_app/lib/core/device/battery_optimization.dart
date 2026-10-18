import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

/// Whether Android lets Simpastil run in the background without battery
/// limits. Battery savers can delay or drop scheduled reminders, so setup and
/// reminder settings say so and offer the exemption.
abstract class BatteryOptimization {
  const BatteryOptimization();

  /// True when the system limits Simpastil in the background. Never true off
  /// Android, and never true when the answer is unknown: an unclear status is
  /// not a reason to worry anyone.
  Future<bool> isRestricted();

  /// Asks the system to stop limiting Simpastil (it shows its own dialog) and
  /// returns whether it is now unrestricted.
  Future<bool> requestUnrestricted();
}

/// The Android implementation, over the `ignoreBatteryOptimizations`
/// permission (granted means unrestricted). Other platforms have nothing to
/// ask, so they report no limits.
class PlatformBatteryOptimization extends BatteryOptimization {
  const PlatformBatteryOptimization();

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool> isRestricted() async {
    if (!_supported) return false;
    try {
      return !await Permission.ignoreBatteryOptimizations.isGranted;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> requestUnrestricted() async {
    if (!_supported) return true;
    try {
      return (await Permission.ignoreBatteryOptimizations.request()).isGranted;
    } on Object {
      return false;
    }
  }
}

/// Replaced in tests with a fake.
final batteryOptimizationProvider = Provider<BatteryOptimization>(
  (ref) => const PlatformBatteryOptimization(),
);
