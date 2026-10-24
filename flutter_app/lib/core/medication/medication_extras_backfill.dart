import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/database.dart';
import 'medication_extras.dart';
import '../sync/pending_operation_repository.dart';
import '../sync/sync_write_scope.dart';

/// Hands the account the medication extras that were set while the server
/// could not keep them.
///
/// Extras set against a server without the `medicationDetailsExtra` contract
/// stay on the device: the request leaves them out and the operation settles.
/// Once the server can keep them its own copy is empty, and against such a
/// server an absent key in a pull means "cleared", which would erase this
/// device's values. So the moment the contract appears, every pill with any
/// extra set is queued once more, before the pull, and left pending
/// meanwhile.
///
/// Running twice costs one redundant update that changes nothing, so the
/// marker is an ordinary preference rather than anything the database has to
/// carry.
class MedicationExtrasBackfill {
  const MedicationExtrasBackfill({required this.db, this.writeScope});

  final AppDatabase db;
  final SyncWriteScope? writeScope;

  static String preferenceKey(String userId) =>
      'medication_extras_sent_$userId';

  Future<void> run({
    required String userId,
    required bool medicationDetailsExtra,
  }) async {
    if (!medicationDetailsExtra) return;
    final SharedPreferences preferences;
    try {
      preferences = await SharedPreferences.getInstance();
    } on Object {
      // Without the marker this would run again on every sync; skip instead.
      return;
    }
    final key = preferenceKey(userId);
    if (preferences.getBool(key) == true) return;
    for (final pill in await _withExtras(userId)) {
      await _queue(userId, pill);
    }
    await preferences.setBool(key, true);
  }

  /// The medicines of [userId] with extras the account has not been
  /// told. A medicine that is not `synced` already carries an unsent edit of
  /// its own, and one without a revision has never reached the account.
  Future<List<Pill>> _withExtras(String userId) async {
    final query =
        db.select(db.pills).join([
          innerJoin(db.profiles, db.profiles.id.equalsExp(db.pills.profileId)),
        ])..where(
          db.profiles.userId.equals(userId) &
              db.profiles.isDeleted.equals(false) &
              db.pills.isDeleted.equals(false) &
              (db.pills.prnMaxPer24h.isNotNull() |
                  db.pills.prnMinGapMinutes.isNotNull() |
                  db.pills.expiresOn.isNotNull() |
                  db.pills.prescriberName.isNotNull() |
                  db.pills.prescriberPhone.isNotNull() |
                  db.pills.pharmacyName.isNotNull() |
                  db.pills.pharmacyPhone.isNotNull()) &
              db.pills.syncStatus.equals('synced') &
              db.pills.revision.isBiggerOrEqualValue(1),
        );
    return [for (final row in await query.get()) row.readTable(db.pills)];
  }

  Future<void> _queue(String userId, Pill pill) async {
    final scope = writeScope;
    final pending = scope == null
        ? PendingOperationRepository(db)
        : PendingOperationRepository(
            db,
            access: scope.access,
            context: await scope.captureContext(),
          );
    await pending.recordAtomically(
      operations: [
        PendingOperationDraft(
          userId: userId,
          operationType: 'pill.update',
          entityType: 'pill',
          entityLocalId: pill.id,
          parentEntityType: 'profile',
          parentEntityLocalId: pill.profileId,
          payload: {
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
      // Nothing local changes: the pill already holds the truth being sent.
      applyProjection: () async {
        await (db.update(db.pills)..where((row) => row.id.equals(pill.id)))
            .write(const PillsCompanion(syncStatus: Value('pending')));
      },
    );
  }
}
