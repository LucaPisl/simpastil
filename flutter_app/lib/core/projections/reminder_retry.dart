import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../utils/app_logger.dart';

/// WorkManager task that re-runs the all-workspace reminder pass.
const reminderRetryTaskName = 'reminderReconcile';
const reminderRetryUniqueName = 'pill_tracker_reminder_retry';

/// How long a Taken/Skip action keeps retrying in its own process before it
/// hands the work to a one-off background task.
const reminderActionRetryDelays = [Duration(seconds: 2), Duration(seconds: 8)];

/// Delay before the handed-off task first runs.
const reminderRetryTaskDelay = Duration(seconds: 30);

/// Queues the one-off task. A task already queued is kept (every pass
/// reconciles every workspace), so a burst of failed actions leaves exactly one
/// retry and never pushes it back.
Future<void> scheduleReminderRetryTask(Duration delay) =>
    Workmanager().registerOneOffTask(
      reminderRetryUniqueName,
      reminderRetryTaskName,
      initialDelay: delay,
      existingWorkPolicy: ExistingWorkPolicy.keep,
    );

/// Counts consecutive busy runs of the retry task. workmanager 0.6.0 does not
/// expose the run attempt count to Dart, so the bound is stored.
const reminderRetryAttemptsKey = 'reminder_retry_attempts';
const reminderRetryMaxAttempts = 3;

/// Whether WorkManager should run the retry task again. Only a busy pass is
/// worth another run, and never more than [reminderRetryMaxAttempts] in a row:
/// a signed-out phone, a denied permission or an unready workspace would fail
/// the same way next time. Returning false ends the task as done.
Future<bool> reminderRetryShouldRepeat(
  SharedPreferences preferences, {
  required bool busy,
}) async {
  try {
    if (!busy) {
      await preferences.remove(reminderRetryAttemptsKey);
      return false;
    }
    final attempts = (preferences.getInt(reminderRetryAttemptsKey) ?? 0) + 1;
    if (attempts >= reminderRetryMaxAttempts) {
      await preferences.remove(reminderRetryAttemptsKey);
      return false;
    }
    await preferences.setInt(reminderRetryAttemptsKey, attempts);
    return true;
  } on Object {
    // Without a counter a repeat could be unbounded.
    return false;
  }
}

/// Runs [attempt] until it reports a healthy result, waiting between attempts
/// and giving up when [stillCurrent] says the session or grant moved on. When
/// the attempts run out the work is handed to [handOff], so a busy or failed
/// reconcile after a dose action is never simply dropped.
///
/// Returns true when an attempt came back healthy.
Future<bool> retryReconcileAfterAction({
  required Future<bool> Function() attempt,
  required Future<bool> Function() stillCurrent,
  required Future<void> Function(Duration delay) handOff,
  List<Duration> delays = reminderActionRetryDelays,
  Future<void> Function(Duration)? wait,
}) async {
  final pause = wait ?? Future<void>.delayed;
  for (var index = 0; ; index++) {
    if (await attempt()) return true;
    if (index >= delays.length) break;
    await pause(delays[index]);
    // The session owner and generation are rechecked before every new attempt.
    if (!await stillCurrent()) return false;
  }
  if (!await stillCurrent()) return false;
  try {
    await handOff(reminderRetryTaskDelay);
  } on Object catch (error) {
    AppLogger.warning(
      'ReminderRetry',
      'Retry task not queued: ${error.runtimeType}',
    );
  }
  return false;
}
