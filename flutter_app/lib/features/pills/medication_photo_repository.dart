import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/medication/medication_photo_processor.dart';
import '../../core/sync/pending_operation_repository.dart';
import '../../core/workspace/workspace_context.dart';
import '../../core/workspace/workspace_provider.dart';

/// The picture kept for one medicine, ready to show.
class MedicationPhotoView {
  const MedicationPhotoView({required this.bytes, required this.sha256});
  final Uint8List bytes;
  final String sha256;
}

/// Reads and changes the one photo each medicine may have.
///
/// A change is local first: the row is marked `pending` (or `removing`) and the
/// next sync sends it. Nothing here touches the network.
class MedicationPhotoRepository {
  const MedicationPhotoRepository({
    required AppDatabase db,
    required PendingOperationRepository pendingOperations,
  }) : _db = db,
       _pendingOperations = pendingOperations;

  final AppDatabase _db;
  final PendingOperationRepository _pendingOperations;

  /// Rows in these states show no picture: the user removed it, or its bytes
  /// have not been downloaded yet.
  static MedicationPhotoView? view(MedicationPhoto? row) {
    if (row == null || row.syncStatus == 'removing') return null;
    if (row.bytesBase64.isEmpty) return null;
    try {
      return MedicationPhotoView(
        bytes: base64Decode(row.bytesBase64),
        sha256: row.sha256,
      );
    } on FormatException {
      return null;
    }
  }

  Future<MedicationPhoto?> _row(String pillId) => (_db.select(
    _db.medicationPhotos,
  )..where((t) => t.pillId.equals(pillId))).getSingleOrNull();

  Future<Pill> _ownedPill(String pillId) async {
    final pill = await _db.pillsDao.getById(pillId);
    if (pill == null || pill.isDeleted) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    final profile = await _db.profilesDao.getById(pill.profileId);
    if (profile == null || profile.isDeleted) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    _pendingOperations.requireCareOwner(profile.userId);
    return pill;
  }

  /// Stores [photo] as the medicine's picture, replacing any earlier one.
  Future<void> save(String pillId, ProcessedMedicationPhoto photo) =>
      _pendingOperations.withCareGrant(() async {
        await _ownedPill(pillId);
        final existing = await _row(pillId);
        if (existing != null &&
            existing.sha256 == photo.sha256 &&
            existing.syncStatus != 'removing') {
          return;
        }
        await _db
            .into(_db.medicationPhotos)
            .insertOnConflictUpdate(
              MedicationPhotosCompanion.insert(
                pillId: pillId,
                bytesBase64: Value(base64Encode(photo.bytes)),
                sha256: photo.sha256,
                revision: Value(existing?.revision ?? 0),
                syncStatus: const Value('pending'),
                remoteSha256: const Value(null),
              ),
            );
      });

  /// Removes the medicine's picture. A picture the account never received is
  /// simply dropped; one it holds is marked so the next sync deletes it there.
  Future<void> remove(String pillId) =>
      _pendingOperations.withCareGrant(() async {
        final pill = await _ownedPill(pillId);
        final existing = await _row(pillId);
        if (existing == null) return;
        final neverSent =
            pill.serverId == null ||
            (existing.syncStatus == 'pending' && existing.revision == 0);
        if (neverSent) {
          await (_db.delete(
            _db.medicationPhotos,
          )..where((t) => t.pillId.equals(pillId))).go();
          return;
        }
        await (_db.update(
          _db.medicationPhotos,
        )..where((t) => t.pillId.equals(pillId))).write(
          const MedicationPhotosCompanion(
            bytesBase64: Value(''),
            syncStatus: Value('removing'),
            remoteSha256: Value(null),
          ),
        );
      });
}

final medicationPhotoRepositoryProvider = Provider<MedicationPhotoRepository>(
  (ref) => MedicationPhotoRepository(
    db: ref.watch(databaseProvider),
    pendingOperations: ref.watch(pendingOperationRepositoryProvider),
  ),
);

/// The picture of one medicine, or null when it has none. Follows the database
/// and re-checks the workspace grant on every change, like the pill lists do.
final medicationPhotoProvider =
    StreamProvider.family<MedicationPhotoView?, String>((ref, pillId) async* {
      final db = ref.watch(databaseProvider);
      final access = ref.watch(workspaceAccessRepositoryProvider);
      final context = await ref.watch(workspaceContextProvider.future);
      yield* (db.select(
        db.medicationPhotos,
      )..where((t) => t.pillId.equals(pillId))).watchSingleOrNull().asyncMap(
        (row) => access.withGrant(context, () async {
          await access.requireCurrent(context);
          return MedicationPhotoRepository.view(row);
        }),
      );
    });
