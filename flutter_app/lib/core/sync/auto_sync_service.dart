import 'dart:async';
import 'dart:math' show min;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/app_logger.dart';
import '../projections/reminder_reconcile_runner.dart';
import '../projections/projection_identity.dart';
import '../session/session_generation_repository.dart';
import '../workspace/workspace_context.dart';
import 'sync_error_classifier.dart';
import 'sync_service.dart';
import 'sync_write_scope.dart';
import 'sync_models.dart';
import 'sync_status_notifier.dart';

/// Manages periodic foreground sync (every 5 minutes), exponential-backoff
/// retries after failures (30s → 1m → 2m → 5m cap), connectivity-triggered
/// recovery, and lifecycle-aware start/stop. Reports every outcome to
/// [syncStatusProvider].
class AutoSyncService {
  AutoSyncService({
    required this.ref,
    Stream<List<ConnectivityResult>>? connectivityStream,
    SessionGenerationRepository? generationRepository,
    this.flushTimeout = defaultStageTimeout,
    this.pullTimeout = defaultStageTimeout,
    this.effectsTimeout = defaultEffectsTimeout,
  }) : _connectivityStream = connectivityStream,
       _generationRepository = generationRepository;

  /// Hard bounds on awaited work. A hung network call or post-sync effect must
  /// never keep the single-flight slot (and so the banner) busy forever.
  static const defaultStageTimeout = Duration(minutes: 3);
  static const defaultEffectsTimeout = Duration(seconds: 30);
  final Duration flushTimeout;
  final Duration pullTimeout;
  final Duration effectsTimeout;

  /// A timed-out stage that is still running this many stage limits after it
  /// started is reported as failed (see [_armWatchdog]). The single-flight
  /// slot stays taken: the stage may still be writing.
  static const hangMultiple = 3;

  final Ref ref;
  final Stream<List<ConnectivityResult>>? _connectivityStream;
  final SessionGenerationRepository? _generationRepository;

  Timer? _timer;
  Timer? _retryTimer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  String? _userId;
  int? _generation;
  int _epoch = 0;
  int _failureCount = 0;
  int _busyCount = 0;
  bool _silentRun = false;
  Future<void>? _straggler;
  Duration _stragglerLimit = defaultStageTimeout;
  Timer? _watchdog;
  bool _stragglerHung = false;
  bool _syncInFlight = false;
  Completer<void>? _inFlightCompletion;

  static const _interval = Duration(minutes: 5);

  /// Floor for a retry aimed at a retrying change's due time.
  static const minPartialRetryDelay = Duration(seconds: 5);

  static const backoffSteps = [
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];

  void start(String userId, {int? generation}) {
    if (_userId == userId && _generation == generation && _timer != null) {
      return;
    }
    _epoch++;
    _userId = userId;
    _generation = generation;
    _failureCount = 0;
    _busyCount = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => _syncNow());
    try {
      _connSub ??= (_connectivityStream ?? Connectivity().onConnectivityChanged)
          .listen(
            _onConnectivityChanged,
            onError: (Object e) =>
                AppLogger.debug('AutoSync', 'Connectivity stream error: $e'),
          );
    } catch (e) {
      // Connectivity is an optimization; session activation and offline use
      // remain available if the platform channel is unavailable.
      AppLogger.debug('AutoSync', 'Connectivity unavailable: ${e.runtimeType}');
    }
    // Also sync immediately on start (catches changes from other devices)
    _syncNow();
  }

  void stop() {
    _epoch++;
    _timer?.cancel();
    _timer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _connSub?.cancel();
    _connSub = null;
    _userId = null;
    _generation = null;
  }

  /// Waits for an already-started sync to finish its local writes. Session
  /// teardown calls this after invalidating the generation and stopping timers.
  Future<void> drain() async {
    // A straggler reported as hung must not block teardown forever: every
    // write it still makes is rechecked against the session generation.
    if (_stragglerHung) return;
    await _inFlightCompletion?.future;
  }

  /// Manual sync (Settings "Sync now"): resets the backoff ladder and
  /// runs immediately. Outcome lands in [syncStatusProvider].
  Future<void> syncNow(String userId, {int? generation}) async {
    if (_userId != userId ||
        (generation != null && _generation != generation)) {
      _epoch++;
      _userId = userId;
      _generation = generation;
    }
    _userId = userId;
    final requestedEpoch = _epoch;
    // A review may have just changed server state after an existing pull took
    // its snapshot. Wait for that pass, then request one fresh pass. Concurrent
    // explicit callers join the same follow-up; stop/session changes cancel it.
    if (!_stragglerHung) await _inFlightCompletion?.future;
    if (requestedEpoch != _epoch || _userId != userId) return;
    // A timed-out stage may still be writing: do nothing, and leave the
    // one-shot backoff bypass for a call that can actually run.
    if (_syncInFlight) return;
    // An explicit request skips retry backoff once; automatic triggers keep it.
    try {
      await ref
          .read(syncServiceProvider)
          .makeRetriesEligibleNow(userId: userId);
    } on Object catch (error) {
      AppLogger.debug(
        'AutoSync',
        'Retry bypass unavailable: ${error.runtimeType}',
      );
    }
    _retryTimer?.cancel();
    _failureCount = 0;
    _busyCount = 0;
    return _syncNow();
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final online = results.any((r) => r != ConnectivityResult.none);
    if (!online) return;
    if (ref.read(syncStatusProvider).phase != SyncPhase.failure) return;
    // Network is back while we were failing — retry right away.
    _retryTimer?.cancel();
    _syncNow();
  }

  Future<void> _syncNow() async {
    // Single-flight: the periodic timer, backoff retry, connectivity callback
    // and manual syncNow can all fire while a sync is still running;
    // overlapping runs would interleave status/prefs writes.
    if (_syncInFlight) {
      if (_stragglerHung) {
        // The straggler never finished: do not wait for it, and keep the
        // visible retry ladder going so the failure is not forgotten.
        if (_userId != null) _scheduleRetry();
        return;
      }
      return _inFlightCompletion?.future;
    }
    final userId = _userId;
    if (userId == null) return;
    _syncInFlight = true;
    // A run started by the busy-retry timer stays invisible: no syncing flip,
    // no revert, so the banner does not flicker while the background task
    // holds the lock.
    final silent = _silentRun;
    _silentRun = false;
    final runEpoch = _epoch;
    final runGeneration = _generation;
    final completion = Completer<void>();
    _inFlightCompletion = completion;

    // Track whether syncService has been successfully resolved so the catch
    // block can report a pending count even after a mid-sync container disposal.
    SyncService? resolvedSyncService;
    SyncStatusNotifier? resolvedNotifier;
    SyncWriteScope? capturedScope;
    SyncRunResult? observedFlush;
    SyncRunResult? observedPull;
    try {
      final notifier = ref.read(syncStatusProvider.notifier);
      resolvedNotifier = notifier;
      await notifier.adoptSession(userId);
      final syncService = ref.read(syncServiceProvider);
      resolvedSyncService = syncService;
      capturedScope = syncService.writeScope;
      ProjectionIdentity? projectionIdentity;
      if (capturedScope != null) {
        capturedScope.requireOwner(userId);
        final context = await capturedScope.captureContext();
        if (runGeneration != null &&
            context.sessionGeneration != runGeneration) {
          throw const WorkspaceAccessFailure(
            WorkspaceAccessFailureCode.staleGrant,
          );
        }
        projectionIdentity = ProjectionIdentity.fromContext(context);
      }
      if (!silent) notifier.markSyncing();
      // Flush-then-pull order is critical: offline-created rows must have
      // their server IDs assigned before pullFromServer runs. Without this
      // ordering, pullFromServer.getByServerId returns null for pending rows
      // and inserts a duplicate row for the same entity.
      await _bounded(
        syncService.flushPending(userId: userId),
        flushTimeout,
        'flush',
      );
      if (!await _isCurrentSession(
        runEpoch,
        userId,
        runGeneration,
        capturedScope,
      )) {
        notifier.revertSyncing();
        return;
      }
      final flushOutcome = syncService.lastFlushOutcome;
      observedFlush = flushOutcome;
      final pulled = await _bounded(
        syncService.pullFromServer(userId: userId),
        pullTimeout,
        'pull',
      );
      observedPull = syncService.lastPullOutcome;
      if (!await _isCurrentSession(
        runEpoch,
        userId,
        runGeneration,
        capturedScope,
      )) {
        notifier.revertSyncing();
        return;
      }
      if (!pulled) throw const SyncFailedException();
      if (projectionIdentity != null || runGeneration != null) {
        try {
          // Every workspace, not just the one that synced: a pull can change
          // care another workspace's reminders depend on, and the audit needs
          // the whole picture. The runner coalesces overlapping triggers.
          await ref
              .read(reminderReconcileRunnerProvider)
              .run()
              .timeout(effectsTimeout);
        } on Object catch (error) {
          AppLogger.warning(
            'AutoSync',
            'Post-pull reminder reconciliation failed: ${error.runtimeType}',
          );
        }
      }
      if (!await _isCurrentSession(
        runEpoch,
        userId,
        runGeneration,
        capturedScope,
      )) {
        notifier.revertSyncing();
        return;
      }
      final runOutcome = SyncRunResult.combine(
        flush: flushOutcome,
        pull: syncService.lastPullOutcome,
      );
      _busyCount = 0;
      _retryTimer?.cancel();
      final counts = await _safeCounts(syncService, userId);
      // Only work that will go out by itself (queued or backing off) calls
      // for another look; blocked and conflicting changes wait for a person.
      final partial =
          runOutcome.status == SyncRunStatus.partiallySynced &&
          counts.operations.automatic > 0;
      if (!partial) _failureCount = 0;
      if (!await _isCurrentSession(
        runEpoch,
        userId,
        runGeneration,
        capturedScope,
      )) {
        notifier.revertSyncing();
        return;
      }
      await notifier.markSuccess(
        pendingCount: counts.pending,
        counts: counts.operations,
        lastRun: runOutcome,
      );
      if (!await _isCurrentSession(
        runEpoch,
        userId,
        runGeneration,
        capturedScope,
      )) {
        return;
      }
      // Some stage was left waiting or refused: look again on the backoff
      // ladder instead of waiting for the next periodic tick.
      if (partial) await _schedulePartialRetry(syncService, userId);
      try {
        await syncService.purgeSyncedTombstones();
      } catch (_) {
        // Non-fatal cleanup.
      }
    } catch (e) {
      if (!await _isCurrentSession(
        runEpoch,
        userId,
        runGeneration,
        capturedScope,
      )) {
        try {
          resolvedNotifier?.revertSyncing();
        } catch (_) {
          // Container disposed mid-sync.
        }
        return;
      }
      if (e is SyncBusyException) {
        // The background task is syncing right now. That is not a failure:
        // keep the failure marker and backoff untouched and look again soon.
        if (!silent) {
          try {
            ref.read(syncStatusProvider.notifier).revertSyncing();
          } catch (_) {
            // Container disposed mid-sync.
          }
        }
        _scheduleBusyRetry();
        return;
      }
      if (e is TimeoutException && _straggler != null) {
        // A bounded stage ran out of time but is still working and keeps the
        // single-flight slot. That is still syncing, not a failure: leave the
        // failure marker alone and let the straggler's quiet run (see the
        // finally block) publish what the stage really achieved.
        try {
          ref.read(syncStatusProvider.notifier).revertSyncing();
        } catch (_) {
          // Container disposed mid-sync.
        }
        return;
      }
      AppLogger.debug('AutoSync', 'Sync failed: ${e.runtimeType}');
      final isAuthFailure = e is DioException && e.response?.statusCode == 401;
      if (isAuthFailure) {
        // The AuthInterceptor logout gate owns auth failures; don't record
        // a sync failure (it would persist a false failure marker) and
        // don't retry — logout will stop() this service.
        try {
          ref.read(syncStatusProvider.notifier).revertSyncing();
        } catch (_) {
          // Container disposed mid-sync.
        }
        return;
      }
      final failureCounts = resolvedSyncService != null
          ? await _safeCounts(resolvedSyncService, userId)
          : (pending: 0, operations: SyncOperationCounts.none);
      try {
        await ref
            .read(syncStatusProvider.notifier)
            .markFailure(
              e,
              lastRun: observedFlush == null && observedPull == null
                  ? null
                  : SyncRunResult.combine(
                      flush: observedFlush,
                      pull: observedPull,
                    ),
              pendingCount: failureCounts.pending,
              counts: failureCounts.operations,
            );
      } catch (_) {
        // Container disposed mid-sync — nowhere to report to.
      }
      if (await _isCurrentSession(
        runEpoch,
        userId,
        runGeneration,
        capturedScope,
      )) {
        _scheduleRetry();
      }
    } finally {
      final straggler = _straggler;
      if (straggler == null) {
        _syncInFlight = false;
        if (identical(_inFlightCompletion, completion)) {
          _inFlightCompletion = null;
        }
        if (!completion.isCompleted) completion.complete();
      } else {
        // A timed-out stage is still running: keep the single-flight slot
        // and the completion until it really ends, so two flushes never
        // interleave and syncNow/drain wait for it instead of returning.
        _straggler = null;
        _armWatchdog(straggler, userId, runEpoch);
        unawaited(
          straggler.whenComplete(() {
            _watchdog?.cancel();
            _watchdog = null;
            _stragglerHung = false;
            _syncInFlight = false;
            if (identical(_inFlightCompletion, completion)) {
              _inFlightCompletion = null;
            }
            if (!completion.isCompleted) completion.complete();
            // The straggler's real outcome is published by a quiet run: no
            // syncing flip and no step on the visible retry ladder.
            if (_userId != null) {
              unawaited(_refreshCountsQuietly(userId));
              _scheduleQuietRun();
            }
          }),
        );
      }
      if (runEpoch != _epoch && _userId != null) unawaited(_syncNow());
    }
  }

  bool _isCurrentRun(int epoch, String userId, int? generation) =>
      _epoch == epoch && _userId == userId && _generation == generation;

  Future<bool> _isCurrentSession(
    int epoch,
    String userId,
    int? generation, [
    SyncWriteScope? scope,
  ]) async {
    if (!_isCurrentRun(epoch, userId, generation)) return false;
    if (scope != null) {
      try {
        await scope.check();
      } on Object {
        return false;
      }
    }
    final repository = _generationRepository;
    if (generation == null || repository == null) return true;
    try {
      return await repository.isCurrent(userId: userId, generation: generation);
    } catch (_) {
      return false;
    }
  }

  /// Re-tallies the unsent changes after the outbox was changed outside a
  /// sync run (a recovery action), so the status everywhere matches it.
  Future<void> refreshCounts(String userId) async {
    final counts = await _safeCounts(ref.read(syncServiceProvider), userId);
    ref
        .read(syncStatusProvider.notifier)
        .updateCounts(pendingCount: counts.pending, counts: counts.operations);
  }

  /// Pending is everything not yet accepted (queued, retrying, stranded);
  /// operations says which of it needs a person.
  Future<({int pending, SyncOperationCounts operations})> _safeCounts(
    SyncService syncService,
    String userId,
  ) async {
    try {
      final operations = await syncService.countOperations(userId: userId);
      return (
        pending: operations.automatic + operations.stranded,
        operations: operations,
      );
    } catch (_) {
      return (pending: 0, operations: SyncOperationCounts.none);
    }
  }

  /// Awaits [work] for at most [limit]. On timeout the caller gets a
  /// [TimeoutException] but the work keeps its single-flight slot (see
  /// [_straggler]); it is never cancelled or double-started.
  Future<T> _bounded<T>(Future<T> work, Duration limit, String stage) {
    final done = Completer<T>();
    var timedOut = false;
    final timer = Timer(limit, () {
      if (done.isCompleted) return;
      timedOut = true;
      _straggler = work.then<void>((_) {}, onError: (Object _) {});
      _stragglerLimit = limit;
      done.completeError(TimeoutException('sync $stage', limit));
    });
    work.then<void>(
      (value) {
        timer.cancel();
        if (!done.isCompleted) done.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        timer.cancel();
        if (!timedOut && !done.isCompleted) done.completeError(error, stack);
      },
    );
    return done.future;
  }

  /// A stage that timed out may never finish (a SQLite wait, a server that
  /// trickles bytes under Dio's per-chunk timeout, a future that never
  /// resolves). Without this the status would stay idle forever, every trigger
  /// would return early and an explicit sync would wait for ever.
  ///
  /// After [hangMultiple] stage limits in total the failure is published and
  /// the normal retry ladder is armed. The single-flight slot is deliberately
  /// NOT released: the straggler may still write, and a second flush or pull
  /// interleaving with it is the exact hazard the slot prevents. Later
  /// triggers see [_stragglerHung] and return without waiting. If the stage
  /// finishes after all, its completion clears the flag and a quiet run
  /// publishes the real outcome over the failure.
  void _armWatchdog(Future<void> straggler, String userId, int runEpoch) {
    _watchdog?.cancel();
    final limit = _stragglerLimit;
    _watchdog = Timer(limit * (hangMultiple - 1), () async {
      _watchdog = null;
      _stragglerHung = true;
      if (_epoch != runEpoch || _userId != userId) return;
      final syncService = ref.read(syncServiceProvider);
      final counts = await _safeCounts(syncService, userId);
      if (!_stragglerHung || _epoch != runEpoch) return;
      try {
        await ref
            .read(syncStatusProvider.notifier)
            .markFailure(
              TimeoutException('sync stage hung', limit * hangMultiple),
              pendingCount: counts.pending,
              counts: counts.operations,
            );
      } catch (_) {
        // Container disposed: nowhere to report to.
      }
      if (_stragglerHung && _epoch == runEpoch) _scheduleRetry();
    });
  }

  Future<void> _refreshCountsQuietly(String? userId) async {
    if (userId == null) return;
    try {
      await refreshCounts(userId);
    } on Object {
      // Container disposed or session gone: nothing to update.
    }
  }

  /// A silent look right after a timed-out stage finally ended, so the status
  /// shows what that stage achieved instead of the timeout.
  void _scheduleQuietRun() {
    _retryTimer?.cancel();
    _retryTimer = Timer(minPartialRetryDelay, () {
      _silentRun = true;
      _syncNow();
    });
  }

  void _scheduleBusyRetry() {
    if (_userId == null) return;
    final delay = backoffSteps[min(_busyCount, backoffSteps.length - 1)];
    _busyCount++;
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _silentRun = true;
      _syncNow();
    });
  }

  /// Looks again when the earliest retrying change is due, silently; with
  /// only queued work (or no readable time) it uses the backoff ladder.
  Future<void> _schedulePartialRetry(
    SyncService syncService,
    String userId,
  ) async {
    if (_userId == null) return;
    DateTime? due;
    try {
      due = await syncService.earliestRetryAt(userId: userId);
    } on Object {
      due = null;
    }
    if (_userId == null) return;
    if (due == null) {
      _scheduleRetry();
      return;
    }
    var delay = due.difference(DateTime.now().toUtc());
    if (delay < minPartialRetryDelay) delay = minPartialRetryDelay;
    if (delay > backoffSteps.last) delay = backoffSteps.last;
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _silentRun = true;
      _syncNow();
    });
  }

  void _scheduleRetry() {
    // An in-flight failure completing after stop() must not re-arm retries
    // for a logged-out user.
    if (_userId == null) return;
    // A periodic tick that fails while a retry is already pending intentionally
    // replaces it, re-arming from "now" at the current rung — attempt rate
    // stays bounded.
    final delay = backoffSteps[min(_failureCount, backoffSteps.length - 1)];
    _failureCount++;
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, _syncNow);
  }
}

final autoSyncServiceProvider = Provider<AutoSyncService>((ref) {
  final service = AutoSyncService(
    ref: ref,
    generationRepository: ref.read(sessionGenerationRepositoryProvider),
  );
  ref.onDispose(service.stop);
  return service;
});
