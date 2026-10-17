import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import '../db/database.dart';
import '../inventory/inventory_service.dart';
import '../utils/app_logger.dart';
import '../workspace/workspace_provider.dart';
import 'projection_reconciler.dart';
import 'reminder_retry.dart';

const reminderTimezonePreferenceKey = 'reminder_last_timezone';

/// Backoff between attempts after a busy or degraded pass. Three retries keep
/// a stuck pass from looping while still outlasting a brief lock holder.
const reminderRetryDelays = [
  Duration(seconds: 2),
  Duration(seconds: 8),
  Duration(seconds: 30),
];

typedef ReminderPass =
    Future<ReconcileAllResult> Function({
      Locale? locale,
      bool refreshActiveActions,
      String? buildKey,
    });

/// Coalesces every trigger that wants the reminders reconciled.
///
/// At most one pass runs and at most one more is queued behind it, so a burst
/// of triggers (resume, sync, settings change) does the work twice, never N
/// times. A busy or degraded result is retried with bounded backoff. The
/// reconciler already serialises the effects themselves; this only prevents
/// redundant passes and gives every caller the result of a pass that started
/// after its request.
class ReminderReconcileRunner {
  ReminderReconcileRunner({
    required ReminderPass pass,
    List<Duration> retryDelays = reminderRetryDelays,
    Future<void> Function(Duration)? delay,
  }) : _pass = pass,
       _retryDelays = retryDelays,
       _delay = delay ?? Future<void>.delayed;

  final ReminderPass _pass;
  final List<Duration> _retryDelays;
  final Future<void> Function(Duration) _delay;

  Future<void>? _running;
  Completer<ReconcileAllResult>? _queued;
  Locale? _queuedLocale;
  bool _queuedRefresh = false;
  String? _queuedBuildKey;
  int passesStarted = 0;

  Completer<void>? _wake;

  /// Resolves with the first attempt's result. A busy or degraded first
  /// attempt keeps retrying in the background so a slow lock holder never
  /// holds up the caller (a sync, for one).
  Future<ReconcileAllResult> run({
    Locale? locale,
    bool refreshActiveActions = false,
    String? buildKey,
  }) {
    if (_running == null) {
      return _start(locale, refreshActiveActions, buildKey);
    }
    _queued ??= Completer<ReconcileAllResult>();
    _queuedLocale = locale ?? _queuedLocale;
    _queuedRefresh = _queuedRefresh || refreshActiveActions;
    _queuedBuildKey = buildKey ?? _queuedBuildKey;
    // A request that arrives during a backoff is itself the retry.
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
    return _queued!.future;
  }

  Future<ReconcileAllResult> _start(
    Locale? locale,
    bool refresh,
    String? buildKey,
  ) {
    final first = Completer<ReconcileAllResult>();
    final whole = _execute(locale, refresh, buildKey, first);
    _running = whole;
    unawaited(whole.whenComplete(_next));
    return first.future;
  }

  void _next() {
    _running = null;
    final queued = _queued;
    if (queued == null) return;
    final locale = _queuedLocale;
    final refresh = _queuedRefresh;
    final buildKey = _queuedBuildKey;
    _queued = null;
    _queuedLocale = null;
    _queuedRefresh = false;
    _queuedBuildKey = null;
    _start(
      locale,
      refresh,
      buildKey,
    ).then(queued.complete, onError: queued.completeError);
  }

  Future<void> _execute(
    Locale? locale,
    bool refresh,
    String? buildKey,
    Completer<ReconcileAllResult> first,
  ) async {
    try {
      for (var attempt = 0; ; attempt++) {
        passesStarted++;
        ReconcileAllResult result;
        try {
          result = await _pass(
            locale: locale,
            refreshActiveActions: refresh,
            buildKey: buildKey,
          );
        } on Object catch (error) {
          AppLogger.warning(
            'ReminderRunner',
            'Reminder pass failed: ${error.runtimeType}',
          );
          result = const ReconcileAllResult.failed();
        }
        if (!first.isCompleted) first.complete(result);
        if (result.healthy || attempt >= _retryDelays.length) return;
        // A request that arrived while the pass ran is itself the retry; do
        // not sit out a backoff first.
        if (_queued != null) return;
        final wake = _wake = Completer<void>();
        await Future.any<void>([_delay(_retryDelays[attempt]), wake.future]);
        _wake = null;
        // A queued request replaces the remaining retries.
        if (_queued != null) return;
      }
    } finally {
      if (!first.isCompleted) {
        first.complete(const ReconcileAllResult.failed());
      }
    }
  }
}

/// The build identity whose first healthy pass runs a strict sweep, and the
/// timezone bookkeeping. A changed timezone or build is simply a reason the
/// next pass must happen and be trusted: both are compared against what the
/// last healthy pass recorded and are only recorded again after one succeeds.
class ReminderTriggerGuard {
  ReminderTriggerGuard(
    this._loadPreferences, {
    Future<String?> Function()? build,
  }) : _build = build ?? _packageBuild;

  final Future<SharedPreferences> Function() _loadPreferences;
  final Future<String?> Function() _build;
  String? _pendingZone;

  static Future<String?> _packageBuild() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } on Object {
      return null;
    }
  }

  Future<String?> buildKey() => _build();

  /// Runs [runner] for a foreground trigger: a new build runs one strict
  /// sweep, a timezone change is logged, and the timezone is recorded again
  /// only after a healthy pass.
  Future<ReconcileAllResult> runForeground(
    ReminderReconcileRunner runner, {
    Locale? locale,
    bool refreshActiveActions = false,
  }) async {
    final changed = await timezoneChanged();
    if (changed) {
      AppLogger.info('ReminderRunner', 'Device timezone changed');
    }
    final result = await runner.run(
      locale: locale,
      refreshActiveActions: refreshActiveActions,
      buildKey: await buildKey(),
    );
    try {
      await passCompleted(result.healthy);
    } on Object {
      // Bookkeeping only; the next trigger records it.
    }
    return result;
  }

  static Future<String?> currentBuildKey() => _packageBuild();

  /// Whether the device timezone differs from the one last reconciled.
  Future<bool> timezoneChanged() async {
    try {
      final zone = tz.local.name;
      final preferences = await _loadPreferences();
      _pendingZone = zone;
      final stored = preferences.getString(reminderTimezonePreferenceKey);
      return stored != null && stored != zone;
    } on Object {
      _pendingZone = null;
      return false;
    }
  }

  Future<void> passCompleted(bool healthy) async {
    final zone = _pendingZone;
    if (!healthy || zone == null) return;
    await (await _loadPreferences()).setString(
      reminderTimezonePreferenceKey,
      zone,
    );
  }
}

final reminderReconcileRunnerProvider = Provider<ReminderReconcileRunner>((
  ref,
) {
  return ReminderReconcileRunner(
    pass: ({locale, refreshActiveActions = false, buildKey}) => ref
        .read(projectionReconcilerProvider)
        .reconcileAll(
          locale: locale,
          refreshActiveActions: refreshActiveActions,
          buildKey: buildKey,
        ),
  );
});

/// Settings > Reminders "Reset reminders" and the sync-recovery link.
final reminderResetProvider =
    Provider<Future<ReminderResetResult> Function(Locale?)>((ref) {
      return (locale) => ref
          .read(projectionReconcilerProvider)
          .resetReminders(
            locale: locale,
            scheduleRetry: () =>
                scheduleReminderRetryTask(reminderRetryTaskDelay),
            rebuild: () =>
                ref.read(reminderReconcileRunnerProvider).run(locale: locale),
            recheckStock: () => InventoryService(
              ref.read(databaseProvider),
              access: ref.read(workspaceAccessRepositoryProvider),
            ).checkAllPillsStock(),
          );
    });
