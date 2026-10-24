import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';

import '../db/database.dart';
import '../sync/sync_write_scope.dart';
import '../utils/app_logger.dart';
import 'medication_photo_processor.dart';

/// Moves medication photos between this device and the account.
///
/// A photo is not a pending operation: it is one file with its own endpoint, so
/// it has its own small state on the row (`pending`, `removing`, `fetch`,
/// `synced`). Every step is best effort. A failure leaves the row as it was,
/// the next sync tries again, and the pill's own sync never waits on a photo.
///
/// Upload runs right after the pill flush (so a new medicine already has its
/// server id) and before the pull (so the pull sees the pill revision the
/// upload produced). Download runs after the pull has recorded which photos the
/// account now holds.
class MedicationPhotoSync {
  const MedicationPhotoSync({
    required this.db,
    required this.dio,
    this.writeScope,
    this.batch = 25,
  });

  final AppDatabase db;
  final Dio dio;
  final SyncWriteScope? writeScope;

  /// The most photos moved in one direction per run, so a first sync of a large
  /// account does not hold the sync lock for long.
  final int batch;

  Future<T> _write<T>(Future<T> Function() action) =>
      writeScope?.write(action) ?? db.transaction(action);

  /// Sends changed photos and removals of [userId]. Never throws.
  Future<void> upload(String userId) async {
    try {
      await _dropOrphans(userId);
      for (final entry in await _rows(userId, const ['pending', 'removing'])) {
        await _uploadOne(entry.photo, entry.pill);
      }
    } on Object catch (error) {
      AppLogger.warning(
        'MedicationPhotoSync',
        'Photo upload stopped: ${error.runtimeType}',
      );
    }
  }

  /// Downloads the photos [userId]'s account holds that this device lacks.
  /// Never throws.
  Future<void> fetch(String userId) async {
    try {
      await _dropOrphans(userId);
      for (final entry in await _rows(userId, const ['fetch'])) {
        await _fetchOne(entry.photo, entry.pill);
      }
    } on Object catch (error) {
      AppLogger.warning(
        'MedicationPhotoSync',
        'Photo download stopped: ${error.runtimeType}',
      );
    }
  }

  Future<List<({MedicationPhoto photo, Pill pill})>> _rows(
    String userId,
    List<String> statuses,
  ) async {
    final query =
        db.select(db.medicationPhotos).join([
            innerJoin(
              db.pills,
              db.pills.id.equalsExp(db.medicationPhotos.pillId),
            ),
            innerJoin(
              db.profiles,
              db.profiles.id.equalsExp(db.pills.profileId),
            ),
          ])
          ..where(
            db.profiles.userId.equals(userId) &
                db.medicationPhotos.syncStatus.isIn(statuses),
          )
          ..limit(batch);
    return [
      for (final row in await query.get())
        (
          photo: row.readTable(db.medicationPhotos),
          pill: row.readTable(db.pills),
        ),
    ];
  }

  /// A photo whose medicine is deleted (or whose person is gone) has nothing to
  /// belong to; the account removes its own copy with the medicine.
  Future<void> _dropOrphans(String userId) => _write(
    () => db.customUpdate(
      'DELETE FROM medication_photos WHERE pill_id IN ('
      'SELECT p.id FROM pills p JOIN profiles r ON r.id=p.profile_id '
      'WHERE r.user_id=? AND (p.is_deleted=1 OR r.is_deleted=1))',
      variables: [Variable<String>(userId)],
      updates: {db.medicationPhotos},
    ),
  );

  Future<void> _uploadOne(MedicationPhoto photo, Pill pill) async {
    final serverId = pill.serverId;
    if (photo.syncStatus == 'removing') {
      if (serverId == null) {
        await _deleteIf(photo.pillId, 'removing');
        return;
      }
      try {
        await dio.delete<dynamic>('/pills/$serverId/photo');
      } on DioException catch (error) {
        // Already gone is as good as removed.
        if (error.response?.statusCode != 404) rethrow;
      }
      await _deleteIf(photo.pillId, 'removing');
      return;
    }
    // A medicine the account has not accepted yet, or one with an unsent edit
    // of its own, waits: the upload moves the account's pill revision, and an
    // edit still based on the old one would then be refused.
    if (serverId == null || pill.syncStatus != 'synced') return;
    final Uint8List bytes;
    try {
      bytes = base64Decode(photo.bytesBase64);
    } on FormatException {
      await _deleteIf(photo.pillId, 'pending');
      return;
    }
    if (!isAcceptableMedicationPhoto(bytes)) {
      await _setStatus(photo, 'pending', 'rejected');
      return;
    }
    final Response<dynamic> response;
    try {
      response = await dio.put<dynamic>(
        '/pills/$serverId/photo',
        data: bytes,
        options: Options(contentType: 'image/jpeg'),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      // The server will never take this file: keep it here, stop retrying.
      if (status == 413 || status == 422) {
        await _setStatus(photo, 'pending', 'rejected');
        return;
      }
      rethrow;
    }
    final body = response.data;
    final revision = body is Map ? body['revision'] : null;
    final pillRevision = body is Map ? body['pillRevision'] : null;
    await _write(() async {
      final current = await (db.select(
        db.medicationPhotos,
      )..where((row) => row.pillId.equals(photo.pillId))).getSingleOrNull();
      // Replaced or removed while the upload was in flight: that newer choice
      // is still waiting, so this answer is not the end of the story.
      if (current == null ||
          current.syncStatus != 'pending' ||
          current.sha256 != photo.sha256) {
        return;
      }
      await (db.update(
        db.medicationPhotos,
      )..where((row) => row.pillId.equals(photo.pillId))).write(
        MedicationPhotosCompanion(
          syncStatus: const Value('synced'),
          revision: Value(_asInt(revision) ?? current.revision),
          remoteSha256: const Value(null),
        ),
      );
      // The upload moved the pill's revision by one. Follow it, or the next
      // edit of this medicine would be based on a revision the account passed.
      final newPillRevision = _asInt(pillRevision);
      final livePill = await db.pillsDao.getById(pill.id);
      if (newPillRevision != null &&
          livePill != null &&
          livePill.syncStatus == 'synced' &&
          livePill.revision == pill.revision &&
          newPillRevision == pill.revision + 1) {
        await (db.update(db.pills)..where((row) => row.id.equals(pill.id)))
            .write(PillsCompanion(revision: Value(newPillRevision)));
      }
    });
  }

  Future<void> _fetchOne(MedicationPhoto photo, Pill pill) async {
    final serverId = pill.serverId;
    if (serverId == null) return;
    final Response<List<int>> response;
    try {
      response = await dio.get<List<int>>(
        '/pills/$serverId/photo',
        options: Options(responseType: ResponseType.bytes),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        await _deleteIf(photo.pillId, 'fetch');
        return;
      }
      rethrow;
    }
    final data = response.data;
    if (data == null) return;
    final bytes = Uint8List.fromList(data);
    if (!isAcceptableMedicationPhoto(bytes)) return;
    final revision = _asInt(response.headers.value('x-photo-revision'));
    final digest = sha256.convert(bytes).toString();
    await _write(() async {
      final current = await (db.select(
        db.medicationPhotos,
      )..where((row) => row.pillId.equals(photo.pillId))).getSingleOrNull();
      // Only a row still waiting for the download takes it; a photo chosen on
      // this device in the meantime is never overwritten.
      if (current == null || current.syncStatus != 'fetch') return;
      await (db.update(
        db.medicationPhotos,
      )..where((row) => row.pillId.equals(photo.pillId))).write(
        MedicationPhotosCompanion(
          bytesBase64: Value(base64Encode(bytes)),
          sha256: Value(digest),
          revision: Value(revision ?? current.revision),
          syncStatus: const Value('synced'),
          remoteSha256: const Value(null),
        ),
      );
    });
  }

  Future<void> _deleteIf(String pillId, String status) => _write(
    () =>
        (db.delete(db.medicationPhotos)..where(
              (row) =>
                  row.pillId.equals(pillId) & row.syncStatus.equals(status),
            ))
            .go(),
  );

  Future<void> _setStatus(MedicationPhoto photo, String from, String to) =>
      _write(
        () =>
            (db.update(db.medicationPhotos)..where(
                  (row) =>
                      row.pillId.equals(photo.pillId) &
                      row.syncStatus.equals(from) &
                      row.sha256.equals(photo.sha256),
                ))
                .write(MedicationPhotosCompanion(syncStatus: Value(to))),
      );

  static int? _asInt(Object? value) => switch (value) {
    final int number => number,
    final String text => int.tryParse(text),
    _ => null,
  };
}
