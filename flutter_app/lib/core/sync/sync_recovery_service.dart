import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../api/api_client.dart' show simpastilClientBuild;
import '../db/database.dart';
import 'auto_sync_service.dart';
import 'capabilities_client.dart';
import 'ledger_mode_hint.dart';
import 'held_stock.dart';
import 'sync_error_classifier.dart';
import 'sync_models.dart';
import 'sync_retry_policy.dart';
import 'sync_review_repository.dart' show projectMigrationIssues;
import 'sync_service.dart';

/// What a person sees an unsent change as.
enum RecoveryItemKind { person, medication, schedule, dose, other }

/// What kind of edit an unsent change is.
enum RecoveryChange { added, edited, removed, dose, stock, other }

/// Why an unsent change has not gone out, in plain terms.
enum RecoveryReason { queued, retrying, blocked, conflict, stranded }

/// Why a recovery action was refused.
enum RecoveryRefusal {
  /// Nothing matched: the item was already fixed or sent.
  nothingToDo,

  /// A change is being sent right now; try again in a moment.
  sending,

  /// The item has dose history that a discard would erase.
  hasDoseHistory,

  /// This kind of change has nothing that can be discarded here.
  notDiscardable,

  /// The server's copy cannot be fetched right now, so nothing was dropped.
  offline,

  /// Someone deleted the item on the server; keeping an edit cannot work.
  serverDeleted,
}

class RecoveryOperation {
  const RecoveryOperation({
    required this.id,
    required this.component,
    required this.change,
    required this.reason,
    required this.state,
    required this.attemptCount,
    this.safeErrorCode,
    this.nextAttemptAt,
    this.serverAlreadyWon = false,
    this.serverDeleted = false,
    this.waitingForStart = false,
  });

  final String id;
  final String component;
  final RecoveryChange change;
  final RecoveryReason reason;
  final String state;
  final int attemptCount;
  final String? safeErrorCode;

  /// For a retrying change: the first moment it may be sent again.
  final DateTime? nextAttemptAt;

  /// A conflict the app already settled in the server's favour; only a
  /// "Dismiss" remains for a person to do.
  final bool serverAlreadyWon;

  /// The server holds a tombstone for the item: someone deleted it there, so
  /// re-sending an edit would only be refused again.
  final bool serverDeleted;

  /// A stock effect (dose, undo or correction) held until its medication's
  /// stock start has been sent.
  final bool waitingForStart;
}

/// One thing the person knows about (a person, a medication, a schedule or a
/// dose) with all of its unsent changes.
class RecoveryItem {
  const RecoveryItem({
    required this.key,
    required this.kind,
    required this.name,
    required this.operations,
    required this.reason,
    required this.canRetry,
    required this.canUseServerVersion,
    required this.discardBlockedByHistory,
    required this.canKeepMine,
    required this.canDismiss,
    required this.needsMedicationReview,
    this.detail,
    this.serverDeleted = false,
    this.canTryAgain = false,
    this.canDiscard = false,
    this.discardCount = 0,
  });

  /// Stable handle for recovery actions: kind plus the local row id. Not shown.
  final String key;
  final RecoveryItemKind kind;

  /// The item's own name as stored on this phone; null when it is gone.
  final String? name;

  /// A second line such as a schedule's time.
  final String? detail;
  final List<RecoveryOperation> operations;
  final RecoveryReason reason;
  final bool canRetry;
  final bool canUseServerVersion;

  /// The item was created on this phone and has dose history: dropping it
  /// would erase records, so discarding is shown disabled with a reason.
  final bool discardBlockedByHistory;
  final bool canKeepMine;
  final bool canDismiss;

  /// Medication-ledger evidence: resolved in the review sheet, not here.
  final bool needsMedicationReview;

  /// The item was deleted on the server; only accepting that is productive.
  final bool serverDeleted;

  /// "Try again": requeue this item's stuck changes (or send what waits).
  final bool canTryAgain;

  /// "Discard this change": drop this item's unsent changes without a
  /// separate "use server version" path. Never offered where that path or a
  /// history guard applies.
  final bool canDiscard;

  /// How many changes discarding drops: the stuck one and everything that
  /// depends on it.
  final int discardCount;

  /// Whether the person has at least one way to resolve this item.
  bool get hasAction =>
      canTryAgain ||
      canDiscard ||
      canUseServerVersion ||
      canKeepMine ||
      canDismiss;

  bool get isCreate => operations.any((o) => o.change == RecoveryChange.added);

  DateTime? get nextAttemptAt {
    DateTime? earliest;
    for (final op in operations) {
      final at = op.nextAttemptAt;
      if (at != null && (earliest == null || at.isBefore(earliest))) {
        earliest = at;
      }
    }
    return earliest;
  }

  String? get safeErrorCode {
    for (final op in operations) {
      if (op.safeErrorCode != null) return op.safeErrorCode;
    }
    return null;
  }
}

/// A kept review note that no unsent change is waiting behind. It blocks
/// nothing; dismissing it closes the note and keeps its stored details.
class RecoveryNote {
  const RecoveryNote({required this.issueId, required this.createdAt});

  final String issueId;
  final DateTime createdAt;
}

class RecoveryReport {
  const RecoveryReport({
    required this.items,
    required this.counts,
    this.notes = const [],
  });

  static const empty = RecoveryReport(
    items: [],
    counts: SyncOperationCounts.none,
  );

  final List<RecoveryItem> items;
  final SyncOperationCounts counts;
  final List<RecoveryNote> notes;

  bool get isEmpty => items.isEmpty && notes.isEmpty;
  bool get hasRetryable => items.any((item) => item.canRetry);
}

class RecoveryOutcome {
  const RecoveryOutcome({
    this.refusal,
    this.affected = 0,
    this.flushed = false,
    this.pulled = false,
    this.busy = false,
    this.serverCopyPending = false,
  });

  final RecoveryRefusal? refusal;
  final int affected;

  /// Whether the follow-up flush ran (false when offline or busy).
  final bool flushed;
  final bool pulled;
  final bool busy;

  /// The unsent change was dropped but the server's copy has not been
  /// downloaded yet. The next pull replays everything and replaces it.
  final bool serverCopyPending;

  bool get ok => refusal == null;
}

typedef RecoveryFlush = Future<void> Function(String userId);
typedef RecoveryPull = Future<bool> Function(String userId);

/// Waits (bounded) for an automatic sync to finish and says whether the
/// sync engine is idle now. A recovery action that flushes or pulls while a
/// run is in flight would silently do nothing and reset checkpoints under
/// that run's pull.
typedef RecoveryWaitForIdle = Future<bool> Function();

typedef RecoveryIsOnline = Future<bool> Function();

/// The recovery actions behind "Fix sync problems".
///
/// Every action works on the outbox as data: it never sends a mutation of its
/// own. After changing the outbox it flushes (always before pulling) and then
/// pulls, exactly like a normal sync.
class SyncRecoveryService {
  SyncRecoveryService({
    required AppDatabase db,
    required RecoveryFlush flush,
    required RecoveryPull pull,
    required Future<T> Function<T>(String userId, Future<T> Function() action)
    write,
    RecoveryWaitForIdle? waitForIdle,
    RecoveryIsOnline? isOnline,
    DateTime Function()? now,
  }) : _db = db,
       _flush = flush,
       _pull = pull,
       _write = write,
       _waitForIdle = waitForIdle ?? _alwaysIdle,
       _isOnline = isOnline ?? _alwaysIdle,
       _now = now ?? (() => DateTime.now().toUtc());

  final AppDatabase _db;
  final RecoveryFlush _flush;
  final RecoveryPull _pull;
  final RecoveryWaitForIdle _waitForIdle;
  final RecoveryIsOnline _isOnline;
  static Future<bool> _alwaysIdle() async => true;
  final Future<T> Function<T>(String userId, Future<T> Function() action)
  _write;
  final DateTime Function() _now;

  /// How long a recovery action waits for a running automatic sync.
  static const idleWait = Duration(seconds: 30);
  static const _ids = Uuid();

  static const _open = {
    'queued',
    'sending',
    'failedRetryable',
    'blocked',
    'conflict',
  };
  static const _conflictIssue = 'stable_revision_conflict_server_wins';

  /// Blocked evidence only the medication review can settle. Requeueing it
  /// would just block it again, so Retry all leaves it alone.
  static const _reviewOnlyCodes = {
    'MEDICATION_BRIDGE_RESULT_UNCERTAIN',
    'MEDICATION_RECONCILIATION_REQUIRED',
    'SPLIT_EFFECT_REQUIRES_RECONCILIATION',
    'SPLIT_REVIEW_REQUIRED',
    'SPLIT_RECONCILIATION_RECEIPT_MISMATCH',
    'MEDICATION_BRIDGE_REQUEST_IDENTITY_MISMATCH',
    'BRIDGE_CANNOT_REPRESENT_PENDING_STATE',
  };

  // ── Diagnose ────────────────────────────────────────────────────────────

  /// How many kept notes Fix sync problems lists. Read-only: unlike
  /// [diagnose] it repairs nothing, so a page can show it just by opening.
  Future<int> countNotes(String userId) async {
    final all = await _db.pendingOperationsDao.getUnsettledForUser(userId);
    final ledgerActive = await LedgerModeHint.read();
    final held = SyncService.deferredStockOperationIds(
      all,
      ledgerActive: ledgerActive,
    );
    final open = {
      for (final op in all)
        if (_open.contains(op.state) && !held.contains(op.id)) op.id,
    };
    final issues = await _db.migrationIssuesDao.getUnresolved(userId);
    return (await _notes(userId, issues, open)).length;
  }

  Future<RecoveryReport> diagnose(String userId) =>
      _write(userId, () => _diagnose(userId));

  Future<RecoveryReport> _diagnose(String userId) async {
    await _releaseOrphanedDependents(userId);
    if (await _reconcileDiscardedProjections(userId)) {
      // Rows were handed back to the server's copy; the next pull must be
      // allowed to replace them, so it replays from the start.
      await _db.syncStateDao.resetPullCheckpoints(userId);
    }
    final all = await _db.pendingOperationsDao.getUnsettledForUser(userId);
    final ledgerActive = await LedgerModeHint.read();
    final counts = SyncService.tallyOperations(all, ledgerActive: ledgerActive);
    // Stock waiting for the server's ledger is information, not a problem.
    final heldForLedger = SyncService.deferredStockOperationIds(
      all,
      ledgerActive: ledgerActive,
    );
    final open = all
        .where(
          (op) => _open.contains(op.state) && !heldForLedger.contains(op.id),
        )
        .toList();
    final issues = await _db.migrationIssuesDao.getUnresolved(userId);
    final notes = await _notes(userId, issues, {for (final op in open) op.id});
    if (open.isEmpty) {
      return RecoveryReport(items: const [], counts: counts, notes: notes);
    }

    final byId = {for (final op in all) op.id: op};
    final conflictOps = <String>{
      for (final issue in issues)
        if (issue.issueCode == _conflictIssue)
          ?_snapshotOperationId(issue.snapshotJson),
    };

    final groups = <String, List<PendingOperation>>{};
    final metas = <String, _Meta>{};
    for (final op in open) {
      final meta = _Meta.of(op);
      metas[op.id] = meta;
      groups.putIfAbsent(meta.key(op), () => []).add(op);
    }

    final items = <RecoveryItem>[];
    for (final entry in groups.entries) {
      final ops = entry.value;
      final first = metas[ops.first.id]!;
      final recoveryOps = <RecoveryOperation>[];
      var canRetry = false;
      var needsReview = false;
      var canKeepMine = false;
      var canDismiss = false;
      var hasStableConflictNeedingChoice = false;
      var hasStableTrouble = false;
      var hasLedgerConflict = false;
      var canTryAgain = false;
      var serverDeletedItem = false;
      for (final op in ops) {
        final meta = metas[op.id]!;
        final queuedOrRetrying =
            op.state == 'queued' || op.state == 'failedRetryable';
        final waitingForStart =
            op.safeErrorCode == inventoryStartPendingCode && queuedOrRetrying;
        final stranded =
            _strandedBehindStuck(op, byId) ||
            (queuedOrRetrying &&
                op.safeErrorCode == inventoryStartReviewWaitCode) ||
            (waitingForStart && _startIsStuck(op, byId.values));
        final reason = switch (op.state) {
          'conflict' => RecoveryReason.conflict,
          'blocked' => RecoveryReason.blocked,
          _ when stranded => RecoveryReason.stranded,
          'failedRetryable' => RecoveryReason.retrying,
          _ => RecoveryReason.queued,
        };
        final ledger = op.component != 'stable' && op.component != 'account';
        var serverWon = false;
        if (op.state == 'conflict' && !ledger) {
          final row = await _rowState(meta);
          serverWon =
              conflictOps.contains(op.id) &&
              row != null &&
              row.syncStatus == 'synced';
        }
        final serverDeleted =
            op.state == 'conflict' && !ledger && _serverDeleted(issues, op.id);
        if (serverDeleted) serverDeletedItem = true;
        if (op.state == 'conflict' && ledger) {
          needsReview = true;
          hasLedgerConflict = true;
        }
        if (op.state != 'conflict' ||
            ledger ||
            (meta.action == 'create' && op.component == 'stable')) {
          // Conflicts of edits are settled by the server/mine choice; every
          // other stuck or waiting change can be sent again.
          canTryAgain = true;
        }
        if (op.state == 'blocked') {
          final reviewOnly = await _isReviewOnly(op);
          if (reviewOnly) {
            needsReview = true;
          } else {
            canRetry = true;
          }
        }
        if (op.state == 'failedRetryable') canRetry = true;
        if (op.state == 'conflict' && !ledger) {
          // Re-sending an edit to something deleted on the server is refused
          // again, so the only offer is to accept the delete.
          if (serverWon && !serverDeleted) canDismiss = true;
          if (!serverDeleted &&
              (meta.action == 'update' || meta.action == 'delete')) {
            canKeepMine = true;
          }
          if (!serverWon || serverDeleted) {
            hasStableConflictNeedingChoice = true;
          }
        }
        if (op.component == 'stable' &&
            (op.state == 'blocked' || op.state == 'conflict') &&
            !serverWon) {
          hasStableTrouble = true;
        }
        recoveryOps.add(
          RecoveryOperation(
            id: op.id,
            component: op.component,
            change: meta.change,
            reason: reason,
            state: op.state,
            attemptCount: op.attemptCount,
            safeErrorCode: op.safeErrorCode,
            nextAttemptAt: reason == RecoveryReason.retrying
                ? SyncRetryPolicy.notBefore(op.lastAttemptAt, op.attemptCount)
                : null,
            serverAlreadyWon: serverWon,
            serverDeleted: serverDeleted,
            waitingForStart: waitingForStart,
          ),
        );
      }
      final discardable = const {
        'profile',
        'pill',
        'schedule',
      }.contains(first.entityType);
      final isCreate = recoveryOps.any(
        (o) => o.change == RecoveryChange.added && o.component == 'stable',
      );
      var historyBlocked = false;
      if (discardable &&
          isCreate &&
          (hasStableTrouble || hasStableConflictNeedingChoice)) {
        historyBlocked = await _hasDoseHistory(
          first.entityType!,
          first.localId!,
        );
      }
      final stableUseServer =
          discardable &&
          (hasStableTrouble || hasStableConflictNeedingChoice) &&
          !historyBlocked;
      final canUseServer = stableUseServer || hasLedgerConflict;
      final hasStable = ops.any((op) => op.component == 'stable');
      final hasOther = ops.any((op) => op.component != 'stable');
      // Anything the stable path cannot drop (history, ledger, account,
      // unknown kinds) can always be discarded on its own.
      final canDiscard =
          hasOther ||
          (hasStable &&
              !(discardable && first.localId != null) &&
              !historyBlocked);
      final reason = recoveryOps
          .map((o) => o.reason)
          .reduce((a, b) => _severity(a) >= _severity(b) ? a : b);
      final labels = await _labels(first);
      items.add(
        RecoveryItem(
          key: entry.key,
          kind: first.kind,
          name: labels.name,
          detail: labels.detail,
          operations: recoveryOps,
          reason: reason,
          canRetry: canRetry,
          canUseServerVersion: canUseServer,
          discardBlockedByHistory: historyBlocked,
          canKeepMine: canKeepMine,
          canDismiss: canDismiss,
          needsMedicationReview: needsReview,
          serverDeleted: serverDeletedItem,
          canTryAgain: canTryAgain,
          canDiscard: canDiscard,
          discardCount: canDiscard
              ? _doomedFor(
                  ops,
                  stableHandled: discardable && first.localId != null,
                ).length
              : 0,
        ),
      );
    }
    items.sort((a, b) {
      final bySeverity = _severity(b.reason).compareTo(_severity(a.reason));
      return bySeverity != 0 ? bySeverity : a.key.compareTo(b.key);
    });
    return RecoveryReport(items: items, counts: counts, notes: notes);
  }

  /// Review notes a person can only close: unresolved, from this phone, not
  /// shown with their own choices on the Sync page and not tied to any change
  /// that is still waiting. Kept details are retained when one is dismissed.
  Future<List<RecoveryNote>> _notes(
    String userId,
    List<MigrationIssue> issues,
    Set<String> shownOperationIds,
  ) async {
    // The Sync page lists exactly what this projection calls actionable, so a
    // note is judged by the same projection: retained history and retired
    // records are information there, never a review.
    final projected = await projectMigrationIssues(
      _db,
      userId,
      issues,
      medicationProjectionSettled: false,
      stableProjectionSettled: false,
    );
    final information = {
      for (final summary in projected)
        if (summary.isHistoricalInformation) summary.id,
    };
    final open = {
      for (final issue in issues)
        if (_linkedOperationId(issue, shownOperationIds) != null)
          issue.id: true,
    };
    return [
      for (final issue in issues)
        if (_isPlainNote(issue) &&
            !information.contains(issue.id) &&
            !open.containsKey(issue.id))
          RecoveryNote(issueId: issue.id, createdAt: issue.createdAt),
    ];
  }

  String? _linkedOperationId(MigrationIssue issue, Set<String> operationIds) {
    final snapshotId = _snapshotOperationId(issue.snapshotJson);
    if (snapshotId != null && operationIds.contains(snapshotId)) {
      return snapshotId;
    }
    return operationIds.contains(issue.entityId) ? issue.entityId : null;
  }

  static bool _isPlainNote(MigrationIssue issue) {
    if (issue.serverId != null) return false;
    // Historical evidence and issues with their own choices on the Sync page
    // are not notes.
    if (issue.entityType == 'legacy_medication_history') return false;
    if (issue.entityType == 'medication_split') return false;
    return !const {
      'invalid_schedule_frequency_days',
      'schedule_timezone_review_required',
      'legacy_split_checkpoint',
    }.contains(issue.issueCode);
  }

  /// A change that waits on a discarded change would wait forever. Free it
  /// (or re-parent it onto the nearest change that still exists).
  Future<int> _releaseOrphanedDependents(String userId) async {
    final all = await _db.pendingOperationsDao.getForUser(userId);
    final byId = {for (final op in all) op.id: op};
    var freed = 0;
    for (final op in all) {
      if (!_open.contains(op.state)) continue;
      var next = op.dependsOnOperationId;
      if (next == null) continue;
      final seen = <String>{};
      var changed = false;
      while (next != null && seen.add(next)) {
        final dependency = byId[next];
        if (dependency != null && dependency.state != 'discarded') break;
        changed = true;
        next = dependency?.dependsOnOperationId;
      }
      if (!changed) continue;
      await (_db.update(_db.pendingOperations)
            ..where((row) => row.id.equals(op.id)))
          .write(PendingOperationsCompanion(dependsOnOperationId: Value(next)));
      freed++;
    }
    return freed;
  }

  /// Rows a discarded change once guarded can be left behind "not synced"
  /// with nothing to send (a build that discarded without handing them back).
  /// Such a row is returned to the server's copy, exactly as a fresh discard
  /// does. A row that any open change still names stays guarded, and events
  /// are never removed or rewritten. Returns whether anything changed.
  ///
  /// A discarded change is looked at until the pass finds nothing left to do
  /// for it, then carries [_reconciledMarker] (appended to its code) and is not scanned again. A
  /// change whose rows another open change still names stays unmarked, so the
  /// pass that follows that change's settlement still hands the rows back.
  Future<bool> _reconcileDiscardedProjections(String userId) async {
    final all = await _db.pendingOperationsDao.getForUser(userId);
    final discarded = [
      for (final op in all)
        if (op.state == 'discarded' && !_isReconciled(op.safeErrorCode)) op,
    ];
    if (discarded.isEmpty) return false;
    final deferred = <String>{};
    var changed = await _reconcileGuardedRows(
      userId,
      all,
      discarded,
      deferredOpIds: deferred,
    );
    final remaining = [
      for (final op in all)
        if (_open.contains(op.state)) op,
    ];
    final byCommand = {for (final op in discarded) op.mutationId: op};
    final orphanOccurrences = <String>{};
    final orphanOps = <String, Set<String>>{};
    final unsent = await (_db.select(
      _db.occurrenceEvents,
    )..where((e) => e.userId.equals(userId) & e.serverId.isNull())).get();
    for (final event in unsent) {
      final op = byCommand[event.commandId];
      if (op != null) {
        orphanOccurrences.add(event.occurrenceId);
        (orphanOps[event.occurrenceId] ??= {}).add(op.id);
      }
    }
    for (final id in orphanOccurrences) {
      if (remaining.any((op) => op.payloadJson.contains(id))) {
        deferred.addAll(orphanOps[id] ?? const {});
        continue;
      }
      final row = await (_db.select(
        _db.medicationOccurrences,
      )..where((o) => o.id.equals(id))).getSingleOrNull();
      if (row == null) continue;
      final events =
          await (_db.select(_db.occurrenceEvents)
                ..where((e) => e.occurrenceId.equals(id))
                ..orderBy([(e) => OrderingTerm.desc(e.resultVersion)]))
              .get();
      // Only a state that the discarded command itself produced is wrong.
      final head = events
          .where((e) => e.resultVersion == row.stateVersion)
          .toList();
      if (head.length != 1 ||
          head.single.serverId != null ||
          !byCommand.containsKey(head.single.commandId)) {
        continue;
      }
      final acknowledged = events.where((e) => e.serverId != null).toList();
      await (_db.update(
        _db.medicationOccurrences,
      )..where((o) => o.id.equals(id))).write(
        MedicationOccurrencesCompanion(
          state: Value(
            acknowledged.isEmpty ? 'pending' : acknowledged.first.toState,
          ),
          stateVersion: Value(
            acknowledged.isEmpty ? 0 : acknowledged.first.resultVersion,
          ),
        ),
      );
      changed = true;
    }
    // The marker is appended to the code that explained the discard, never
    // written over it, and only while the row is still discarded.
    for (final op in discarded) {
      if (deferred.contains(op.id)) continue;
      final code = op.safeErrorCode;
      await (_db.update(_db.pendingOperations)..where(
            (row) => row.id.equals(op.id) & row.state.equals('discarded'),
          ))
          .write(
            PendingOperationsCompanion(
              safeErrorCode: Value(
                code == null ? _reconciledMarker : '$code$_reconciledSuffix',
              ),
            ),
          );
    }
    return changed;
  }

  /// Written on a discarded change once its projections were reconciled. It is
  /// appended to the original error code (`CODE__DISCARD_RECONCILED`) so the
  /// reason for the discard is kept; a discard without a code carries it alone.
  static const _reconciledMarker = 'DISCARD_RECONCILED';
  static const _reconciledSuffix = '__$_reconciledMarker';

  static bool _isReconciled(String? code) =>
      code != null && code.endsWith(_reconciledMarker);

  static int _severity(RecoveryReason reason) => switch (reason) {
    RecoveryReason.conflict => 5,
    RecoveryReason.blocked => 4,
    RecoveryReason.stranded => 3,
    RecoveryReason.retrying => 2,
    RecoveryReason.queued => 1,
  };

  bool _strandedBehindStuck(
    PendingOperation op,
    Map<String, PendingOperation> byId,
  ) {
    if (op.state == 'blocked' || op.state == 'conflict') return false;
    final seen = <String>{op.id};
    var next = op.dependsOnOperationId;
    while (next != null && seen.add(next)) {
      final dependency = byId[next];
      if (dependency == null) return false;
      if (dependency.state == 'blocked' || dependency.state == 'conflict') {
        return true;
      }
      next = dependency.dependsOnOperationId;
    }
    return false;
  }

  /// The medication's stock start is blocked with an uncertain outcome, so a
  /// held stock effect cannot go out until a person settles it.
  bool _startIsStuck(PendingOperation held, Iterable<PendingOperation> all) {
    String? pillId;
    try {
      final payload = jsonDecode(held.payloadJson);
      final command = payload is Map ? payload['inventoryCommand'] : null;
      final projection = payload is Map ? payload['localProjection'] : null;
      final id = command is Map
          ? command['pillId']
          : projection is Map
          ? projection['pillId']
          : null;
      if (id is String) pillId = id;
    } on FormatException {
      return false;
    }
    if (pillId == null) return false;
    return all.any(
      (op) => blockedMayHaveApplied(op) && startPillId(op) == pillId,
    );
  }

  Future<bool> _isReviewOnly(PendingOperation op) async {
    if (_reviewOnlyCodes.contains(op.safeErrorCode)) return true;
    if (op.component == 'stable' || op.component == 'account') return false;
    final effects = await _db.pendingOperationsDao.getEffects(op.id);
    return effects.any(
      (e) => e.state == 'uncertain' || e.state == 'localReviewRequired',
    );
  }

  // ── Retry all ───────────────────────────────────────────────────────────

  /// Requeues every blocked and retrying change under its own id (a frozen
  /// body stays frozen, so a changed body or an unsupported undo is blocked
  /// again by the next send), then flushes and pulls.
  Future<RecoveryOutcome> retryAll(String userId) async {
    final requeued = await _write(userId, () async {
      final ops = await _db.pendingOperationsDao.getUnsettledForUser(userId);
      final targets = <PendingOperation>[];
      for (final op in ops) {
        if (op.state == 'failedRetryable') {
          targets.add(op);
        } else if (op.state == 'blocked' && !await _isReviewOnly(op)) {
          targets.add(op);
        }
      }
      final exhaustedIds = <String>{};
      for (final op in targets) {
        final exhausted =
            op.safeErrorCode == SyncRetryPolicy.retryExhaustedCode;
        await (_db.update(_db.pendingOperations)..where(
              (row) => row.id.equals(op.id) & row.state.equals(op.state),
            ))
            .write(
              PendingOperationsCompanion(
                state: const Value('queued'),
                lastAttemptAt: const Value(null),
                safeErrorCode: const Value(null),
                safeCorrelationId: const Value(null),
                // Only a spent retry budget is refilled; it always has a
                // frozen body, so a replay stays byte-identical.
                attemptCount: exhausted ? const Value(0) : const Value.absent(),
              ),
            );
        if (exhausted) exhaustedIds.add(op.id);
      }
      if (exhaustedIds.isNotEmpty) {
        await _resolveIssues(
          userId,
          (issue) =>
              issue.issueCode == SyncRetryPolicy.retryExhaustedIssueCode &&
              exhaustedIds.contains(issue.entityId),
        );
      }
      return targets.length;
    });
    final result = await _flushAndPull(userId);
    return RecoveryOutcome(
      affected: requeued,
      flushed: result.flushed,
      pulled: result.pulled,
      busy: result.busy,
    );
  }

  // ── Try again (one item) ────────────────────────────────────────────────

  /// Requeues this item's stuck changes under their own ids (a frozen body
  /// stays frozen, so the server recognises a repeat), closes the review
  /// notes they raised, then flushes and pulls. Changes that only wait are
  /// simply sent. A conflict over an edit is not requeued: it needs the
  /// server/mine choice, because the same edit would be refused again.
  Future<RecoveryOutcome> tryAgain(String userId, String key) async {
    final result = await _write<({RecoveryRefusal? refusal, int count})>(
      userId,
      () async {
        final all = await _db.pendingOperationsDao.getForUser(userId);
        final mine = [
          for (final op in all)
            if (_open.contains(op.state) && _Meta.of(op).key(op) == key) op,
        ];
        if (mine.isEmpty) {
          return (refusal: RecoveryRefusal.nothingToDo, count: 0);
        }
        if (mine.any((op) => op.state == 'sending')) {
          return (refusal: RecoveryRefusal.sending, count: 0);
        }
        final requeue = <PendingOperation>[
          for (final op in mine)
            if (op.state == 'blocked' ||
                op.state == 'failedRetryable' ||
                (op.state == 'conflict' &&
                    (op.component != 'stable' ||
                        _Meta.of(op).action == 'create')))
              op,
        ];
        final queuedOnly = mine.every((op) => op.state == 'queued');
        if (requeue.isEmpty && !queuedOnly) {
          return (refusal: RecoveryRefusal.nothingToDo, count: 0);
        }
        for (final op in requeue) {
          await (_db.update(_db.pendingOperations)..where(
                (row) => row.id.equals(op.id) & row.state.equals(op.state),
              ))
              .write(
                PendingOperationsCompanion(
                  state: const Value('queued'),
                  lastAttemptAt: const Value(null),
                  safeErrorCode: const Value(null),
                  safeCorrelationId: const Value(null),
                  attemptCount:
                      op.safeErrorCode == SyncRetryPolicy.retryExhaustedCode
                      ? const Value(0)
                      : const Value.absent(),
                ),
              );
        }
        final ids = {for (final op in requeue) op.id};
        if (ids.isNotEmpty) {
          await _resolveIssues(
            userId,
            (issue) =>
                ids.contains(_snapshotOperationId(issue.snapshotJson)) ||
                ids.contains(issue.entityId),
          );
        }
        return (refusal: null, count: requeue.length);
      },
    );
    if (result.refusal != null) return RecoveryOutcome(refusal: result.refusal);
    final sent = await _flushAndPull(userId);
    return RecoveryOutcome(
      affected: result.count,
      flushed: sent.flushed,
      pulled: sent.pulled,
      busy: sent.busy,
    );
  }

  /// What discarding an item drops: its stuck changes (or the whole item when
  /// nothing is stuck) plus every change of the same item that depends,
  /// directly or through others, on a dropped one. A queued undo chained to a
  /// dropped dose could never be sent, so it goes with it. Changes that do
  /// not depend on a dropped one are released, not lost.
  static List<PendingOperation> _doomedFor(
    List<PendingOperation> mine, {
    required bool stableHandled,
  }) {
    final candidates = [
      for (final op in mine)
        if (op.component != 'stable' || !stableHandled) op,
    ];
    final stuck = [
      for (final op in candidates)
        if (op.state != 'queued') op,
    ];
    final doomed = stuck.isEmpty ? candidates : stuck;
    final ids = {for (final op in doomed) op.id};
    var grew = true;
    while (grew) {
      grew = false;
      for (final op in candidates) {
        if (ids.contains(op.id)) continue;
        if (ids.contains(op.dependsOnOperationId)) {
          ids.add(op.id);
          grew = true;
        }
      }
    }
    return [
      for (final op in candidates)
        if (ids.contains(op.id)) op,
    ];
  }

  // ── Discard (one item) ──────────────────────────────────────────────────

  /// Drops this item's unsent changes that have no "use the server's
  /// version" path: dose and stock commands, bridge and account changes and
  /// changes of unknown kind. Only changes that never reached the server are
  /// dropped, and nothing already recorded is rewritten. Changes that waited
  /// behind a stuck one are released, not dropped, the rows the dropped changes guarded
  /// are handed back to the server's copy, and the flush that follows sends
  /// what was waiting before the pull replaces those rows.
  Future<RecoveryOutcome> discardItem(String userId, String key) async {
    var needsServerCopy = false;
    final refusal = await _write<RecoveryRefusal?>(userId, () async {
      final all = await _db.pendingOperationsDao.getForUser(userId);
      final mine = [
        for (final op in all)
          if (_open.contains(op.state) && _Meta.of(op).key(op) == key) op,
      ];
      if (mine.isEmpty) return RecoveryRefusal.nothingToDo;
      if (mine.any((op) => op.state == 'sending')) {
        return RecoveryRefusal.sending;
      }
      final first = _Meta.of(mine.first);
      final stableHandled =
          const {'profile', 'pill', 'schedule'}.contains(first.entityType) &&
          first.localId != null;
      final doomed = _doomedFor(mine, stableHandled: stableHandled);
      if (doomed.isEmpty) return RecoveryRefusal.notDiscardable;
      if (doomed.any((op) => op.component == 'stable') &&
          first.entityType != null &&
          first.localId != null &&
          doomed.any((op) => _Meta.of(op).action == 'create') &&
          await _hasDoseHistory(first.entityType!, first.localId!)) {
        return RecoveryRefusal.hasDoseHistory;
      }
      needsServerCopy = await _discardUnsent(userId, all, doomed);
      return null;
    });
    if (refusal != null) return RecoveryOutcome(refusal: refusal);
    return _afterDiscard(userId, needsServerCopy);
  }

  /// Marks [doomed] discarded, releases what waited behind them and hands the
  /// local rows they guarded back to the server's copy. Returns whether the
  /// next pull must replay from the start (checkpoints are reset here, so a
  /// failing pull cannot leave those rows un-replayed).
  Future<bool> _discardUnsent(
    String userId,
    List<PendingOperation> all,
    List<PendingOperation> doomed,
  ) async {
    final ids = {for (final op in doomed) op.id};
    await _discardOps(userId, all, ids);
    await _repairOccurrences(all, doomed);
    final reconciled = await _reconcileGuardedRows(userId, all, doomed);
    // Ledger state (occurrences, stock) is rebuilt from the server by a full
    // replay, whether or not a guarded row needed freeing.
    final ledger = doomed.any((op) => op.component != 'stable');
    if (ledger || reconciled) {
      await _db.syncStateDao.resetPullCheckpoints(userId);
      return true;
    }
    return false;
  }

  /// A dropped dose command leaves its occurrence showing the state the
  /// command optimistically set. When nothing else unsent names the
  /// occurrence, put the projection back to the latest server-acknowledged
  /// event (or pending, version 0). Events themselves are never touched.
  Future<void> _repairOccurrences(
    List<PendingOperation> all,
    List<PendingOperation> dropped,
  ) async {
    final droppedIds = {for (final op in dropped) op.id};
    final occurrenceIds = {
      for (final op in dropped)
        if (_Meta.of(op) case final meta
            when meta.entityType == 'occurrence' && meta.localId != null)
          meta.localId!,
    };
    for (final id in occurrenceIds) {
      final stillUnsent = all.any((op) {
        if (droppedIds.contains(op.id) || !_open.contains(op.state)) {
          return false;
        }
        final meta = _Meta.of(op);
        return meta.entityType == 'occurrence' && meta.localId == id;
      });
      if (stillUnsent) continue;
      final events =
          await (_db.select(_db.occurrenceEvents)
                ..where(
                  (e) => e.occurrenceId.equals(id) & e.serverId.isNotNull(),
                )
                ..orderBy([
                  (e) => OrderingTerm.desc(e.resultVersion),
                  (e) => OrderingTerm.desc(e.recordedAt),
                ])
                ..limit(1))
              .get();
      await (_db.update(
        _db.medicationOccurrences,
      )..where((o) => o.id.equals(id))).write(
        MedicationOccurrencesCompanion(
          state: Value(events.isEmpty ? 'pending' : events.first.toState),
          stateVersion: Value(events.isEmpty ? 0 : events.first.resultVersion),
        ),
      );
    }
  }

  Future<RecoveryOutcome> _afterDiscard(
    String userId,
    bool needsServerCopy,
  ) async {
    final outcome = await _recheck(userId, resetCheckpoints: false);
    if (needsServerCopy && !outcome.pulled) {
      return RecoveryOutcome(
        flushed: outcome.flushed,
        busy: outcome.busy,
        serverCopyPending: true,
      );
    }
    return outcome;
  }

  /// A local row that a dropped change guarded stays "not synced" forever and
  /// the pull never replaces it. Hand it back, unless another unsent change
  /// still names it. A dose row that only the dropped change created is
  /// retired the way a discarded create is.
  Future<bool> _reconcileGuardedRows(
    String userId,
    List<PendingOperation> all,
    List<PendingOperation> dropped, {
    Set<String>? deferredOpIds,
  }) async {
    final droppedIds = {for (final op in dropped) op.id};
    final owners = <String, Set<String>>{};
    void own(String id, PendingOperation op) => (owners[id] ??= {}).add(op.id);
    final remaining = [
      for (final op in all)
        if (_open.contains(op.state) && !droppedIds.contains(op.id)) op,
    ];
    bool stillNamed(String id) => remaining.any(
      (op) => op.payloadJson.contains(id) || op.dependsOnOperationId == id,
    );
    final pills = <String>{};
    final doseLogs = <String>{};
    final createdDoseLogs = <String>{};
    for (final op in dropped) {
      final meta = _Meta.of(op);
      Map<String, Object?>? payload;
      try {
        final decoded = jsonDecode(op.payloadJson);
        if (decoded is Map) payload = Map<String, Object?>.from(decoded);
      } on FormatException {
        payload = null;
      }
      final projection = payload?['localProjection'];
      if (projection is Map) {
        final pillId = projection['pillId'];
        final delta = projection['inventoryDelta'];
        if (pillId is String && delta is int && delta != 0) {
          pills.add(pillId);
          own(pillId, op);
        }
        final doseId = projection['legacyDoseSourceId'];
        if (doseId is String) {
          doseLogs.add(doseId);
          own(doseId, op);
        }
      }
      if (meta.entityType == 'pill' && meta.localId != null) {
        pills.add(meta.localId!);
        own(meta.localId!, op);
      }
      if (meta.entityType == 'dose_log' && meta.localId != null) {
        doseLogs.add(meta.localId!);
        own(meta.localId!, op);
        if (meta.action == 'create' ||
            op.operationType == 'legacy_dose_write') {
          createdDoseLogs.add(meta.localId!);
        }
      }
    }
    var changed = false;
    for (final id in pills) {
      if (stillNamed(id)) {
        deferredOpIds?.addAll(owners[id] ?? const {});
        continue;
      }
      final row = await _db.pillsDao.getById(id);
      if (row == null || row.syncStatus == 'synced') continue;
      // A pill never sent has no server copy to return to.
      if (row.serverId == null) continue;
      await (_db.update(_db.pills)..where((r) => r.id.equals(id))).write(
        const PillsCompanion(syncStatus: Value('synced')),
      );
      changed = true;
    }
    for (final id in doseLogs) {
      if (stillNamed(id)) {
        deferredOpIds?.addAll(owners[id] ?? const {});
        continue;
      }
      final row = await (_db.select(
        _db.doseLogs,
      )..where((r) => r.id.equals(id))).getSingleOrNull();
      if (row == null || row.syncStatus == 'synced') continue;
      if (row.serverId == null) {
        if (!createdDoseLogs.contains(id)) continue;
        await (_db.update(_db.doseLogs)..where((r) => r.id.equals(id))).write(
          DoseLogsCompanion(
            isDeleted: const Value(true),
            syncStatus: const Value('synced'),
            updatedAt: Value(_now()),
          ),
        );
      } else {
        await (_db.update(_db.doseLogs)..where((r) => r.id.equals(id))).write(
          const DoseLogsCompanion(syncStatus: Value('synced')),
        );
      }
      changed = true;
    }
    return changed;
  }

  // ── Review notes ────────────────────────────────────────────────────────

  /// Closes a kept review note that nothing waits behind. The stored details
  /// stay; only the unresolved mark is removed.
  Future<RecoveryOutcome> dismissNote(String userId, String issueId) async {
    final closed = await _write(userId, () async {
      final issues = await _db.migrationIssuesDao.getUnresolved(userId);
      final all = await _db.pendingOperationsDao.getUnsettledForUser(userId);
      final held = SyncService.deferredStockOperationIds(
        all,
        ledgerActive: await LedgerModeHint.read(),
      );
      final ids = {
        for (final op in all)
          if (_open.contains(op.state) && !held.contains(op.id)) op.id,
      };
      final notes = (await _notes(
        userId,
        issues,
        ids,
      )).map((n) => n.issueId).toSet();
      if (!notes.contains(issueId)) return 0;
      await _resolveIssues(userId, (issue) => issue.id == issueId);
      return 1;
    });
    return closed == 0
        ? const RecoveryOutcome(refusal: RecoveryRefusal.nothingToDo)
        : const RecoveryOutcome(affected: 1);
  }

  // ── Use server version ──────────────────────────────────────────────────

  /// Drops this phone's unsent change to a person, medication or schedule so
  /// the server's version wins. Dose history is never dropped.
  ///
  /// Dropping an edit marks the row as the server's copy, so the pull that
  /// follows must be able to replace it. Waiting for a running sync and
  /// checking the network happen before anything is dropped; the replay of
  /// the pull checkpoints is recorded together with the drop, so even a pull
  /// that then fails still replaces the row on the next run.
  Future<RecoveryOutcome> useServerVersion(String userId, String key) async {
    if (!await _waitForIdle()) return const RecoveryOutcome(busy: true);
    final online = await _isOnline();
    var needsServerCopy = false;
    final refusal = await _write<RecoveryRefusal?>(userId, () async {
      final all = await _db.pendingOperationsDao.getForUser(userId);
      final mine = [
        for (final op in all)
          if (_open.contains(op.state) && _Meta.of(op).key(op) == key) op,
      ];
      if (mine.isEmpty) return RecoveryRefusal.nothingToDo;
      if (mine.any((op) => op.state == 'sending')) {
        return RecoveryRefusal.sending;
      }
      final meta = _Meta.of(mine.first);
      final type = meta.entityType;
      final localId = meta.localId;
      final stable = [
        for (final op in mine)
          if (op.component == 'stable') op,
      ];
      if (type == null ||
          localId == null ||
          !const {'profile', 'pill', 'schedule'}.contains(type) ||
          stable.isEmpty) {
        // A dose or stock conflict: the server's copy wins by dropping the
        // unsent command and downloading the ledger again.
        final conflicts = [
          for (final op in mine)
            if (op.component != 'stable' && op.state == 'conflict') op,
        ];
        if (conflicts.isEmpty) return RecoveryRefusal.notDiscardable;
        if (!online) return RecoveryRefusal.offline;
        needsServerCopy = await _discardUnsent(userId, all, conflicts);
        return null;
      }
      final isCreate = stable.any((op) => _Meta.of(op).action == 'create');
      if (isCreate) {
        if (await _hasDoseHistory(type, localId)) {
          return RecoveryRefusal.hasDoseHistory;
        }
        await _discardCreate(userId, all, type, localId);
      } else {
        final issues = await _db.migrationIssuesDao.getUnresolved(userId);
        final deletedThere = stable.any((op) => _serverDeleted(issues, op.id));
        // Accepting a delete the server already made needs no download.
        if (!deletedThere && !online) return RecoveryRefusal.offline;
        // The same medication can also carry this phone's unsent stock
        // command (same item key). Taking the server's version drops it
        // too; left behind it would conflict again on every sync, because
        // the server's revision has moved past its frozen base revision.
        // Dropping it needs the server copy, so refuse before discarding
        // anything: an offline refusal must change nothing.
        final stock = [
          for (final op in mine)
            if (op.component != 'stable') op,
        ];
        if (stock.isNotEmpty && !online) return RecoveryRefusal.offline;
        await _discardOps(userId, all, {for (final op in stable) op.id});
        await _resetRowToServer(type, localId, deleted: deletedThere);
        if (stock.isNotEmpty) {
          await _discardUnsent(userId, all, stock);
          needsServerCopy = true;
        }
        if (!deletedThere) {
          // The pull must really refresh the row: replay from the beginning,
          // recorded now so a failing pull cannot leave it un-replayed.
          await _db.syncStateDao.resetPullCheckpoints(userId);
          needsServerCopy = true;
        }
      }
      return null;
    });
    if (refusal != null) return RecoveryOutcome(refusal: refusal);
    final outcome = await _recheck(userId, resetCheckpoints: !needsServerCopy);
    if (needsServerCopy && !outcome.pulled) {
      return RecoveryOutcome(
        flushed: outcome.flushed,
        busy: outcome.busy,
        serverCopyPending: true,
      );
    }
    return outcome;
  }

  Future<void> _discardCreate(
    String userId,
    List<PendingOperation> all,
    String type,
    String localId,
  ) async {
    // The item and everything that hangs off it on this phone.
    final profiles = <String>{if (type == 'profile') localId};
    final pills = <String>{if (type == 'pill') localId};
    final schedules = <String>{if (type == 'schedule') localId};
    if (profiles.isNotEmpty) {
      for (final id in profiles) {
        pills.addAll([
          for (final pill in await _db.pillsDao.getByProfileId(id)) pill.id,
        ]);
      }
    }
    for (final id in pills) {
      schedules.addAll([
        for (final s in await _db.schedulesDao.getByPillId(id)) s.id,
      ]);
    }
    final entityIds = {...profiles, ...pills, ...schedules};
    // Operations of those entities plus anything that depends on them.
    final doomed = <String>{};
    var grew = true;
    while (grew) {
      grew = false;
      for (final op in all) {
        if (!_open.contains(op.state) || doomed.contains(op.id)) continue;
        final meta = _Meta.of(op);
        final belongs =
            entityIds.contains(meta.localId) ||
            entityIds.contains(meta.parentLocalId) ||
            doomed.contains(op.dependsOnOperationId);
        if (belongs) {
          doomed.add(op.id);
          grew = true;
        }
      }
    }
    await _discardOps(userId, all, doomed);
    final now = _now();
    for (final id in schedules) {
      await (_db.update(_db.schedules)..where((r) => r.id.equals(id))).write(
        SchedulesCompanion(
          isDeleted: const Value(true),
          syncStatus: const Value('synced'),
          updatedAt: Value(now),
        ),
      );
    }
    for (final id in pills) {
      await (_db.update(_db.pills)..where((r) => r.id.equals(id))).write(
        PillsCompanion(
          isDeleted: const Value(true),
          syncStatus: const Value('synced'),
          updatedAt: Value(now),
        ),
      );
    }
    for (final id in profiles) {
      await (_db.update(_db.profiles)..where((r) => r.id.equals(id))).write(
        ProfilesCompanion(
          isDeleted: const Value(true),
          syncStatus: const Value('synced'),
          updatedAt: Value(now),
        ),
      );
    }
  }

  /// Marks [ids] discarded, re-parents operations that depended on them onto
  /// the nearest surviving ancestor (or frees them) and closes the review
  /// issues those operations raised.
  Future<void> _discardOps(
    String userId,
    List<PendingOperation> all,
    Set<String> ids,
  ) async {
    final byId = {for (final op in all) op.id: op};
    for (final op in all) {
      if (ids.contains(op.id)) continue;
      if (!ids.contains(op.dependsOnOperationId)) continue;
      var next = op.dependsOnOperationId;
      final seen = <String>{};
      while (next != null && ids.contains(next) && seen.add(next)) {
        next = byId[next]?.dependsOnOperationId;
      }
      await (_db.update(_db.pendingOperations)
            ..where((row) => row.id.equals(op.id)))
          .write(PendingOperationsCompanion(dependsOnOperationId: Value(next)));
    }
    await (_db.update(_db.pendingOperations)
          ..where((row) => row.id.isIn(ids) & row.state.isIn(_open.toList())))
        .write(const PendingOperationsCompanion(state: Value('discarded')));
    await _resolveIssues(
      userId,
      (issue) =>
          ids.contains(issue.entityId) ||
          ids.contains(_snapshotOperationId(issue.snapshotJson)),
    );
  }

  Future<void> _resetRowToServer(
    String type,
    String localId, {
    bool deleted = false,
  }) async {
    switch (type) {
      case 'profile':
        await (_db.update(
          _db.profiles,
        )..where((r) => r.id.equals(localId))).write(
          ProfilesCompanion(
            syncStatus: const Value('synced'),
            isDeleted: Value(deleted),
          ),
        );
      case 'pill':
        await (_db.update(_db.pills)..where((r) => r.id.equals(localId))).write(
          PillsCompanion(
            syncStatus: const Value('synced'),
            isDeleted: Value(deleted),
          ),
        );
      case 'schedule':
        await (_db.update(
          _db.schedules,
        )..where((r) => r.id.equals(localId))).write(
          SchedulesCompanion(
            syncStatus: const Value('synced'),
            isDeleted: Value(deleted),
          ),
        );
    }
  }

  // ── Keep my change ──────────────────────────────────────────────────────

  /// Records the person's edit again on top of the latest server revision,
  /// under a new mutation id. The operation keeps its place in the outbox.
  Future<RecoveryOutcome> keepMyChange(String userId, String key) async {
    final refusal = await _write<RecoveryRefusal?>(userId, () async {
      final all = await _db.pendingOperationsDao.getForUser(userId);
      final mine = [
        for (final op in all)
          if (op.state == 'conflict' &&
              op.component == 'stable' &&
              _Meta.of(op).key(op) == key)
            op,
      ];
      if (mine.isEmpty) return RecoveryRefusal.nothingToDo;
      final issues = await _db.migrationIssuesDao.getUnresolved(userId);
      if (mine.any((op) => _serverDeleted(issues, op.id))) {
        return RecoveryRefusal.serverDeleted;
      }
      for (final op in mine) {
        final meta = _Meta.of(op);
        final type = meta.entityType;
        final localId = meta.localId;
        if (type == null ||
            localId == null ||
            (meta.action != 'update' && meta.action != 'delete')) {
          continue;
        }
        Map<String, Object?> payload;
        try {
          final decoded = jsonDecode(op.payloadJson);
          if (decoded is! Map) continue;
          payload = Map<String, Object?>.from(decoded);
        } on FormatException {
          continue;
        }
        final revision = _serverRevision(issues, op.id);
        await _reapplyIntent(type, localId, meta.action!, payload, revision);
        for (final frozen in const [
          'frozenRequest',
          'resolvedCommand',
          'resolvedInventoryRequest',
          'medicationBridgeRequest',
        ]) {
          payload.remove(frozen);
        }
        await (_db.update(
          _db.pendingOperations,
        )..where((row) => row.id.equals(op.id))).write(
          PendingOperationsCompanion(
            mutationId: Value(_ids.v4()),
            payloadJson: Value(jsonEncode(payload)),
            state: const Value('queued'),
            attemptCount: const Value(0),
            lastAttemptAt: const Value(null),
            safeErrorCode: const Value(null),
            safeCorrelationId: const Value(null),
          ),
        );
        await _resolveIssues(
          userId,
          (issue) => _snapshotOperationId(issue.snapshotJson) == op.id,
        );
      }
      return null;
    });
    if (refusal != null) return RecoveryOutcome(refusal: refusal);
    final result = await _flushAndPull(userId);
    return RecoveryOutcome(
      flushed: result.flushed,
      pulled: result.pulled,
      busy: result.busy,
      affected: 1,
    );
  }

  /// Whether the conflict issue of [operationId] recorded a server tombstone.
  bool _serverDeleted(List<MigrationIssue> issues, String operationId) {
    for (final issue in issues) {
      if (issue.issueCode != _conflictIssue) continue;
      if (_snapshotOperationId(issue.snapshotJson) != operationId) continue;
      try {
        final decoded = jsonDecode(issue.snapshotJson);
        final entity = decoded is Map ? decoded['serverEntity'] : null;
        if (entity is Map && entity['deletedAt'] != null) return true;
      } on FormatException {
        continue;
      }
    }
    return false;
  }

  int? _serverRevision(List<MigrationIssue> issues, String operationId) {
    for (final issue in issues) {
      if (_snapshotOperationId(issue.snapshotJson) != operationId) continue;
      try {
        final decoded = jsonDecode(issue.snapshotJson);
        final entity = decoded is Map ? decoded['serverEntity'] : null;
        final revision = entity is Map ? entity['revision'] : null;
        final parsed = int.tryParse('$revision');
        if (parsed != null && parsed > 0) return parsed;
      } on FormatException {
        continue;
      }
    }
    return null;
  }

  Future<void> _reapplyIntent(
    String type,
    String localId,
    String action,
    Map<String, Object?> payload,
    int? serverRevision,
  ) async {
    final data = payload['data'] is Map
        ? Map<String, Object?>.from(payload['data'] as Map)
        : <String, Object?>{};
    final isDelete = action == 'delete';
    Value<T> pick<T>(String name) =>
        !isDelete && data.containsKey(name) && data[name] is T?
        ? Value(data[name] as T)
        : const Value.absent();
    final now = _now();
    switch (type) {
      case 'profile':
        await (_db.update(
          _db.profiles,
        )..where((r) => r.id.equals(localId))).write(
          ProfilesCompanion(
            name: pick<String>('name'),
            avatarEmoji: pick<String>('avatarEmoji'),
            isActive: pick<bool>('isActive'),
            isDeleted: isDelete ? const Value(true) : const Value.absent(),
            revision: serverRevision == null
                ? const Value.absent()
                : Value(serverRevision),
            syncStatus: const Value('pending'),
            updatedAt: Value(now),
          ),
        );
      case 'pill':
        await (_db.update(_db.pills)..where((r) => r.id.equals(localId))).write(
          PillsCompanion(
            name: pick<String>('name'),
            dosage: pick<String>('dosage'),
            notes: pick<String>('notes'),
            color: pick<String>('color'),
            lowStockThreshold: pick<int>('lowStockThreshold'),
            isPrn: pick<bool>('isPrn'),
            isDeleted: isDelete ? const Value(true) : const Value.absent(),
            revision: serverRevision == null
                ? const Value.absent()
                : Value(serverRevision),
            syncStatus: const Value('pending'),
            updatedAt: Value(now),
          ),
        );
      case 'schedule':
        final days = data['frequencyDays'];
        await (_db.update(
          _db.schedules,
        )..where((r) => r.id.equals(localId))).write(
          SchedulesCompanion(
            hour: pick<int>('hour'),
            minute: pick<int>('minute'),
            frequency: pick<String>('frequency'),
            isActive: pick<bool>('isActive'),
            timeZone: pick<String>('timeZone'),
            frequencyDays: isDelete || !data.containsKey('frequencyDays')
                ? const Value.absent()
                : Value(
                    days == null
                        ? null
                        : (days is String ? days : jsonEncode(days)),
                  ),
            isDeleted: isDelete ? const Value(true) : const Value.absent(),
            revision: serverRevision == null
                ? const Value.absent()
                : Value(serverRevision),
            syncStatus: const Value('pending'),
            updatedAt: Value(now),
          ),
        );
    }
  }

  // ── Dismiss ─────────────────────────────────────────────────────────────

  /// Closes conflicts the app already settled in the server's favour.
  Future<RecoveryOutcome> dismiss(String userId, String key) async {
    final count = await _write(userId, () async {
      final all = await _db.pendingOperationsDao.getForUser(userId);
      final issues = await _db.migrationIssuesDao.getUnresolved(userId);
      final settled = <String>{
        for (final issue in issues)
          if (issue.issueCode == _conflictIssue)
            ?_snapshotOperationId(issue.snapshotJson),
      };
      final ids = <String>{};
      for (final op in all) {
        if (op.state != 'conflict' || op.component != 'stable') continue;
        if (_Meta.of(op).key(op) != key || !settled.contains(op.id)) continue;
        final row = await _rowState(_Meta.of(op));
        if (row != null && row.syncStatus == 'synced') ids.add(op.id);
      }
      if (ids.isEmpty) return 0;
      await _discardOps(userId, all, ids);
      return ids.length;
    });
    return count == 0
        ? const RecoveryOutcome(refusal: RecoveryRefusal.nothingToDo)
        : RecoveryOutcome(affected: count);
  }

  // ── Re-download ─────────────────────────────────────────────────────────

  /// Sends what is waiting, forgets where each pull stopped and downloads
  /// everything again. Unsent changes are kept: merges skip any row that has
  /// one.
  Future<RecoveryOutcome> redownload(String userId) =>
      _recheck(userId, resetCheckpoints: true);

  Future<RecoveryOutcome> _recheck(
    String userId, {
    required bool resetCheckpoints,
  }) async {
    var flushed = false;
    try {
      // Never flush into, or reset checkpoints under, a run in flight.
      if (!await _waitForIdle()) return const RecoveryOutcome(busy: true);
      await _flush(userId);
      flushed = true;
    } on SyncBusyException {
      return const RecoveryOutcome(busy: true);
    }
    if (resetCheckpoints) {
      // An automatic run may have started while the flush was sending; its
      // pull must not lose its staging run to this reset.
      if (!await _waitForIdle()) {
        return const RecoveryOutcome(flushed: true, busy: true);
      }
      await _write(userId, () => _db.syncStateDao.resetPullCheckpoints(userId));
    }
    try {
      final pulled = await _pull(userId);
      return RecoveryOutcome(flushed: flushed, pulled: pulled);
    } on SyncBusyException {
      return RecoveryOutcome(flushed: flushed, busy: true);
    }
  }

  Future<({bool flushed, bool pulled, bool busy})> _flushAndPull(
    String userId,
  ) async {
    try {
      if (!await _waitForIdle()) {
        return (flushed: false, pulled: false, busy: true);
      }
      await _flush(userId);
    } on SyncBusyException {
      return (flushed: false, pulled: false, busy: true);
    }
    try {
      final pulled = await _pull(userId);
      return (flushed: true, pulled: pulled, busy: false);
    } on SyncBusyException {
      return (flushed: true, pulled: false, busy: true);
    }
  }

  // ── Diagnostics ─────────────────────────────────────────────────────────

  /// A report safe to paste into a support message: counts, codes, versions
  /// and times. It never includes names, notes, tokens, e-mail addresses, the
  /// server address or full identifiers (operations appear as short hashes).
  Future<String> buildDiagnostics(
    String userId, {
    ServerCapabilities? capabilities,
    String? appVersion,
  }) async {
    final data = await _write(userId, () async {
      final ops = await _db.pendingOperationsDao.getForUser(userId);
      final issues = await _db.migrationIssuesDao.getUnresolved(userId);
      final states = await (_db.select(
        _db.syncComponentStates,
      )..where((row) => row.userId.equals(userId))).get();
      return (ops, issues, states);
    });
    final ops = data.$1;
    final issues = data.$2;
    final states = data.$3;
    final unsent = ops.where((op) => _open.contains(op.state)).toList();
    final counts = SyncService.tallyOperations(
      unsent,
      ledgerActive: capabilities?.medicationLedgerActive,
    );

    String code(String? raw) =>
        raw != null && RegExp(r'^[A-Z][A-Z0-9_]{0,63}$').hasMatch(raw)
        ? raw
        : (raw == null ? '-' : 'OTHER');
    String type(String raw) =>
        RegExp(r'^[A-Za-z_]{1,32}(\.[A-Za-z_]{1,32})?$').hasMatch(raw)
        ? raw
        : 'unknown';
    String shortHash(String id) =>
        sha256.convert(utf8.encode(id)).toString().substring(0, 8);
    String day(DateTime? at) =>
        at == null ? 'never' : at.toUtc().toIso8601String();
    Map<String, int> tally(Iterable<String> values) {
      final out = <String, int>{};
      for (final v in values) {
        out[v] = (out[v] ?? 0) + 1;
      }
      return Map.fromEntries(
        out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
      );
    }

    String line(Map<String, int> m) => m.isEmpty
        ? 'none'
        : m.entries.map((e) => '${e.key}=${e.value}').join(', ');

    final out = StringBuffer()
      ..writeln('Simpastil sync diagnostics')
      ..writeln(
        'App build: $simpastilClientBuild'
        '${appVersion == null ? '' : ' ($appVersion)'}',
      )
      ..writeln('Created: ${day(_now())}');
    if (capabilities == null) {
      out.writeln('Server: capabilities unavailable');
    } else {
      out.writeln(
        'Server: release ${capabilities.serverRelease.replaceAll(RegExp(r'[^0-9A-Za-z._+-]'), '')}, '
        'minimum client build ${capabilities.minimumClientBuild}, '
        'medication ledger ${capabilities.medicationLedgerActive ? 'active' : 'inactive'}, '
        'bridge contract ${capabilities.medicationBridgeContractVersion}, '
        'bridge PRN ${capabilities.medicationBridgePrnCommands ? 'yes' : 'no'}, '
        'bridge undo ${capabilities.bridgeUndo ? 'yes' : 'no'}',
      );
    }
    out
      ..writeln('Unsent changes: ${counts.total}')
      ..writeln(
        'Tally: queued=${counts.queued}, retrying=${counts.retrying}, '
        'blocked=${counts.blocked}, conflict=${counts.conflict}, '
        'stranded=${counts.stranded}, '
        'awaitingLedger=${counts.awaitingLedger}',
      )
      ..writeln('By state: ${line(tally(ops.map((o) => o.state)))}')
      ..writeln(
        'Unsent by component: ${line(tally(unsent.map((o) => o.component)))}',
      )
      ..writeln(
        'Error codes: ${line(tally(unsent.where((o) => o.safeErrorCode != null).map((o) => code(o.safeErrorCode))))}',
      )
      ..writeln(
        'Review items: ${line(tally(issues.map((i) => code(i.issueCode.toUpperCase()))))}',
      );
    for (final state in states) {
      out.writeln(
        'Component ${state.component}: ${state.currentState}, '
        'last full sync ${day(state.lastFullSuccessAt)}, '
        'checkpoint ${state.lastCompletedCursor == null ? 'none' : 'set'}',
      );
    }
    if (unsent.isNotEmpty) out.writeln('Operations:');
    for (final op in unsent.take(50)) {
      out.writeln(
        '  ${shortHash(op.id)} ${op.component} ${type(op.operationType)} '
        '${op.state} code=${code(op.safeErrorCode)} attempts=${op.attemptCount} '
        'last=${day(op.lastAttemptAt)}',
      );
    }
    if (unsent.length > 50) out.writeln('  (${unsent.length - 50} more)');
    return out.toString();
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  Future<void> _resolveIssues(
    String userId,
    bool Function(MigrationIssue issue) test,
  ) async {
    final issues = await _db.migrationIssuesDao.getUnresolved(userId);
    await _db.migrationIssuesDao.markResolved(
      [
        for (final issue in issues)
          if (test(issue)) issue.id,
      ],
      resolvedByUserId: userId,
      at: _now(),
    );
  }

  static String? _snapshotOperationId(String snapshotJson) {
    try {
      final decoded = jsonDecode(snapshotJson);
      final id = decoded is Map ? decoded['operationId'] : null;
      return id is String ? id : null;
    } on FormatException {
      return null;
    }
  }

  Future<({String syncStatus, bool isDeleted})?> _rowState(_Meta meta) async {
    final id = meta.localId;
    if (id == null) return null;
    switch (meta.entityType) {
      case 'profile':
        final row = await _db.profilesDao.getById(id);
        return row == null
            ? null
            : (syncStatus: row.syncStatus, isDeleted: row.isDeleted);
      case 'pill':
        final row = await _db.pillsDao.getById(id);
        return row == null
            ? null
            : (syncStatus: row.syncStatus, isDeleted: row.isDeleted);
      case 'schedule':
        final row = await _db.schedulesDao.getById(id);
        return row == null
            ? null
            : (syncStatus: row.syncStatus, isDeleted: row.isDeleted);
    }
    return null;
  }

  /// Dose logs, recorded occurrences or dose events attached to the item.
  Future<bool> _hasDoseHistory(String type, String localId) async {
    final pillIds = <String>{};
    final scheduleIds = <String>{};
    if (type == 'profile') {
      for (final pill in await _db.pillsDao.getByProfileId(localId)) {
        pillIds.add(pill.id);
      }
    } else if (type == 'pill') {
      pillIds.add(localId);
    } else if (type == 'schedule') {
      scheduleIds.add(localId);
    }
    for (final id in pillIds) {
      for (final schedule in await _db.schedulesDao.getByPillId(id)) {
        scheduleIds.add(schedule.id);
      }
    }
    for (final id in scheduleIds) {
      final logs = await _db
          .customSelect(
            'SELECT 1 FROM dose_logs WHERE schedule_id = ? LIMIT 1',
            variables: [Variable<String>(id)],
          )
          .get();
      if (logs.isNotEmpty) return true;
    }
    for (final (column, ids) in [
      ('pill_id', pillIds),
      ('schedule_id', scheduleIds),
    ]) {
      for (final id in ids) {
        // Events of discarded commands never reached the server and are not
        // history worth protecting.
        final events = await _db
            .customSelect(
              'SELECT 1 FROM occurrence_events AS e '
              'JOIN medication_occurrences AS o ON o.id = e.occurrence_id '
              'WHERE o.$column = ? AND NOT EXISTS ('
              "SELECT 1 FROM pending_operations AS p WHERE p.state = 'discarded' "
              'AND p.mutation_id = e.command_id) LIMIT 1',
              variables: [Variable<String>(id)],
            )
            .get();
        if (events.isNotEmpty) return true;
      }
    }
    return false;
  }

  Future<({String? name, String? detail})> _labels(_Meta meta) async {
    final id = meta.localId;
    if (id == null) return (name: null, detail: null);
    switch (meta.entityType) {
      case 'profile':
        return (name: (await _db.profilesDao.getById(id))?.name, detail: null);
      case 'pill':
        return (name: (await _db.pillsDao.getById(id))?.name, detail: null);
      case 'schedule':
        final schedule = await _db.schedulesDao.getById(id);
        if (schedule == null) return (name: null, detail: null);
        final pill = await _db.pillsDao.getById(schedule.pillId);
        final time =
            '${schedule.hour.toString().padLeft(2, '0')}:${schedule.minute.toString().padLeft(2, '0')}';
        return (name: pill?.name, detail: time);
      case 'occurrence':
        final row = await (_db.select(
          _db.medicationOccurrences,
        )..where((o) => o.id.equals(id))).getSingleOrNull();
        final pillId = row?.pillId;
        final pill = pillId == null ? null : await _db.pillsDao.getById(pillId);
        return (name: pill?.name, detail: row?.plannedLocalTime);
    }
    return (name: null, detail: null);
  }
}

/// What an operation's payload says it touches. Reads only the structural
/// fields; never the data.
class _Meta {
  _Meta({
    required this.entityType,
    required this.localId,
    required this.parentLocalId,
    required this.action,
    required this.kind,
    required this.change,
  });

  final String? entityType;
  final String? localId;
  final String? parentLocalId;
  final String? action;
  final RecoveryItemKind kind;
  final RecoveryChange change;

  String key(PendingOperation op) =>
      localId == null ? 'op:${op.id}' : '${kind.name}:$localId';

  factory _Meta.of(PendingOperation op) {
    String? entityType, localId, parent, action;
    try {
      final decoded = jsonDecode(op.payloadJson);
      if (decoded is Map) {
        entityType = decoded['entityType'] as String?;
        localId = decoded['entityLocalId'] as String?;
        parent = decoded['parentEntityLocalId'] as String?;
        action = decoded['action'] as String?;
      }
    } on FormatException {
      // Unreadable payloads are shown as an unnamed change.
    } on TypeError {
      // Same: a malformed field is not worth failing the screen for.
    }
    final type = op.operationType;
    action ??= type.contains('.') ? type.split('.').last : null;
    final kind = switch (entityType) {
      'profile' => RecoveryItemKind.person,
      'pill' => RecoveryItemKind.medication,
      'schedule' => RecoveryItemKind.schedule,
      'occurrence' || 'dose_log' => RecoveryItemKind.dose,
      _ =>
        type.startsWith('legacy_dose') || type.startsWith('medication.')
            ? RecoveryItemKind.dose
            : type.startsWith('legacy_stock') || type.startsWith('inventory.')
            ? RecoveryItemKind.medication
            : RecoveryItemKind.other,
    };
    final change =
        type.startsWith('inventory.') || type.startsWith('legacy_stock')
        ? RecoveryChange.stock
        : type.startsWith('medication.') || type.startsWith('legacy_dose')
        ? RecoveryChange.dose
        : switch (action) {
            'create' => RecoveryChange.added,
            'update' || 'repair' => RecoveryChange.edited,
            'delete' => RecoveryChange.removed,
            _ => RecoveryChange.other,
          };
    return _Meta(
      entityType: entityType,
      localId: localId,
      parentLocalId: parent,
      action: action,
      kind: kind,
      change: change,
    );
  }
}

final syncRecoveryServiceProvider = Provider<SyncRecoveryService>((ref) {
  final sync = ref.watch(syncServiceProvider);
  return SyncRecoveryService(
    db: ref.watch(databaseProvider),
    waitForIdle: () async {
      try {
        await ref
            .read(autoSyncServiceProvider)
            .drain()
            .timeout(SyncRecoveryService.idleWait);
      } on TimeoutException {
        // Still running: reported as busy below.
      }
      return !sync.isSyncing;
    },
    isOnline: sync.isOnline,
    flush: (userId) async {
      if (sync.isSyncing) throw const SyncBusyException();
      await sync.flushPending(userId: userId);
      // flushPending returns without an outcome when a run claimed the
      // engine first: that is busy, not a flush that found nothing to send.
      if (sync.lastFlushOutcome == null) throw const SyncBusyException();
    },
    pull: (userId) async {
      if (sync.isSyncing) throw const SyncBusyException();
      return sync.pullFromServer(userId: userId);
    },
    write: <T>(userId, action) async {
      final scope = sync.writeScope;
      if (scope == null) return ref.read(databaseProvider).transaction(action);
      scope.requireOwner(userId);
      return scope.write(action);
    },
  );
});
