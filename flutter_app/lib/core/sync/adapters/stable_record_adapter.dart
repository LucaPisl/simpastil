import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;

import '../../api/api_client.dart' show simpastilClientBuild;
import '../../db/database.dart';
import '../held_stock.dart';
import '../sync_retry_policy.dart';
import '../sync_write_scope.dart';
import '../capabilities_client.dart';

enum StableMutationStatus {
  acknowledged,
  legacyAcceptedAwaitingReconciliation,
  conflict,
  retryable,
  uncertain,
  blocked,
}

class StableMutationResult {
  const StableMutationResult(
    this.status, {
    this.acknowledgedMutationId,
    this.serverId,
    this.revision,
    this.safeErrorCode,
    this.safeCorrelationId,
    this.applyReceipt,
    this.retryAfter,
  });

  final StableMutationStatus status;
  final String? acknowledgedMutationId;
  final String? serverId;
  final int? revision;
  final String? safeErrorCode;
  final String? safeCorrelationId;
  final Future<void> Function()? applyReceipt;

  /// The server's own wish for when to come back (`Retry-After`), if any.
  final Duration? retryAfter;
}

abstract class StableRecordAdapter {
  const StableRecordAdapter({
    required this.db,
    required this.dio,
    this.writeScope,
  });

  final AppDatabase db;
  final Dio dio;
  final SyncWriteScope? writeScope;
  Future<T> writeOperation<T>(
    PendingOperation operation,
    Future<T> Function() action,
  ) =>
      writeScope?.write(() async {
        await writeScope!.requireOperation(operation);
        return action();
      }) ??
      db.transaction(action);
  Future<T> writeEntity<T>(
    String type,
    String id,
    Future<T> Function() action,
  ) =>
      writeScope?.write(() async {
        await writeScope!.requireEntity(type, id);
        return action();
      }) ??
      db.transaction(action);

  Future<bool> hasOtherIntent(
    PendingOperation current,
    String type,
    String id,
  ) async {
    final workspaceId = await writeScope?.workspaceId;
    // Stock held for the server's ledger stays on the phone by design; it is
    // not an unsent edit of this record, so it cannot keep the row pending.
    final held = {
      for (final operation in await heldStockOperations(db, current.userId))
        operation.id,
    };
    for (final row in await db.pendingOperationsDao.getForUser(
      current.userId,
    )) {
      if (row.id == current.id ||
          held.contains(row.id) ||
          row.state == 'committed' ||
          row.state == 'discarded') {
        continue;
      }
      // Keep original delivery evidence without letting an exactly settled
      // intent make a later acknowledged metadata receipt look pending forever.
      if (workspaceId != null &&
          await db.pendingOperationsDao.isSettled(
            row,
            workspaceId: workspaceId,
          )) {
        continue;
      }
      final payload = jsonDecode(row.payloadJson);
      if (payload is Map<String, dynamic> &&
          payload['entityType'] == type &&
          payload['entityLocalId'] == id) {
        return true;
      }
    }
    return false;
  }

  Future<void> markLocalReceipt(
    PendingOperation operation,
    String type,
    String id,
    String serverId,
    int? revision,
  ) => writeEntity(type, id, () async {
    final preservePending = await hasOtherIntent(operation, type, id);
    switch (type) {
      case 'profile':
        await db.profilesDao.markSynced(id, serverId, revision: revision);
        if (preservePending) {
          await (db.update(db.profiles)..where((row) => row.id.equals(id)))
              .write(const ProfilesCompanion(syncStatus: Value('pending')));
        }
      case 'pill':
        await db.pillsDao.markSynced(id, serverId, revision: revision);
        if (preservePending) {
          await (db.update(db.pills)..where((row) => row.id.equals(id))).write(
            const PillsCompanion(syncStatus: Value('pending')),
          );
        }
      case 'schedule':
        await db.schedulesDao.markSynced(id, serverId, revision: revision);
        if (preservePending) {
          await (db.update(db.schedules)..where((row) => row.id.equals(id)))
              .write(const SchedulesCompanion(syncStatus: Value('pending')));
        }
    }
  });

  Future<StableMutationResult> send(PendingOperation operation);

  /// True when replaying a request that may have been applied is harmless:
  /// the mutation id makes the server answer from its receipt. The legacy
  /// protocol has no such id, so a lost response stays uncertain there.
  bool get replayIsIdempotent => true;

  /// The exact request this operation would send now, or null when the
  /// adapter does not freeze requests. The flush freezes it at first send, in
  /// the transaction that claims the operation, and compares it on replay.
  Future<Map<String, Object?>?> buildFrozenRequest(
    PendingOperation operation,
  ) async => null;

  static StableRecordAdapter? forCapabilities(
    CapabilitySnapshot capabilities, {
    required StableRecordAdapter legacy,
    required StableRecordAdapter versioned,
  }) {
    if (capabilities.availability == CapabilityAvailability.present &&
        capabilities.capabilities!.minimumClientBuild > simpastilClientBuild) {
      return null;
    }
    return switch (capabilities.availability) {
      CapabilityAvailability.absent => legacy,
      CapabilityAvailability.unavailable => null,
      CapabilityAvailability.localAccessUnavailable => null,
      CapabilityAvailability.present => versioned,
    };
  }

  Map<String, Object?> decodeOperation(PendingOperation operation) {
    final decoded = jsonDecode(operation.payloadJson);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Pending stable operation is not an object');
    }
    return decoded;
  }

  Map<String, Object?> dataFrom(Map<String, Object?> payload) {
    final data = payload['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Pending stable operation has no data');
    }
    return data;
  }

  String? extractServerId(Map<String, dynamic>? response) {
    if (response == null) return null;
    final direct = response['id'];
    if (direct is String) return direct;
    final nested = response['data'];
    if (nested is Map<String, dynamic> && nested['id'] is String) {
      return nested['id'] as String;
    }
    return null;
  }

  int? extractRevision(Map<String, dynamic>? response) {
    if (response == null) return null;
    final entity = response['data'] is Map<String, dynamic>
        ? response['data'] as Map<String, dynamic>
        : response;
    final revision = entity['revision'];
    return revision is int ? revision : int.tryParse('$revision');
  }

  Future<String?> serverIdFor(String entityType, String localId) async {
    await writeScope?.requireEntity(entityType, localId);
    switch (entityType) {
      case 'profile':
        final row = await db.profilesDao.getById(localId);
        return row?.serverId;
      case 'pill':
        final row = await db.pillsDao.getById(localId);
        return row?.serverId;
      case 'schedule':
        final row = await db.schedulesDao.getById(localId);
        return row?.serverId;
      default:
        return null;
    }
  }

  Future<String?> parentServerId(Map<String, Object?> payload) async {
    final type = payload['parentEntityType'];
    final localId = payload['parentEntityLocalId'];
    if (type is! String || localId is! String) return null;
    return serverIdFor(type, localId);
  }

  String? responseErrorCode(DioException error) {
    final body = error.response?.data;
    if (body is Map<String, dynamic> && body['error'] is Map<String, dynamic>) {
      final code = (body['error'] as Map<String, dynamic>)['code'];
      if (code is String && RegExp(r'^[A-Z][A-Z0-9_]{0,63}$').hasMatch(code)) {
        return code;
      }
    }
    return null;
  }

  String? responseCorrelationId(DioException error) {
    final body = error.response?.data;
    if (body is Map<String, dynamic> && body['error'] is Map<String, dynamic>) {
      final id = (body['error'] as Map<String, dynamic>)['correlationId'];
      if (id is String && id.length <= 128) return id;
    }
    return null;
  }

  StableMutationResult classifyFailure(DioException error) {
    final status = error.response?.statusCode;
    final code = responseErrorCode(error);
    if (SyncRetryPolicy.isAwaitingReconciliation(error)) {
      // A server-side split reconciliation is pending; the person cannot
      // resolve it by choosing a side, so it is not presented as a conflict.
      return StableMutationResult(
        StableMutationStatus.blocked,
        safeErrorCode: SyncRetryPolicy.awaitingReconciliationCode,
        safeCorrelationId: responseCorrelationId(error),
      );
    }
    if (status == 409) {
      return StableMutationResult(
        StableMutationStatus.conflict,
        safeErrorCode: code,
        safeCorrelationId: responseCorrelationId(error),
      );
    }
    if (SyncRetryPolicy.isTransient(error)) {
      return StableMutationResult(
        replayIsIdempotent
            ? StableMutationStatus.retryable
            : StableMutationStatus.uncertain,
        safeErrorCode: code ?? 'TRANSPORT_UNCERTAIN',
        safeCorrelationId: responseCorrelationId(error),
        retryAfter: SyncRetryPolicy.retryAfter(error),
      );
    }
    final body = error.response?.data;
    final errorBody = body is Map<String, dynamic> ? body['error'] : null;
    final retryable =
        errorBody is Map<String, dynamic> && errorBody['retryable'] == true;
    return StableMutationResult(
      retryable ? StableMutationStatus.retryable : StableMutationStatus.blocked,
      safeErrorCode: code,
      safeCorrelationId: responseCorrelationId(error),
    );
  }
}

/// Drift and durable payloads may carry ISO weekdays as JSON text from older
/// local rows; the wire contract always receives an integer array.
List<int>? frequencyDaysToWire(Object? value) {
  if (value == null) return null;
  final decoded = value is String ? jsonDecode(value) : value;
  if (decoded is! List ||
      decoded.any((day) => day is! int || day < 1 || day > 7)) {
    throw const FormatException('frequencyDays must be ISO weekday integers');
  }
  return List<int>.unmodifiable(decoded.cast<int>());
}
