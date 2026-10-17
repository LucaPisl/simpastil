import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/database.dart';
import '../sync/pending_operation_repository.dart';
import '../sync/sync_write_scope.dart';
import 'medication_amount.dart';
import 'medication_detail_wire.dart';

/// Hands the account the reviewed details that were saved while the server
/// could not keep them.
///
/// A review made against a server without the `medicationDetails` contract
/// stays on the device: the request leaves those fields out, and the operation
/// settles rather than failing. Once the server can keep them its own copy is
/// empty, and the first pull after the upgrade would carry that emptiness back
/// over the review. So the moment the contract appears, every reviewed
/// medicine is queued once more, before that pull: the account learns the
/// details before it can answer with them, and each medicine is left pending
/// meanwhile, which is what stops a pull in between from overwriting it.
///
/// Running twice costs one redundant update that changes nothing, so the marker
/// is an ordinary preference rather than anything the database has to carry.
class MedicationDetailBackfill {
  const MedicationDetailBackfill({required this.db, this.writeScope});

  final AppDatabase db;
  final SyncWriteScope? writeScope;

  static String preferenceKey(String userId) =>
      'medication_details_sent_$userId';

  Future<void> run({
    required String userId,
    required bool medicationDetails,
  }) async {
    if (!medicationDetails) return;
    final SharedPreferences preferences;
    try {
      preferences = await SharedPreferences.getInstance();
    } on Object {
      // Without the marker this would run again on every sync; skip instead.
      return;
    }
    final key = preferenceKey(userId);
    if (preferences.getBool(key) == true) return;
    for (final (pill, detail) in await _reviewed(userId)) {
      await _queue(userId, pill, detail);
    }
    await preferences.setBool(key, true);
  }

  /// The medicines of [userId] whose details say something the account has not
  /// been told. A medicine that is not `synced` already carries an unsent edit
  /// of its own, and one without a revision has never reached the account, so
  /// neither is this method's business.
  Future<List<(Pill, MedicationDetail)>> _reviewed(String userId) async {
    final query =
        db.select(db.pills).join([
          innerJoin(db.profiles, db.profiles.id.equalsExp(db.pills.profileId)),
          innerJoin(
            db.medicationDetails,
            db.medicationDetails.pillId.equalsExp(db.pills.id),
          ),
        ])..where(
          db.profiles.userId.equals(userId) &
              db.profiles.isDeleted.equals(false) &
              db.pills.isDeleted.equals(false) &
              db.pills.syncStatus.equals('synced') &
              db.pills.revision.isBiggerOrEqualValue(1),
        );
    final reviewed = <(Pill, MedicationDetail)>[];
    for (final row in await query.get()) {
      final detail = row.readTable(db.medicationDetails);
      if (_amount(detail).isUnknown &&
          detail.packageStrength == null &&
          detail.form == null &&
          !detail.legacyDosageReviewed) {
        continue;
      }
      reviewed.add((row.readTable(db.pills), detail));
    }
    return reviewed;
  }

  MedicationAmount _amount(MedicationDetail detail) {
    try {
      return MedicationAmount.fromJson(
        Map<String, Object?>.from(jsonDecode(detail.amountJson) as Map),
      );
    } on Object {
      return const MedicationAmount.unknown();
    }
  }

  Future<void> _queue(String userId, Pill pill, MedicationDetail detail) async {
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
              ...medicationDetailWire(
                amount: _amount(detail),
                packageStrength: detail.packageStrength,
                form: detail.form,
                legacyDosageReviewed: detail.legacyDosageReviewed,
              ),
            },
          },
        ),
      ],
      // Nothing local changes: the medicine and its details already hold the
      // truth being sent. Pending is the mark that it is unsent.
      applyProjection: () async {
        await (db.update(db.pills)..where((row) => row.id.equals(pill.id)))
            .write(const PillsCompanion(syncStatus: Value('pending')));
      },
    );
  }
}
