import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../backup/backup_manifest.dart';
import '../../backup/import_plan.dart';
import '../database.dart';

/// Protected import facts. Services apply current workspace authorization before
/// exposing results; no method promotes archived work into a live queue.
class ImportDao {
  const ImportDao(this.database);
  final AppDatabase database;

  Future<List<ImportReceipt>> receipts(String workspaceId) => (database.select(
    database.importReceipts,
  )..where((r) => r.workspaceId.equals(workspaceId))).get();
  Future<List<ImportConflict>> conflicts(String workspaceId) =>
      (database.select(
        database.importConflicts,
      )..where((r) => r.workspaceId.equals(workspaceId))).get();

  /// A proven imported historical occurrence can retain its captured person
  /// after the live medication moved. This binding grants no recording access.
  Future<bool> isDetachedOccurrence(
    String workspaceId,
    String occurrenceId,
  ) async =>
      await database
          .customSelect(
            'SELECT 1 FROM import_evidence e JOIN import_receipts r ON r.id=e.receipt_id '
            'WHERE r.workspace_id=? AND e.entity_table=? AND e.entity_key=? '
            'AND e.version=? AND e.ordinal=0 AND e.disposition=? LIMIT 1',
            variables: [
              Variable(workspaceId),
              const Variable('medication_occurrences'),
              Variable(jsonEncode([occurrenceId])),
              const Variable('incoming'),
              const Variable('detachedHistory'),
            ],
            readsFrom: {database.importEvidence, database.importReceipts},
          )
          .getSingleOrNull() !=
      null;

  Future<Map<String, Object?>> originalRow({
    required String receiptId,
    required String table,
    required String key,
    String version = 'incoming',
  }) async {
    final chunks =
        await (database.select(database.importEvidence)
              ..where(
                (r) =>
                    r.receiptId.equals(receiptId) &
                    r.entityTable.equals(table) &
                    r.entityKey.equals(key) &
                    r.version.equals(version),
              )
              ..orderBy([(r) => OrderingTerm.asc(r.ordinal)]))
            .get();
    if (chunks.isEmpty) {
      throw const ImportFailure(ImportFailureCode.invalidSource);
    }
    try {
      final bytes = BytesBuilder(copy: false);
      var ordinal = 0;
      for (final chunk in chunks) {
        if (chunk.ordinal != ordinal++ ||
            chunk.sourceDigest != chunks.first.sourceDigest ||
            chunk.payloadBase64.length > 512 * 1024) {
          throw const ImportFailure(ImportFailureCode.invalidSource);
        }
        final part = base64.decode(chunk.payloadBase64);
        if (bytes.length + part.length > maximumBackupBytes) {
          throw const ImportFailure(ImportFailureCode.invalidSource);
        }
        bytes.add(part);
      }
      final data = bytes.takeBytes();
      if (sha256.convert(data).toString() != chunks.first.sourceDigest) {
        throw const ImportFailure(ImportFailureCode.invalidSource);
      }
      final value = jsonDecode(utf8.decode(data));
      if (value is! Map || value.values.any((v) => v is Map || v is List)) {
        throw const ImportFailure(ImportFailureCode.invalidSource);
      }
      return Map<String, Object?>.unmodifiable(value.cast<String, Object?>());
    } on ImportFailure {
      rethrow;
    } catch (_) {
      throw const ImportFailure(ImportFailureCode.invalidSource);
    }
  }
}
