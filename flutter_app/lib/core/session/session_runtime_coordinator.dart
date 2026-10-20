import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../projections/projection_identity.dart';
import '../projections/projection_effects_gate.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_provider.dart';
import '../projections/projection_reconciler.dart';
import '../sync/auto_sync_service.dart';
import '../utils/app_logger.dart';
import '../widget/widget_snapshot.dart';
import 'session_generation_repository.dart';

/// Owns the foreground runtime associated with one persisted session identity.
/// Fresh login and restored login both call [start] with the same generation
/// contract; invalidation advances that generation before teardown begins.
class SessionRuntimeCoordinator {
  SessionRuntimeCoordinator({
    required this.generations,
    this.access,
    Future<void> Function(ProjectionIdentity identity)? retireProjection,
    Future<void> Function(ProjectionIdentity identity)? reconcileWorkspace,
    required void Function(String userId, int generation) startSync,
    required void Function() stopSync,
    void Function(void Function() start)? scheduleStart,
    Future<void> Function()? drainSync,
    Future<void> Function()? cancelNotifications,
    Future<void> Function()? clearProjections,
    Future<void> Function(String userId, int generation)? reconcileProjections,
  }) : _retireProjection = retireProjection,
       _reconcileWorkspace = reconcileWorkspace,
       _startSync = startSync,
       _stopSync = stopSync,
       _scheduleStart = scheduleStart ?? _runImmediately,
       _drainSync = drainSync ?? _noOp,
       _cancelNotifications = cancelNotifications ?? _noOp,
       _clearProjections = clearProjections ?? _noOp,
       _reconcileProjections = reconcileProjections ?? _reconcileNoOp;

  final SessionGenerationRepository generations;
  final WorkspaceAccessRepository? access;
  final Future<void> Function(ProjectionIdentity)? _retireProjection;
  final Future<void> Function(ProjectionIdentity)? _reconcileWorkspace;
  final void Function(String userId, int generation) _startSync;
  final void Function() _stopSync;
  final void Function(void Function()) _scheduleStart;
  final Future<void> Function() _drainSync;
  final Future<void> Function() _cancelNotifications;
  final Future<void> Function() _clearProjections;
  final Future<void> Function(String userId, int generation)
  _reconcileProjections;

  SessionIdentity? _activeIdentity;
  bool _running = false;
  ProjectionIdentity? _activeProjection;
  Future<void> _operations = Future<void>.value();

  SessionIdentity? get activeIdentity => _activeIdentity;

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _operations.then((_) => action());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> start(String userId, int generation) => _enqueue(() async {
    final identity = (userId, generation);
    if (!await generations.isCurrent(userId: userId, generation: generation)) {
      return;
    }
    ProjectionIdentity? projection;
    if (access != null) {
      final context = await access!.contextForOwner(userId);
      if (context == null || context.sessionGeneration != generation) return;
      projection = ProjectionIdentity.fromContext(context);
    }
    if (_activeIdentity == identity && _running) return;
    if (_activeIdentity != null && _activeIdentity != identity) {
      final retired = _activeProjection;
      _running = false;
      _activeIdentity = null;
      _activeProjection = null;
      _stopSync();
      await _drainSync();
      await _retire(retired, cancelNotifications: true);
    }
    // Teardown can wait for an old request or OS effect. Never start a session
    // that became stale during that wait.
    if (!await generations.isCurrent(userId: userId, generation: generation) ||
        (projection != null && await projection.resolve(access!) == null)) {
      return;
    }
    _activeIdentity = identity;
    _activeProjection = projection;
    _running = true;
    _scheduleStart(() {
      unawaited(_startCaptured(identity, projection));
    });
  });

  Future<void> _startCaptured(
    SessionIdentity identity,
    ProjectionIdentity? projection,
  ) async {
    if (!_running || _activeIdentity != identity) return;
    try {
      if (access != null) {
        if (!await generations.isCurrent(
              userId: identity.$1,
              generation: identity.$2,
            ) ||
            projection == null ||
            await projection.resolve(access!) == null) {
          return;
        }
        if (!_running || _activeIdentity != identity) return;
      }
      _startSync(identity.$1, identity.$2);
    } on Object catch (error) {
      if (_activeIdentity == identity) {
        _running = false;
        try {
          _stopSync();
        } on Object {
          /* Optional startup cleanup. */
        }
      }
      AppLogger.warning(
        'SessionRuntime',
        'Foreground startup unavailable: ${error.runtimeType}',
      );
      return;
    }
    try {
      if (projection != null) {
        await _reconcileWorkspace?.call(projection);
      } else {
        await _reconcileProjections(identity.$1, identity.$2);
      }
    } on Object catch (error) {
      AppLogger.warning(
        'SessionRuntime',
        'Reminder reconciliation unavailable: ${error.runtimeType}',
      );
    }
  }

  Future<void> pause() => _enqueue(() async {
    if (!_running) return;
    _running = false;
    _stopSync();
  });

  Future<void> resume() async {
    final identity = _activeIdentity;
    if (identity != null) await start(identity.$1, identity.$2);
  }

  /// Auth has already revoked protected access. Capture the retired identity
  /// before queueing teardown so a later A completion cannot stop B.
  Future<int> invalidate({
    bool cancelNotifications = true,
    bool captureActiveIdentity = true,
    SessionIdentity? identity,
    ProjectionIdentity? projectionIdentity,
  }) {
    final captured =
        identity ?? (captureActiveIdentity ? _activeIdentity : null);
    final projection =
        projectionIdentity ??
        (captured == _activeIdentity ? _activeProjection : null);
    return _enqueue(() async {
      final protected = access != null;
      final target =
          captured ?? (protected ? null : await generations.currentIdentity());
      if (target == null) return generations.currentGeneration();
      final ownsRuntime = _activeIdentity == target;
      final generation = protected
          ? await generations.currentGeneration()
          : await generations.advanceTo(null);
      if (ownsRuntime) {
        _running = false;
        _activeIdentity = null;
        _activeProjection = null;
        try {
          _stopSync();
        } on Object {
          /* Remaining teardown still runs. */
        }
        try {
          await _drainSync();
        } on Object {
          /* Exact retirement remains useful. */
        }
      }
      await _retire(projection, cancelNotifications: cancelNotifications);
      return generation;
    });
  }

  Future<void> _retire(
    ProjectionIdentity? identity, {
    required bool cancelNotifications,
  }) async {
    if (access != null) {
      if (identity != null) {
        try {
          await _retireProjection?.call(identity);
        } on Object {
          /* Grant is already revoked. */
        }
      }
      return;
    }
    // Explicit compatibility constructors are retained for legacy unit fixtures.
    if (cancelNotifications) {
      try {
        await _cancelNotifications();
      } on Object {
        /* Optional OS teardown. */
      }
    }
    try {
      await _clearProjections();
    } on Object {
      /* Optional OS teardown. */
    }
  }

  static Future<void> _noOp() async {}

  static Future<void> _reconcileNoOp(String userId, int generation) async {}

  static void _runImmediately(void Function() start) => start();
}

Future<void> retireCapturedRuntimeProjections({
  required Future<void> Function() retireReminders,
  required Future<void> Function() retireWidget,
}) async {
  try {
    await retireReminders();
  } finally {
    await retireWidget();
  }
}

/// Runs [start] after the current frame. A post-frame callback never asks for
/// a frame itself, so when the UI is idle (a sign-in that has just finished
/// drawing) the start would wait for the next unrelated repaint; asking for
/// one makes the first sync begin right away.
void scheduleStartAfterFrame(void Function() start) {
  final binding = WidgetsBinding.instance;
  binding.addPostFrameCallback((_) => start());
  binding.scheduleFrame();
}

final sessionRuntimeCoordinatorProvider = Provider<SessionRuntimeCoordinator>((
  ref,
) {
  final autoSync = ref.read(autoSyncServiceProvider);
  final access = ref.read(workspaceAccessRepositoryProvider);
  return SessionRuntimeCoordinator(
    generations: ref.read(sessionGenerationRepositoryProvider),
    access: access,
    startSync: (userId, generation) =>
        autoSync.start(userId, generation: generation),
    stopSync: autoSync.stop,
    scheduleStart: scheduleStartAfterFrame,
    drainSync: autoSync.drain,
    retireProjection: (identity) => retireCapturedRuntimeProjections(
      retireReminders: () =>
          ref.read(projectionReconcilerProvider).retire(identity),
      retireWidget: () => clearWidgetSnapshot(
        identity: identity,
        access: access,
        effectsGate: privateProjectionEffectsGate,
      ),
    ),
    reconcileWorkspace: (identity) async {
      await ref
          .read(projectionReconcilerProvider)
          .reconcile(projectionIdentity: identity);
    },
  );
});
