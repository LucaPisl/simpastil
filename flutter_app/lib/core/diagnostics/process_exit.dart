/// Why Android says the previous process ended, as a fixed name. Anything the
/// platform reports that is not on this list is read as [other].
class ProcessExit {
  const ProcessExit({required this.reason, required this.at});

  final String reason;
  final DateTime at;

  /// Endings that mean the person or the system chose to stop the app, not
  /// that it failed. They never raise a crash notice.
  static const benignReasons = {
    'user_requested',
    'user_stopped',
    'package_updated',
    'package_state_change',
    'permission_change',
    'freezer',
  };

  static const knownReasons = {
    'crash',
    'crash_native',
    'anr',
    'low_memory',
    'signaled',
    'initialization_failure',
    'excessive_resource_usage',
    'dependency_died',
    'other',
    'unknown',
    ...benignReasons,
  };

  bool get benign => benignReasons.contains(reason);
}
