import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../db/database.dart';
import '../../workspace/workspace_context.dart';
import '../sync_write_scope.dart';
import '../legacy_split_checkpoint.dart';
import 'medication_sync_adapter.dart';

/// The only medication writer used when `/capabilities` is explicitly 404.
/// Each remote subeffect is checkpointed before the request and acknowledged
/// before the next ordinal is allowed to start.
class LegacyMedicationSyncAdapter {
  const LegacyMedicationSyncAdapter({
    required this.db,
    required this.dio,
    this.writeScope,
  });

  final AppDatabase db;
  final Dio dio;
  final SyncWriteScope? writeScope;
  Future<T> _write<T>(
    PendingOperation operation,
    Future<T> Function() action,
  ) =>
      writeScope?.write(() async {
        await writeScope!.requireOperation(operation);
        return action();
      }) ??
      db.transaction(action);

  Future<MedicationMutationResult> flush(PendingOperation operation) async {
    await writeScope?.requireOperation(operation);
    if (operation.component != 'medication') {
      return const MedicationMutationResult(
        MedicationMutationStatus.blocked,
        safeErrorCode: 'NOT_A_MEDICATION_OPERATION',
      );
    }
    while (true) {
      final checkpoint = await LegacySplitCheckpoint.load(db, operation.id);
      if (checkpoint == null || checkpoint.effects.isEmpty) {
        return const MedicationMutationResult(
          MedicationMutationStatus.blocked,
          safeErrorCode: 'MISSING_SPLIT_CHECKPOINT',
        );
      }
      if (checkpoint.hasUncertainEffect) {
        return const MedicationMutationResult(
          MedicationMutationStatus.uncertain,
          safeErrorCode: 'SPLIT_EFFECT_REQUIRES_RECONCILIATION',
        );
      }
      if (checkpoint.isComplete) {
        return MedicationMutationResult(
          MedicationMutationStatus.acknowledged,
          commandId: operation.mutationId,
        );
      }
      final effect = checkpoint.nextEffect;
      if (effect == null) {
        return const MedicationMutationResult(
          MedicationMutationStatus.blocked,
          safeErrorCode: 'SPLIT_CHECKPOINT_ORDER_INVALID',
        );
      }

      final request = await _prepareRequest(operation, effect);
      if (request == null) {
        return const MedicationMutationResult(
          MedicationMutationStatus.waitingForMapping,
          safeErrorCode: 'MEDICATION_PARENT_NOT_MAPPED',
        );
      }
      final started = await _write(
        operation,
        () => db.pendingOperationsDao.markEffectSending(
          effect.id,
          DateTime.now().toUtc(),
        ),
      );
      if (!started) {
        return const MedicationMutationResult(
          MedicationMutationStatus.blocked,
          safeErrorCode: 'SPLIT_CHECKPOINT_CLAIM_LOST',
        );
      }

      try {
        final response = await _send(request);
        final serverId = response.serverId ?? request.knownServerId;
        if (request.requiresServerId && serverId == null) {
          await _write(
            operation,
            () => db.pendingOperationsDao.markEffectUncertain(
              effect.id,
              safeErrorCode: 'LEGACY_RECEIPT_ID_MISSING',
            ),
          );
          return const MedicationMutationResult(
            MedicationMutationStatus.uncertain,
            safeErrorCode: 'LEGACY_RECEIPT_ID_MISSING',
          );
        }
        final acknowledged = await _write(operation, () async {
          final acknowledged = await db.pendingOperationsDao.acknowledgeEffect(
            effectId: effect.id,
            safeServerId: serverId ?? 'local-noop:${operation.id}',
            safeResultFingerprint: _sha256({
              'statusCode': response.statusCode,
              'data': response.data,
              'requestFingerprint': effect.requestFingerprint,
            }),
            acknowledgedAt: DateTime.now().toUtc(),
          );
          final localDoseId = request.localDoseId;
          if (acknowledged &&
              effect.kind == 'dose' &&
              localDoseId != null &&
              serverId != null) {
            await writeScope?.requireEntity('doseLog', localDoseId);
            await db.doseLogsDao.markSynced(localDoseId, serverId);
          }
          return acknowledged;
        });
        if (!acknowledged) {
          await _write(
            operation,
            () => db.pendingOperationsDao.markEffectUncertain(
              effect.id,
              safeErrorCode: 'LEGACY_ACK_NOT_DURABLE',
            ),
          );
          return const MedicationMutationResult(
            MedicationMutationStatus.uncertain,
            safeErrorCode: 'LEGACY_ACK_NOT_DURABLE',
          );
        }
      } on DioException catch (error) {
        if (error.response?.statusCode == 401) {
          await _write(
            operation,
            () => db.pendingOperationsDao.markEffectRetryable(effect.id),
          );
          rethrow;
        }
        final errorCode = _errorCode(error);
        final correlationId = _correlationId(error);
        await _write(
          operation,
          () => db.pendingOperationsDao.markEffectUncertain(
            effect.id,
            safeErrorCode: errorCode,
            safeCorrelationId: correlationId,
          ),
        );
        return MedicationMutationResult(
          error.response?.statusCode == 409
              ? MedicationMutationStatus.conflict
              : MedicationMutationStatus.uncertain,
          safeErrorCode: errorCode,
          safeCorrelationId: correlationId,
        );
      } on WorkspaceAccessFailure {
        rethrow;
      } on Object {
        await _write(
          operation,
          () => db.pendingOperationsDao.markEffectUncertain(
            effect.id,
            safeErrorCode: 'LEGACY_EFFECT_RESULT_UNCERTAIN',
          ),
        );
        return const MedicationMutationResult(
          MedicationMutationStatus.uncertain,
          safeErrorCode: 'LEGACY_EFFECT_RESULT_UNCERTAIN',
        );
      }
    }
  }

  Future<_LegacyRequest?> _prepareRequest(
    PendingOperation operation,
    PendingOperationEffect effect,
  ) async {
    final payload = _decode(operation.payloadJson);
    if (payload == null) return null;
    final inventoryCommand = payload['inventoryCommand'];
    if (inventoryCommand is Map<String, dynamic>) {
      if (effect.kind != 'inventory') return null;
      final localPillId = inventoryCommand['pillId'];
      final targetStock =
          inventoryCommand['initialStock'] ?? inventoryCommand['targetStock'];
      if (localPillId is! String || targetStock is! int) return null;
      final pill = await db.pillsDao.getById(localPillId);
      final serverId = pill?.serverId;
      if (serverId == null) return null;
      return _LegacyRequest.patch(
        path: '/pills/$serverId',
        body: {'currentStock': targetStock},
        knownServerId: serverId,
      );
    }
    final command = payload['command'];
    if (command is! Map<String, dynamic>) return null;
    if (effect.kind == 'dose') {
      final sourceId = effect.legacySourceId;
      final occurrenceId = command['occurrenceId'];
      if (sourceId == null || occurrenceId is! String) return null;
      final occurrence = await db.medicationLedgerDao.getOccurrenceById(
        occurrenceId,
      );
      final scheduleId = occurrence?.scheduleId;
      if (occurrence == null || scheduleId == null) return null;
      final schedule = await db.schedulesDao.getById(scheduleId);
      final scheduleServerId = schedule?.serverId;
      if (scheduleServerId == null) return null;
      final log = await db.doseLogsDao.getById(sourceId);
      final logServerId = log?.serverId;
      final targetState = _targetState(command);
      if (targetState == null) return null;
      if (targetState == 'pending' && log?.serverId == null) {
        return _LegacyRequest.localNoop(localDoseId: sourceId);
      }
      final plannedAt = occurrence.plannedAt;
      if (plannedAt == null) return null;
      if (targetState == 'pending') {
        return _LegacyRequest.delete(
          path: '/logs/$logServerId',
          knownServerId: logServerId!,
          localDoseId: sourceId,
        );
      }
      final body = <String, Object?>{
        'status': targetState,
        'scheduledAt': plannedAt.toUtc().toIso8601String(),
        'takenAt': command['actualAt'],
        'note': command['note'],
      };
      if (logServerId != null) {
        return _LegacyRequest.patch(
          path: '/logs/$logServerId',
          body: body,
          knownServerId: logServerId,
          localDoseId: sourceId,
        );
      }
      return _LegacyRequest.post(
        path: '/logs/$scheduleServerId',
        body: body,
        localDoseId: sourceId,
      );
    }
    if (effect.kind == 'inventory') {
      final projection = payload['localProjection'];
      final pillId = projection is Map<String, dynamic>
          ? projection['pillId']
          : null;
      final targetStock = projection is Map<String, dynamic>
          ? projection['resultingStock']
          : null;
      if (pillId is! String || targetStock is! int) return null;
      final pill = await db.pillsDao.getById(pillId);
      final serverId = pill?.serverId;
      if (serverId == null) return null;
      return _LegacyRequest.patch(
        path: '/pills/$serverId',
        body: {'currentStock': targetStock},
        knownServerId: serverId,
      );
    }
    return null;
  }

  Future<_LegacyResponse> _send(_LegacyRequest request) async {
    if (request.method == 'noop') {
      return const _LegacyResponse(statusCode: 204, data: null);
    }
    final response = switch (request.method) {
      'post' => await dio.post<dynamic>(request.path!, data: request.body),
      'patch' => await dio.patch<dynamic>(request.path!, data: request.body),
      'delete' => await dio.delete<dynamic>(request.path!),
      _ => throw StateError('Unknown legacy medication request method'),
    };
    return _LegacyResponse(
      statusCode: response.statusCode,
      data: response.data,
      serverId: _serverId(response.data),
    );
  }

  Map<String, dynamic>? _decode(String json) {
    try {
      final value = jsonDecode(json);
      return value is Map<String, dynamic> ? value : null;
    } on FormatException {
      return null;
    }
  }

  String? _targetState(Map<String, dynamic> command) {
    final target = command['targetState'];
    if (target is String) return target;
    return switch (command['action']) {
      'take' => 'taken',
      'skip' => 'skipped',
      _ => null,
    };
  }

  String? _serverId(Object? data) {
    if (data is! Map<String, dynamic>) return null;
    if (data['id'] is String) return data['id'] as String;
    final nested = data['data'];
    return nested is Map<String, dynamic> && nested['id'] is String
        ? nested['id'] as String
        : null;
  }

  String? _errorCode(DioException error) {
    final body = error.response?.data;
    final details = body is Map<String, dynamic> ? body['error'] : null;
    final code = details is Map<String, dynamic> ? details['code'] : null;
    return code is String && RegExp(r'^[A-Z][A-Z0-9_]{0,63}$').hasMatch(code)
        ? code
        : null;
  }

  String? _correlationId(DioException error) {
    final body = error.response?.data;
    final details = body is Map<String, dynamic> ? body['error'] : null;
    final id = details is Map<String, dynamic>
        ? details['correlationId']
        : null;
    return id is String && id.length <= 128 ? id : null;
  }

  String _sha256(Object? value) =>
      sha256.convert(utf8.encode(jsonEncode(_canonicalize(value)))).toString();

  Object? _canonicalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonicalize(value[key])};
    }
    if (value is Iterable) return value.map(_canonicalize).toList();
    return value;
  }
}

class _LegacyRequest {
  const _LegacyRequest({
    required this.method,
    this.path,
    this.body,
    this.knownServerId,
    this.localDoseId,
    this.requiresServerId = false,
  });

  const _LegacyRequest.localNoop({String? localDoseId})
    : this(method: 'noop', localDoseId: localDoseId);

  const _LegacyRequest.post({
    required String path,
    required Map<String, Object?> body,
    String? localDoseId,
  }) : this(
         method: 'post',
         path: path,
         body: body,
         localDoseId: localDoseId,
         requiresServerId: true,
       );

  const _LegacyRequest.patch({
    required String path,
    required Map<String, Object?> body,
    required String knownServerId,
    String? localDoseId,
  }) : this(
         method: 'patch',
         path: path,
         body: body,
         knownServerId: knownServerId,
         localDoseId: localDoseId,
       );

  const _LegacyRequest.delete({
    required String path,
    required String knownServerId,
    String? localDoseId,
  }) : this(
         method: 'delete',
         path: path,
         knownServerId: knownServerId,
         localDoseId: localDoseId,
       );

  final String method;
  final String? path;
  final Map<String, Object?>? body;
  final String? knownServerId;
  final String? localDoseId;
  final bool requiresServerId;
}

class _LegacyResponse {
  const _LegacyResponse({
    required this.statusCode,
    required this.data,
    this.serverId,
  });

  final int? statusCode;
  final Object? data;
  final String? serverId;
}
