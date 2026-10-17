import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/database.dart';

/// Client-only marker on a recorded miss that the app wrote on its own. It
/// lives in the local operation payload (`intent.origin`) and is never sent.
const autoMissOrigin = 'auto';

/// The server (or a newer fact on it) refused the automatic miss. The dose
/// stays as the server has it and nothing is shown to the person.
const autoMissNotAppliedCode = 'AUTO_MISS_NOT_APPLIED';

/// The person acted on the dose before the automatic miss ever left the
/// device, so the miss was withdrawn instead of being sent.
const autoMissWithdrawnCode = 'AUTO_MISS_WITHDRAWN';

const _openStates = {
  'queued',
  'sending',
  'failedRetryable',
  'conflict',
  'blocked',
};

Map<String, Object?>? _payloadOf(PendingOperation operation) {
  try {
    final decoded = jsonDecode(operation.payloadJson);
    return decoded is Map ? Map<String, Object?>.from(decoded) : null;
  } on FormatException {
    return null;
  }
}

/// Whether [operation] is a miss that the app recorded automatically.
bool isAutoMissOperation(PendingOperation operation) {
  if (operation.component != 'medication' ||
      operation.operationType != 'medication.command') {
    return false;
  }
  final payload = _payloadOf(operation);
  final intent = payload?['intent'];
  final command = payload?['command'];
  return intent is Map &&
      intent['origin'] == autoMissOrigin &&
      command is Map &&
      command['action'] == 'miss';
}

/// Drops an automatic miss that must not (or can no longer) be sent, and
/// hands its occurrence back to the latest server-acknowledged state.
///
/// Only the operation changes state; the local event row stays, and the
/// ledger readers skip an unsent event whose command was discarded. A person
/// never sees a review item for this, because nobody chose the miss.
/// Returns false when the operation had already left [from].
Future<bool> discardAutoMissOperation(
  AppDatabase db,
  PendingOperation operation, {
  required String from,
  required String safeErrorCode,
  bool resetPullCheckpoints = false,
}) async {
  final moved = await db.pendingOperationsDao.transitionState(
    operationId: operation.id,
    from: from,
    to: 'discarded',
    safeErrorCode: safeErrorCode,
  );
  if (!moved) return false;

  final all = await db.pendingOperationsDao.getForUser(operation.userId);
  for (final other in all) {
    if (other.dependsOnOperationId != operation.id) continue;
    await (db.update(
      db.pendingOperations,
    )..where((row) => row.id.equals(other.id))).write(
      PendingOperationsCompanion(
        dependsOnOperationId: Value(operation.dependsOnOperationId),
      ),
    );
  }

  final command = _payloadOf(operation)?['command'];
  final occurrenceId = command is Map ? command['occurrenceId'] : null;
  if (occurrenceId is String) {
    final stillNamed = all.any(
      (other) =>
          other.id != operation.id &&
          _openStates.contains(other.state) &&
          other.payloadJson.contains(occurrenceId),
    );
    if (!stillNamed) await _restoreOccurrence(db, occurrenceId);
  }
  if (resetPullCheckpoints) {
    await db.syncStateDao.resetPullCheckpoints(operation.userId);
  }
  return true;
}

Future<void> _restoreOccurrence(AppDatabase db, String occurrenceId) async {
  final occurrence = await db.medicationLedgerDao.getOccurrenceById(
    occurrenceId,
  );
  if (occurrence == null) return;
  final acknowledged =
      await (db.select(db.occurrenceEvents)
            ..where(
              (e) =>
                  e.occurrenceId.equals(occurrenceId) & e.serverId.isNotNull(),
            )
            ..orderBy([
              (e) => OrderingTerm.desc(e.resultVersion),
              (e) => OrderingTerm.desc(e.recordedAt),
            ])
            ..limit(1))
          .get();
  await (db.update(
    db.medicationOccurrences,
  )..where((row) => row.id.equals(occurrenceId))).write(
    MedicationOccurrencesCompanion(
      state: Value(
        acknowledged.isEmpty ? 'pending' : acknowledged.first.toState,
      ),
      stateVersion: Value(
        acknowledged.isEmpty ? 0 : acknowledged.first.resultVersion,
      ),
      updatedAt: Value(DateTime.now().toUtc()),
    ),
  );
  // The legacy dose-log projection of the miss goes with it.
  final scheduleId = occurrence.scheduleId;
  final plannedAt = occurrence.plannedAt;
  if (scheduleId == null || plannedAt == null) return;
  final log = await db.doseLogsDao.getByScheduledSlot(scheduleId, plannedAt);
  if (log != null && !log.isDeleted && log.status == 'missed') {
    await (db.update(db.doseLogs)..where((row) => row.id.equals(log.id))).write(
      DoseLogsCompanion(
        isDeleted: const Value(true),
        syncStatus: const Value('synced'),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }
}
