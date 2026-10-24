import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../db/database.dart';
import '../medication/medication_extras.dart';
import 'pending_operation_repository.dart';
import 'pill_unsent_work.dart';
import 'sync_write_scope.dart';

/// Moves a pill edit made before the journal existed into the journal.
///
/// The older writer marked a pill unsent when its PATCH failed and only logged
/// the failure. The settle leaves such a row alone (it has no journal history,
/// so its edit was never delivered) and the pull guards it. On a server with
/// the versioned protocol nothing else resends it: the legacy resend reads
/// unsent rows, the versioned path reads only the journal. Without this the
/// row would stay unsent, and the server's own changes to it would never
/// apply, until the person edited it again.
///
/// So each such row is queued once as a `pill.update` carrying the whole pill
/// (a `pill.delete` for a deleted one). Queuing it gives the pill journal
/// history, so the next run passes it by: no marker is needed. A journal that
/// cannot be read could already hold the pill's work, so nothing is queued
/// then.
///
/// The person can edit the pill between the first read and the queue (a sync
/// starts while they save). Their edit is queued with the newer values, so an
/// older snapshot queued behind it would overwrite it on the server. Each pill
/// is therefore re-read, and its journal history and unsent flag rechecked,
/// inside the transaction that queues it.
class PreJournalPillBackfill {
  const PreJournalPillBackfill({
    required this.db,
    this.writeScope,
    @visibleForTesting this.beforeQueue,
  });

  final AppDatabase db;
  final SyncWriteScope? writeScope;

  /// Runs after the candidates were read and before each is queued, so a test
  /// can save an edit in that gap.
  final Future<void> Function(String pillId)? beforeQueue;

  /// Queues the pre-journal edits of [userId]; returns how many it queued.
  Future<int> run({required String userId}) async {
    final candidates = await _unsentKnownPills(userId);
    if (candidates.isEmpty) return 0;
    final journal = await PillJournal.read(db, userId);
    if (journal.unknown) return 0;
    var queued = 0;
    for (final pill in candidates) {
      if (journal.journaledIds.contains(pill.id)) continue;
      await beforeQueue?.call(pill.id);
      if (await _queue(userId, pill.id)) queued++;
    }
    return queued;
  }

  /// The unsent pills of [userId] the server already knows. A pill without a
  /// server id never reached it and is not an edit to resend. [only] limits
  /// the read to one pill.
  Future<List<Pill>> _unsentKnownPills(String userId, {String? only}) async {
    final query =
        db.select(db.pills).join([
          innerJoin(db.profiles, db.profiles.id.equalsExp(db.pills.profileId)),
        ])..where(
          db.profiles.userId.equals(userId) &
              db.profiles.isDeleted.equals(false) &
              db.pills.syncStatus.equals('pending') &
              db.pills.serverId.isNotNull() &
              (only == null ? const Constant(true) : db.pills.id.equals(only)),
        );
    return [for (final row in await query.get()) row.readTable(db.pills)];
  }

  /// Queues [pillId] from a fresh read, in the same transaction as the
  /// insert; returns false when it no longer needs queuing.
  Future<bool> _queue(String userId, String pillId) async {
    final scope = writeScope;
    final pending = scope == null
        ? PendingOperationRepository(db)
        : PendingOperationRepository(
            db,
            access: scope.access,
            context: await scope.captureContext(),
          );
    return pending.withCareGrant(() async {
      final fresh = await _unsentKnownPills(userId, only: pillId);
      if (fresh.isEmpty) return false;
      final journal = await PillJournal.read(db, userId);
      if (journal.unknown || journal.journaledIds.contains(pillId)) {
        return false;
      }
      await _record(pending, userId, fresh.single);
      return true;
    });
  }

  Future<void> _record(
    PendingOperationRepository pending,
    String userId,
    Pill pill,
  ) async {
    await pending.recordAtomically(
      operations: [
        PendingOperationDraft(
          userId: userId,
          operationType: pill.isDeleted ? 'pill.delete' : 'pill.update',
          entityType: 'pill',
          entityLocalId: pill.id,
          parentEntityType: 'profile',
          parentEntityLocalId: pill.profileId,
          payload: pill.isDeleted
              ? {'action': 'delete', 'data': <String, Object?>{}}
              : {
                  'action': 'update',
                  'data': {
                    'name': pill.name,
                    'dosage': pill.dosage,
                    'notes': pill.notes,
                    'color': pill.color,
                    'lowStockThreshold': pill.lowStockThreshold,
                    'isPrn': pill.isPrn,
                    'shape': pill.shape,
                    ...MedicationExtras.fromPill(pill).toPayload(),
                  },
                },
        ),
      ],
      // Nothing local changes: the row already holds the edit being sent.
      applyProjection: () async {},
    );
  }
}
