import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:uuid/uuid.dart';

import '../../db/database.dart';
import '../legacy_prn_recovery_proof.dart';
import '../stable_record_merger.dart'
    show mergeWirePillDetails, wirePillCompanion;
import '../pill_unsent_work.dart' show PillJournal;
import '../schedule_repair_intent.dart';
import 'stable_record_adapter.dart';

class V2StableAdapter extends StableRecordAdapter {
  const V2StableAdapter({
    required super.db,
    required super.dio,
    super.writeScope,
    this.medicationDetails = false,
    this.medicationShapes = false,
    this.medicationDetailsExtra = false,
  });

  /// Whether this server stores the reviewed medication details. A server
  /// without them rejects unknown fields outright, so they are left out of the
  /// request; the medicine's own fields still go, and the review stays on this
  /// device until a server that can keep it is reached.
  final bool medicationDetails;

  /// Whether this server stores the picked medication shape. Without it the
  /// field is left out of the request, exactly as the details are, and the
  /// pick stays on this device.
  final bool medicationShapes;

  /// Whether this server stores the medication extras (limits, expiry and
  /// contacts). Without it the request leaves them out.
  final bool medicationDetailsExtra;

  static const _ids = Uuid();

  Future<StableMutationResult> _sendRepair(PendingOperation operation) async {
    final intent = ScheduleRepairIntent.fromOperation(operation);
    if (intent == null) {
      return const StableMutationResult(
        StableMutationStatus.blocked,
        safeErrorCode: 'INVALID_SCHEDULE_REPAIR',
      );
    }
    final payload = decodeOperation(operation);
    final localId = payload['entityLocalId'];
    final parentId = payload['parentEntityLocalId'];
    if (localId is! String ||
        parentId is! String ||
        await serverIdFor('schedule', localId) != intent.scheduleId ||
        await serverIdFor('pill', parentId) != intent.pillId) {
      return const StableMutationResult(
        StableMutationStatus.blocked,
        safeErrorCode: 'SCHEDULE_REPAIR_IDENTITY_CHANGED',
      );
    }
    try {
      final response = await dio.post<dynamic>(
        intent.path,
        data: intent.request,
      );
      if (!intent.matchesReceipt(response.data)) {
        return const StableMutationResult(
          StableMutationStatus.blocked,
          safeErrorCode: 'SCHEDULE_REPAIR_RECEIPT_MISMATCH',
        );
      }
      // Commit the verified receipt and unblock authoritative pull together.
      // Later optimistic edits keep their fields and gain the new base revision.
      return StableMutationResult(
        StableMutationStatus.acknowledged,
        acknowledgedMutationId: operation.mutationId,
        applyReceipt: () async {
          final current = await db.schedulesDao.getById(localId);
          // A concurrent pull can already contain this repair or a later edit.
          // The cached receipt settles intent, never rewinds that projection.
          if (current == null || current.revision >= 2) return;
          final preservePending = await hasOtherIntent(
            operation,
            'schedule',
            localId,
          );
          final document = intent.request['schedule'] as Map;
          await (db.update(
            db.schedules,
          )..where((row) => row.id.equals(localId))).write(
            SchedulesCompanion(
              revision: const Value(2),
              syncStatus: Value(preservePending ? 'pending' : 'synced'),
              lastSyncAt: Value(DateTime.now().millisecondsSinceEpoch),
              hour: preservePending
                  ? const Value.absent()
                  : Value(document['hour'] as int),
              minute: preservePending
                  ? const Value.absent()
                  : Value(document['minute'] as int),
              frequency: preservePending
                  ? const Value.absent()
                  : Value(document['frequency'] as String),
              frequencyDays: preservePending
                  ? const Value.absent()
                  : Value(
                      document['frequencyDays'] == null
                          ? null
                          : jsonEncode(document['frequencyDays']),
                    ),
              isActive: preservePending
                  ? const Value.absent()
                  : Value(document['isActive'] as bool),
              timeZone: preservePending
                  ? const Value.absent()
                  : Value(document['timeZone'] as String),
              timeZoneStatus: preservePending
                  ? const Value.absent()
                  : const Value('known'),
            ),
          );
        },
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) rethrow;
      if (error.response == null || (error.response?.statusCode ?? 0) >= 500) {
        return StableMutationResult(
          StableMutationStatus.retryable,
          safeErrorCode: 'SCHEDULE_REPAIR_OUTCOME_UNCONFIRMED',
          safeCorrelationId: responseCorrelationId(error),
        );
      }
      return classifyFailure(error);
    }
  }

  @override
  Future<Map<String, Object?>?> buildFrozenRequest(
    PendingOperation operation,
  ) async {
    if (operation.operationType == 'schedule.repair') return null;
    try {
      final payload = decodeOperation(operation);
      final data = dataFrom(payload);
      final entityType = payload['entityType'];
      final localId = payload['entityLocalId'];
      final action = payload['action'];
      if (entityType is! String || localId is! String || action is! String) {
        return null;
      }
      final path = await _path(payload, entityType, localId, action);
      if (path == null) return null;
      final body = await _versionedBody(
        operation,
        payload,
        data,
        entityType,
        localId,
        action,
      );
      return body == null ? null : {'path': path, 'body': body};
    } on FormatException {
      return null;
    }
  }

  @override
  Future<StableMutationResult> send(PendingOperation operation) async {
    await writeScope?.requireOperation(operation);
    if (operation.operationType == 'schedule.repair') {
      return _sendRepair(operation);
    }
    late final Map<String, Object?> payload;
    late final Map<String, Object?> data;
    try {
      payload = decodeOperation(operation);
      data = dataFrom(payload);
    } on Object {
      return const StableMutationResult(
        StableMutationStatus.blocked,
        safeErrorCode: 'INVALID_STABLE_OPERATION',
      );
    }

    final entityType = payload['entityType'];
    final localId = payload['entityLocalId'];
    final action = payload['action'];
    if (entityType is! String || localId is! String || action is! String) {
      return const StableMutationResult(
        StableMutationStatus.blocked,
        safeErrorCode: 'INVALID_STABLE_IDENTITY',
      );
    }
    var path = await _path(payload, entityType, localId, action);
    if (path == null) {
      return const StableMutationResult(
        StableMutationStatus.blocked,
        safeErrorCode: 'STABLE_PARENT_NOT_RECONCILED',
      );
    }

    var body = await _versionedBody(
      operation,
      payload,
      data,
      entityType,
      localId,
      action,
    );
    if (body == null) {
      return const StableMutationResult(
        StableMutationStatus.blocked,
        safeErrorCode: 'STABLE_ENTITY_NOT_MAPPED',
      );
    }
    // A request frozen at first send is replayed byte for byte under the same
    // mutation id; the flush already refused any drift from a fresh build.
    final frozen = payload['frozenRequest'];
    if (frozen is Map && frozen['path'] is String && frozen['body'] is Map) {
      path = frozen['path'] as String;
      body = Map<String, Object?>.from(frozen['body'] as Map);
    }

    Map<String, dynamic>? recovery;
    try {
      recovery = _legacyPrnRecovery(payload, data, entityType, localId, action);
      if (recovery != null &&
          !await _recoveryParentsMatch(operation, payload, recovery)) {
        return const StableMutationResult(
          StableMutationStatus.blocked,
          safeErrorCode: 'LEGACY_PRN_RECOVERY_PARENT_CHANGED',
        );
      }
      if (recovery != null &&
          !await _recoveryServerStateAllowsCreate(
            path,
            localId,
            data,
            recovery['parentServerId'] as String,
          )) {
        return const StableMutationResult(
          StableMutationStatus.blocked,
          safeErrorCode: 'LEGACY_PRN_RECOVERY_SERVER_NOT_EMPTY',
        );
      }
      late final Response<Map<String, dynamic>> response;
      switch (action) {
        case 'create':
          response = await dio.post<Map<String, dynamic>>(path, data: body);
        case 'update':
          response = await dio.patch<Map<String, dynamic>>(path, data: body);
        case 'delete':
          response = await dio.delete<Map<String, dynamic>>(path, data: body);
        default:
          return const StableMutationResult(
            StableMutationStatus.blocked,
            safeErrorCode: 'UNKNOWN_STABLE_ACTION',
          );
      }

      final expectedServerId = action == 'create'
          ? localId
          : await serverIdFor(entityType, localId);
      final serverId = action == 'create'
          ? extractServerId(response.data)
          : expectedServerId;
      final revision = action == 'delete'
          ? null
          : extractRevision(response.data);
      if (action != 'delete' &&
          (expectedServerId == null ||
              serverId != expectedServerId ||
              revision == null ||
              revision < 1)) {
        return const StableMutationResult(
          StableMutationStatus.uncertain,
          safeErrorCode: 'VERSIONED_RECEIPT_IDENTITY_MISMATCH',
        );
      }
      if (recovery != null &&
          (!_exactRecoveryEntity(
                response.data,
                localId,
                data,
                recovery['parentServerId'] as String,
              ) ||
              !await _recoveryServerStateIsExact(
                path,
                localId,
                data,
                recovery['parentServerId'] as String,
              ))) {
        return const StableMutationResult(
          StableMutationStatus.uncertain,
          safeErrorCode: 'LEGACY_PRN_RECOVERY_RECEIPT_MISMATCH',
        );
      }
      return StableMutationResult(
        StableMutationStatus.acknowledged,
        acknowledgedMutationId: operation.mutationId,
        serverId: serverId,
        revision: revision,
        applyReceipt: serverId == null
            ? null
            : recovery == null
            ? () => markLocalReceipt(
                operation,
                entityType,
                localId,
                serverId,
                revision,
              )
            : () => _applyLegacyPrnRecovery(
                operation,
                recovery!,
                localId,
                serverId,
                revision!,
                data,
              ),
      );
    } on FormatException {
      return const StableMutationResult(
        StableMutationStatus.blocked,
        safeErrorCode: 'INVALID_LEGACY_PRN_RECOVERY',
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) rethrow;
      if (recovery != null) {
        if (error.response?.statusCode == 409) {
          final classified = classifyFailure(error);
          return StableMutationResult(
            StableMutationStatus.conflict,
            safeErrorCode:
                classified.safeErrorCode ?? 'LEGACY_PRN_RECOVERY_CONFLICT',
            safeCorrelationId: classified.safeCorrelationId,
          );
        }
        if (error.response == null ||
            (error.response?.statusCode ?? 0) >= 500) {
          return StableMutationResult(
            StableMutationStatus.retryable,
            safeErrorCode: 'LEGACY_PRN_RECOVERY_OUTCOME_UNCONFIRMED',
            safeCorrelationId: responseCorrelationId(error),
          );
        }
      }
      final classified = classifyFailure(error);
      // An update of an entity another device deleted answers 404 with the
      // tombstone. Server wins like a revision conflict: adopt the tombstone
      // and settle the operation as a conflict instead of leaving a pending
      // ghost row that pulls skip.
      final updateOfTombstone =
          action == 'update' &&
          error.response?.statusCode == 404 &&
          _currentTombstone(error) != null;
      if (updateOfTombstone) {
        return StableMutationResult(
          StableMutationStatus.conflict,
          safeErrorCode: classified.safeErrorCode,
          safeCorrelationId: classified.safeCorrelationId,
          applyReceipt: () => _applyConflict(operation, payload, error),
        );
      }
      return StableMutationResult(
        classified.status,
        safeErrorCode: classified.safeErrorCode,
        safeCorrelationId: classified.safeCorrelationId,
        retryAfter: classified.retryAfter,
        applyReceipt: error.response?.statusCode == 409
            ? () => _applyConflict(operation, payload, error)
            : null,
      );
    }
  }

  Future<bool> _recoveryParentsMatch(
    PendingOperation operation,
    Map<String, Object?> payload,
    Map<String, dynamic> marker,
  ) async {
    final localPillId = payload['parentEntityLocalId'];
    if (payload['parentEntityType'] != 'pill' || localPillId is! String) {
      return false;
    }
    final pill = await db.pillsDao.getById(localPillId);
    final profile = pill == null
        ? null
        : await db.profilesDao.getById(pill.profileId);
    final localId = payload['entityLocalId'];
    if (localId is! String) return false;
    final schedule = await db.schedulesDao.getById(localId);
    final issue = await db.migrationIssuesDao.getById(
      marker['issueId'] as String,
    );
    final aliases =
        await (db.select(db.schedules)..where(
              (candidate) =>
                  candidate.id.equals(localId) |
                  candidate.serverId.equals(localId),
            ))
            .get();
    final localPrnRows =
        await (db.select(db.schedules)..where(
              (candidate) =>
                  candidate.pillId.equals(localPillId) &
                  candidate.frequency.equals('prn'),
            ))
            .get();
    final history = (await db.pendingOperationsDao.getForUser(operation.userId))
        .where((candidate) {
          if (candidate.component != 'stable') return false;
          try {
            final decoded = jsonDecode(candidate.payloadJson);
            return decoded is Map &&
                decoded['entityType'] == 'schedule' &&
                decoded['entityLocalId'] == localId;
          } on FormatException {
            return true;
          }
        })
        .toList();
    return pill != null &&
        profile != null &&
        schedule != null &&
        issue != null &&
        pill.isPrn &&
        !pill.isDeleted &&
        pill.syncStatus == 'synced' &&
        pill.serverId == marker['parentServerId'] &&
        !profile.isDeleted &&
        profile.syncStatus == 'synced' &&
        profile.serverId != null &&
        profile.userId == operation.userId &&
        schedule.pillId == pill.id &&
        schedule.serverId == null &&
        schedule.revision == 1 &&
        schedule.syncStatus == 'pending' &&
        !schedule.isDeleted &&
        !schedule.isActive &&
        schedule.frequency == 'prn' &&
        schedule.frequencyDays == null &&
        schedule.timeZone == null &&
        schedule.timeZoneStatus == 'legacy_unknown' &&
        legacyPrnPreimageFingerprint(schedule) ==
            marker['preimageFingerprint'] &&
        issue.userId == operation.userId &&
        issue.serverId == null &&
        issue.entityType == 'schedule' &&
        issue.entityId == localId &&
        issue.issueCode == 'invalid_schedule_frequency_days' &&
        issue.resolutionState == 'unresolved' &&
        issue.revision == 1 &&
        legacyPrnSnapshotFingerprint(issue.snapshotJson) ==
            marker['snapshotFingerprint'] &&
        _exactLegacyPrnIssueSnapshot(issue.snapshotJson, localId) &&
        localPrnRows.length == 1 &&
        localPrnRows.single.id == localId &&
        aliases.length == 1 &&
        history.length == 1 &&
        history.single.id == operation.id;
  }

  Map<String, dynamic>? _legacyPrnRecovery(
    Map<String, Object?> payload,
    Map<String, Object?> data,
    String entityType,
    String localId,
    String action,
  ) {
    final marker = payload['legacyPrnRecovery'];
    if (marker == null) return null;
    if (entityType != 'schedule' ||
        action != 'create' ||
        marker is! Map<String, dynamic> ||
        marker.keys.toSet().difference(const {
          'kind',
          'issueId',
          'snapshotFingerprint',
          'preimageFingerprint',
          'parentServerId',
        }).isNotEmpty ||
        marker['kind'] != legacyPrnRecoveryKind ||
        marker['issueId'] is! String ||
        marker['snapshotFingerprint'] is! String ||
        marker['preimageFingerprint'] is! String ||
        marker['parentServerId'] is! String ||
        data['frequency'] != 'prn' ||
        data['frequencyDays'] != null ||
        data['isActive'] != true ||
        data['timeZone'] is! String ||
        data['hour'] is! int ||
        data['minute'] is! int) {
      throw const FormatException('Legacy PRN recovery proof is invalid.');
    }
    return marker;
  }

  Future<bool> _recoveryServerStateAllowsCreate(
    String path,
    String localId,
    Map<String, Object?> data,
    String parentServerId,
  ) async {
    final response = await dio.get<dynamic>(path);
    final rows = _scheduleRows(response.data);
    return rows != null &&
        (rows.isEmpty ||
            (rows.length == 1 &&
                _exactRecoveryEntity(
                  rows.single,
                  localId,
                  data,
                  parentServerId,
                )));
  }

  Future<bool> _recoveryServerStateIsExact(
    String path,
    String localId,
    Map<String, Object?> data,
    String parentServerId,
  ) async {
    final rows = _scheduleRows((await dio.get<dynamic>(path)).data);
    return rows != null &&
        rows.length == 1 &&
        _exactRecoveryEntity(rows.single, localId, data, parentServerId);
  }

  List<Map<String, dynamic>>? _scheduleRows(Object? body) {
    if (body is! Map<String, dynamic> ||
        body.keys.toSet().difference(const {'schedules'}).isNotEmpty ||
        body['schedules'] is! List) {
      return null;
    }
    final result = <Map<String, dynamic>>[];
    for (final row in body['schedules'] as List) {
      if (row is! Map<String, dynamic>) return null;
      result.add(row);
    }
    return result;
  }

  bool _exactRecoveryEntity(
    Object? raw,
    String localId,
    Map<String, Object?> data,
    String parentServerId,
  ) {
    final row =
        raw is Map<String, dynamic> && raw['data'] is Map<String, dynamic>
        ? raw['data'] as Map<String, dynamic>
        : raw;
    return row is Map<String, dynamic> &&
        row['id'] == localId &&
        row['pillId'] == parentServerId &&
        row['revision'] == '1' &&
        row['hour'] == data['hour'] &&
        row['minute'] == data['minute'] &&
        row['frequency'] == 'prn' &&
        row['frequencyDays'] == null &&
        row['isActive'] == true &&
        row['timeZone'] == data['timeZone'] &&
        row['timeZoneStatus'] == 'known' &&
        row['deletedAt'] == null;
  }

  Future<void> _applyLegacyPrnRecovery(
    PendingOperation operation,
    Map<String, dynamic> marker,
    String localId,
    String serverId,
    int revision,
    Map<String, Object?> data,
  ) => writeOperation(operation, () async {
    final row = await db.schedulesDao.getById(localId);
    final issueId = marker['issueId'] as String;
    final issue = await db.migrationIssuesDao.getById(issueId);
    final storedOperation = await db.pendingOperationsDao.getById(operation.id);
    final pill = row == null ? null : await db.pillsDao.getById(row.pillId);
    final profile = pill == null
        ? null
        : await db.profilesDao.getById(pill.profileId);
    final aliases =
        await (db.select(db.schedules)..where(
              (candidate) =>
                  candidate.id.equals(localId) |
                  candidate.serverId.equals(localId),
            ))
            .get();
    final localPrnRows = row == null
        ? const <Schedule>[]
        : await (db.select(db.schedules)..where(
                (candidate) =>
                    candidate.pillId.equals(row.pillId) &
                    candidate.frequency.equals('prn'),
              ))
              .get();
    if (row == null ||
        issue == null ||
        pill == null ||
        profile == null ||
        pill.isDeleted ||
        profile.isDeleted ||
        localPrnRows.length != 1 ||
        localPrnRows.single.id != localId ||
        aliases.length != 1 ||
        storedOperation?.state != 'committed' ||
        operation.userId != profile.userId ||
        !pill.isPrn ||
        pill.serverId != marker['parentServerId'] ||
        pill.syncStatus != 'synced' ||
        profile.serverId == null ||
        profile.syncStatus != 'synced' ||
        row.serverId != null ||
        row.revision != 1 ||
        row.syncStatus != 'pending' ||
        row.isDeleted ||
        row.isActive ||
        row.frequency != 'prn' ||
        row.frequencyDays != null ||
        row.timeZone != null ||
        row.timeZoneStatus != 'legacy_unknown' ||
        legacyPrnPreimageFingerprint(row) != marker['preimageFingerprint'] ||
        issue.userId != operation.userId ||
        issue.serverId != null ||
        issue.entityType != 'schedule' ||
        issue.entityId != localId ||
        issue.issueCode != 'invalid_schedule_frequency_days' ||
        issue.resolutionState != 'unresolved' ||
        issue.revision != 1 ||
        !_exactLegacyPrnIssueSnapshot(issue.snapshotJson, localId) ||
        legacyPrnSnapshotFingerprint(issue.snapshotJson) !=
            marker['snapshotFingerprint'] ||
        serverId != localId ||
        revision != 1) {
      throw const FormatException('Legacy PRN recovery preimage changed.');
    }
    final now = DateTime.now().toUtc();
    await (db.update(db.schedules)..where((s) => s.id.equals(localId))).write(
      SchedulesCompanion(
        isActive: const Value(true),
        timeZone: Value(data['timeZone'] as String),
        timeZoneStatus: const Value('known'),
        serverId: Value(serverId),
        revision: Value(revision),
        syncStatus: const Value('synced'),
        lastSyncAt: Value(now.millisecondsSinceEpoch),
      ),
    );
    await (db.update(
      db.migrationIssues,
    )..where((i) => i.id.equals(issueId))).write(
      MigrationIssuesCompanion(
        resolutionState: const Value('resolved'),
        resolvedAt: Value(now),
        resolvedByUserId: Value(operation.userId),
        updatedAt: Value(now),
      ),
    );
  });

  bool _exactLegacyPrnIssueSnapshot(String value, String localId) {
    try {
      final snapshot = jsonDecode(value);
      return snapshot is Map &&
          snapshot.length == 4 &&
          snapshot.keys.toSet().difference(const {
            'scheduleId',
            'frequency',
            'frequencyDays',
            'isPrn',
          }).isEmpty &&
          snapshot['scheduleId'] == localId &&
          snapshot['frequency'] == 'prn' &&
          snapshot['frequencyDays'] == null &&
          snapshot['isPrn'] == true;
    } on FormatException {
      return false;
    }
  }

  Future<String?> _path(
    Map<String, Object?> payload,
    String entityType,
    String localId,
    String action,
  ) async {
    if (entityType == 'profile') {
      if (action == 'create') return '/profiles';
      final id = await serverIdFor('profile', localId);
      return id == null ? null : '/profiles/$id';
    }
    final parentId = await parentServerId(payload);
    if (parentId == null) return null;
    if (entityType == 'pill') {
      if (action == 'create') return '/profiles/$parentId/pills';
      final id = await serverIdFor('pill', localId);
      return id == null ? null : '/profiles/$parentId/pills/$id';
    }
    if (entityType == 'schedule') {
      if (action == 'create') return '/pills/$parentId/schedules';
      final id = await serverIdFor('schedule', localId);
      return id == null ? null : '/pills/$parentId/schedules/$id';
    }
    return null;
  }

  Future<Map<String, Object?>?> _versionedBody(
    PendingOperation operation,
    Map<String, Object?> payload,
    Map<String, Object?> data,
    String entityType,
    String localId,
    String action,
  ) async {
    final result = <String, Object?>{'mutationId': operation.mutationId};
    if (action == 'delete' || action == 'update') {
      final revision = switch (entityType) {
        'profile' => (await db.profilesDao.getById(localId))?.revision,
        'pill' => (await db.pillsDao.getById(localId))?.revision,
        'schedule' => (await db.schedulesDao.getById(localId))?.revision,
        _ => null,
      };
      if (revision == null || revision < 1) return null;
      result['baseRevision'] = revision.toString();
      if (action == 'delete') return result;
    } else if (action == 'create') {
      result['id'] = localId;
    } else {
      return null;
    }

    switch (entityType) {
      case 'profile':
        result.addAll(_pick(data, const ['name', 'avatarEmoji', 'isActive']));
      case 'pill':
        // Initial stock is an inventory command, never a stable-record field.
        result.addAll(
          _pick(data, const [
            'name',
            'dosage',
            'notes',
            'color',
            'lowStockThreshold',
            'isPrn',
          ]),
        );
        if (medicationDetails) {
          result.addAll(
            _pick(data, const [
              'amountPerUse',
              'packageStrength',
              'form',
              'legacyDosageReviewed',
            ]),
          );
        }
        if (medicationShapes) {
          result.addAll(_pick(data, const ['shape']));
        }
        if (medicationDetailsExtra) {
          result.addAll(
            _pick(data, const [
              'prnMaxPer24h',
              'prnMinGapMinutes',
              'expiresOn',
              'prescriberName',
              'prescriberPhone',
              'pharmacyName',
              'pharmacyPhone',
            ]),
          );
        }
        // A create has nothing to clear, and servers before the nullable
        // create schema reject explicit nulls for these optional texts.
        // Omitting them is the same unset value and the same server
        // fingerprint, so retries still replay.
        if (action == 'create') {
          for (final key in const [
            'dosage',
            'notes',
            'color',
            'prnMaxPer24h',
            'prnMinGapMinutes',
            'expiresOn',
            'prescriberName',
            'prescriberPhone',
            'pharmacyName',
            'pharmacyPhone',
          ]) {
            if (result[key] == null) result.remove(key);
          }
        }
      case 'schedule':
        result.addAll(
          _pick(data, const [
            'hour',
            'minute',
            'frequency',
            'isActive',
            'timeZone',
            // Present only for a schedule that uses an interval or a date
            // window; a missing key is left out of the request entirely.
            'everyDays',
            'anchorDate',
            'startDate',
            'endDate',
          ]),
        );
        if (data.containsKey('frequencyDays')) {
          result['frequencyDays'] = frequencyDaysToWire(data['frequencyDays']);
        }
      default:
        return null;
    }
    return result;
  }

  Map<String, Object?> _pick(Map<String, Object?> source, List<String> keys) =>
      {
        for (final key in keys)
          if (source.containsKey(key)) key: source[key],
      };

  /// The `currentEntity` of an error body when it is a soft-deleted entity.
  Map<String, dynamic>? _currentTombstone(DioException error) {
    final body = error.response?.data;
    if (body is! Map<String, dynamic> || body['error'] is! Map) return null;
    final details = (body['error'] as Map)['details'];
    if (details is! Map) return null;
    final entity = details['currentEntity'];
    if (entity is! Map<String, dynamic> || entity['deletedAt'] == null) {
      return null;
    }
    return entity;
  }

  Future<void> _applyConflict(
    PendingOperation operation,
    Map<String, Object?> payload,
    DioException error,
  ) async {
    final body = error.response?.data;
    if (body is! Map<String, dynamic> ||
        body['error'] is! Map<String, dynamic>) {
      return;
    }
    final details = (body['error'] as Map<String, dynamic>)['details'];
    if (details is! Map<String, dynamic>) return;
    final entity = details['currentEntity'];
    if (entity is! Map<String, dynamic> ||
        entity['id'] is! String ||
        entity['revision'] is! String) {
      return;
    }
    final localId = payload['entityLocalId'];
    final entityType = payload['entityType'];
    if (localId is! String || entityType is! String) return;
    final expectedType = switch (entityType) {
      'profile' => 'profiles',
      'pill' => 'pills',
      'schedule' => 'schedules',
      _ => null,
    };
    if (entity['entityType'] != expectedType) return;
    final revision = int.tryParse(entity['revision'] as String);
    if (revision == null || revision < 1) return;

    await writeOperation(operation, () async {
      final preservePending = await hasOtherIntent(
        operation,
        entityType,
        localId,
      );
      if (!preservePending) {
        switch (entityType) {
          case 'profile':
            final local = await db.profilesDao.getById(localId);
            if (local == null ||
                (local.serverId != null && local.serverId != entity['id'])) {
              break;
            }
            await db.profilesDao.update_(
              ProfilesCompanion(
                id: Value(local.id),
                userId: Value(local.userId),
                name: Value(entity['name'] as String),
                avatarEmoji: Value(entity['avatarEmoji'] as String),
                isActive: Value(entity['isActive'] as bool),
                createdAt: Value(local.createdAt),
                updatedAt: Value(
                  _parseDate(entity['updatedAt']) ?? local.updatedAt,
                ),
                serverId: Value(entity['id'] as String),
                revision: Value(revision),
                syncStatus: const Value('synced'),
                lastSyncAt: Value(DateTime.now().millisecondsSinceEpoch),
                isDeleted: Value(entity['deletedAt'] != null),
              ),
            );
          case 'pill':
            final local = await db.pillsDao.getById(localId);
            if (local == null ||
                (local.serverId != null && local.serverId != entity['id'])) {
              break;
            }
            final remoteProfileId = entity['profileId'];
            final mappedProfile = remoteProfileId is String
                ? await db.profilesDao.getByServerId(remoteProfileId)
                : null;
            if (mappedProfile != null) {
              await writeScope?.requireEntity('profile', mappedProfile.id);
            }
            // The same mapper as the pull merge, so every field the account
            // holds is adopted here too; a field left out would stay local
            // on a row marked synced and never be resent.
            final journal = await PillJournal.read(db, operation.userId);
            await db.pillsDao.update_(
              wirePillCompanion(
                entity,
                medicationDetailsExtra: medicationDetailsExtra,
                keepStockOf: journal.keepsLocalStock(local.id) ? local : null,
                keepRecountMarkOf: journal.holdsRecountMark(local.id)
                    ? local
                    : null,
              ).copyWith(
                id: Value(local.id),
                profileId: Value(mappedProfile?.id ?? local.profileId),
                createdAt: Value(local.createdAt),
                updatedAt: Value(
                  _parseDate(entity['updatedAt']) ?? local.updatedAt,
                ),
                serverId: Value(entity['id'] as String),
                revision: Value(revision),
                syncStatus: const Value('synced'),
                lastSyncAt: Value(DateTime.now().millisecondsSinceEpoch),
                isDeleted: Value(entity['deletedAt'] != null),
              ),
            );
            // The server's reviewed details win with the rest of the record.
            // A pull skips a pill holding unsent work, so without this the
            // review made on another device never reaches this one.
            await mergeWirePillDetails(db, entity, local.id);
          case 'schedule':
            final local = await db.schedulesDao.getById(localId);
            if (local == null ||
                (local.serverId != null && local.serverId != entity['id'])) {
              break;
            }
            final days = entity['frequencyDays'];
            final encodedDays = days == null ? null : jsonEncode(days);
            await db.schedulesDao.update_(
              SchedulesCompanion(
                id: Value(local.id),
                pillId: Value(local.pillId),
                hour: Value(entity['hour'] as int),
                minute: Value(entity['minute'] as int),
                frequency: Value(entity['frequency'] as String),
                frequencyDays: Value(encodedDays),
                everyDays: Value(entity['everyDays'] as int?),
                anchorDate: Value(entity['anchorDate'] as String?),
                startDate: Value(entity['startDate'] as String?),
                endDate: Value(entity['endDate'] as String?),
                timeZone: Value(entity['timeZone'] as String?),
                timeZoneStatus: Value(
                  entity['timeZoneStatus'] as String? ?? 'legacy_unknown',
                ),
                isActive: Value(entity['isActive'] as bool),
                createdAt: Value(local.createdAt),
                updatedAt: Value(
                  _parseDate(entity['updatedAt']) ?? local.updatedAt,
                ),
                serverId: Value(entity['id'] as String),
                revision: Value(revision),
                syncStatus: const Value('synced'),
                lastSyncAt: Value(DateTime.now().millisecondsSinceEpoch),
                isDeleted: Value(entity['deletedAt'] != null),
              ),
            );
        }
      }
      await db.migrationIssuesDao.record(
        MigrationIssuesCompanion.insert(
          id: _ids.v4(),
          userId: operation.userId,
          entityType: entityType,
          entityId: localId,
          issueCode: 'stable_revision_conflict_server_wins',
          snapshotJson: jsonEncode({
            'operationId': operation.id,
            'mutationId': operation.mutationId,
            'localIntent': payload,
            'serverEntity': entity,
          }),
          serverId: Value(entity['id'] as String),
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    });
  }

  DateTime? _parseDate(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}
