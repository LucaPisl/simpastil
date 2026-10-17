import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show Value;
import 'package:simpastil_storage/simpastil_storage.dart';

import '../../features/auth/auth_provider.dart';
import '../../features/pills/pill_provider.dart';
import '../../features/profiles/profile_provider.dart';
import '../auth/credential_refresh_factory.dart';
import '../db/database.dart';
import '../l10n/locale_provider.dart';
import '../projections/projection_effects_gate.dart';
import '../protection/app_lock_controller.dart';
import '../projections/projection_identity.dart';
import '../projections/projection_reconciler.dart';
import '../session/session_generation_repository.dart';
import '../session/session_runtime_coordinator.dart';
import '../startup/protection_readiness.dart';
import '../storage/appearance_preferences.dart';
import '../storage/portable_preference_writer.dart';
import '../storage/shared_preferences_provider.dart';
import '../sync/auto_sync_service.dart';
import '../theme/theme_provider.dart';
import '../widget/protected_widget_publisher.dart';
import '../widget/widget_snapshot.dart';
import '../workspace/workspace_provider.dart';
import '../workspace/workspace_context.dart';
import 'backup_file_access.dart';
import 'backup_import_session.dart';
import 'backup_service.dart';
import 'import_service.dart';

final backupFileAccessProvider = Provider<BackupFileAccess>(
  (_) => const AndroidBackupFileAccess(),
);
final backupProjectionEffectsGateProvider = Provider<ProjectionEffectsGate>(
  (_) => privateProjectionEffectsGate,
);
final backupWidgetPlatformProvider = Provider<WidgetProjectionPlatform>(
  (_) => NativeWidgetProjectionPlatform(),
);

/// A current-access check never substitutes for the operation-scoped lease.
final backupDisclosureCheckProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    ref
        .read(appLockControllerProvider.notifier)
        .captureAccess()
        .requireCurrent();
  },
);

/// Capture at operation/session creation, not at the final disclosure boundary.
/// SAF/Home invalidation cannot be repaired by silently capturing a new lease.
final backupInterfaceLeaseProvider = Provider<CaptureInterfaceAccess>(
  (ref) =>
      () => ref
          .read(appLockControllerProvider.notifier)
          .captureAccess()
          .requireCurrent,
);

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(
    database: ref.watch(databaseProvider),
    access: ref.watch(workspaceAccessRepositoryProvider),
    preferences: ref.watch(sharedPreferencesProvider),
    files: ref.watch(backupFileAccessProvider),
    beforeDisclosure: ref.watch(backupDisclosureCheckProvider),
    captureInterfaceAccess: ref.watch(backupInterfaceLeaseProvider),
  ),
);

typedef OpenBackupImport =
    Future<BackupImportSession> Function(
      SelectedBackupSource source, {
      String? password,
    });

/// Production binding for the reviewed backend. No activation can bypass the
/// selected-file fingerprint, runtime drain or native process-shared barriers.
final openBackupImportProvider = Provider<OpenBackupImport>(
  (ref) => (source, {password}) async {
    final requireInterfaceAccess = ref.read(backupInterfaceLeaseProvider)();
    requireInterfaceAccess();
    final database = ref.read(databaseProvider);
    final access = ref.read(workspaceAccessRepositoryProvider);
    final preferences = ref.read(sharedPreferencesProvider);
    final storage = await ref.read(localStorageServicesProvider.future);
    final local = await (database.select(
      database.careWorkspaces,
    )..where((w) => w.kind.equals('local'))).getSingleOrNull();
    final context = local == null
        ? null
        : await access.contextForOwner(local.ownerUserId);
    if (context == null) {
      throw const ImportFailure(ImportFailureCode.staleAccess);
    }
    final refreshGate = await ref.read(credentialRefreshGateProvider)();
    final runtime = ref.read(sessionRuntimeCoordinatorProvider);
    final autoSync = ref.read(autoSyncServiceProvider);
    SessionIdentity? priorRuntime;

    return BackupImportSession.open(
      backup: ref.read(backupServiceProvider),
      source: source,
      password: password,
      buildImport: (_, recheck) async => ImportService(
        database: database,
        access: access,
        preferences: preferences,
        context: context,
        requireInterfaceAccess: requireInterfaceAccess,
        store: storage.files,
        refreshGate: refreshGate,
        projectionGate: ref.read(backupProjectionEffectsGateProvider),
        preferenceGate: ref.read(portablePreferenceGateProvider),
        syncDirectory: const SimpastilStorage().syncDirectory,
        sourceRecheck: recheck,
        drainRuntime: () async {
          priorRuntime = runtime.activeIdentity;
          await runtime.pause();
          await autoSync.drain();
        },
        resumeRuntime: runtime.resume,
        afterFullActivation: (old, fresh) async {
          await ref.read(refreshRestoredPreferenceCachesProvider)(fresh);
          if (priorRuntime case final identity?) {
            final grant = old
                .where(
                  (g) =>
                      g.ownerUserId == identity.$1 &&
                      g.sessionGeneration == identity.$2,
                )
                .firstOrNull;
            await runtime.invalidate(
              captureActiveIdentity: false,
              identity: identity,
              projectionIdentity: grant == null
                  ? null
                  : ProjectionIdentity.fromContext(grant),
            );
          }
          return _finishRestoreProjections(ref, fresh);
        },
      ),
    );
  },
);

final refreshRestoredPreferenceCachesProvider =
    Provider<Future<void> Function(WorkspaceContext)>(
      (ref) => (fresh) async {
        // Use persisted values even if another restore preference still needs retry.
        ref.invalidate(localeNotifierProvider);
        ref.invalidate(appearanceRepositoryProvider);
        ref.invalidate(siblingDetectionModeProvider);
        ref.invalidate(prnInStatsProvider);
        ref.invalidate(prnInWidgetProvider);
        ref.invalidate(workspaceContextProvider);
        ref.invalidate(selectedProfileIdProvider);
        ref.invalidate(primaryProfileIdProvider);
        ref.invalidate(protectionReadinessProvider);
        await ref
            .read(authNotifierProvider.notifier)
            .refreshAfterCareReplacement(fresh);
      },
    );

Future<bool> _finishRestoreProjections(
  Ref ref,
  WorkspaceContext context,
) async {
  final database = ref.read(databaseProvider);
  final access = ref.read(workspaceAccessRepositoryProvider);
  final preferences = ref.read(sharedPreferencesProvider);
  final reconciler = ref.read(projectionReconcilerProvider);
  final platform = ref.read(backupWidgetPlatformProvider);
  final publisher = ProtectedWidgetPublisher(
    access: access,
    effectsGate: ref.read(backupProjectionEffectsGateProvider),
    platform: platform,
    build: (captured) => computeWidgetSnapshot(
      db: database,
      prefs: preferences,
      access: access,
      context: captured,
    ),
  );
  await reconciler.retireUnavailable();
  await publisher.retireUnavailable();
  final identity = ProjectionIdentity.fromContext(context);
  final report = await reconciler.reconcile(projectionIdentity: identity);
  final appearance = await AppearancePreferencesRepository(
    SharedAppearancePreferenceStorage(
      preferences,
      gate: ref.read(portablePreferenceGateProvider),
    ),
  ).load();
  await publisher.publish(identity, themeMode: appearance.mode.name);
  final marker = await platform.read(widgetProjectionIdentityKey);
  await access.requireCurrent(context);
  return report != null &&
      !report.degraded &&
      marker != null &&
      identity.owns(jsonDecode(marker));
}

/// Runs after both optional phone capabilities initialize, or on explicit retry.
/// A failure leaves protected retirement proof intact and does not alter care.
final retryRestoreProjectionsProvider = Provider<Future<bool> Function()>(
  (ref) => () async {
    final database = ref.read(databaseProvider);
    if (await (database.select(database.deviceRestoreIntents)
              ..where((r) => r.projectionsCompleted.equals(false))
              ..limit(1))
            .getSingleOrNull() ==
        null) {
      return true;
    }
    try {
      final access = ref.read(workspaceAccessRepositoryProvider);
      final context = await access.currentContext();
      if (!await _finishRestoreProjections(ref, context)) return false;
      await access.withGrant(context, () async {
        await (database.update(
          database.deviceRestoreIntents,
        )..where((r) => r.projectionsCompleted.equals(false))).write(
          const DeviceRestoreIntentsCompanion(
            projectionsCompleted: Value(true),
          ),
        );
      });
      return true;
    } catch (_) {
      return false;
    }
  },
);
