import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/database.dart';
import 'ledger_mode_hint.dart';
import 'sync_retry_policy.dart';
import 'sync_service.dart';

/// Stock commands held in the outbox for the server's ledger (bridge mode).
///
/// This reuses [SyncService.deferredStockOperationIds] so the counts, banners
/// and sync decisions all agree on what "held" means. The result is empty
/// unless the server is known to have an inactive ledger.
Future<List<PendingOperation>> heldStockOperations(
  AppDatabase db,
  String userId,
) async {
  final ledgerActive = await LedgerModeHint.read();
  if (ledgerActive != false) return const [];
  final unsettled = await db.pendingOperationsDao.getUnsettledForUser(userId);
  final held = SyncService.deferredStockOperationIds(
    unsettled,
    ledgerActive: ledgerActive,
  );
  return [
    for (final operation in unsettled)
      if (held.contains(operation.id)) operation,
  ];
}

/// The local pill ids that have a held stock command.
Future<Set<String>> heldStockPillIds(AppDatabase db, String userId) async {
  final ids = <String>{};
  for (final operation in await heldStockOperations(db, userId)) {
    try {
      final payload = jsonDecode(operation.payloadJson);
      if (payload is! Map) continue;
      final command = payload['inventoryCommand'];
      final id =
          payload['entityLocalId'] ??
          (command is Map ? command['pillId'] : null);
      if (id is String) ids.add(id);
    } on FormatException {
      continue;
    }
  }
  return ids;
}

/// The local pill ids that have an unsettled inventory command that can still
/// reach the server, in any mode. A pull must not replace the phone's count
/// for these pills: the command carries the person's count (or a delta on it)
/// and has not reached the server, so the server's value is older than the
/// phone's.
///
/// A command in conflict, or blocked for review only, is not counted: it is
/// waiting for a person's decision (Use server version or Discard), and the
/// review must show the server's count, not a phone count no command will
/// ever deliver. A blocked command with an uncertain effect still counts: the
/// server may or may not hold it.
Future<Set<String>> unsettledInventoryPillIds(
  AppDatabase db,
  String userId,
) async {
  final ids = <String>{};
  for (final operation in await db.pendingOperationsDao.getUnsettledForUser(
    userId,
  )) {
    if (operation.component != 'medication') continue;
    if (operation.state == 'conflict') continue;
    if (operation.state == 'blocked' && !blockedMayHaveApplied(operation)) {
      continue;
    }
    try {
      final payload = jsonDecode(operation.payloadJson);
      if (payload is! Map || payload['inventoryCommand'] is! Map) continue;
      final id = (payload['inventoryCommand'] as Map)['pillId'];
      if (id is String) ids.add(id);
    } on FormatException {
      continue;
    }
  }
  return ids;
}

/// Why a stock effect waits for its pill's opening count. Persisted on the
/// held operation so the Sync page can say so.
const inventoryStartPendingCode = 'INVENTORY_START_PENDING';

/// Why an opening itself waits: another change touching the pill is blocked
/// or in conflict, so the count it would send is not settled. Persisted on
/// the start; the blocker is by definition stuck, so the start is stranded.
const inventoryStartReviewWaitCode = 'INVENTORY_START_WAITS_FOR_REVIEW';

/// Wait reasons the sync pass persists on a queued operation.
const inventoryWaitCodes = {
  inventoryStartPendingCode,
  inventoryStartReviewWaitCode,
};

/// Results whose effect on the server is unknown: the request may have been
/// applied. A start in this state still orders the stock effects after it.
const startUncertainCodes = {
  'MEDICATION_COMMAND_RESULT_UNCERTAIN',
  'MEDICATION_RECEIPT_IDENTITY_MISMATCH',
  'MEDICATION_INVENTORY_RESULT_UNCERTAIN',
};

/// The local pill id when [operation] is a stock start, else null.
String? startPillId(PendingOperation operation) {
  if (operation.component != 'medication') return null;
  try {
    final payload = jsonDecode(operation.payloadJson);
    final command = payload is Map ? payload['inventoryCommand'] : null;
    if (command is Map &&
        command['action'] == 'start' &&
        command['pillId'] is String) {
      return command['pillId'] as String;
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// Whether a start can still apply on the server, so that a later stock
/// effect must wait for it: it is queued, being sent or retrying, or its
/// outcome is uncertain. A start in conflict (the pill was already started,
/// the server's count is set) or blocked for review will never apply by
/// itself, so later doses, undos and corrections go out without it.
bool startCanStillApply(PendingOperation start) => switch (start.state) {
  'queued' || 'sending' || 'failedRetryable' => true,
  'blocked' => blockedMayHaveApplied(start),
  _ => false,
};

/// A blocked command whose effect on the server is unknown: its outcome is
/// uncertain, its retries ran out after transient failures, or it awaits
/// reconciliation. The server may have applied it, so what waits behind it
/// stays held. A definitive refusal (for example 400/422,
/// `MEDICATION_INVENTORY_REJECTED`) never applied and is not listed, even
/// though it keeps its frozen request.
bool blockedMayHaveApplied(PendingOperation operation) =>
    operation.state == 'blocked' &&
    (startUncertainCodes.contains(operation.safeErrorCode) ||
        operation.safeErrorCode == SyncRetryPolicy.retryExhaustedCode ||
        operation.safeErrorCode == SyncRetryPolicy.awaitingReconciliationCode);

/// Whether [localEventId] is in the frozen `foldedEventIds` of an opening that
/// has not committed yet but still can: its dose will be folded into it.
Future<bool> isPendingFolded(
  AppDatabase db,
  String userId,
  String localEventId,
) async {
  for (final op in await db.pendingOperationsDao.getUnsettledForUser(userId)) {
    if (startPillId(op) == null || !startCanStillApply(op)) continue;
    try {
      final payload = jsonDecode(op.payloadJson);
      final ids = payload is Map ? payload['foldedEventIds'] : null;
      if (ids is List && ids.contains(localEventId)) return true;
    } on FormatException {
      continue;
    }
  }
  return false;
}

/// Position in the outbox. The device clock can step backwards, so ordering
/// by `createdAt` could misplace an operation; the table's implicit rowid only
/// grows with each insert.
Future<Map<String, int>> outboxSequence(AppDatabase db, String userId) async {
  final rows = await db
      .customSelect(
        'SELECT id, rowid AS seq FROM pending_operations WHERE user_id = ?',
        variables: [Variable.withString(userId)],
      )
      .get();
  return {for (final r in rows) r.read<String>('id'): r.read<int>('seq')};
}

/// Whether an unsettled start for [localPillId], recorded before [operation]
/// and still able to apply, must be sent first.
Future<bool> startPrecedes(
  AppDatabase db,
  PendingOperation operation,
  String localPillId,
) async {
  final sequence = await outboxSequence(db, operation.userId);
  final mine = sequence[operation.id];
  for (final other in await db.pendingOperationsDao.getUnsettledForUser(
    operation.userId,
  )) {
    if (other.id == operation.id || startPillId(other) != localPillId) {
      continue;
    }
    if (!startCanStillApply(other)) continue;
    final theirs = sequence[other.id];
    final before = mine != null && theirs != null
        ? theirs < mine
        : !other.createdAt.isAfter(operation.createdAt);
    if (before) return true;
  }
  return false;
}
