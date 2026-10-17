import 'reminder_readiness.dart';

/// One word describing whether reminders can reach this phone.
///
/// It only reads facts that already exist (Android permissions and the last
/// coverage report); it never schedules, cancels or re-plans anything.
enum ReminderStatusKind {
  /// Permissions are still being read.
  checking,

  /// Notifications and exact alarms are allowed and coverage is healthy.
  on,

  /// Android notifications are off for the app: nothing will appear.
  needsPermission,

  /// Notifications are allowed but exact alarms are not: they may be late.
  mayBeLate,

  /// Permissions are fine but the last reconciliation could not schedule
  /// every reminder.
  someMissing,

  /// This platform cannot report or deliver reminders.
  unavailable,
}

ReminderStatusKind reminderStatusOf({
  required ReminderPermissions? permissions,
  bool coverageDegraded = false,
}) {
  if (permissions == null) return ReminderStatusKind.checking;
  return switch (permissions.problem) {
    ReminderReadinessProblem.platformUnavailable =>
      ReminderStatusKind.unavailable,
    ReminderReadinessProblem.denied => ReminderStatusKind.needsPermission,
    ReminderReadinessProblem.exactUnavailable => ReminderStatusKind.mayBeLate,
    ReminderReadinessProblem.schedulingFailed => ReminderStatusKind.someMissing,
    null =>
      coverageDegraded ? ReminderStatusKind.someMissing : ReminderStatusKind.on,
  };
}
