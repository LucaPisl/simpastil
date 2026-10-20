import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

import '../db/daos/medication_ledger_dao.dart';
import '../db/database.dart';
import '../sync/sync_review_repository.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import 'local_occurrence_snapshot.dart';
import 'occurrence_materializer.dart';
import 'medication_amount.dart';
import 'medication_command.dart';
import 'medication_repository.dart';
import 'reviewed_stock.dart';
import 'routine_definition.dart';
import 'routine_repository.dart';

enum CareSharingOutcome {
  reconciled,
  localOnly,
  pending,
  acknowledged,
  needsReview,
  uncertain,
}

enum CareProjectionOutcome { notRequested, refreshed, unavailable }

/// One reviewed action. Keep this object for retries; prepare a new one only
/// when the person deliberately chooses a new action.
class PreparedCareIntent {
  const PreparedCareIntent._({
    required CareRecordingService origin,
    required this.personId,
    required this.occurrenceId,
    required this.commandId,
    required this.expectedStateVersion,
    required this.action,
    required this.amount,
    required this.actualTimeKnown,
    required this.localDate,
    this.actualAt,
    this.note,
    this.targetState,
    this.reversesEventId,
    MedicationOccurrencesCompanion? prnOccurrence,
    int? routineRevision,
    String? pillId,
    Schedule? connectedPrnSentinel,
  }) : _origin = origin,
       _prnOccurrence = prnOccurrence,
       _routineRevision = routineRevision,
       _pillId = pillId,
       _connectedPrnSentinel = connectedPrnSentinel;
  final CareRecordingService _origin;
  final MedicationOccurrencesCompanion? _prnOccurrence;
  final int? _routineRevision;
  final String? _pillId;
  final Schedule? _connectedPrnSentinel;
  final String personId;
  final String occurrenceId;
  final String commandId;
  final int expectedStateVersion;
  final String localDate;
  final MedicationAction action;
  final MedicationAmount amount;
  final DateTime? actualAt;
  final bool actualTimeKnown;
  final String? note;
  final MedicationState? targetState;
  final String? reversesEventId;
}

class CareEventFacts {
  const CareEventFacts({
    required this.event,
    required this.amount,
    required this.stock,
    this.authorId,
    this.authorName,
    this.localReversalEventId,
  });
  final OccurrenceEvent event;
  final MedicationAmount amount;
  final String? authorId;
  final String? authorName;
  final String? localReversalEventId;
  final CareStockOutcome stock;
}

/// Durable care and optional effects have independent outcomes.
class CareRecordingReceipt extends CareEventFacts {
  const CareRecordingReceipt._({
    required this.personId,
    required this.current,
    required this.sharing,
    required this.projection,
    required super.event,
    required super.amount,
    required super.stock,
    super.authorId,
    super.authorName,
    super.localReversalEventId,
    required CareRecordingService origin,
  }) : _origin = origin;
  final CareRecordingService _origin;
  final String personId;
  final MedicationOccurrence current;
  final CareSharingOutcome sharing;
  final CareProjectionOutcome projection;
}

/// Captures authority once. All care publication is inside the protected grant;
/// platform refresh runs after the transaction has committed.
class CareRecordingService {
  CareRecordingService({
    required this.database,
    required this.access,
    required this.context,
    DateTime Function()? clock,
    this.afterCareSave,
  }) : _clock = clock ?? DateTime.now;
  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final WorkspaceContext context;
  final DateTime Function() _clock;
  final Future<void> Function()? afterCareSave;
  static const _ids = Uuid();

  Future<({Pill pill, Profile person})> _parents(
    String personId,
    String pillId,
  ) async {
    await access.requireCurrent(context, profileId: personId);
    final pill = await database.pillsDao.getById(pillId);
    final person = await database.profilesDao.getById(personId);
    if (pill == null ||
        pill.isDeleted ||
        pill.profileId != personId ||
        person == null ||
        person.isDeleted) {
      throw const MedicationCommandBlocked('wrong_person');
    }
    return (pill: pill, person: person);
  }

  Future<MedicationOccurrence> _occurrence(
    String personId,
    String occurrenceId,
  ) async {
    final row = await database.medicationLedgerDao.getOccurrenceById(
      occurrenceId,
    );
    if (row == null ||
        row.userId != context.ownerUserId ||
        row.pillId == null) {
      throw const MedicationCommandBlocked('occurrence_missing');
    }
    await _parents(personId, row.pillId!);
    final snapshot = decodeScheduleSnapshot(
      jsonDecode(row.scheduleSnapshotJson) as Map<String, dynamic>,
    );
    if (!snapshotOwns(snapshot, context.ownerUserId, context.workspaceId) ||
        snapshot.profileId != personId) {
      throw const MedicationCommandBlocked('occurrence_identity_unproven');
    }
    return row;
  }

  void _time(DateTime? actualAt, bool known) {
    if (known != (actualAt != null)) {
      throw ArgumentError('Choose a known time or Unknown');
    }
  }

  Future<PreparedCareIntent> prepareTakenNow({
    required String personId,
    required String occurrenceId,
    required int expectedStateVersion,
    MedicationAmount amount = const MedicationAmount.unknown(),
    String? note,
  }) => prepare(
    personId: personId,
    occurrenceId: occurrenceId,
    expectedStateVersion: expectedStateVersion,
    action: MedicationAction.take,
    amount: amount,
    actualAt: _clock().toUtc(),
    actualTimeKnown: true,
    note: note,
  );

  Future<PreparedCareIntent> prepare({
    required String personId,
    required String occurrenceId,
    required int expectedStateVersion,
    required MedicationAction action,
    required MedicationAmount amount,
    required DateTime? actualAt,
    required bool actualTimeKnown,
    String? note,
    MedicationState? targetState,
  }) => access.withGrant(context, () async {
    _time(actualAt, actualTimeKnown);
    if (action == MedicationAction.undo) {
      throw ArgumentError('Prepare Undo from its receipt');
    }
    final row = await _occurrence(personId, occurrenceId);
    if (row.stateVersion != expectedStateVersion || row.supersededAt != null) {
      throw const MedicationCommandBlocked('occurrence_head_changed');
    }
    return PreparedCareIntent._(
      origin: this,
      personId: personId,
      occurrenceId: occurrenceId,
      commandId: _ids.v4(),
      expectedStateVersion: expectedStateVersion,
      action: action,
      localDate: row.plannedLocalDate,
      amount: amount,
      actualAt: actualAt?.toUtc(),
      actualTimeKnown: actualTimeKnown,
      note: note,
      targetState: targetState,
    );
  });

  /// Each deliberate administration creates one stable identity. Preparing a
  /// review writes no care; committing the same intent is idempotent.
  Future<PreparedCareIntent> prepareConnectedPrn({
    required String personId,
    required String pillId,
    required String sentinelId,
    required String reviewedLocalDate,
    required MedicationAmount amount,
    required DateTime? actualAt,
    required bool actualTimeKnown,
    String? note,
  }) => access.withGrant(context, () async {
    if (context.isLocal) {
      throw const MedicationCommandBlocked('connected_prn_required');
    }
    _time(actualAt, actualTimeKnown);
    final parents = await _parents(personId, pillId);
    final sentinel = await database.schedulesDao.getById(sentinelId);
    if (!parents.pill.isPrn ||
        sentinel == null ||
        sentinel.pillId != pillId ||
        sentinel.isDeleted ||
        !sentinel.isActive ||
        sentinel.frequency != 'prn') {
      throw const MedicationCommandBlocked('prn_not_available');
    }
    await _uniqueConnectedPrnSentinel(pillId, sentinelId);
    _connectedPrnDate(sentinel, reviewedLocalDate, actualAt);
    final id = _ids.v4();
    final now = _clock().toUtc();
    return PreparedCareIntent._(
      origin: this,
      personId: personId,
      occurrenceId: id,
      commandId: _ids.v4(),
      expectedStateVersion: 0,
      action: MedicationAction.take,
      localDate: reviewedLocalDate,
      amount: amount,
      actualAt: actualAt?.toUtc(),
      actualTimeKnown: actualTimeKnown,
      note: note,
      connectedPrnSentinel: sentinel,
      pillId: pillId,
      prnOccurrence: MedicationOccurrencesCompanion.insert(
        id: id,
        userId: context.ownerUserId,
        pillId: Value(pillId),
        scheduleId: Value(sentinelId),
        occurrenceKey: 'prn:v1:$id',
        source: 'prn',
        scheduleRevision: Value(sentinel.revision),
        plannedLocalDate: reviewedLocalDate,
        timeZone: sentinel.timeZone!,
        provenance: 'exact',
        scheduleSnapshotJson: jsonEncode(
          ScheduleSnapshotV1(
            pillName: parents.pill.name,
            dosage: parents.pill.dosage,
            frequency: 'prn',
            frequencyDays: null,
            hour: null,
            minute: null,
            timeZone: sentinel.timeZone!,
            profileId: personId,
            profileName: parents.person.name,
          ).toJson(),
        ),
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  void _connectedPrnDate(Schedule sentinel, String date, DateTime? actualAt) {
    parseRoutineDate(date);
    if (sentinel.timeZoneStatus != 'known' || sentinel.timeZone == null) {
      throw const MedicationCommandBlocked('prn_time_zone_review_required');
    }
    final zone = tz.getLocation(sentinel.timeZone!);
    if (actualAt != null &&
        routineDateKey(tz.TZDateTime.from(actualAt, zone)) != date) {
      throw const MedicationCommandBlocked('actual_date_not_reviewed');
    }
  }

  Future<void> _uniqueConnectedPrnSentinel(
    String pillId,
    String sentinelId,
  ) async {
    final active = (await database.schedulesDao.getByPillId(pillId))
        .where((s) => s.isActive && !s.isDeleted && s.frequency == 'prn')
        .toList();
    if (active.length != 1 || active.single.id != sentinelId) {
      throw const MedicationCommandBlocked('prn_routine_ambiguous');
    }
  }

  Future<LocalRoutine> _prnVersion(
    String personId,
    String pillId,
    int expectedRevision,
    String date,
    DateTime? actualAt,
  ) async {
    if (!context.isLocal) {
      throw const MedicationCommandBlocked('local_prn_required');
    }
    await _parents(personId, pillId);
    final versions = await RoutineRepository(
      database: database,
      access: access,
      context: context,
    ).loadForPill(pillId);
    final effective = versions
        .where((v) => !v.effectiveFrom.isAfter(_clock().toUtc()))
        .toList();
    final version = effective.lastOrNull;
    if (version == null || version.revision != expectedRevision) {
      throw const MedicationCommandBlocked('routine_changed');
    }
    final definition = RoutineDefinition.fromJson(
      jsonDecode(version.definitionJson) as Map<String, dynamic>,
    );
    if (definition.kind != RoutineKind.prn ||
        !definition.isWithinDates(parseRoutineDate(date))) {
      throw const MedicationCommandBlocked('prn_not_available');
    }
    if (actualAt != null &&
        routineDateKey(
              tz.TZDateTime.from(actualAt, tz.getLocation(definition.timeZone)),
            ) !=
            date) {
      throw const MedicationCommandBlocked('actual_date_not_reviewed');
    }
    return version;
  }

  Future<PreparedCareIntent> preparePrn({
    required String personId,
    required String pillId,
    required int expectedRoutineRevision,
    required String reviewedLocalDate,
    required MedicationAmount amount,
    required DateTime? actualAt,
    required bool actualTimeKnown,
    String? note,
  }) => access.withGrant(context, () async {
    _time(actualAt, actualTimeKnown);
    final version = await _prnVersion(
      personId,
      pillId,
      expectedRoutineRevision,
      reviewedLocalDate,
      actualAt,
    );
    final parents = await _parents(personId, pillId);
    final definition = RoutineDefinition.fromJson(
      jsonDecode(version.definitionJson) as Map<String, dynamic>,
    );
    final id = _ids.v4();
    final createdAt = _clock().toUtc();
    final snapshot = LocalOccurrenceSnapshot(
      pillName: parents.pill.name,
      dosage: parents.pill.dosage,
      hour: 0,
      minute: 0,
      timeZone: definition.timeZone,
      profileId: personId,
      profileName: parents.person.name,
      workspaceId: context.workspaceId,
      ownerUserId: context.ownerUserId,
      routineId: version.routineId,
      routineRevision: version.revision,
      slotId: 'prn',
      amount: amount,
      routineDefinition: definition,
    );
    return PreparedCareIntent._(
      origin: this,
      personId: personId,
      occurrenceId: id,
      commandId: _ids.v4(),
      expectedStateVersion: 0,
      action: MedicationAction.take,
      amount: amount,
      localDate: reviewedLocalDate,
      actualAt: actualAt?.toUtc(),
      actualTimeKnown: actualTimeKnown,
      note: note,
      routineRevision: version.revision,
      pillId: pillId,
      prnOccurrence: MedicationOccurrencesCompanion.insert(
        id: id,
        userId: context.ownerUserId,
        pillId: Value(pillId),
        scheduleId: Value(localRoutinePrnScheduleId(version.routineId)),
        occurrenceKey: 'prn:local:v2:${context.workspaceId}:$id',
        source: 'prn',
        scheduleRevision: Value(version.revision),
        plannedLocalDate: reviewedLocalDate,
        timeZone: definition.timeZone,
        snapshotVersion: const Value(2),
        scheduleSnapshotJson: jsonEncode(snapshot.toJson()),
        provenance: 'exact',
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
    );
  });

  Future<PreparedCareIntent> prepareUndo(CareRecordingReceipt receipt) =>
      access.withGrant(context, () async {
        if (!identical(receipt._origin, this)) {
          throw ArgumentError('Receipt belongs to another care service');
        }
        return _prepareUndo(
          receipt.personId,
          receipt.current.id,
          receipt.event.resultVersion,
          receipt.event.id,
        );
      });

  /// A completed card can offer Undo after reopening without recreating a
  /// receipt or accepting a different event from the one shown on screen.
  Future<PreparedCareIntent> prepareUndoForEntry({
    required String personId,
    required String occurrenceId,
    required int expectedStateVersion,
    required String headEventId,
  }) => access.withGrant(
    context,
    () =>
        _prepareUndo(personId, occurrenceId, expectedStateVersion, headEventId),
  );

  Future<PreparedCareIntent> _prepareUndo(
    String personId,
    String occurrenceId,
    int expectedStateVersion,
    String headEventId,
  ) async {
    final row = await _occurrence(personId, occurrenceId);
    final events = await database.medicationLedgerDao.getEventsForOccurrence(
      row.id,
    );
    final discarded = await database.medicationLedgerDao.discardedCommandIds(
      context.ownerUserId,
    );
    final head = headEventsAt(
      events,
      row.stateVersion,
      discardedCommandIds: discarded,
    ).where((e) => e.userId == context.ownerUserId).singleOrNull;
    if (row.stateVersion != expectedStateVersion ||
        head?.id != headEventId ||
        head!.action == 'undo' ||
        head.origin == 'legacy_handoff') {
      throw const MedicationCommandBlocked('occurrence_head_changed');
    }
    final target = MedicationState.values.byName(head.fromState);
    final previous = headEventsAt(
      events,
      head.baseVersion,
      discardedCommandIds: discarded,
    ).singleOrNull;
    final previousFacts = previous == null ? null : await _facts(previous);
    return PreparedCareIntent._(
      origin: this,
      personId: personId,
      occurrenceId: row.id,
      commandId: _ids.v4(),
      expectedStateVersion: row.stateVersion,
      action: MedicationAction.undo,
      localDate: row.plannedLocalDate,
      targetState: target,
      reversesEventId: head.id,
      amount: target == MedicationState.taken
          ? previousFacts?.amount ?? const MedicationAmount.unknown()
          : const MedicationAmount.unknown(),
      actualAt: target == MedicationState.taken ? previous?.actualAt : null,
      actualTimeKnown:
          target == MedicationState.taken && previous?.actualTimeKnown == true,
    );
  }

  Future<CareEventFacts> _facts(OccurrenceEvent event) async {
    final details =
        await (database.select(database.careEventDetails)..where(
              (d) =>
                  d.workspaceId.equals(context.workspaceId) &
                  d.eventId.equals(event.id),
            ))
            .getSingleOrNull();
    return CareEventFacts(
      event: event,
      amount: details == null
          ? event.administrationAmountJson == null
                ? const MedicationAmount.unknown()
                : MedicationAmount.fromJson(
                    Map<String, Object?>.from(
                      jsonDecode(event.administrationAmountJson!) as Map,
                    ),
                  )
          : MedicationAmount.fromJson(
              Map<String, Object?>.from(jsonDecode(details.amountJson) as Map),
            ),
      authorId: details?.authorId,
      authorName: details?.authorName,
      localReversalEventId: details?.localReversalEventId,
      stock: details == null
          ? CareStockOutcome.notTracked
          : CareStockOutcome.values.byName(details.stockOutcome),
    );
  }

  Future<CareRecordingReceipt> commit(PreparedCareIntent intent) async {
    if (!identical(intent._origin, this)) {
      throw ArgumentError('Intent belongs to another care service');
    }
    final saved = await access.withGrant(context, () async {
      await access.requireCurrent(context, profileId: intent.personId);
      final receipt =
          await (database.select(database.careEventDetails)..where(
                (d) =>
                    d.workspaceId.equals(context.workspaceId) &
                    d.commandId.equals(intent.commandId),
              ))
              .getSingleOrNull();
      if (intent._connectedPrnSentinel != null &&
          receipt == null &&
          await database.schedulesDao.getById(
                intent._connectedPrnSentinel.id,
              ) !=
              intent._connectedPrnSentinel) {
        throw const MedicationCommandBlocked('routine_changed');
      }
      if (intent._prnOccurrence != null && receipt == null) {
        if (intent._connectedPrnSentinel != null) {
          await _parents(intent.personId, intent._pillId!);
          await _uniqueConnectedPrnSentinel(
            intent._pillId,
            intent._connectedPrnSentinel.id,
          );
          _connectedPrnDate(
            intent._connectedPrnSentinel,
            intent.localDate,
            intent.actualAt,
          );
        } else {
          await _prnVersion(
            intent.personId,
            intent._pillId!,
            intent._routineRevision!,
            intent._prnOccurrence.plannedLocalDate.value,
            intent.actualAt,
          );
        }
        await database.medicationLedgerDao.upsertOccurrence(
          intent._prnOccurrence,
        );
      }
      await _occurrence(intent.personId, intent.occurrenceId);
      // No platform callbacks inside this enclosing protected transaction.
      await MedicationRepository(
        database,
        access: access,
        context: context,
      ).apply(
        userId: context.ownerUserId,
        occurrenceId: intent.occurrenceId,
        action: intent.action,
        commandIdOverride: intent.commandId,
        expectedStateVersion: intent.expectedStateVersion,
        expectedPersonId: intent.personId,
        amount: intent.amount,
        actualAt: intent.actualAt,
        actualTimeKnown: intent.actualTimeKnown,
        note: intent.note,
        intendedState: intent.targetState,
        reversesEventId: intent.reversesEventId,
      );
      final events = await database.medicationLedgerDao.getEventsForOccurrence(
        intent.occurrenceId,
      );
      final event = events
          .where(
            (e) =>
                e.commandId == intent.commandId &&
                e.userId == context.ownerUserId,
          )
          .single;
      final facts = await _facts(event);
      final current = await _occurrence(intent.personId, intent.occurrenceId);
      final operation = await database.pendingOperationsDao.getByMutationId(
        context.ownerUserId,
        intent.commandId,
      );
      final sharing = context.isLocal
          ? CareSharingOutcome.localOnly
          : operation != null
          ? await operationSharingOutcome(database, context, operation)
          : CareSharingOutcome.pending;
      return (facts: facts, current: current, sharing: sharing);
    });
    var projection = CareProjectionOutcome.notRequested;
    if (afterCareSave != null) {
      try {
        await access.requireCurrent(context);
        await afterCareSave!();
        projection = CareProjectionOutcome.refreshed;
      } on Object {
        projection = CareProjectionOutcome.unavailable;
      }
    }
    return CareRecordingReceipt._(
      origin: this,
      personId: intent.personId,
      current: saved.current,
      sharing: saved.sharing,
      projection: projection,
      event: saved.facts.event,
      amount: saved.facts.amount,
      stock: saved.facts.stock,
      authorId: saved.facts.authorId,
      authorName: saved.facts.authorName,
      localReversalEventId: saved.facts.localReversalEventId,
    );
  }

  Future<List<CareEventFacts>> historyForPerson(
    String personId,
  ) => access.withGrant(context, () async {
    await access.requireCurrent(context, profileId: personId);
    final rows = await database.medicationLedgerDao.getOccurrencesForUser(
      context.ownerUserId,
    );
    final result = <CareEventFacts>[];
    for (final row in rows) {
      final snapshot = decodeScheduleSnapshot(
        jsonDecode(row.scheduleSnapshotJson) as Map<String, dynamic>,
      );
      if (!snapshotOwns(snapshot, context.ownerUserId, context.workspaceId) ||
          snapshot.profileId != personId) {
        continue;
      }
      // Historical snapshots preserve the original person and medication labels.
      for (final event
          in await database.medicationLedgerDao.getEventsForOccurrence(
            row.id,
          )) {
        if (event.userId == context.ownerUserId) {
          result.add(await _facts(event));
        }
      }
    }
    result.sort((a, b) {
      final date = a.event.recordedAt.compareTo(b.event.recordedAt);
      return date != 0
          ? date
          : a.event.resultVersion.compareTo(b.event.resultVersion);
    });
    return List.unmodifiable(result);
  });
}
