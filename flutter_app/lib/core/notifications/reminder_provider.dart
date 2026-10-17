import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';
import '../protection/app_lock_controller.dart';
import '../projections/projection_reconciler.dart';
import '../projections/projection_registry.dart';
import '../storage/shared_preferences_provider.dart';
import '../workspace/workspace_provider.dart';
import 'notification_service.dart';
import 'reminder_preferences.dart';
import 'reminder_readiness.dart';

final reminderPreferencesRepositoryProvider =
    FutureProvider<ReminderPreferencesRepository>((ref) async {
      final contextFuture = ref.watch(workspaceContextProvider.future);
      final database = ref.watch(databaseProvider);
      final access = ref.watch(workspaceAccessRepositoryProvider);
      final context = await contextFuture;
      await access.requireCurrent(context);
      return ReminderPreferencesRepository(
        database: database,
        access: access,
        context: context,
      );
    });

typedef SetReminderFullDetails = Future<void> Function(bool fullDetails);

/// Interface-locked settings write. The repository rechecks this captured
/// lease after resolving the workspace grant and immediately before commit.
final setReminderFullDetailsProvider = Provider<SetReminderFullDetails>((ref) {
  return (fullDetails) async {
    final lease = ref.read(appLockControllerProvider.notifier).captureAccess();
    lease.requireCurrent();
    final repository = await ref.read(
      reminderPreferencesRepositoryProvider.future,
    );
    lease.requireCurrent();
    await repository.setFullDetails(
      fullDetails,
      requireInterfaceAccess: lease.requireCurrent,
    );
    // The app's care projection coordinator watches deviceReminderSettings
    // and refreshes notification and widget projections from this commit.
    ref.invalidate(reminderPreferencesRepositoryProvider);
  };
});

final reminderReadinessServiceProvider =
    FutureProvider<ReminderReadinessService>((ref) async {
      final contextFuture = ref.watch(workspaceContextProvider.future);
      final database = ref.watch(databaseProvider);
      final access = ref.watch(workspaceAccessRepositoryProvider);
      final preferences = ref.watch(sharedPreferencesProvider);
      // Native plugin preparation remains optional. A service created too early
      // reports unavailable rather than permission or delivery success.
      final context = await contextFuture;
      await access.requireCurrent(context);
      return ReminderReadinessService(
        database: database,
        access: access,
        context: context,
        preferences: ProjectionRegistry(preferences),
        platform: NotificationService(),
      );
    });

final reminderReadinessProvider = FutureProvider.autoDispose<ReminderReadiness>(
  (ref) async {
    final service = await ref.watch(reminderReadinessServiceProvider.future);
    return service.inspect();
  },
);

/// Reads the last reminder coverage result for the currently authorized care
/// workspace. Auto-disposal refreshes it when the settings page is reopened.
final reminderCoverageProvider =
    FutureProvider.autoDispose<ProjectionReconciliationReport?>((ref) async {
      final lock = ref.watch(appLockControllerProvider);
      if (!lock.canAccess) throw const AppLockRequired();
      final lease = ref
          .read(appLockControllerProvider.notifier)
          .captureAccess();
      final contextFuture = ref.watch(workspaceContextProvider.future);
      final access = ref.watch(workspaceAccessRepositoryProvider);
      final preferences = ref.watch(sharedPreferencesProvider);
      final context = await contextFuture;
      lease.requireCurrent();
      await access.requireCurrent(context);
      await preferences.reload();
      lease.requireCurrent();
      await access.requireCurrent(context);
      final report = ProjectionReconciler.readStatus(
        preferences,
        context.ownerUserId,
      );
      lease.requireCurrent();
      await access.requireCurrent(context);
      if (report?.userId != context.ownerUserId ||
          report?.sessionGeneration != context.accessEpoch) {
        return null;
      }
      return report;
    });
