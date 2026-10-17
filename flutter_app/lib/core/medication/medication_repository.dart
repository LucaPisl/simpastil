import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:uuid/uuid.dart';

import '../db/daos/medication_ledger_dao.dart';
import '../db/database.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import '../sync/held_stock.dart' show isPendingFolded;
import '../sync/pending_operation_repository.dart';
import '../notifications/reminder_preferences.dart';
import '../projections/projection_command_id.dart';
import '../projections/projection_identity.dart';
import '../storage/recorded_by_preference.dart';
import '../utils/app_logger.dart';
import 'auto_miss_discard.dart';
import 'medication_command.dart';
import 'occurrence_reducer.dart';
import 'local_occurrence_snapshot.dart';
import 'medication_amount.dart';
import 'reviewed_stock.dart';

class MedicationCommandBlocked implements Exception {
  const MedicationCommandBlocked(this.code);

  final String code;

  @override
  String toString() => 'Medication command blocked: $code';
}

typedef MedicationStockChanged = Future<void> Function(Pill pill);

/// Records medication intent, its legacy split checkpoints, and optimistic
/// ledger projections as one local transaction.
class MedicationRepository {
  MedicationRepository(
    this._db, {
    MedicationStockChanged? onStockChanged,
    WorkspaceAccessRepository? access,
    WorkspaceContext? context,
  }) : _pendingOperations = PendingOperationRepository(
         _db,
         access: access,
         context: context,
       ),
       _access = access,
       _context = context,
       _onStockChanged = onStockChanged {
    if ((access == null) != (context == null)) {
      throw ArgumentError('Access and context must be captured together');
    }
  }

  final WorkspaceAccessRepository? _access;
  final WorkspaceContext? _context;
  void _requireOwner(String owner) {
    if (_context != null && _context.ownerUserId != owner) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
  }

  Future<T> _guarded<T>(Future<T> Function() action) => _context == null
      ? _db.transaction(action)
      : _access!.withGrant(_context, action);

  /// Validates a delivered reminder for review without recording care or
  /// changing stock. Platform payloads are hints; the protected occurrence,
  /// its parents, reminder choices and workspace grant remain authoritative.
  Future<bool> isCurrentReminderActionForReview({
    required String occurrenceId,
    required String projectionId,
    required String kind,
    required int deliveredStateVersion,
  }) => _isCurrentProtectedProjectionForReview(
    occurrenceId: occurrenceId,
    projectionId: projectionId,
    kind: kind,
    deliveredStateVersion: deliveredStateVersion,
    requireReminderPreferences: true,
  );

  /// Validates a protected widget action for review without applying its
  /// Take/Skip verb. Widget eligibility follows widget publication choices,
  /// not notification-only schedule and full-details preferences.
  Future<bool> isCurrentWidgetActionForReview({
    required String occurrenceId,
    required String projectionId,
    required int deliveredStateVersion,
  }) => _isCurrentProtectedProjectionForReview(
    occurrenceId: occurrenceId,
    projectionId: projectionId,
    kind: 'widget',
    deliveredStateVersion: deliveredStateVersion,
    requireReminderPreferences: false,
  );

  Future<bool> _isCurrentProtectedProjectionForReview({
    required String occurrenceId,
    required String projectionId,
    required String kind,
    required int deliveredStateVersion,
    required bool requireReminderPreferences,
  }) async {
    final context = _context;
    if (context == null ||
        deliveredStateVersion < 0 ||
        (kind != 'widget' &&
            !const {'reminder', 'snooze'}.contains(kind) &&
            !isFollowUpReminderKind(kind))) {
      return false;
    }
    final identity = ProjectionIdentity.fromContext(context);
    final expectedProjectionId = reminderProjectionId(
      userId: identity.ownerId,
      sessionGeneration: identity.grantEpoch,
      occurrenceId: occurrenceId,
      kind: kind,
      workspaceId: identity.workspaceId,
      grantEpoch: identity.grantEpoch,
      stateVersion: deliveredStateVersion,
    );
    if (expectedProjectionId != projectionId) return false;

    return _guarded(() async {
      final occurrence = await _db.medicationLedgerDao.getOccurrenceById(
        occurrenceId,
      );
      if (occurrence == null ||
          occurrence.userId != context.ownerUserId ||
          occurrence.source != 'scheduled' ||
          !occurrence.expected ||
          occurrence.provenance != 'exact' ||
          occurrence.state != 'pending' ||
          occurrence.stateVersion != deliveredStateVersion ||
          occurrence.supersededAt != null ||
          occurrence.pillId == null ||
          occurrence.scheduleId == null) {
        return false;
      }

      final pill = await _db.pillsDao.getById(occurrence.pillId!);
      final schedule = await _db.schedulesDao.getById(occurrence.scheduleId!);
      if (pill == null ||
          schedule == null ||
          schedule.pillId != pill.id ||
          pill.isDeleted ||
          pill.isPrn ||
          schedule.isDeleted ||
          !schedule.isActive) {
        return false;
      }
      try {
        await _requireOccurrenceParents(occurrence);
      } on WorkspaceAccessFailure catch (error) {
        if (error.code == WorkspaceAccessFailureCode.wrongPerson) {
          return false;
        }
        rethrow;
      } on MedicationCommandBlocked {
        return false;
      }

      final person = await _db.profilesDao.getById(pill.profileId);
      if (person == null ||
          person.isDeleted ||
          person.userId != context.ownerUserId) {
        return false;
      }
      final personChoice = await (_db.select(
        _db.devicePersonReminders,
      )..where((row) => row.profileId.equals(person.id))).getSingleOrNull();
      if (personChoice?.enabled != true) return false;

      if (!requireReminderPreferences) return true;

      late final ReminderPreferences preferences;
      try {
        preferences = await ReminderPreferencesRepository(
          database: _db,
          access: _access!,
          context: context,
        ).load();
      } on FormatException {
        return false;
      }
      if (!preferences.fullDetails) return false;
      final scheduleChoice = preferences.choiceFor(schedule.id);
      if (!scheduleChoice.enabled) return false;
      if (isFollowUpReminderKind(kind)) {
        final minutes = int.tryParse(kind.split(':').last);
        if (minutes == null ||
            !scheduleChoice.followUpMinutes.contains(minutes)) {
          return false;
        }
      }
      return true;
    });
  }

  Future<void> _requireOccurrenceParents(
    MedicationOccurrence occurrence,
  ) async {
    final pillId = occurrence.pillId;
    final scheduleId = occurrence.scheduleId;
    final pill = pillId == null ? null : await _db.pillsDao.getById(pillId);
    final schedule = scheduleId == null
        ? null
        : await _db.schedulesDao.getById(scheduleId);
    if ((pillId != null && pill == null) ||
        (scheduleId != null &&
            (schedule == null || pill == null || schedule.pillId != pill.id))) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    if (pill != null) {
      final person = await _db.profilesDao.getById(pill.profileId);
      if (person == null || person.userId != occurrence.userId) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.wrongPerson,
        );
      }
      if (_context != null) {
        try {
          final snapshot = decodeScheduleSnapshot(
            jsonDecode(occurrence.scheduleSnapshotJson) as Map<String, dynamic>,
          );
          if (!snapshotOwns(
                snapshot,
                occurrence.userId,
                _context.workspaceId,
              ) ||
              snapshot.profileId != pill.profileId ||
              snapshot.timeZone != occurrence.timeZone) {
            throw const FormatException('Contradictory occurrence identity');
          }
        } on Object {
          throw const MedicationCommandBlocked('occurrence_identity_unproven');
        }
      }
    }
  }

  Future<void> _notifyCommittedStock(Pill? pill) async {
    if (pill == null || _onStockChanged == null) return;
    try {
      if (_context != null) await _access!.requireCurrent(_context);
      await _onStockChanged(pill);
    } on Object catch (error) {
      AppLogger.warning(
        'MedicationRepository',
        'Stock committed; notification unavailable: ${error.runtimeType}',
      );
    }
  }

  final AppDatabase _db;
  final PendingOperationRepository _pendingOperations;
  final MedicationStockChanged? _onStockChanged;
  static const _ids = Uuid();

  /// Resolves only a previously materialized, exact slot; this method never
  /// recreates schedule keys or local-time/DST rules.
  Future<MedicationOccurrence?> occurrenceForScheduleSlot({
    required String userId,
    required String scheduleId,
    required DateTime scheduledAt,
  }) => _guarded(() async {
    _requireOwner(userId);
    final rows =
        await (_db.select(_db.medicationOccurrences)..where(
              (row) =>
                  row.userId.equals(userId) &
                  row.scheduleId.equals(scheduleId) &
                  row.plannedAt.equals(scheduledAt.toUtc()) &
                  row.supersededAt.isNull(),
            ))
            .get();
    return rows.length == 1 ? rows.single : null;
  });

  Future<MedicationOccurrence?> uniquePendingPrnOccurrenceForDate({
    required String userId,
    required String scheduleId,
    required DateTime localDate,
  }) => _guarded(() async {
    _requireOwner(userId);
    final dateKey = _localDateKey(localDate);
    final rows =
        await (_db.select(_db.medicationOccurrences)..where(
              (row) =>
                  row.userId.equals(userId) &
                  row.scheduleId.equals(scheduleId) &
                  row.source.equals('prn') &
                  row.plannedLocalDate.equals(dateKey) &
                  row.state.equals('pending') &
                  row.supersededAt.isNull(),
            ))
            .get();
    return rows.length == 1 ? rows.single : null;
  });

  Future<MedicationCommand> apply({
    required String userId,
    required String occurrenceId,
    required MedicationAction action,
    DateTime? actualAt,
    required bool actualTimeKnown,
    String? note,
    String? commandIdOverride,
    MedicationState? intendedState,
    String? reversesEventId,
    String? rebasesCommandId,
    MedicationAmount amount = const MedicationAmount.unknown(),
    int? expectedStateVersion,
    String? expectedPersonId,
  }) async {
    _requireOwner(userId);
    Pill? changedStock;
    final command = await _guarded(
      () => _applyInTransaction(
        userId: userId,
        occurrenceId: occurrenceId,
        action: action,
        actualAt: actualAt,
        actualTimeKnown: actualTimeKnown,
        note: note,
        commandIdOverride: commandIdOverride,
        intendedState: intendedState,
        reversesEventId: reversesEventId,
        rebasesCommandId: rebasesCommandId,
        amount: amount,
        expectedStateVersion: expectedStateVersion,
        expectedPersonId: expectedPersonId,
        stockCommitted: (pill) => changedStock = pill,
      ),
    );
    await _notifyCommittedStock(changedStock);
    return command;
  }

  /// Native taps carry display hints. Their full grant, current person reminder
  /// choice and exact occurrence parents are checked together with publication.
  Future<MedicationCommand> applyDeviceAction({
    required String occurrenceId,
    required String projectionId,
    required String kind,
    required MedicationAction action,
    DateTime? now,
    int? deliveredStateVersion,
  }) async {
    final context = _context;
    if (context == null ||
        deliveredStateVersion == null ||
        deliveredStateVersion < 0 ||
        (!const {'widget', 'reminder', 'snooze'}.contains(kind) &&
            !isFollowUpReminderKind(kind)) ||
        !const {
          MedicationAction.take,
          MedicationAction.skip,
        }.contains(action)) {
      throw const MedicationCommandBlocked('device_action_unproven');
    }
    final identity = ProjectionIdentity.fromContext(context);
    final expected = reminderProjectionId(
      userId: identity.ownerId,
      sessionGeneration: identity.grantEpoch,
      occurrenceId: occurrenceId,
      kind: kind,
      workspaceId: identity.workspaceId,
      grantEpoch: identity.grantEpoch,
      stateVersion: deliveredStateVersion,
    );
    if (expected != projectionId) {
      throw const MedicationCommandBlocked('device_projection_unproven');
    }
    Pill? changedStock;
    final command = await _guarded(() async {
      final occurrence = await _db.medicationLedgerDao.getOccurrenceById(
        occurrenceId,
      );
      if (occurrence == null ||
          occurrence.userId != context.ownerUserId ||
          occurrence.source != 'scheduled' ||
          !occurrence.expected ||
          occurrence.provenance != 'exact' ||
          occurrence.supersededAt != null ||
          occurrence.pillId == null ||
          occurrence.scheduleId == null) {
        throw const MedicationCommandBlocked('device_occurrence_unavailable');
      }
      await _requireOccurrenceParents(occurrence);
      final pill = (await _db.pillsDao.getById(occurrence.pillId!))!;
      final person = (await _db.profilesDao.getById(pill.profileId))!;
      final schedule = (await _db.schedulesDao.getById(
        occurrence.scheduleId!,
      ))!;
      final reminders = await (_db.select(
        _db.devicePersonReminders,
      )..where((row) => row.profileId.equals(person.id))).getSingleOrNull();
      if (person.isDeleted ||
          pill.isDeleted ||
          pill.isPrn ||
          schedule.isDeleted ||
          !schedule.isActive ||
          reminders?.enabled != true) {
        throw const MedicationCommandBlocked('device_occurrence_unavailable');
      }
      final deviceChoice =
          await (_db.select(_db.deviceScheduleReminders)..where(
                (row) =>
                    row.workspaceId.equals(context.workspaceId) &
                    row.scheduleId.equals(schedule.id),
              ))
              .getSingleOrNull();
      if ((kind != 'widget' && deviceChoice?.enabled == false) ||
          (isFollowUpReminderKind(kind) &&
              !List<int>.from(
                jsonDecode(deviceChoice?.followUpMinutesJson ?? '[]') as List,
              ).contains(int.parse(kind.split(':').last)))) {
        throw const MedicationCommandBlocked('device_occurrence_unavailable');
      }
      final commandId = kind == 'widget'
          ? widgetActionCommandId(
              projectionId: projectionId,
              occurrenceId: occurrenceId,
              action: action.name,
            )
          : notificationActionCommandId(
              projectionId: projectionId,
              occurrenceId: occurrenceId,
              action: action.name,
              stateVersion: deliveredStateVersion,
            );
      final prior = await _db.pendingOperationsDao.getByMutationId(
        context.ownerUserId,
        commandId,
      );
      final localReceipt =
          await (_db.select(_db.careEventDetails)..where(
                (d) =>
                    d.workspaceId.equals(context.workspaceId) &
                    d.commandId.equals(commandId),
              ))
              .getSingleOrNull();
      if (prior == null &&
          localReceipt == null &&
          (occurrence.state != 'pending' ||
              occurrence.stateVersion != deliveredStateVersion)) {
        throw const MedicationCommandBlocked('device_occurrence_unavailable');
      }
      final actualAt = action == MedicationAction.take
          ? (now ?? DateTime.now())
          : null;
      return _applyInTransaction(
        userId: context.ownerUserId,
        occurrenceId: occurrenceId,
        action: action,
        actualAt: actualAt,
        actualTimeKnown: actualAt != null,
        commandIdOverride: commandId,
        allowReplayTimingDrift: true,
        stockCommitted: (pill) => changedStock = pill,
      );
    });
    await _notifyCommittedStock(changedStock);
    return command;
  }

  Future<MedicationCommand> _applyInTransaction({
    required String userId,
    required String occurrenceId,
    required MedicationAction action,
    DateTime? actualAt,
    required bool actualTimeKnown,
    String? note,
    String? commandIdOverride,
    MedicationState? intendedState,
    String? reversesEventId,
    String? rebasesCommandId,
    MedicationAmount amount = const MedicationAmount.unknown(),
    int? expectedStateVersion,
    String? expectedPersonId,
    bool allowReplayTimingDrift = false,
    required void Function(Pill) stockCommitted,
  }) async {
    if (actualTimeKnown != (actualAt != null)) {
      throw ArgumentError('actualTimeKnown must match actualAt presence');
    }
    if (note != null && note.length > 500) {
      throw ArgumentError.value(note, 'note', 'must be at most 500 characters');
    }
    final identity = ProjectionCommandIdentity(
      userId: userId,
      occurrenceId: occurrenceId,
      action: action.name,
      actualAt: actualAt?.toUtc().toIso8601String(),
      note: note,
    );
    final commandId = commandIdOverride ?? projectionCommandId(identity);

    final requestFingerprint = _fingerprint({
      'owner': userId,
      'occurrenceId': occurrenceId,
      'action': action.name,
      'targetState': intendedState?.name,
      'actualAt': actualAt?.toUtc().toIso8601String(),
      'actualTimeKnown': actualTimeKnown,
      'note': note,
      'reversesEventId': reversesEventId,
      'rebasesCommandId': rebasesCommandId,
      'amount': amount.toJson(),
      'expectedStateVersion': expectedStateVersion,
      'expectedPersonId': expectedPersonId,
    });
    final context = _context;
    if (context != null) {
      final receipt =
          await (_db.select(_db.careEventDetails)..where(
                (r) =>
                    r.workspaceId.equals(context.workspaceId) &
                    r.commandId.equals(commandId),
              ))
              .getSingleOrNull();
      if (receipt != null) {
        final recorded = _commandFromOperation(receipt.commandJson);
        final row = await _db.medicationLedgerDao.getOccurrenceById(
          recorded.occurrenceId,
        );
        if (recorded.userId != userId ||
            recorded.occurrenceId != occurrenceId ||
            row == null) {
          throw const MedicationCommandBlocked('command_identity_unproven');
        }
        await _requireOccurrenceParents(row);
        if (expectedPersonId != null) {
          await _access!.requireCurrent(context, profileId: expectedPersonId);
        }
        if (!allowReplayTimingDrift &&
            receipt.requestFingerprint != requestFingerprint) {
          throw const MedicationCommandBlocked('command_intent_changed');
        }
        return recorded;
      }
    }

    // A callback replay returns the exact durable command before consulting a
    // newer projection head; it cannot turn a retry into a second correction.
    final prior = await _db.pendingOperationsDao.getByMutationId(
      userId,
      commandId,
    );
    if (prior != null) {
      final replay = _commandFromOperation(prior.payloadJson);
      if (replay.userId != userId || replay.occurrenceId != occurrenceId) {
        throw const MedicationCommandBlocked('command_identity_unproven');
      }
      return replay;
    }

    final loaded = await _db.medicationLedgerDao.getOccurrenceById(
      occurrenceId,
    );
    if (loaded == null || loaded.userId != userId) {
      throw const MedicationCommandBlocked('occurrence_missing');
    }
    var occurrence = loaded;
    await _requireOccurrenceParents(occurrence);
    if (expectedStateVersion != null &&
        occurrence.stateVersion != expectedStateVersion) {
      throw const MedicationCommandBlocked('occurrence_head_changed');
    }
    if (expectedPersonId != null) {
      final pill = occurrence.pillId == null
          ? null
          : await _db.pillsDao.getById(occurrence.pillId!);
      if (pill?.profileId != expectedPersonId) {
        throw const MedicationCommandBlocked('wrong_person');
      }
      if (context != null) {
        await _access!.requireCurrent(context, profileId: expectedPersonId);
      }
    }
    if (occurrence.supersededAt != null) {
      throw const MedicationCommandBlocked('occurrence_superseded');
    }
    if (occurrence.provenance != 'exact' || occurrence.occurrenceKey.isEmpty) {
      throw const MedicationCommandBlocked('occurrence_identity_unproven');
    }
    if (occurrence.source == 'scheduled' && occurrence.plannedAt == null) {
      throw const MedicationCommandBlocked('planned_instant_missing');
    }
    if (action == MedicationAction.miss) {
      // Only an expected, scheduled dose whose planned time has passed can be
      // recorded as missed; the server refuses every other occurrence too.
      final plannedAt = occurrence.plannedAt;
      if (occurrence.source != 'scheduled' ||
          !occurrence.expected ||
          plannedAt == null ||
          plannedAt.isAfter(DateTime.now())) {
        throw const MedicationCommandBlocked('miss_not_allowed');
      }
    }
    if (action == MedicationAction.take || action == MedicationAction.skip) {
      occurrence = await _withdrawUnsentAutoMiss(occurrence);
    }

    final fromState = _stateFromStorage(occurrence.state);
    final events = await _db.medicationLedgerDao.getEventsForOccurrence(
      occurrenceId,
    );
    final heads = headEventsAt(
      events,
      occurrence.stateVersion,
      discardedCommandIds: await _db.medicationLedgerDao.discardedCommandIds(
        occurrence.userId,
      ),
    );
    final currentEvent = heads.length == 1 ? heads.single : null;
    final reversesHead =
        reversesEventId != null &&
        (reversesEventId == currentEvent?.id ||
            reversesEventId == currentEvent?.serverId);
    final currentHead = currentEvent?.id;
    final localReversalId = reversesHead ? currentEvent!.id : reversesEventId;
    final rebased = rebaseMedicationIntent(
      serverState: fromState,
      intendedAction: action,
      intendedState: intendedState,
      reversesEventId:
          action == MedicationAction.correct && expectedStateVersion != null
          ? currentHead
          : localReversalId,
      headEventId: currentHead,
      isSuperseded: occurrence.supersededAt != null,
      identityMatches:
          occurrence.userId == userId && occurrence.occurrenceKey.isNotEmpty,
    );
    if (rebased.blocked || rebased.action == null || rebased.toState == null) {
      throw MedicationCommandBlocked(rebased.reason ?? 'rebase_blocked');
    }

    final command = MedicationCommand(
      commandId: commandId,
      userId: userId,
      occurrenceId: occurrence.id,
      occurrenceKey: occurrence.occurrenceKey,
      action: rebased.action!,
      targetState:
          rebased.action == MedicationAction.correct ||
              rebased.action == MedicationAction.undo
          ? rebased.toState
          : null,
      reversesEventId: reversesEventId,
      rebasesCommandId: rebasesCommandId,
      actualAt: actualAt,
      actualTimeKnown: actualTimeKnown,
      note: note,
      baseVersion: occurrence.stateVersion,
    );
    final now = DateTime.now().toUtc();
    final eventId = _ids.v4();
    final pillId = occurrence.pillId;
    final pill = pillId == null ? null : await _db.pillsDao.getById(pillId);
    final existingDoseLog =
        occurrence.scheduleId == null || occurrence.plannedAt == null
        ? null
        : await _db.doseLogsDao.getByScheduledSlot(
            occurrence.scheduleId!,
            occurrence.plannedAt!,
          );
    final schedule = occurrence.scheduleId == null
        ? null
        : await _db.schedulesDao.getById(occurrence.scheduleId!);
    final legacyDoseSourceId =
        existingDoseLog?.id ??
        projectionCommandIdForKey('legacy-dose-source-v1:$commandId');
    final hasTrackedStock =
        context?.isLocal != true &&
        occurrence.source != 'prn' &&
        pill?.currentStock != null;
    var inventoryDelta = hasTrackedStock ? rebased.inventoryDelta : 0;
    // A dose taken before the ledger was active was folded into the pill's
    // opening count and has no inventory event on the server, which applies
    // its undo as 0. The phone does the same, and says so.
    var stockUnchangedByUndo = false;
    if (action == MedicationAction.undo &&
        pill != null &&
        inventoryDelta != 0 &&
        await _reversesFoldedDose(
          occurrenceId: occurrence.id,
          pillId: pill.id,
          reversesEventId: reversesEventId!,
        )) {
      inventoryDelta = 0;
      stockUnchangedByUndo = true;
    }
    final reversesInventoryEventId =
        action == MedicationAction.undo && pill != null && inventoryDelta != 0
        ? await _reversedInventoryServerId(
            occurrenceId: occurrence.id,
            pillId: pill.id,
            reversesEventId: reversesEventId!,
          )
        : null;
    if (action == MedicationAction.undo &&
        hasTrackedStock &&
        inventoryDelta != 0 &&
        reversesInventoryEventId == null) {
      throw const MedicationCommandBlocked('inventory_reversal_not_mapped');
    }
    final nextStock = hasTrackedStock
        ? pill!.currentStock! + inventoryDelta
        : null;
    final payload = <String, Object?>{
      'userId': userId,
      'command': command.toWire(),
      'eventId': eventId,
      'administrationAmount': amount.toJson(),
      'intent': {
        'action': action.name,
        if (intendedState != null) 'targetState': intendedState.name,
        'actualAt': actualAt?.toUtc().toIso8601String(),
        'actualTimeKnown': actualTimeKnown,
        'note': note,
        // Client-only: a miss is written by the app, not chosen by a person.
        // The sync adapter drops a refused automatic miss silently instead of
        // raising a review item. It is never part of the wire command.
        if (action == MedicationAction.miss) 'origin': autoMissOrigin,
      },
      'localProjection': {
        'fromState': fromState.name,
        'toState': rebased.toState!.name,
        'inventoryDelta': inventoryDelta,
        'pillId': pillId,
        'observedStock': pill?.currentStock,
        'resultingStock': nextStock,
        'legacyDoseSourceId': legacyDoseSourceId,
        'observedBaseStock': pill?.serverId == null ? null : pill?.currentStock,
        'observedBasePillRevision':
            pill?.serverId == null || pill?.currentStock == null
            ? null
            : pill?.revision.toString(),
        'observedBaseDoseFingerprint':
            existingDoseLog == null ||
                existingDoseLog.isDeleted ||
                existingDoseLog.serverId == null ||
                schedule?.serverId == null
            ? null
            : _legacyDoseFingerprint(
                existingDoseLog,
                serverScheduleId: schedule!.serverId!,
                serverDoseId: existingDoseLog.serverId ?? existingDoseLog.id,
              ),
      },
    };
    final doseFingerprint = _fingerprint({
      'kind': 'dose',
      'command': command.toWire(),
      'scheduleId': occurrence.scheduleId,
      'plannedAt': occurrence.plannedAt?.toUtc().toIso8601String(),
    });
    final effects = <PendingOperationEffectDraft>[
      PendingOperationEffectDraft(
        kind: 'dose',
        legacySourceId: legacyDoseSourceId,
        requestFingerprint: doseFingerprint,
      ),
      if (hasTrackedStock && inventoryDelta != 0)
        PendingOperationEffectDraft(
          kind: 'inventory',
          legacySourceId: pillId,
          requestFingerprint: _fingerprint({
            'kind': 'inventory',
            'pillId': pillId,
            'observedStock': pill!.currentStock,
            'resultingStock': nextStock,
            'delta': inventoryDelta,
            'commandId': commandId,
          }),
        ),
    ];

    final originalOperation =
        action == MedicationAction.undo && currentEvent != null
        ? await _db.pendingOperationsDao.getByMutationId(
            userId,
            currentEvent.commandId,
          )
        : null;
    final operation = PendingOperationDraft(
      userId: userId,
      mutationId: commandId,
      component: 'medication',
      contractVersion: 2,
      operationType: 'medication.command',
      entityType: 'occurrence',
      entityLocalId: occurrence.id,
      payload: payload,
      effects: effects,
      dependsOnOperationId: originalOperation?.id,
    );
    Future<void> applyProjection() async {
      await _db.medicationLedgerDao.appendOccurrenceEvent(
        OccurrenceEventsCompanion.insert(
          id: eventId,
          userId: userId,
          occurrenceId: occurrence.id,
          commandId: commandId,
          action: command.action.name,
          fromState: fromState.name,
          toState: rebased.toState!.name,
          reversesEventId: Value(reversesEventId),
          rebasesCommandId: Value(rebasesCommandId),
          actualAt: Value(actualAt?.toUtc()),
          actualTimeKnown: Value(actualTimeKnown),
          note: Value(note),
          administrationAmountJson: Value(
            occurrence.source == 'prn' &&
                    command.action == MedicationAction.take
                ? jsonEncode(amount.toJson())
                : null,
          ),
          origin: 'native',
          baseVersion: occurrence.stateVersion,
          resultVersion: occurrence.stateVersion + 1,
          recordedAt: now,
        ),
      );
      await (_db.update(
        _db.medicationOccurrences,
      )..where((row) => row.id.equals(occurrence.id))).write(
        MedicationOccurrencesCompanion(
          state: Value(rebased.toState!.name),
          stateVersion: Value(occurrence.stateVersion + 1),
          updatedAt: Value(now),
        ),
      );
      if (pill != null && nextStock != null && inventoryDelta != 0) {
        await _db.medicationLedgerDao.appendInventoryEvent(
          InventoryEventsCompanion.insert(
            id: _ids.v4(),
            userId: userId,
            pillId: pill.id,
            commandId: commandId,
            kind: switch (command.action) {
              MedicationAction.undo => 'dose_reversal',
              MedicationAction.correct => 'correction',
              _ => 'dose',
            },
            delta: inventoryDelta,
            occurrenceEventId: Value(eventId),
            reversesInventoryEventId: Value(reversesInventoryEventId),
            origin: 'native',
            provenanceJson: Value(
              jsonEncode({
                'occurrenceId': occurrence.id,
                'occurrenceKey': occurrence.occurrenceKey,
              }),
            ),
            recordedAt: now,
          ),
        );
        await (_db.update(
          _db.pills,
        )..where((row) => row.id.equals(pill.id))).write(
          PillsCompanion(
            currentStock: Value(nextStock),
            syncStatus: Value(pill.syncStatus),
            updatedAt: Value(now),
          ),
        );
      }
      if (context != null) {
        CareStockOutcome stockOutcome = !hasTrackedStock
            ? CareStockOutcome.notTracked
            : stockUnchangedByUndo
            ? CareStockOutcome.unchanged
            : CareStockOutcome.applied;
        String? stockEffect;
        if (context.isLocal && pill != null) {
          final headDetails = currentEvent == null
              ? null
              : await (_db.select(_db.careEventDetails)..where(
                      (d) =>
                          d.eventId.equals(currentEvent.id) &
                          d.workspaceId.equals(context.workspaceId),
                    ))
                    .getSingleOrNull();
          final stock = await commitReviewedStockEffect(
            db: _db,
            context: context,
            pill: pill,
            action: command.action.name,
            fromState: fromState.name,
            toState: rebased.toState!.name,
            amount: amount,
            headDetails: headDetails,
          );
          stockOutcome = stock.outcome;
          stockEffect = stock.effectJson;
        }
        final author = await (_db.select(
          _db.workspaceAuthors,
        )..where((a) => a.id.equals(context.authorId))).getSingle();
        await _db
            .into(_db.careEventDetails)
            .insert(
              CareEventDetailsCompanion.insert(
                eventId: eventId,
                workspaceId: context.workspaceId,
                commandId: commandId,
                authorId: context.authorId,
                // The app, not a person, marks a dose missed, so no name is
                // stamped on it.
                authorName: Value(
                  action == MedicationAction.miss
                      ? null
                      : await resolveRecordedByName(
                          db: _db,
                          context: context,
                          patientProfileId: pill?.profileId,
                          authorDisplayName: author.displayName,
                        ),
                ),
                amountJson: jsonEncode(amount.toJson()),
                commandJson: jsonEncode({
                  'userId': userId,
                  'command': command.toWire(),
                }),
                requestFingerprint: requestFingerprint,
                localReversalEventId: Value(
                  action == MedicationAction.undo ? localReversalId : null,
                ),
                stockOutcome: stockOutcome.name,
                stockEffectJson: Value(stockEffect),
              ),
            );
      }
      await _writeDoseLogProjection(
        occurrence: occurrence,
        toState: rebased.toState!,
        actualAt: actualAt,
        actualTimeKnown: actualTimeKnown,
        note: note,
        localDoseId: legacyDoseSourceId,
        updatedAt: now,
      );
    }

    if (context?.isLocal == true) {
      await applyProjection();
    } else {
      await _pendingOperations.record(
        operation: operation,
        applyProjection: applyProjection,
      );
    }

    if (pill != null && nextStock != null && inventoryDelta != 0) {
      final updated = await _db.pillsDao.getById(pill.id);
      if (updated != null) stockCommitted(updated);
    }
    return command;
  }

  Future<MedicationCommand?> rebaseConflict(String operationId) async {
    Pill? changedStock;
    final command = await _guarded(
      () => _rebaseInTransaction(operationId, (pill) => changedStock = pill),
    );
    await _notifyCommittedStock(changedStock);
    return command;
  }

  Future<MedicationCommand?> _rebaseInTransaction(
    String operationId,
    void Function(Pill) stockCommitted,
  ) async {
    final original = await _db.pendingOperationsDao.getById(operationId);
    if (original == null || original.component != 'medication') return null;
    _requireOwner(original.userId);
    final originalPayload = _decodeObject(original.payloadJson);
    final originalCommand = originalPayload?['command'];
    final intent = originalPayload?['intent'];
    if (originalPayload == null ||
        originalCommand is! Map<String, dynamic> ||
        intent is! Map<String, dynamic>) {
      return null;
    }
    final originalCommandId = originalCommand['commandId'];
    if (originalCommandId is! String) return null;

    if (original.state != 'conflict') {
      final existing = await _linkedRebase(original.userId, originalCommandId);
      return existing == null
          ? null
          : _commandFromOperation(existing.payloadJson);
    }

    final localOccurrenceId = originalPayload['entityLocalId'];
    if (localOccurrenceId is! String) return null;
    final occurrence = await _db.medicationLedgerDao.getOccurrenceById(
      localOccurrenceId,
    );
    if (occurrence == null ||
        occurrence.userId != original.userId ||
        occurrence.serverId == null ||
        occurrence.provenance != 'exact' ||
        occurrence.occurrenceKey.isEmpty ||
        occurrence.supersededAt != null) {
      await _blockConflictForReview(original, 'rebase_identity_unproven');
      return null;
    }
    await _requireOccurrenceParents(occurrence);
    final intendedAction = MedicationAction.values.byName(
      intent['action'] as String,
    );
    final intendedStateRaw = intent['targetState'];
    final intendedState = intendedStateRaw is String
        ? MedicationState.values.byName(intendedStateRaw)
        : null;
    final reversesEventId =
        intent['reversesEventId'] as String? ??
        originalCommand['reversesEventId'] as String?;
    final allEvents = await _db.medicationLedgerDao.getEventsForOccurrence(
      occurrence.id,
    );
    final serverEvents = allEvents.where((event) => event.serverId != null);
    final serverHead = serverEvents.isEmpty ? null : serverEvents.last.serverId;
    final rebase = rebaseMedicationIntent(
      serverState: _stateFromStorage(occurrence.state),
      intendedAction: intendedAction,
      intendedState: intendedState,
      reversesEventId: reversesEventId,
      headEventId: serverHead,
      isSuperseded: occurrence.supersededAt != null,
      identityMatches: true,
    );
    if (rebase.blocked || rebase.action == null || rebase.toState == null) {
      await _blockConflictForReview(
        original,
        rebase.reason ?? 'rebase_blocked',
      );
      return null;
    }

    final actualAtRaw = intent['actualAt'];
    final actualAt = actualAtRaw is String ? DateTime.parse(actualAtRaw) : null;
    final actualTimeKnown = intent['actualTimeKnown'] as bool;
    final note = intent['note'] as String?;
    final linkedCommandId = projectionCommandIdForKey(
      'medication-rebase-v1:$originalCommandId:${occurrence.serverId}:'
      '${occurrence.stateVersion}:${serverHead ?? 'none'}:${rebase.toState!.name}',
    );
    final priorLinked = await _db.pendingOperationsDao.getByMutationId(
      original.userId,
      linkedCommandId,
    );
    if (priorLinked != null) {
      return _commandFromOperation(priorLinked.payloadJson);
    }

    final newCommand = MedicationCommand(
      commandId: linkedCommandId,
      userId: original.userId,
      occurrenceId: occurrence.id,
      occurrenceKey: occurrence.occurrenceKey,
      action: rebase.action!,
      targetState:
          rebase.action == MedicationAction.correct ||
              rebase.action == MedicationAction.undo
          ? rebase.toState
          : null,
      reversesEventId: reversesEventId,
      rebasesCommandId: originalCommandId,
      actualAt: actualAt,
      actualTimeKnown: actualTimeKnown,
      note: note,
      baseVersion: occurrence.stateVersion,
    );
    final now = DateTime.now().toUtc();
    final eventId = _ids.v4();
    final pillId = occurrence.pillId;
    final pill = pillId == null ? null : await _db.pillsDao.getById(pillId);
    // Same rule as [apply]: as-needed doses never touch stock, and stock may go
    // negative (surfaced for reconciliation) rather than block a taken dose.
    final hasTrackedStock =
        occurrence.source != 'prn' && pill?.currentStock != null;
    var inventoryDelta = hasTrackedStock ? rebase.inventoryDelta : 0;
    if (rebase.action == MedicationAction.undo &&
        pill != null &&
        inventoryDelta != 0 &&
        await _reversesFoldedDose(
          occurrenceId: occurrence.id,
          pillId: pill.id,
          reversesEventId: reversesEventId!,
        )) {
      inventoryDelta = 0;
    }
    final reversesInventoryEventId =
        rebase.action == MedicationAction.undo &&
            pill != null &&
            inventoryDelta != 0
        ? await _reversedInventoryServerId(
            occurrenceId: occurrence.id,
            pillId: pill.id,
            reversesEventId: reversesEventId!,
          )
        : null;
    if (rebase.action == MedicationAction.undo &&
        hasTrackedStock &&
        inventoryDelta != 0 &&
        reversesInventoryEventId == null) {
      await _blockConflictForReview(original, 'inventory_reversal_not_mapped');
      return null;
    }
    final nextStock = hasTrackedStock
        ? pill!.currentStock! + inventoryDelta
        : null;
    final previousProjection = originalPayload['localProjection'];
    final localDoseId = previousProjection is Map<String, dynamic>
        ? previousProjection['legacyDoseSourceId'] as String?
        : null;
    final doseSourceId =
        localDoseId ??
        projectionCommandIdForKey('legacy-dose-source-v1:$linkedCommandId');
    final payload = <String, Object?>{
      'userId': original.userId,
      'command': newCommand.toWire(),
      'intent': intent,
      'rebasedFromCommandId': originalCommandId,
      'localProjection': {
        'fromState': occurrence.state,
        'toState': rebase.toState!.name,
        'inventoryDelta': inventoryDelta,
        'pillId': pillId,
        'observedStock': pill?.currentStock,
        'resultingStock': nextStock,
        'legacyDoseSourceId': doseSourceId,
      },
    };
    final effects = <PendingOperationEffectDraft>[
      PendingOperationEffectDraft(
        kind: 'dose',
        legacySourceId: doseSourceId,
        requestFingerprint: _fingerprint({
          'kind': 'dose',
          'command': newCommand.toWire(),
          'occurrenceKey': occurrence.occurrenceKey,
        }),
      ),
      if (hasTrackedStock && inventoryDelta != 0)
        PendingOperationEffectDraft(
          kind: 'inventory',
          legacySourceId: pillId,
          requestFingerprint: _fingerprint({
            'kind': 'inventory',
            'pillId': pillId,
            'observedStock': pill!.currentStock,
            'resultingStock': nextStock,
            'delta': inventoryDelta,
            'commandId': linkedCommandId,
          }),
        ),
    ];
    await _pendingOperations.record(
      operation: PendingOperationDraft(
        userId: original.userId,
        mutationId: linkedCommandId,
        component: 'medication',
        contractVersion: 2,
        operationType: 'medication.command',
        entityType: 'occurrence',
        entityLocalId: occurrence.id,
        dependsOnOperationId: original.id,
        payload: payload,
        effects: effects,
      ),
      applyProjection: () async {
        await _db.medicationLedgerDao.appendOccurrenceEvent(
          OccurrenceEventsCompanion.insert(
            id: eventId,
            userId: original.userId,
            occurrenceId: occurrence.id,
            commandId: linkedCommandId,
            action: rebase.action!.name,
            fromState: occurrence.state,
            toState: rebase.toState!.name,
            reversesEventId: Value(reversesEventId),
            rebasesCommandId: Value(originalCommandId),
            actualAt: Value(actualAt?.toUtc()),
            actualTimeKnown: Value(actualTimeKnown),
            note: Value(note),
            origin: 'native',
            baseVersion: occurrence.stateVersion,
            resultVersion: occurrence.stateVersion + 1,
            recordedAt: now,
          ),
        );
        await (_db.update(
          _db.medicationOccurrences,
        )..where((row) => row.id.equals(occurrence.id))).write(
          MedicationOccurrencesCompanion(
            state: Value(rebase.toState!.name),
            stateVersion: Value(occurrence.stateVersion + 1),
            updatedAt: Value(now),
          ),
        );
        if (pill != null && nextStock != null && inventoryDelta != 0) {
          await _db.medicationLedgerDao.appendInventoryEvent(
            InventoryEventsCompanion.insert(
              id: _ids.v4(),
              userId: original.userId,
              pillId: pill.id,
              commandId: linkedCommandId,
              kind: rebase.action == MedicationAction.undo
                  ? 'dose_reversal'
                  : rebase.action == MedicationAction.correct
                  ? 'correction'
                  : 'dose',
              delta: inventoryDelta,
              occurrenceEventId: Value(eventId),
              reversesInventoryEventId: Value(reversesInventoryEventId),
              origin: 'native',
              provenanceJson: Value(
                jsonEncode({
                  'occurrenceId': occurrence.id,
                  'occurrenceKey': occurrence.occurrenceKey,
                  'rebasesCommandId': originalCommandId,
                }),
              ),
              recordedAt: now,
            ),
          );
          await (_db.update(
            _db.pills,
          )..where((row) => row.id.equals(pill.id))).write(
            PillsCompanion(
              currentStock: Value(nextStock),
              syncStatus: Value(pill.syncStatus),
              updatedAt: Value(now),
            ),
          );
        }
        await _writeDoseLogProjection(
          occurrence: occurrence,
          toState: rebase.toState!,
          actualAt: actualAt,
          actualTimeKnown: actualTimeKnown,
          note: note,
          localDoseId: doseSourceId,
          updatedAt: now,
        );
        await _db.pendingOperationsDao.transitionState(
          operationId: original.id,
          from: 'conflict',
          to: 'committed',
        );
      },
    );
    if (pill != null && nextStock != null && inventoryDelta != 0) {
      final updated = await _db.pillsDao.getById(pill.id);
      if (updated != null) stockCommitted(updated);
    }
    return newCommand;
  }

  /// A person who acts on a dose before its automatic miss left the device
  /// never sees a miss: the unsent command is withdrawn and the dose is
  /// handled as it was before. A miss that was already tried or sent stays in
  /// the ledger, and the action rebases onto it (a late take or a skip).
  Future<MedicationOccurrence> _withdrawUnsentAutoMiss(
    MedicationOccurrence occurrence,
  ) async {
    if (occurrence.state != 'missed') return occurrence;
    final events = await _db.medicationLedgerDao.getEventsForOccurrence(
      occurrence.id,
    );
    final head = [
      for (final event in events)
        if (event.serverId == null &&
            event.action == MedicationAction.miss.name &&
            event.resultVersion == occurrence.stateVersion)
          event,
    ];
    if (head.length != 1) return occurrence;
    final operation = await _db.pendingOperationsDao.getByMutationId(
      occurrence.userId,
      head.single.commandId,
    );
    if (operation == null ||
        !isAutoMissOperation(operation) ||
        operation.state != 'queued' ||
        operation.attemptCount != 0) {
      return occurrence;
    }
    final withdrawn = await discardAutoMissOperation(
      _db,
      operation,
      from: 'queued',
      safeErrorCode: autoMissWithdrawnCode,
    );
    if (!withdrawn) return occurrence;
    return await _db.medicationLedgerDao.getOccurrenceById(occurrence.id) ??
        occurrence;
  }

  Future<void> _writeDoseLogProjection({
    required MedicationOccurrence occurrence,
    required MedicationState toState,
    required DateTime? actualAt,
    required bool actualTimeKnown,
    required String? note,
    required String localDoseId,
    required DateTime updatedAt,
  }) async {
    final scheduleId = occurrence.scheduleId;
    final plannedAt = occurrence.plannedAt;
    if (scheduleId == null || plannedAt == null) return;
    final existing = await _db.doseLogsDao.getByScheduledSlot(
      scheduleId,
      plannedAt,
    );
    if (toState == MedicationState.pending) {
      if (existing != null) {
        await (_db.update(
          _db.doseLogs,
        )..where((row) => row.id.equals(existing.id))).write(
          DoseLogsCompanion(
            isDeleted: const Value(true),
            syncStatus: const Value('synced'),
            updatedAt: Value(updatedAt),
          ),
        );
      }
      return;
    }
    await _db.doseLogsDao.upsert(
      DoseLogsCompanion(
        id: Value(existing?.id ?? localDoseId),
        scheduleId: Value(scheduleId),
        scheduledAt: Value(plannedAt),
        takenAt: Value(
          toState == MedicationState.taken
              ? (actualTimeKnown ? actualAt : null)
              : null,
        ),
        status: Value(switch (toState) {
          MedicationState.taken => 'taken',
          MedicationState.missed => 'missed',
          _ => 'skipped',
        }),
        note: Value(note),
        createdAt: Value(existing?.createdAt ?? updatedAt),
        updatedAt: Value(updatedAt),
        serverId: Value(existing?.serverId),
        revision: Value(existing?.revision ?? 1),
        syncStatus: const Value('synced'),
        isDeleted: const Value(false),
      ),
    );
  }

  MedicationCommand _commandFromOperation(String payloadJson) {
    final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
    final value = payload['command'] as Map<String, dynamic>;
    return MedicationCommand(
      commandId: value['commandId'] as String,
      userId: payload['userId'] as String? ?? '',
      occurrenceId: value['occurrenceId'] as String,
      occurrenceKey: value['occurrenceKey'] as String,
      action: MedicationAction.values.byName(value['action'] as String),
      targetState: value['targetState'] == null
          ? null
          : MedicationState.values.byName(value['targetState'] as String),
      reversesEventId: value['reversesEventId'] as String?,
      rebasesCommandId: value['rebasesCommandId'] as String?,
      actualAt: value['actualAt'] == null
          ? null
          : DateTime.parse(value['actualAt'] as String),
      actualTimeKnown: value['actualTimeKnown'] as bool,
      note: value['note'] as String?,
      baseVersion: int.parse(value['baseVersion'] as String),
    );
  }

  Map<String, dynamic>? _decodeObject(String json) {
    try {
      final value = jsonDecode(json);
      return value is Map<String, dynamic> ? value : null;
    } on FormatException {
      return null;
    }
  }

  Future<PendingOperation?> _linkedRebase(
    String userId,
    String originalCommandId,
  ) async {
    for (final operation in await _db.pendingOperationsDao.getForUser(userId)) {
      if (operation.component != 'medication') continue;
      final payload = _decodeObject(operation.payloadJson);
      final command = payload?['command'];
      if (command is Map<String, dynamic> &&
          command['rebasesCommandId'] == originalCommandId) {
        return operation;
      }
    }
    return null;
  }

  Future<void> _blockConflictForReview(
    PendingOperation operation,
    String reason,
  ) async {
    final issueId = projectionCommandIdForKey(
      'medication-rebase-review-v1:${operation.id}:$reason',
    );
    final now = DateTime.now().toUtc();
    await _db.transaction(() async {
      await _db.pendingOperationsDao.transitionState(
        operationId: operation.id,
        from: 'conflict',
        to: 'blocked',
        safeErrorCode: reason,
      );
      await _db.migrationIssuesDao.record(
        MigrationIssuesCompanion.insert(
          id: issueId,
          userId: operation.userId,
          entityType: 'medication_command',
          entityId: operation.id,
          issueCode: 'medication_rebase_requires_review',
          snapshotJson: jsonEncode({
            'operationId': operation.id,
            'mutationId': operation.mutationId,
            'reason': reason,
          }),
          createdAt: now,
          updatedAt: now,
        ),
      );
    });
  }

  /// Whether the dose an undo reverses was folded into its pill's opening
  /// count: taken while the ledger was inactive (no server inventory event)
  /// and now included in a committed opening. Its undo changes no stock.
  Future<bool> _reversesFoldedDose({
    required String occurrenceId,
    required String pillId,
    required String reversesEventId,
  }) async {
    final reversed = await _reversedInventoryEvent(
      occurrenceId: occurrenceId,
      pillId: pillId,
      reversesEventId: reversesEventId,
    );
    if (reversed == null || reversed.serverId != null) return false;
    try {
      final provenance = jsonDecode(reversed.provenanceJson ?? '{}');
      if (provenance is Map && provenance['foldedIntoOpening'] is String) {
        return true;
      }
    } on FormatException {
      // Not marked; fall through to the pending-opening check.
    }
    // An opening that has frozen this dose but not committed yet (retrying)
    // will fold it: the server then applies the undo as 0.
    return isPendingFolded(_db, reversed.userId, reversed.id);
  }

  Future<String?> _reversedInventoryServerId({
    required String occurrenceId,
    required String pillId,
    required String reversesEventId,
  }) async {
    final reversed = await _reversedInventoryEvent(
      occurrenceId: occurrenceId,
      pillId: pillId,
      reversesEventId: reversesEventId,
    );
    return reversed == null ? null : reversed.serverId ?? reversed.id;
  }

  Future<InventoryEvent?> _reversedInventoryEvent({
    required String occurrenceId,
    required String pillId,
    required String reversesEventId,
  }) async {
    final events = await _db.medicationLedgerDao.getEventsForOccurrence(
      occurrenceId,
    );
    final reversedEvent = events.where(
      (event) =>
          event.serverId == reversesEventId || event.id == reversesEventId,
    );
    if (reversedEvent.isEmpty) return null;
    final event = reversedEvent.last;
    final inventory = await _db.medicationLedgerDao.getInventoryEventsForPill(
      pillId,
    );
    final reversedInventory = inventory.where(
      (candidate) =>
          // A pulled inventory event names the occurrence event by its server
          // id; the local row keeps the id the phone generated.
          candidate.occurrenceEventId == event.id ||
          (event.serverId != null &&
              candidate.occurrenceEventId == event.serverId) ||
          candidate.occurrenceEventId == reversesEventId,
    );
    return reversedInventory.isEmpty ? null : reversedInventory.last;
  }

  MedicationState _stateFromStorage(String state) =>
      MedicationState.values.byName(state);

  static String _fingerprint(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(_canonicalize(value)))).toString();

  String _legacyDoseFingerprint(
    DoseLog log, {
    required String serverScheduleId,
    required String serverDoseId,
  }) => legacyDoseFingerprint(
    log,
    serverScheduleId: serverScheduleId,
    serverDoseId: serverDoseId,
  );

  /// The dose fingerprint the server compares for a bridge undo.
  @visibleForTesting
  static String legacyDoseFingerprint(
    DoseLog log, {
    required String serverScheduleId,
    required String serverDoseId,
  }) => _fingerprint({
    'id': serverDoseId,
    'scheduleId': serverScheduleId,
    'scheduledAt': _wholeSecondIso(log.scheduledAt),
    'takenAt': log.takenAt == null ? null : _wholeSecondIso(log.takenAt!),
    'status': log.status,
    'deletedAt': null,
  });

  /// Whole-second UTC ISO form (`...:SS.000Z`). The local store keeps whole
  /// seconds while the server keeps milliseconds, so the fingerprint must not
  /// depend on which precision the value was read at.
  static String _wholeSecondIso(DateTime value) =>
      DateTime.fromMillisecondsSinceEpoch(
        value.millisecondsSinceEpoch - value.millisecondsSinceEpoch % 1000,
        isUtc: true,
      ).toIso8601String();

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonicalize(value[key])};
    }
    if (value is Iterable) return value.map(_canonicalize).toList();
    return value;
  }

  String _localDateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
