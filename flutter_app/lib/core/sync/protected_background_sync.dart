import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../auth/credential_refresh_coordinator.dart';
import '../auth/credential_refresh_factory.dart';
import '../auth/installation_key_repository.dart';
import '../auth/protected_credentials_repository.dart';
import '../auth/scoped_token_service.dart';
import '../db/database.dart';
import '../doses/auto_miss_sweeper.dart';
import '../inventory/inventory_service.dart';
import '../notifications/notification_service.dart';
import '../projections/projection_effects_gate.dart';
import '../projections/projection_identity.dart';
import '../projections/projection_reconciler.dart';
import '../projections/reminder_reconcile_runner.dart';
import '../projections/reminder_retry.dart';
import '../session/session_generation_repository.dart';
import '../utils/app_logger.dart';
import '../widget/widget_snapshot.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import 'sync_error_classifier.dart';
import 'sync_service.dart';
import 'sync_write_scope.dart';

typedef BackgroundClientFactory =
    ApiClient Function(
      ScopedTokenService tokens,
      Future<CredentialRefreshCoordinator> Function() refresh,
      void Function() onAuthFailure,
    );

/// Headless sync has the same frozen authority and single-use refresh gate as
/// foreground sync. Compatibility preferences cannot adopt an account/server.
class ProtectedBackgroundSync {
  ProtectedBackgroundSync({
    required this.access,
    required this.credentials,
    required this.keys,
    Future<CredentialRefreshGate> Function()? refreshGate,
    BackgroundClientFactory? clientFactory,
    this.isOnline,
    this.publishEffects,
    this.retireEffects,
    this.recoverEffects,
    this.sweepMisses,
  }) : refreshGate = refreshGate ?? createNativeCredentialRefreshGate,
       clientFactory = clientFactory ?? _client;
  final WorkspaceAccessRepository access;
  final ProtectedCredentialsRepository credentials;
  final InstallationKeyRepository keys;
  final Future<CredentialRefreshGate> Function() refreshGate;
  final BackgroundClientFactory clientFactory;
  final Future<bool> Function()? isOnline;
  final Future<void> Function(WorkspaceContext context)? publishEffects;
  final Future<void> Function(ProjectionIdentity identity)? retireEffects;
  final Future<void> Function()? recoverEffects;

  /// Records overdue doses as missed just before the flush, so the new
  /// misses leave in the same request round as everything else.
  final Future<void> Function()? sweepMisses;

  static ApiClient _client(
    ScopedTokenService tokens,
    Future<CredentialRefreshCoordinator> Function() refresh,
    void Function() onAuthFailure,
  ) => ApiClient(
    baseUrl: '${tokens.endpoint}/api/v1',
    tokenService: tokens,
    onAuthFailure: onAuthFailure,
    scopedRefresh: refresh,
  );

  Future<bool> run() async {
    final capability = await access.currentNetworkCapability();
    try {
      await recoverEffects?.call();
    } on Object catch (error) {
      AppLogger.warning(
        'BackgroundSync',
        'Interrupted retirement unavailable: ${error.runtimeType}',
      );
    }
    if (capability == null) return false;
    final scope = SyncWriteScope(access: access, capability: capability);
    await scope.check(); // Refuse unresolved retained care before any request.
    final context = (await access.contextForOwner(capability.ownerId))!;
    final installation = await access.captureInstallation(capability.endpoint);
    if (installation == null || installation.networkEpoch != capability.epoch) {
      return false;
    }
    final tokens = ScopedTokenService(
      credentials: credentials,
      keys: keys,
      endpoint: capability.endpoint,
      capability: capability,
      installation: Future.value(installation),
    );
    if (!await tokens.isCurrent() || await tokens.readBundle() == null) {
      return false;
    }
    var accessRejected = false;
    final client = clientFactory(
      tokens,
      () async => createCredentialRefreshCoordinator(
        credentials: credentials,
        keys: keys,
        gate: await refreshGate(),
        endpoint: capability.endpoint,
        capability: capability,
      ),
      () => accessRejected = true,
    );
    try {
      if (client.networkCapability != capability) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.staleGrant,
        );
      }
      final sync = SyncService(
        db: access.database,
        dio: client.dio,
        writeScope: scope,
        isOnline: isOnline,
      );
      try {
        try {
          await sweepMisses?.call();
        } on Object catch (error) {
          AppLogger.warning(
            'BackgroundSync',
            'Missed-dose sweep unavailable: ${error.runtimeType}',
          );
        }
        await sync.flushPending(userId: capability.ownerId);
        await scope.check();
        if (!await sync.pullFromServer(userId: capability.ownerId)) {
          return false;
        }
      } on SyncBusyException {
        // The foreground app is syncing and publishes its own effects.
        AppLogger.debug('BackgroundSync', 'Skipped: sync already running');
        return true;
      }
      await scope.check();
      try {
        await publishEffects?.call(context);
      } on Object catch (error) {
        AppLogger.warning(
          'BackgroundSync',
          'Optional projections unavailable: ${error.runtimeType}',
        );
      }
      await scope.check();
      return true;
    } finally {
      client.dio.close(force: true);
      if (accessRejected) {
        try {
          await retireEffects?.call(ProjectionIdentity.fromContext(context));
        } on Object catch (error) {
          AppLogger.warning(
            'BackgroundSync',
            'Captured retirement unavailable: ${error.runtimeType}',
          );
        }
      }
    }
  }
}

Future<void> retireBackgroundProjections({
  required Future<SharedPreferences> Function() loadPreferences,
  required Future<void> Function(SharedPreferences) retireReminders,
  required Future<void> Function() retireWidget,
}) async {
  try {
    await retireReminders(await loadPreferences());
  } finally {
    await retireWidget();
  }
}

/// The one-off retry after a Taken/Skip action whose reminder pass failed or
/// was busy. Runs only the all-workspace reminder pass: no network, no sync.
/// Every grant is rechecked by the pass itself.
///
/// Returns true when the task is finished and false only when WorkManager
/// should run it again, which happens only for a busy pass (or a thrown
/// error) and at most [reminderRetryMaxAttempts] times in a row. A signed-out
/// phone, no ready workspace or a degraded one is final: the periodic sync and
/// the next foreground trigger own those.
Future<bool> runProtectedReminderRetry({
  AppDatabase? db,
  ProjectionReconciler? reconciler,
  SharedPreferences? preferences,
}) async {
  final database = reconciler == null ? (db ?? AppDatabase()) : null;
  final ownDb = reconciler == null && db == null;
  SharedPreferences? prefs = preferences;
  try {
    prefs ??= await SharedPreferences.getInstance();
    await prefs.reload();
    var busy = false;
    try {
      final ProjectionReconciler pass;
      if (reconciler != null) {
        pass = reconciler;
      } else {
        final access = WorkspaceAccessRepository(
          database!,
          effectsGate: privateProjectionEffectsGate,
        );
        await NotificationService.initializeTimeZones();
        pass = ProjectionReconciler(
          database: database,
          access: access,
          effectsGate: privateProjectionEffectsGate,
          preferences: prefs,
          generations: SessionGenerationRepository(prefs, access: access),
          platform: NotificationService(),
          platformKind: ProjectionReconciler.currentPlatformKind,
        );
      }
      final result = await pass.reconcileAll(
        buildKey: await ReminderTriggerGuard.currentBuildKey(),
      );
      busy = result.busy;
    } on Object catch (error) {
      AppLogger.warning(
        'BackgroundSync',
        'Reminder retry unavailable: ${error.runtimeType}',
      );
      busy = true;
    }
    return !await reminderRetryShouldRepeat(prefs, busy: busy);
  } on Object {
    return true;
  } finally {
    if (ownDb) {
      try {
        await database?.close();
      } on Object {
        /* Failed protected open remains unavailable. */
      }
    }
  }
}

Future<bool> runProtectedBackgroundSync({AppDatabase? db}) async {
  final database = db ?? AppDatabase();
  final ownDb = db == null;
  try {
    final access = WorkspaceAccessRepository(
      database,
      effectsGate: privateProjectionEffectsGate,
    );
    final credentials = ProtectedCredentialsRepository(
      access: access,
      store: const SecureCredentialSlotStore(),
    );
    final keys = InstallationKeyRepository(
      access: access,
      store: const SecureCredentialSlotStore(),
    );
    return await ProtectedBackgroundSync(
      access: access,
      credentials: credentials,
      keys: keys,
      sweepMisses: () async {
        await AutoMissSweeper(
          db: database,
          access: access,
          preferences: await SharedPreferences.getInstance(),
        ).sweep();
      },
      recoverEffects: () => retireBackgroundProjections(
        loadPreferences: SharedPreferences.getInstance,
        retireReminders: (prefs) async {
          await ProjectionReconciler(
            database: database,
            access: access,
            effectsGate: privateProjectionEffectsGate,
            preferences: prefs,
            generations: SessionGenerationRepository(prefs, access: access),
            platform: NotificationService(),
            platformKind: ProjectionReconciler.currentPlatformKind,
          ).retireUnavailable();
        },
        retireWidget: () => retireUnavailableWidgetSnapshot(access: access),
      ),
      retireEffects: (identity) => retireBackgroundProjections(
        loadPreferences: SharedPreferences.getInstance,
        retireReminders: (prefs) async {
          await ProjectionReconciler(
            database: database,
            access: access,
            effectsGate: privateProjectionEffectsGate,
            preferences: prefs,
            generations: SessionGenerationRepository(prefs, access: access),
            platform: NotificationService(),
            platformKind: ProjectionReconciler.currentPlatformKind,
          ).retire(identity);
        },
        retireWidget: () =>
            clearWidgetSnapshot(identity: identity, access: access),
      ),
      publishEffects: (context) async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        final identity = ProjectionIdentity.fromContext(context);
        Future<void> attempt(Future<void> Function() effect) async {
          await access.requireCurrent(context);
          try {
            await effect();
          } on Object catch (error) {
            AppLogger.warning(
              'BackgroundSync',
              'Projection unavailable: ${error.runtimeType}',
            );
          }
        }

        await attempt(() async {
          await NotificationService.initializeTimeZones();
          await access.requireCurrent(context);
          await ProjectionReconciler(
            database: database,
            access: access,
            effectsGate: privateProjectionEffectsGate,
            preferences: prefs,
            generations: SessionGenerationRepository(prefs, access: access),
            platform: NotificationService(),
            platformKind: ProjectionReconciler.currentPlatformKind,
          ).reconcileAll(
            buildKey: await ReminderTriggerGuard.currentBuildKey(),
          );
        });
        await attempt(
          () => InventoryService(
            database,
            access: access,
            context: context,
            preferences: prefs,
          ).checkAllPillsStock(),
        );
        await attempt(
          () => publishWidgetSnapshot(
            db: database,
            access: access,
            projectionIdentity: identity,
          ),
        );
      },
    ).run();
  } on Object catch (error) {
    AppLogger.warning(
      'BackgroundSync',
      'Run unavailable: ${error.runtimeType}',
    );
    return false;
  } finally {
    if (ownDb) {
      try {
        await database.close();
      } on Object {
        /* Failed protected open remains unavailable. */
      }
    }
  }
}

/// The periodic missed-dose pass. It needs no network and no sign-in, so a
/// local-only or offline phone records misses on time too. When it records
/// something it lets reminders and the widget follow, because a missed dose
/// must stop alerting.
///
/// Returns true even after a failure: the next period tries again, and a
/// retry storm would only drain the battery.
Future<bool> runProtectedAutoMiss({
  AppDatabase? db,
  SharedPreferences? preferences,
  DateTime Function()? clock,
  Future<void> Function(AppDatabase, WorkspaceAccessRepository)? publish,
}) async {
  AppDatabase? database = db;
  final ownDb = db == null;
  try {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    await prefs.reload();
    if (!AutoMissSweeper.anyEnabled(prefs)) return true;
    database ??= AppDatabase();
    final access = WorkspaceAccessRepository(
      database,
      effectsGate: privateProjectionEffectsGate,
    );
    final result = await AutoMissSweeper(
      db: database,
      access: access,
      preferences: prefs,
      clock: clock,
    ).sweep();
    if (result.recorded > 0) {
      await (publish ?? _publishAfterMisses)(database, access);
    }
    return true;
  } on Object catch (error) {
    AppLogger.warning(
      'BackgroundSync',
      'Missed-dose pass unavailable: ${error.runtimeType}',
    );
    return true;
  } finally {
    if (ownDb) {
      try {
        await database?.close();
      } on Object {
        /* Failed protected open remains unavailable. */
      }
    }
  }
}

Future<void> _publishAfterMisses(
  AppDatabase database,
  WorkspaceAccessRepository access,
) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  try {
    await NotificationService.initializeTimeZones();
    await ProjectionReconciler(
      database: database,
      access: access,
      effectsGate: privateProjectionEffectsGate,
      preferences: prefs,
      generations: SessionGenerationRepository(prefs, access: access),
      platform: NotificationService(),
      platformKind: ProjectionReconciler.currentPlatformKind,
    ).reconcileAll(buildKey: await ReminderTriggerGuard.currentBuildKey());
  } on Object catch (error) {
    AppLogger.warning(
      'BackgroundSync',
      'Reminders after missed doses unavailable: ${error.runtimeType}',
    );
  }
  try {
    await publishWidgetSnapshot(db: database, access: access);
  } on Object catch (error) {
    AppLogger.warning(
      'BackgroundSync',
      'Widget after missed doses unavailable: ${error.runtimeType}',
    );
  }
}
