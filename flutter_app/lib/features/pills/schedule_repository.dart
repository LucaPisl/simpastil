import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:collection/collection.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:uuid/uuid.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../core/db/daos/pills_dao.dart';
import '../../core/db/daos/profiles_dao.dart';
import '../../core/db/daos/medication_ledger_dao.dart';
import '../../core/db/daos/migration_issues_dao.dart';
import '../../core/db/daos/schedules_dao.dart';
import '../../core/db/database.dart';
import '../../core/errors/app_error.dart';
import '../../core/medication/occurrence_materializer.dart';
import '../../core/projections/projection_command_id.dart';
import '../../core/sync/pending_operation_repository.dart';
import '../../core/sync/legacy_prn_recovery_proof.dart';
import '../../core/sync/schedule_repair_intent.dart';
import '../../core/sync/sync_write_scope.dart';
import '../../core/sync/adapters/schedules_sync_adapter.dart';
import '../../core/sync/adapters/v2_stable_adapter.dart';
import '../../core/workspace/workspace_context.dart';
import '../../core/utils/app_logger.dart';

// ── Abstract interface ────────────────────────────────────────────────────────

abstract class ScheduleRepository {
  Future<Result<Schedule>> recoverLegacyPrn({
    required String localId,
    required String timeZone,
  });

  Future<Result<Schedule>> create({
    required String pillId,
    required int hour,
    required int minute,
    required String frequency,
    List<int>? frequencyDays,
    bool isActive,
  });

  Future<Result<Schedule>> update(
    String localId, {
    required int hour,
    required int minute,
    required String frequency,
    List<int>? frequencyDays,
    required bool isActive,
  });

  Future<Result<void>> delete(String localId);

  Future<Result<Schedule>> repair({
    required String localId,
    required String issueId,
    required int expectedIssueRevision,
    required int hour,
    required int minute,
    required String frequency,
    required List<int>? frequencyDays,
    required bool isActive,
    required DateTime effectiveFromLocalDate,
    required String timeZone,
  });
}

// ── Concrete implementation ───────────────────────────────────────────────────

class ScheduleRepositoryImpl implements ScheduleRepository {
  const ScheduleRepositoryImpl({
    required SchedulesDao schedulesDao,
    required PillsDao pillsDao,
    required ProfilesDao profilesDao,
    required MedicationLedgerDao ledgerDao,
    required MigrationIssuesDao migrationIssuesDao,
    required PendingOperationRepository pendingOperations,
    required Dio dio,
    required Future<void> Function() reconcileProjections,
  }) : _schedulesDao = schedulesDao,
       _pillsDao = pillsDao,
       _profilesDao = profilesDao,
       _ledgerDao = ledgerDao,
       _migrationIssuesDao = migrationIssuesDao,
       _pendingOperations = pendingOperations,
       _dio = dio,
       _reconcileProjections = reconcileProjections;

  final SchedulesDao _schedulesDao;
  final PillsDao _pillsDao;
  final ProfilesDao _profilesDao;
  final MedicationLedgerDao _ledgerDao;
  final MigrationIssuesDao _migrationIssuesDao;
  final PendingOperationRepository _pendingOperations;
  final Dio _dio;
  final Future<void> Function() _reconcileProjections;

  static const _uuid = Uuid();

  Future<Profile?> _readProfile(String id) =>
      _pendingOperations.withCareGrant(() async {
        final profile = await _profilesDao.getById(id);
        if (profile != null) {
          _pendingOperations.requireCareOwner(profile.userId);
          if (profile.isDeleted) {
            throw const WorkspaceAccessFailure(
              WorkspaceAccessFailureCode.wrongPerson,
            );
          }
        }
        return profile;
      });

  Future<Pill?> _readPill(String id) =>
      _pendingOperations.withCareGrant(() async {
        final pill = await _pillsDao.getById(id);
        if (pill?.isDeleted == true) {
          throw const WorkspaceAccessFailure(
            WorkspaceAccessFailureCode.wrongPerson,
          );
        }
        if (pill != null && await _readProfile(pill.profileId) == null) {
          throw const WorkspaceAccessFailure(
            WorkspaceAccessFailureCode.wrongPerson,
          );
        }
        return pill;
      });

  Future<Schedule?> _readSchedule(String id) =>
      _pendingOperations.withCareGrant(() async {
        final schedule = await _schedulesDao.getById(id);
        if (schedule != null && await _readPill(schedule.pillId) == null) {
          throw const WorkspaceAccessFailure(
            WorkspaceAccessFailureCode.wrongPerson,
          );
        }
        return schedule;
      });

  Future<MigrationIssue?> _readIssue(String id) =>
      _pendingOperations.withCareGrant(() async {
        final issue = await _migrationIssuesDao.getById(id);
        if (issue != null) _pendingOperations.requireCareOwner(issue.userId);
        return issue;
      });

  Future<void> _requireUnchangedSchedule(Schedule expected) async {
    if (await _readSchedule(expected.id) != expected) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.unavailable,
      );
    }
  }

  Future<void> _requireUnchangedParents(Pill pill, Profile profile) async {
    if (await _readPill(pill.id) != pill ||
        await _readProfile(profile.id) != profile) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.unavailable,
      );
    }
  }

  Future<void> _effects(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      AppLogger.warning(
        'ScheduleRepository',
        'Optional projection unavailable: ${error.runtimeType}',
      );
    }
  }

  @override
  Future<Result<Schedule>> recoverLegacyPrn({
    required String localId,
    required String timeZone,
  }) async {
    try {
      tz.getLocation(timeZone);
    } on Object {
      return const Err(ConflictError());
    }
    final initial = await _readSchedule(localId);
    if (initial == null) return const Err(NotFoundError());
    final pill = await _readPill(initial.pillId);
    final profile = pill == null ? null : await _readProfile(pill.profileId);
    if (pill == null || profile == null || pill.serverId == null) {
      return const Err(NotFoundError());
    }
    try {
      final response = await _dio.get<dynamic>(
        '/pills/${pill.serverId}/schedules',
      );
      if (!_emptyScheduleList(response.data)) {
        return const Err(ConflictError());
      }
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        return const Err(UnauthorizedError());
      }
      return Err(NetworkError(error.message ?? 'Network error'));
    }

    final issueMatches = await _pendingOperations.withCareGrant(() async {
      _pendingOperations.requireCareOwner(profile.userId);
      return (await _migrationIssuesDao.getUnresolved(profile.userId))
          .where((candidate) => _isExactLegacyPrnIssue(candidate, initial))
          .toList();
    });
    if (issueMatches.length != 1 ||
        !_isLegacyPrnPreimage(initial, pill, profile)) {
      return const Err(ConflictError());
    }
    final issue = issueMatches.single;
    final snapshotFingerprint = legacyPrnSnapshotFingerprint(
      issue.snapshotJson,
    );
    final preimageFingerprint = legacyPrnPreimageFingerprint(initial);
    try {
      await _pendingOperations.record(
        operation: PendingOperationDraft(
          userId: profile.userId,
          operationType: 'schedule.create',
          entityType: 'schedule',
          entityLocalId: localId,
          parentEntityType: 'pill',
          parentEntityLocalId: pill.id,
          payload: {
            'action': 'create',
            'legacyPrnRecovery': {
              'kind': legacyPrnRecoveryKind,
              'issueId': issue.id,
              'snapshotFingerprint': snapshotFingerprint,
              'preimageFingerprint': preimageFingerprint,
              'parentServerId': pill.serverId,
            },
            'data': {
              'hour': initial.hour,
              'minute': initial.minute,
              'frequency': 'prn',
              'frequencyDays': null,
              'isActive': true,
              'timeZone': timeZone,
            },
          },
        ),
        applyProjection: () async {
          final retained = await _schedulesDao.getById(localId);
          if (retained == null) {
            throw StateError('retained schedule disappeared');
          }
          final parent = await _pillsDao.getById(retained.pillId);
          final owner = parent == null
              ? null
              : await _profilesDao.getById(parent.profileId);
          final db = _schedulesDao.attachedDatabase;
          final rows = await (db.select(
            db.schedules,
          )..where((row) => row.pillId.equals(retained.pillId))).get();
          final aliases =
              await (db.select(db.schedules)..where(
                    (row) =>
                        row.id.equals(localId) | row.serverId.equals(localId),
                  ))
                  .get();
          final matches =
              (await _migrationIssuesDao.getUnresolved(profile.userId))
                  .where(
                    (candidate) => _isExactLegacyPrnIssue(candidate, retained),
                  )
                  .toList();
          final history =
              (await db.pendingOperationsDao.getForUser(profile.userId)).where((
                operation,
              ) {
                if (operation.component != 'stable') return false;
                try {
                  final payload = jsonDecode(operation.payloadJson);
                  return payload is Map &&
                      payload['entityType'] == 'schedule' &&
                      payload['entityLocalId'] == localId;
                } on FormatException {
                  return true;
                }
              }).toList();
          if (legacyPrnPreimageFingerprint(retained) != preimageFingerprint ||
              parent == null ||
              owner == null ||
              parent != pill ||
              owner != profile ||
              !_isLegacyPrnPreimage(retained, parent, owner) ||
              rows.where((row) => row.frequency == 'prn').length != 1 ||
              aliases.length != 1 ||
              matches.length != 1 ||
              matches.single.id != issue.id ||
              legacyPrnSnapshotFingerprint(matches.single.snapshotJson) !=
                  snapshotFingerprint ||
              history.length != 1 ||
              history.single.operationType != 'schedule.create') {
            throw StateError('legacy PRN recovery preimage changed');
          }
        },
      );
    } on Object {
      return const Err(ConflictError());
    }
    return Ok(initial);
  }

  bool _emptyScheduleList(Object? body) =>
      body is Map<String, dynamic> &&
      body.length == 1 &&
      body['schedules'] is List &&
      (body['schedules'] as List).isEmpty;

  bool _isLegacyPrnPreimage(Schedule row, Pill pill, Profile profile) =>
      RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
      ).hasMatch(row.id) &&
      row.pillId == pill.id &&
      pill.profileId == profile.id &&
      pill.isPrn &&
      pill.serverId != null &&
      pill.syncStatus == 'synced' &&
      profile.serverId != null &&
      profile.syncStatus == 'synced' &&
      row.serverId == null &&
      row.revision == 1 &&
      row.syncStatus == 'pending' &&
      !row.isDeleted &&
      !row.isActive &&
      row.frequency == 'prn' &&
      row.frequencyDays == null &&
      row.timeZone == null &&
      row.timeZoneStatus == 'legacy_unknown';

  bool _isExactLegacyPrnIssue(MigrationIssue issue, Schedule row) {
    if (issue.serverId != null ||
        issue.resolutionState != 'unresolved' ||
        issue.revision != 1 ||
        issue.entityType != 'schedule' ||
        issue.issueCode != 'invalid_schedule_frequency_days' ||
        issue.entityId != row.id) {
      return false;
    }
    try {
      final snapshot = jsonDecode(issue.snapshotJson);
      return snapshot is Map &&
          snapshot.length == 4 &&
          snapshot.keys.toSet().difference(const {
            'scheduleId',
            'frequency',
            'frequencyDays',
            'isPrn',
          }).isEmpty &&
          snapshot['scheduleId'] == row.id &&
          snapshot['frequency'] == 'prn' &&
          snapshot['frequencyDays'] == null &&
          snapshot['isPrn'] == true;
    } on FormatException {
      return false;
    }
  }

  // ── create ─────────────────────────────────────────────────────────────────

  @override
  Future<Result<Schedule>> create({
    required String pillId,
    required int hour,
    required int minute,
    required String frequency,
    List<int>? frequencyDays,
    bool isActive = true,
  }) async {
    final pill = await _readPill(pillId);
    if (pill == null) return const Err(NotFoundError());
    final profile = await _readProfile(pill.profileId);
    if (profile == null) return const Err(NotFoundError());

    final localId = _uuid.v4();
    final now = DateTime.now();
    final timeZone = tz.local.name;

    final companion = SchedulesCompanion.insert(
      id: localId,
      pillId: pillId,
      hour: hour,
      minute: minute,
      frequency: frequency,
      timeZone: Value(timeZone),
      timeZoneStatus: const Value('known'),
      frequencyDays: Value(
        frequencyDays != null ? jsonEncode(frequencyDays) : null,
      ),
      isActive: Value(isActive),
      createdAt: now,
      updatedAt: now,
    );

    await _pendingOperations.record(
      operation: PendingOperationDraft(
        userId: profile.userId,
        operationType: 'schedule.create',
        entityType: 'schedule',
        entityLocalId: localId,
        parentEntityType: 'pill',
        parentEntityLocalId: pillId,
        payload: {
          'action': 'create',
          'data': {
            'hour': hour,
            'minute': minute,
            'frequency': frequency,
            // Local Drift text remains JSON; the immutable wire payload stores
            // the canonical int[] shape expected by contract v2.
            'frequencyDays': frequencyDays,
            'isActive': isActive,
            'timeZone': timeZone,
          },
        },
      ),
      applyProjection: () async {
        await _requireUnchangedParents(pill, profile);
        await _schedulesDao.upsert(companion);
        await _projectOccurrences(
          userId: profile.userId,
          scheduleId: localId,
          scheduleRevision: 1,
          pill: pill,
          profileName: profile.name,
          hour: hour,
          minute: minute,
          frequency: frequency,
          frequencyDays: frequencyDays,
          isActive: isActive,
          timeZone: timeZone,
          now: now,
        );
      },
    );
    final local = await _readSchedule(localId);
    if (local == null) {
      return const Err(UnknownError('Failed to read schedule after insert'));
    }

    await _effects(_reconcileProjections);

    final updated = await _readSchedule(localId);
    return Ok(updated ?? local);
  }

  // ── update ─────────────────────────────────────────────────────────────────

  @override
  Future<Result<Schedule>> update(
    String localId, {
    required int hour,
    required int minute,
    required String frequency,
    List<int>? frequencyDays,
    required bool isActive,
  }) async {
    final existing = await _readSchedule(localId);
    if (existing == null) return const Err(NotFoundError());

    final pill = await _readPill(existing.pillId);
    if (pill == null) return const Err(NotFoundError());
    final profile = await _readProfile(pill.profileId);
    if (profile == null) return const Err(NotFoundError());

    final now = DateTime.now();
    final timeZone = tz.local.name;
    final companion = SchedulesCompanion(
      id: Value(localId),
      pillId: Value(existing.pillId),
      hour: Value(hour),
      minute: Value(minute),
      frequency: Value(frequency),
      timeZone: Value(timeZone),
      timeZoneStatus: const Value('known'),
      frequencyDays: Value(
        frequencyDays != null ? jsonEncode(frequencyDays) : null,
      ),
      isActive: Value(isActive),
      createdAt: Value(existing.createdAt),
      updatedAt: Value(now),
      serverId: Value(existing.serverId),
      revision: Value(existing.revision),
      syncStatus: const Value('pending'),
      lastSyncAt: Value(existing.lastSyncAt),
      isDeleted: Value(existing.isDeleted),
    );

    await _pendingOperations.record(
      operation: PendingOperationDraft(
        userId: profile.userId,
        operationType: 'schedule.update',
        entityType: 'schedule',
        entityLocalId: localId,
        parentEntityType: 'pill',
        parentEntityLocalId: existing.pillId,
        payload: {
          'action': 'update',
          'data': {
            'hour': hour,
            'minute': minute,
            'frequency': frequency,
            'frequencyDays': frequencyDays,
            'isActive': isActive,
            'timeZone': timeZone,
          },
        },
      ),
      applyProjection: () async {
        await _requireUnchangedSchedule(existing);
        await _requireUnchangedParents(pill, profile);
        await _schedulesDao.update_(companion);
        await _projectOccurrences(
          userId: profile.userId,
          scheduleId: localId,
          scheduleRevision: existing.revision + 1,
          pill: pill,
          profileName: profile.name,
          hour: hour,
          minute: minute,
          frequency: frequency,
          frequencyDays: frequencyDays,
          isActive: isActive,
          timeZone: timeZone,
          now: now,
        );
      },
    );
    await _effects(_reconcileProjections);

    final result = await _readSchedule(localId);
    return Ok(result!);
  }

  // ── delete ─────────────────────────────────────────────────────────────────

  @override
  Future<Result<void>> delete(String localId) async {
    final existing = await _readSchedule(localId);
    if (existing == null) return const Ok(null);

    final pill = await _readPill(existing.pillId);
    if (pill == null) return const Err(NotFoundError());
    final profile = await _readProfile(pill.profileId);
    if (profile == null) return const Err(NotFoundError());
    final now = DateTime.now();
    await _pendingOperations.record(
      operation: PendingOperationDraft(
        userId: profile.userId,
        operationType: 'schedule.delete',
        entityType: 'schedule',
        entityLocalId: localId,
        parentEntityType: 'pill',
        parentEntityLocalId: existing.pillId,
        payload: {'action': 'delete', 'data': <String, Object?>{}},
      ),
      applyProjection: () async {
        await _requireUnchangedSchedule(existing);
        await _schedulesDao.softDelete(localId);
        await _supersedeFutureOccurrences(
          userId: profile.userId,
          scheduleId: localId,
          now: now,
        );
      },
    );

    await _effects(_reconcileProjections);

    return const Ok(null);
  }

  /// Repairs a server-quarantined schedule through the revisioned endpoint.
  /// The local issue is deliberately untouched; only its later account-sync
  /// revision 2 is allowed to remove the review card.
  @override
  Future<Result<Schedule>> repair({
    required String localId,
    required String issueId,
    required int expectedIssueRevision,
    required int hour,
    required int minute,
    required String frequency,
    required List<int>? frequencyDays,
    required bool isActive,
    required DateTime effectiveFromLocalDate,
    required String timeZone,
  }) async {
    final issue = await _readIssue(issueId);
    final schedule = await _readSchedule(localId);
    if (issue == null ||
        issue.serverId != issue.id ||
        issue.resolutionState != 'unresolved' ||
        issue.revision != expectedIssueRevision ||
        !const {'schedule', 'schedules'}.contains(issue.entityType) ||
        !const {
          'invalid_schedule_frequency_days',
          'schedule_timezone_review_required',
        }.contains(issue.issueCode) ||
        schedule == null ||
        issue.entityId != schedule.id && issue.entityId != schedule.serverId ||
        schedule.revision != 1 ||
        expectedIssueRevision != 1 ||
        schedule.isDeleted) {
      return const Err(ConflictError());
    }
    final pill = await _readPill(schedule.pillId);
    if (pill == null || pill.syncStatus != 'synced') {
      return const Err(NotFoundError());
    }
    final profile = await _readProfile(pill.profileId);
    if (profile == null || profile.userId != issue.userId) {
      return const Err(NotFoundError());
    }
    final scheduleId = schedule.serverId ?? schedule.id;
    final pillId = pill.serverId ?? pill.id;
    final date = effectiveFromLocalDate.toIso8601String().substring(0, 10);
    if (timeZone.trim().isEmpty || timeZone.length > 128) {
      return const Err(UnknownError('Invalid schedule time zone'));
    }
    final document = <String, Object?>{
      'hour': hour,
      'minute': minute,
      'frequency': frequency,
      'frequencyDays': frequencyDays,
      'isActive': isActive,
      'timeZone': timeZone,
    };
    if (!ScheduleRepairIntent.validDocument(document)) {
      return const Err(ConflictError());
    }
    try {
      tz.getLocation(timeZone);
      final db = _schedulesDao.attachedDatabase;
      final operationId = await _pendingOperations.withCareGrant(() async {
        await _requireUnchangedSchedule(schedule);
        await _requireUnchangedParents(pill, profile);
        if (await _readIssue(issueId) != issue) {
          throw const WorkspaceAccessFailure(
            WorkspaceAccessFailureCode.unavailable,
          );
        }
        final operations = await db.pendingOperationsDao.getForUser(
          profile.userId,
        );
        final target = <PendingOperation>[];
        for (final operation in operations) {
          final payload = jsonDecode(operation.payloadJson);
          if (payload is Map &&
              payload['entityType'] == 'schedule' &&
              payload['entityLocalId'] == localId) {
            target.add(operation);
          }
        }
        // Once reviewed, the frozen request is the retry authority. A second
        // review cannot silently replace an in-flight or accepted request.
        for (final operation in target.where(
          (op) => op.operationType == 'schedule.repair',
        )) {
          final intent = ScheduleRepairIntent.fromOperation(operation);
          final payload = jsonDecode(operation.payloadJson) as Map;
          final envelope = payload['reviewedRepair'] as Map;
          if (envelope['issueId'] != issueId) continue;
          if (intent == null ||
              intent.pillId != pillId ||
              intent.scheduleId != scheduleId ||
              intent.request['effectiveFromLocalDate'] != date ||
              !const DeepCollectionEquality().equals(
                intent.request['schedule'],
                document,
              )) {
            throw const FormatException('Reviewed repair changed');
          }
          return operation.id;
        }
        final rejected = await rejectedScheduleUpdateForReview(
          db,
          schedule,
          profile.userId,
        );
        final open = target
            .where((op) => op.state != 'committed' && op.state != 'discarded')
            .toList();
        if (rejected == null &&
            (schedule.syncStatus != 'synced' || open.isNotEmpty)) {
          throw const FormatException('Schedule has unresolved intent');
        }
        final mutationId =
            rejected?.mutationId ??
            projectionCommandIdForKey(
              jsonEncode({
                'kind': 'schedule-repair-v2',
                'issueId': issueId,
                'issueRevision': expectedIssueRevision,
                'scheduleId': scheduleId,
                'effectiveFromLocalDate': date,
                'schedule': document,
              }),
            );
        final repair = <String, Object?>{
          'version': 1,
          'pillServerId': pillId,
          'scheduleServerId': scheduleId,
          'issueId': issueId,
          'issueRevision': expectedIssueRevision,
          'request': {
            'mutationId': mutationId,
            'baseRevision': '1',
            'effectiveFromLocalDate': date,
            'schedule': document,
          },
          if (rejected != null)
            'originalOperation': {
              'payloadJson': rejected.payloadJson,
              'operationType': rejected.operationType,
              'state': rejected.state,
              'safeErrorCode': rejected.safeErrorCode,
              'safeCorrelationId': rejected.safeCorrelationId,
              'attemptCount': rejected.attemptCount,
              'lastAttemptAt': rejected.lastAttemptAt?.toIso8601String(),
            },
        };
        if (rejected != null) {
          // The server rejected this exact mutation before writing a receipt.
          // Keep its identity/dependencies and archive all original evidence.
          await (db.update(
            db.pendingOperations,
          )..where((row) => row.id.equals(rejected.id))).write(
            PendingOperationsCompanion(
              operationType: const Value('schedule.repair'),
              state: const Value('queued'),
              safeErrorCode: const Value(null),
              safeCorrelationId: const Value(null),
              payloadJson: Value(
                jsonEncode({
                  'entityType': 'schedule',
                  'entityLocalId': localId,
                  'parentEntityType': 'pill',
                  'parentEntityLocalId': schedule.pillId,
                  'action': 'repair',
                  'reviewedRepair': repair,
                }),
              ),
            ),
          );
          return rejected.id;
        }
        return (await _pendingOperations.record(
          operation: PendingOperationDraft(
            userId: profile.userId,
            operationType: 'schedule.repair',
            entityType: 'schedule',
            entityLocalId: localId,
            parentEntityType: 'pill',
            parentEntityLocalId: schedule.pillId,
            mutationId: mutationId,
            payload: {'action': 'repair', 'reviewedRepair': repair},
          ),
          applyProjection: () async {},
        )).operationId;
      });
      final access = _pendingOperations.access;
      final scope = access == null
          ? null
          : SyncWriteScope(
              access: access,
              capability: await access.currentNetworkCapability(),
            );
      if (scope != null &&
          await scope.captureContext() != _pendingOperations.context) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.staleGrant,
        );
      }
      await SchedulesSyncAdapter(db).flush(
        profile.userId,
        V2StableAdapter(db: db, dio: _dio, writeScope: scope),
        onlyOperationId: operationId,
      );
      return await _pendingOperations.withCareGrant(() async {
        final operation = await db.pendingOperationsDao.getById(operationId);
        if (operation?.state == 'committed') return Ok(schedule);
        if (operation?.state == 'failedRetryable' ||
            operation?.state == 'queued' ||
            operation?.state == 'sending') {
          return const Err<Schedule>(
            NetworkError('Schedule repair awaiting confirmation'),
          );
        }
        return const Err<Schedule>(ConflictError());
      });
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        return const Err(UnauthorizedError());
      }
      return const Err(NetworkError('Schedule repair awaiting confirmation'));
    } on WorkspaceAccessFailure {
      rethrow;
    } on FormatException {
      return const Err(ConflictError());
    } catch (error) {
      return Err(UnknownError(error.runtimeType));
    }
  }

  Future<void> _projectOccurrences({
    required String userId,
    required String scheduleId,
    required int scheduleRevision,
    required Pill pill,
    required String profileName,
    required int hour,
    required int minute,
    required String frequency,
    required List<int>? frequencyDays,
    required bool isActive,
    required String timeZone,
    required DateTime now,
  }) async {
    final zoneNow = tz.TZDateTime.from(now, tz.getLocation(timeZone));
    final today = DateTime.utc(zoneNow.year, zoneNow.month, zoneNow.day);
    final through = DateTime.utc(today.year, today.month, today.day + 30);
    // Keys share the server's schedule identity once mapped. Stored links stay
    // local, and existing recorded occurrences retain their original keys.
    final schedule = await _schedulesDao.getById(scheduleId);
    final source = ScheduledOccurrenceSource(
      userId: userId,
      id: schedule?.serverId ?? scheduleId,
      scheduleRevision: scheduleRevision.toString(),
      pillId: pill.id,
      pillName: pill.name,
      dosage: pill.dosage,
      frequency: frequency,
      frequencyDays: frequencyDays,
      hour: hour,
      minute: minute,
      timeZone: timeZone,
      profileId: pill.profileId,
      profileName: profileName,
      isActive: isActive,
    );
    final materialized = OccurrenceMaterializer().materialize(
      source: source,
      fromLocalDate: _localDateKey(today),
      throughLocalDate: _localDateKey(through),
    );
    final nowUtc = now.toUtc();
    final replacementIdsByDate = <String, String>{};
    for (final item in materialized) {
      final existing = await _ledgerDao.getOccurrenceByKey(
        userId,
        item.occurrenceKey,
      );
      final occurrenceId = existing?.id ?? _uuid.v4();
      replacementIdsByDate[item.plannedLocalDate] = occurrenceId;
      if (existing != null) continue;
      await _ledgerDao.upsertOccurrence(
        MedicationOccurrencesCompanion.insert(
          id: occurrenceId,
          userId: userId,
          pillId: Value(pill.id),
          scheduleId: Value(scheduleId),
          occurrenceKey: item.occurrenceKey,
          source: 'scheduled',
          scheduleRevision: Value(scheduleRevision),
          plannedLocalDate: item.plannedLocalDate,
          plannedLocalTime: Value(item.plannedLocalTime),
          timeZone: item.timeZone,
          plannedAt: Value(item.plannedAt),
          expected: const Value(true),
          snapshotVersion: const Value(1),
          scheduleSnapshotJson: jsonEncode(item.scheduleSnapshot.toJson()),
          provenance: 'exact',
          state: const Value('pending'),
          stateVersion: const Value(0),
          serverSequence: const Value(null),
          supersededAt: const Value(null),
          supersededByOccurrenceId: const Value(null),
          createdAt: nowUtc,
          updatedAt: nowUtc,
        ),
      );
    }

    await _supersedeFutureOccurrences(
      userId: userId,
      scheduleId: scheduleId,
      now: now,
      replacementIdsByDate: replacementIdsByDate,
    );
  }

  Future<void> _supersedeFutureOccurrences({
    required String userId,
    required String scheduleId,
    required DateTime now,
    Map<String, String>? replacementIdsByDate,
  }) async {
    final nowUtc = now.toUtc();
    final materializer = OccurrenceMaterializer();
    for (final occurrence in await _ledgerDao.getOccurrencesForSchedule(
      scheduleId,
    )) {
      if (occurrence.userId != userId || occurrence.supersededAt != null) {
        continue;
      }
      final replacementId = replacementIdsByDate?[occurrence.plannedLocalDate];
      if (replacementId == occurrence.id) continue;
      final plannedAt = occurrence.plannedAt;
      if (plannedAt == null) continue;
      final events = await _ledgerDao.getEventsForOccurrence(occurrence.id);
      if (!materializer.canSupersede(
        plannedAt: plannedAt,
        stateVersion: occurrence.stateVersion,
        hasOccurrenceEvent: events.isNotEmpty,
        now: now,
      )) {
        continue;
      }
      await _ledgerDao.supersedeOccurrence(
        id: occurrence.id,
        supersededAt: nowUtc,
        supersededByOccurrenceId: replacementId,
      );
    }
  }

  String _localDateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
