import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/database.dart';
import '../medication/medication_command.dart';
import '../medication/medication_repository.dart';
import '../projections/projection_command_id.dart';
import '../storage/preference_keys.dart';
import '../sync/ledger_mode_hint.dart';
import '../utils/app_logger.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';

/// The oldest dose the sweep will ever record as missed, however long the app
/// was not running.
const autoMissLookBack = Duration(days: 7);

/// Most doses recorded per person and sweep; the next sweep carries on.
const autoMissBatchSize = 200;

/// WorkManager names of the periodic sweep. It needs no network: a phone
/// that is offline or has only a local workspace records misses too.
const autoMissTaskName = 'autoMiss';
const autoMissTaskUniqueName = 'pill_tracker_auto_miss';

const _minDelayMinutes = 1;
const _maxDelayMinutes = 1439;

/// What one [AutoMissSweeper.sweep] did.
class AutoMissSweepResult {
  const AutoMissSweepResult({this.recorded = 0, this.aborted = false});

  /// Misses applied: written, or already written by a run that overlapped
  /// this one (queued for sync in a connected workspace).
  final int recorded;

  /// Access changed while sweeping (signed out, other server, new session), so
  /// the sweep stopped early. The next trigger starts again.
  final bool aborted;
}

/// The planned-time range of doses that may be recorded as missed now.
///
/// A dose qualifies when its planned time is at least [delay] old, but never
/// before the setting was switched on ([since]) and never older than
/// [autoMissLookBack]. Returns null while no dose can qualify yet.
({DateTime from, DateTime to})? autoMissWindow({
  required DateTime now,
  required Duration delay,
  required DateTime since,
}) {
  final to = now.subtract(delay);
  final capped = now.subtract(autoMissLookBack);
  final from = since.isAfter(capped) ? since : capped;
  return from.isAfter(to) ? null : (from: from, to: to);
}

/// Records a dose that nobody recorded in time as a `miss` event.
///
/// This is the only writer of automatic misses. It goes through
/// [MedicationRepository.apply], exactly like a tap, so a connected workspace
/// queues an ordinary append-only command for sync and a local workspace
/// writes its ledger directly. Every other device then reads the miss like any
/// other recorded fact.
///
/// Safe to run from the foreground and from background isolates at the same
/// time: the command ID is derived from the person, workspace and occurrence,
/// so two runs cannot write two misses for one dose.
class AutoMissSweeper {
  AutoMissSweeper({
    required this.db,
    required this.access,
    required this.preferences,
    DateTime Function()? clock,
    Future<bool> Function()? serverRecordsMisses,
  }) : _clock = clock ?? DateTime.now,
       _serverRecordsMisses = serverRecordsMisses ?? _hintedServerSupport;

  final AppDatabase db;
  final WorkspaceAccessRepository access;
  final SharedPreferences preferences;
  final DateTime Function() _clock;
  final Future<bool> Function() _serverRecordsMisses;

  static Future<bool> _hintedServerSupport() async =>
      await LedgerModeHint.read() == true &&
      await LedgerModeHint.readRecordedMiss();

  /// Whether any person on this device may have the setting on. Recording is
  /// on by default, so an absent preference counts as on and only an explicit
  /// `false` counts as off. Still a cheap check on the preferences alone, so
  /// the periodic task leaves the protected database closed once everyone who
  /// has answered has turned the setting off.
  static bool anyEnabled(SharedPreferences preferences) {
    final answered = preferences.getKeys().where(
      (key) => key.startsWith(_enabledPrefix),
    );
    if (answered.isEmpty) return true;
    return answered.any((key) => preferences.getBool(key) != false);
  }

  static final _enabledPrefix = autoMissEnabledPreferenceKey('');

  Future<AutoMissSweepResult> sweep() async {
    // A background isolate holds a stale copy of the preferences.
    await preferences.reload();
    if (!anyEnabled(preferences)) return const AutoMissSweepResult();
    await access.workspaces.ensureLocal();
    final workspaces = await db.select(db.careWorkspaces).get();
    var recorded = 0;
    for (final workspace in workspaces) {
      final owner = workspace.ownerUserId;
      if (!_enabled(owner)) continue;
      final WorkspaceContext? context;
      try {
        context = await access.contextForOwner(owner);
      } on WorkspaceAccessFailure {
        return AutoMissSweepResult(recorded: recorded, aborted: true);
      }
      if (context == null) continue;
      final now = _clock();
      // A connected workspace records only against a server that stores
      // misses. Until then nothing is back-filled: recording starts from the
      // moment the server can take it, so an upgrade never lands a burst.
      if (!context.isLocal && !await _serverRecordsMisses()) {
        await _setSince(owner, now);
        continue;
      }
      final since = _since(owner);
      if (since == null) {
        // No starting point yet, either because the setting is on by default
        // or because it predates this build. Start from now, so doses that are
        // already overdue are never swept in as a burst of misses.
        await _setSince(owner, now);
        continue;
      }
      final window = autoMissWindow(
        now: now,
        delay: Duration(minutes: _delayMinutes(owner)),
        since: since,
      );
      if (window == null) continue;
      try {
        recorded += await _sweepWorkspace(context, window);
      } on WorkspaceAccessFailure {
        return AutoMissSweepResult(recorded: recorded, aborted: true);
      }
    }
    if (recorded > 0) {
      AppLogger.debug('AutoMiss', 'Recorded $recorded missed dose(s)');
    }
    return AutoMissSweepResult(recorded: recorded);
  }

  Future<int> _sweepWorkspace(
    WorkspaceContext context,
    ({DateTime from, DateTime to}) window,
  ) async {
    final owner = context.ownerUserId;
    final repository = MedicationRepository(
      db,
      access: access,
      context: context,
    );
    final passed = <String>{};
    var recorded = 0;
    var attempted = 0;
    while (attempted < autoMissBatchSize && _enabled(owner)) {
      final rows =
          await (db.select(db.medicationOccurrences)
                ..where(
                  (o) =>
                      o.userId.equals(owner) &
                      o.state.equals('pending') &
                      o.stateVersion.equals(0) &
                      o.source.equals('scheduled') &
                      o.expected.equals(true) &
                      o.provenance.equals('exact') &
                      o.supersededAt.isNull() &
                      o.id.isNotIn(passed) &
                      o.plannedAt.isBiggerOrEqualValue(window.from) &
                      o.plannedAt.isSmallerOrEqualValue(window.to),
                )
                ..orderBy([(o) => OrderingTerm.asc(o.plannedAt)])
                ..limit(autoMissBatchSize - attempted))
              .get();
      if (rows.isEmpty) break;
      for (final row in rows) {
        attempted++;
        passed.add(row.id);
        if (await _write(repository, context, row)) recorded++;
      }
    }
    return recorded;
  }

  /// Returns whether a miss was written. A dose the repository refuses (its
  /// person or medication changed, a miss already exists, ...) is left alone
  /// and is not tried again in this sweep.
  Future<bool> _write(
    MedicationRepository repository,
    WorkspaceContext context,
    MedicationOccurrence row,
  ) async {
    final commandId = autoMissCommandId(
      ownerUserId: context.ownerUserId,
      occurrenceKey: row.occurrenceKey,
    );
    // A miss that was withdrawn, discarded or refused earlier keeps its
    // command, and the dose is never marked again by this device.
    if (await db.pendingOperationsDao.getByMutationId(
          context.ownerUserId,
          commandId,
        ) !=
        null) {
      return false;
    }
    try {
      await repository.apply(
        userId: context.ownerUserId,
        occurrenceId: row.id,
        action: MedicationAction.miss,
        actualTimeKnown: false,
        commandIdOverride: commandId,
        expectedStateVersion: 0,
      );
      return true;
    } on MedicationCommandBlocked {
      return false;
    } on WorkspaceAccessFailure catch (error) {
      // A dose whose medication or person is gone is not an access change.
      if (error.code == WorkspaceAccessFailureCode.wrongPerson) return false;
      rethrow;
    } on Object catch (error) {
      // One dose that cannot be written must not stop the others.
      AppLogger.warning(
        'AutoMiss',
        'A missed dose was not recorded: ${error.runtimeType}',
      );
      return false;
    }
  }

  // On by default: a person who has never answered still has misses recorded,
  // and only an explicit `false` turns it off. This back-fills nothing, because
  // an owner with no `since` marker gets one set to now by the sweep below.
  bool _enabled(String owner) =>
      preferences.getBool(autoMissEnabledPreferenceKey(owner)) ?? true;

  int _delayMinutes(String owner) {
    final stored = preferences.getInt(autoMissDelayPreferenceKey(owner));
    return (stored ?? autoMissDefaultDelayMinutes).clamp(
      _minDelayMinutes,
      _maxDelayMinutes,
    );
  }

  DateTime? _since(String owner) {
    final stored = preferences.getInt(autoMissSincePreferenceKey(owner));
    return stored == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(stored, isUtc: true);
  }

  Future<void> _setSince(String owner, DateTime at) async {
    try {
      await preferences.setInt(
        autoMissSincePreferenceKey(owner),
        at.toUtc().millisecondsSinceEpoch,
      );
    } on Object {
      // Not recorded: the next sweep tries again and nothing is missed early.
    }
  }
}
