import 'dart:async';

import '../db/database.dart';
import '../utils/app_logger.dart';

/// Refreshes optional phone effects after committed care/device choices without
/// making a successful care save wait for a native plugin or permission.
class CareProjectionCoordinator {
  CareProjectionCoordinator({required this.database, required this.refresh});
  final AppDatabase database;
  final Future<void> Function() refresh;
  StreamSubscription<Object>? _subscription;
  bool _closed = false;
  bool _dirty = false;
  Future<void>? _running;

  void start() {
    if (_closed) return;
    _subscription ??= database
        .customSelect(
          // Drift shares identical SQL streams; keep this dependency set distinct.
          'SELECT 1 AS care_projection_changes',
          readsFrom: {
            database.profiles,
            database.pills,
            database.schedules,
            database.localRoutines,
            database.medicationOccurrences,
            database.devicePersonReminders,
            database.deviceScheduleReminders,
            database.deviceReminderSettings,
            database.careWorkspaces,
            database.workspaceGrants,
          },
        )
        .watch()
        .listen(
          (_) => requestRefresh(),
          onError: (Object error) {
            AppLogger.warning(
              'CareProjections',
              'Care changes unavailable: ${error.runtimeType}',
            );
          },
        );
    requestRefresh();
  }

  void requestRefresh() {
    if (_closed) return;
    _dirty = true;
    if (_running != null) return;
    final future = _drain();
    _running = future;
    future.whenComplete(() {
      if (identical(_running, future)) _running = null;
      if (_dirty && !_closed) requestRefresh();
    });
  }

  Future<void> _drain() async {
    while (_dirty && !_closed) {
      _dirty = false;
      try {
        await refresh();
      } on Object catch (error) {
        AppLogger.warning(
          'CareProjections',
          'Phone effects unavailable: ${error.runtimeType}',
        );
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    _dirty = false;
    await _subscription?.cancel();
    await _running;
  }
}
