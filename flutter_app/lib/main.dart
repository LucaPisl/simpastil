import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';
import 'package:workmanager/workmanager.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'core/inventory/inventory_service.dart';
import 'core/widget/widget_action_handler.dart';
import 'core/widget/widget_snapshot.dart';
import 'core/diagnostics/diagnostic_event.dart';
import 'core/diagnostics/diagnostics_recorder.dart';
import 'core/diagnostics/diagnostics_session.dart';
import 'core/utils/app_logger.dart';
import 'core/db/database.dart';
import 'core/doses/auto_miss_sweeper.dart';
import 'core/notifications/foreground_care_signal.dart';
import 'core/notifications/notification_action_handler.dart';
import 'core/notifications/notification_plugin.dart';
import 'core/notifications/notification_service.dart';
import 'core/projections/care_projection_coordinator.dart';
import 'core/session/session_runtime_coordinator.dart';
import 'core/protection/app_lock_controller.dart';
import 'core/startup/optional_capability.dart';
import 'core/startup/foreground_session.dart';
import 'core/backup/backup_providers.dart';
import 'core/storage/shared_preferences_provider.dart';
import 'core/sync/protected_background_sync.dart';
import 'core/server/server_config_notifier.dart';
import 'core/workspace/workspace_context.dart';
import 'features/updates/data/github_release_check.dart';
import 'core/projections/reminder_reconcile_runner.dart';
import 'core/projections/reminder_retry.dart';
import 'core/workspace/workspace_provider.dart';
import 'l10n/app_localizations.dart';
import 'shared/app/simpastil_app.dart';
import 'shared/app/startup_splash.dart';
import 'shared/app/widget_review_handoff.dart';

export 'shared/app/simpastil_app.dart' show SimpastilApp;

// ── WorkManager background task dispatcher ────────────────────────────────────

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask(
    (taskName, inputData) => switch (taskName) {
      reminderRetryTaskName => runProtectedReminderRetry(),
      autoMissTaskName => runProtectedAutoMiss(),
      _ => runProtectedBackgroundSync(),
    },
  );
}

// ── Notification tap stream ────────────────────────────────────────────────────

/// Preserve the delivered response until the foreground handoff consumes it.
/// Neither a cold launch nor a lock wait may reduce identity to a route string.
final _notificationResponseNotifier = ValueNotifier<NotificationReviewRequest?>(
  null,
);
int _notificationTapGeneration = 0;
bool _foregroundApplicationInitializationInProgress = false;
final _startupLifecycleMonitor = StartupLifecycleMonitor();

/// Remembers background transitions while the startup splash is mounted and
/// the protected runtime has not registered its own observer yet.
class StartupLifecycleMonitor with WidgetsBindingObserver {
  bool _observing = false;
  bool _backgrounded = false;

  void start() {
    if (_observing) return;
    _observing = true;
    _backgrounded = _isBackground(WidgetsBinding.instance.lifecycleState);
    WidgetsBinding.instance.addObserver(this);
  }

  bool takeBackgrounded() {
    final result = _backgrounded;
    _backgrounded = false;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    return result;
  }

  void dispose() {
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    _observing = false;
    _backgrounded = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isBackground(state)) _backgrounded = true;
  }

  static bool _isBackground(AppLifecycleState? state) =>
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.detached;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _startupLifecycleMonitor.start();
  unawaited(DiagnosticsSession.shared.start());

  FlutterError.onError = (details) {
    AppLogger.error(
      'FlutterError',
      details.exception.toString(),
      null,
      details.stack,
    );
    DiagnosticsRecorder.shared.recordError(
      DiagnosticKind.flutterError,
      details.exception,
      details.stack,
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.error('PlatformDispatcher', error.toString(), error, stack);
    DiagnosticsRecorder.shared.recordError(
      DiagnosticKind.uncaughtError,
      error,
      stack,
    );
    return true;
  };

  // Render a first frame while protected storage and session restoration run.
  // Care remains behind the existing readiness and app-lock gates.
  runApp(const StartupSplash());
  await _initializeForegroundApplication();
}

void _retryForegroundApplicationInitialization() {
  runApp(const StartupSplash());
  unawaited(_initializeForegroundApplication());
}

Future<void> _initializeForegroundApplication() async {
  if (_foregroundApplicationInitializationInProgress) return;
  _foregroundApplicationInitializationInProgress = true;
  try {
    await _initializeForegroundApplicationOnce();
  } finally {
    _foregroundApplicationInitializationInProgress = false;
  }
}

Future<void> _initializeForegroundApplicationOnce() async {
  // Load SharedPreferences before creating providers so that
  // ServerConfigNotifier.build() can read the URL synchronously.
  late final SharedPreferences prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } on Object catch (error, stack) {
    AppLogger.warning(
      'Startup',
      'Preferences unavailable: ${error.runtimeType}',
    );
    DiagnosticsRecorder.shared.recordError(
      DiagnosticKind.startupFailed,
      error,
      stack,
      component: DiagnosticComponent.startup,
    );
    runApp(
      const StartupSplash(
        failed: true,
        onRetry: _retryForegroundApplicationInitialization,
      ),
    );
    return;
  }

  // Build the container and restore required auth state. Optional plugins and
  // permissions are deliberately deferred until after the first frame.
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  restoreSessionWhenCareRecovers(container);
  try {
    await restoreForegroundSession(container);
  } on Object catch (error, stack) {
    // Still open the established recovery/login shell. It keeps care behind
    // the existing readiness and app-lock checks and lets the user retry there.
    AppLogger.warning(
      'Startup',
      'Session restoration deferred: ${error.runtimeType}',
    );
    DiagnosticsRecorder.shared.recordError(
      DiagnosticKind.startupFailed,
      error,
      stack,
      component: DiagnosticComponent.startup,
    );
  }

  // The protected shell does not wait on optional notification, widget, or
  // background-worker initialization.
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: SimpastilRuntime(
        startupLifecycleMonitor: _startupLifecycleMonitor,
      ),
    ),
  );
}

// ── Notification initialisation ───────────────────────────────────────────────

Future<void> _initNotifications() async {
  final initialGeneration = _notificationTapGeneration;
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidSettings);

  await notificationsPlugin.initialize(
    initSettings,
    onDidReceiveNotificationResponse: _onNotificationTap,
    onDidReceiveBackgroundNotificationResponse: _onBackgroundNotificationTap,
  );

  // Handle taps that launched the app from a terminated state.
  final launchDetails = await notificationsPlugin
      .getNotificationAppLaunchDetails();
  final response = launchDetails?.notificationResponse;
  if (launchDetails?.didNotificationLaunchApp == true &&
      response != null &&
      initialGeneration == _notificationTapGeneration) {
    _notificationResponseNotifier.value = NotificationReviewRequest(
      response,
      isInitial: true,
    );
  }
}

/// Called when the user taps a notification while the app is in the foreground
/// or background (but not terminated).
@pragma('vm:entry-point')
void _onNotificationTap(NotificationResponse response) {
  _notificationTapGeneration++;
  _notificationResponseNotifier.value = NotificationReviewRequest(response);
}

/// Called when the user taps a notification while the app is terminated.
/// Runs in a background isolate — cannot access Dart globals from the main
/// isolate. The launch-details check above handles this case at startup.
@pragma('vm:entry-point')
void _onBackgroundNotificationTap(NotificationResponse response) {
  unawaited(handleBackgroundNotificationAction(response));
}

// ── ScaffoldMessenger key (root-level) ────────────────────────────────────────

/// Keeps runtime feedback attached to the application's root messenger.
final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

// ── Foreground runtime ────────────────────────────────────────────────────────

/// Native preparation and protected effects used by the foreground shell.
/// Each callback resolves its authority through the existing protected services.
class ForegroundProjectionOperations {
  const ForegroundProjectionOperations({
    required this.initializeNotifications,
    required this.initializeBackgroundSync,
    required this.initializeWidget,
    required this.reconcileReminders,
    required this.refreshWidget,
    required this.checkStock,
    this.sweepAutoMiss = _noSweep,
  });
  final Future<void> Function() initializeNotifications;
  final Future<void> Function() initializeBackgroundSync;
  final Future<void> Function() initializeWidget;
  final Future<void> Function() reconcileReminders;
  final Future<void> Function() refreshWidget;
  final Future<void> Function() checkStock;

  /// Records overdue doses as missed; reminders and the widget follow through
  /// the care-change coordinator.
  final Future<void> Function() sweepAutoMiss;
}

Future<void> _noSweep() async {}

final foregroundProjectionOperationsProvider =
    Provider<ForegroundProjectionOperations>((ref) {
      var workManagerInitialized = false;
      var disposed = false;
      var notificationsReady = false;
      var widgetReady = false;
      CareProjectionCoordinator? coordinator;
      Future<void>? sweeping;
      late final ForegroundProjectionOperations operations;
      ref.onDispose(() {
        disposed = true;
        unawaited(coordinator?.close());
      });
      void watchCommittedCare() {
        if (disposed) return;
        coordinator ??= CareProjectionCoordinator(
          database: ref.read(databaseProvider),
          refresh: () async {
            if (disposed) return;
            await Future.wait([
              if (notificationsReady) operations.reconcileReminders(),
              if (widgetReady) operations.refreshWidget(),
            ]);
            if (notificationsReady && widgetReady && !disposed) {
              await ref.read(retryRestoreProjectionsProvider)();
            }
          },
        );
        coordinator!.start();
      }

      operations = ForegroundProjectionOperations(
        initializeNotifications: () async {
          await NotificationService.initializeTimeZones();
          await _initNotifications();
          notificationsReady = true;
          watchCommittedCare();
        },
        initializeBackgroundSync: () async {
          if (!workManagerInitialized) {
            await Workmanager().initialize(
              callbackDispatcher,
              isInDebugMode: false,
            );
            workManagerInitialized = true;
          }
          await Workmanager().registerPeriodicTask(
            'pill_tracker_background_sync',
            'backgroundSync',
            frequency: const Duration(minutes: 15),
            constraints: Constraints(networkType: NetworkType.connected),
            // `update` rewrites the already-scheduled periodic work in place, so a
            // changed frequency or constraint in a newer build reaches upgraded
            // installs; `keep` would pin the first-ever specification forever.
            existingWorkPolicy: ExistingWorkPolicy.update,
          );
          // Recording a missed dose needs no network, so it has its own
          // task: a local-only or offline phone must record on time too.
          await Workmanager().registerPeriodicTask(
            autoMissTaskUniqueName,
            autoMissTaskName,
            frequency: const Duration(minutes: 15),
            existingWorkPolicy: ExistingWorkPolicy.update,
          );
        },
        initializeWidget: () async {
          await HomeWidget.registerInteractivityCallback(
            widgetBackgroundCallback,
          );
          widgetReady = true;
          watchCommittedCare();
        },
        reconcileReminders: () =>
            ReminderTriggerGuard(SharedPreferences.getInstance).runForeground(
              ref.read(reminderReconcileRunnerProvider),
              refreshActiveActions: ref
                  .read(appLockPolicyStoreProvider)
                  .snapshot()
                  .enabled,
            ),
        refreshWidget: () async {
          final db = ref.read(databaseProvider);
          final access = ref.read(workspaceAccessRepositoryProvider);
          await retireUnavailableWidgetSnapshot(access: access);
          await publishWidgetSnapshot(db: db, access: access);
        },
        sweepAutoMiss: () {
          // Resume, the midnight timer and a workspace change can arrive
          // together; they share one run.
          return sweeping ??= () async {
            try {
              await AutoMissSweeper(
                db: ref.read(databaseProvider),
                access: ref.read(workspaceAccessRepositoryProvider),
                preferences: await SharedPreferences.getInstance(),
              ).sweep();
            } finally {
              sweeping = null;
            }
          }();
        },
        checkStock: () => InventoryService(
          ref.read(databaseProvider),
          access: ref.read(workspaceAccessRepositoryProvider),
        ).checkAllPillsStock(),
      );
      return operations;
    });

class SimpastilRuntime extends ConsumerStatefulWidget {
  const SimpastilRuntime({
    super.key,
    this.clock = DateTime.now,
    this.startupLifecycleMonitor,
  });

  final DateTime Function() clock;
  final StartupLifecycleMonitor? startupLifecycleMonitor;

  @override
  ConsumerState<SimpastilRuntime> createState() => _SimpastilAppState();
}

class _SimpastilAppState extends ConsumerState<SimpastilRuntime>
    with WidgetsBindingObserver {
  bool _foreground = true;
  Object? _lastWorkspaceKey;
  Timer? _midnightReconcileTimer;
  Timer? _autoMissTimer;
  ForegroundCareSignal? _careSignal;

  @override
  void initState() {
    super.initState();
    // A notification button that ran in a headless engine nudges the visible
    // app, which would otherwise show stale care until it next resumes.
    _careSignal = ForegroundCareSignal.listen(() {
      if (mounted && _foreground) {
        ref.read(databaseProvider).refreshExternalChanges();
      }
    });
    final initialLifecycleState = WidgetsBinding.instance.lifecycleState;
    _foreground =
        initialLifecycleState != AppLifecycleState.hidden &&
        initialLifecycleState != AppLifecycleState.paused &&
        initialLifecycleState != AppLifecycleState.detached;
    final returnedFromBackgroundDuringStartup =
        widget.startupLifecycleMonitor?.takeBackgrounded() ?? false;
    // Register this state as a lifecycle observer for didChangeAppLifecycleState.
    WidgetsBinding.instance.addObserver(this);
    if (!_foreground) {
      // Runtime can mount after the initial pause event, such as after a
      // startup splash restores the session while the app is backgrounded.
      unawaited(_attempt(ref.read(sessionRuntimeCoordinatorProvider).pause));
    } else if (returnedFromBackgroundDuringStartup) {
      // Startup may finish after the app has already resumed. The splash had
      // no providers to refresh, so replay the foreground handoff after this
      // runtime has completed its initial frame.
      _foreground = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        didChangeAppLifecycleState(AppLifecycleState.resumed);
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
    // Optional plugins and permissions must not delay the shell's first frame.
    _armMidnightReconcile();
    _armAutoMissSweep();
  }

  void _initializeOptionalCapabilities(AppLocalizations localizations) {
    final notifier = ref.read(optionalCapabilityProvider.notifier);
    final operations = ref.read(foregroundProjectionOperationsProvider);
    unawaited(
      notifier.initialize(
        id: 'notifications',
        label: localizations.core_notifChannelName,
        operation: () async {
          await operations.initializeNotifications();
          if (!mounted || !_foreground) return;
          await Future.wait([
            Future<void>.sync(operations.reconcileReminders),
            Future<void>.sync(operations.checkStock),
          ]);
        },
      ),
    );

    unawaited(
      notifier.initialize(
        id: 'background_sync',
        label: 'Background sync',
        operation: operations.initializeBackgroundSync,
      ),
    );

    unawaited(
      notifier.initialize(
        id: 'home_widget',
        label: 'Home-screen widget',
        operation: () async {
          await operations.initializeWidget();
          if (!mounted || !_foreground) return;
          await operations.refreshWidget();
        },
      ),
    );
  }

  Future<void> _attempt(Future<void> Function() operation) async {
    try {
      await operation();
    } on Object catch (error) {
      AppLogger.warning(
        'Main',
        'Foreground operation unavailable: ${error.runtimeType}',
      );
    }
  }

  /// Phones with no server ask GitHub for the latest release, at most once a
  /// day; with a server, the server's answer arrives with the capabilities.
  void _checkForUpdate() {
    if (!mounted || !_foreground) return;
    if (ref.read(serverConfigProvider) != null) return;
    unawaited(
      _attempt(
        () => ref
            .read(gitHubReleaseCheckProvider)
            .runIfDue(ref.read(sharedPreferencesProvider)),
      ),
    );
  }

  void _refreshReadyProjections() {
    if (!mounted || !_foreground) return;
    final capabilities = ref.read(optionalCapabilityProvider);
    final operations = ref.read(foregroundProjectionOperationsProvider);
    // Overdue doses are recorded first so the reminder and widget passes below
    // (and the care-change refresh after them) already see them as missed.
    unawaited(_attempt(operations.sweepAutoMiss));
    // Each protected service captures and rechecks its own authority. Failure
    // of one optional platform must not suppress the others.
    if (capabilities.isReady('notifications')) {
      unawaited(_attempt(operations.reconcileReminders));
      unawaited(_attempt(operations.checkStock));
    }
    if (capabilities.isReady('home_widget')) {
      unawaited(_attempt(operations.refreshWidget));
    }
  }

  /// A dose turns overdue while the app is open, so the foreground checks
  /// every minute (a cheap preference read when nobody uses the setting).
  void _armAutoMissSweep() {
    _autoMissTimer?.cancel();
    if (!mounted || !_foreground) return;
    _autoMissTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted || !_foreground) return;
      unawaited(
        _attempt(
          ref.read(foregroundProjectionOperationsProvider).sweepAutoMiss,
        ),
      );
    });
  }

  void _armMidnightReconcile() {
    _midnightReconcileTimer?.cancel();
    if (!mounted || !_foreground) return;
    final now = widget.clock();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    _midnightReconcileTimer = Timer(nextMidnight.difference(now), () {
      _refreshReadyProjections();
      if (mounted && _foreground) _armMidnightReconcile();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.resumed) {
      final returnedFromBackground = !_foreground;
      _foreground = true;
      _armMidnightReconcile();
      _armAutoMissSweep();
      if (!returnedFromBackground) return;
      // A headless engine may have committed care or revoked access while away.
      // Refresh those reads even when optional native projections are unavailable.
      ref.read(databaseProvider).refreshExternalChanges();
      // The network coordinator owns connected session eligibility. Local
      // projection recovery remains available without an authenticated account.
      unawaited(_attempt(ref.read(sessionRuntimeCoordinatorProvider).resume));
      // A failed startup must not permanently exclude the capability from
      // foreground recovery. One genuine background return retries degraded
      // services; an in-flight attempt is still joined, never overlapped.
      final optional = ref.read(optionalCapabilityProvider);
      for (final capability in optional.degraded) {
        unawaited(
          ref.read(optionalCapabilityProvider.notifier).retry(capability.id),
        );
      }
      _refreshReadyProjections();
      _checkForUpdate();
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (!_foreground) return;
      _foreground = false;
      _midnightReconcileTimer?.cancel();
      _autoMissTimer?.cancel();
      unawaited(_attempt(ref.read(sessionRuntimeCoordinatorProvider).pause));
    }
  }

  @override
  void dispose() {
    _careSignal?.close();
    _midnightReconcileTimer?.cancel();
    _autoMissTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<WorkspaceContext>>(workspaceContextProvider, (
      _,
      next,
    ) {
      if (next is! AsyncData<WorkspaceContext>) return;
      final workspace = next.value;
      final key = (
        workspace.workspaceId,
        workspace.ownerUserId,
        workspace.authorId,
        workspace.kind,
        workspace.accessEpoch,
        workspace.endpoint,
        workspace.sessionGeneration,
        workspace.networkEpoch,
      );
      if (key == _lastWorkspaceKey) return;
      _lastWorkspaceKey = key;
      _refreshReadyProjections();
    });

    return WidgetReviewHandoff(
      notifications: _notificationResponseNotifier,
      validateNotification: (response) => validateNotificationActionForReview(
        response,
        db: ref.read(databaseProvider),
        access: ref.read(workspaceAccessRepositoryProvider),
      ),
      dispatchNotification: (response, navigateTo) => handleNotificationAction(
        response,
        navigateTo,
        database: ref.read(databaseProvider),
        access: ref.read(workspaceAccessRepositoryProvider),
      ),
      validate: (uri) => validateWidgetActionForReview(
        uri,
        db: ref.read(databaseProvider),
        access: ref.read(workspaceAccessRepositoryProvider),
      ),
      child: SimpastilApp(
        scaffoldMessengerKey: _scaffoldMessengerKey,
        onLocalizationsReady: _initializeOptionalCapabilities,
      ),
    );
  }
}
