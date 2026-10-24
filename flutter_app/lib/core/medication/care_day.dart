import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:timezone/timezone.dart' as tz;

import '../db/daos/medication_ledger_dao.dart';
import '../db/database.dart';
import '../sync/sync_review_repository.dart';
import '../db/daos/import_dao.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import 'care_recording.dart';
import 'current_name_display.dart';
import 'local_occurrence_snapshot.dart';
import 'medication_amount.dart';
import 'medication_repository.dart';
import 'occurrence_materializer.dart';
import 'recorded_amount.dart';
import 'routine_definition.dart';
import 'routine_repository.dart';
import 'routine_preview.dart';
import 'stock_plan.dart';

enum CareDayState {
  noPeople,
  noMedications,
  noRoutine,
  dayOff,
  asNeeded,
  laterDue,
  pending,
  recorded,
}

class CareDayEntry {
  const CareDayEntry({
    required this.occurrence,
    required this.person,
    required this.pill,
    required this.snapshot,
    required this.plannedAmount,
    required this.sharing,
    this.head,
  });
  final MedicationOccurrence occurrence;
  final Profile person;
  final Pill pill;
  final ScheduleSnapshotV1 snapshot;
  final MedicationAmount plannedAmount;
  final OccurrenceEvent? head;
  final CareSharingOutcome sharing;
  bool get canRecord =>
      occurrence.provenance == 'exact' && occurrence.supersededAt == null;
}

class CarePrnOption {
  const CarePrnOption({
    required this.person,
    required this.pill,
    required this.routine,
    required this.definition,
  });
  final Profile person;
  final Pill pill;
  final LocalRoutine routine;
  final RoutineDefinition definition;
}

/// Informational future care, with no new occurrence or recording authority.
class CareNextDose {
  const CareNextDose({
    required this.person,
    required this.pill,
    required this.routineId,
    required this.planned,
    required this.amount,
  });
  final Profile person;
  final Pill pill;
  final String? routineId;
  final RoutinePlannedEntry planned;
  final MedicationAmount amount;
}

class CareDay {
  CareDay({
    required this.localDate,
    required this.state,
    required List<Profile> people,
    required List<CareDayEntry> entries,
    required List<CarePrnOption> prn,
    this.nextDose,
  }) : people = List.unmodifiable(people),
       entries = List.unmodifiable(entries),
       prn = List.unmodifiable(prn);
  final String localDate;
  final CareDayState state;
  final List<Profile> people;
  final List<CareDayEntry> entries;
  final List<CarePrnOption> prn;
  final CareNextDose? nextDose;
  int get remainingCount => entries
      .where((e) => e.occurrence.expected && e.occurrence.state == 'pending')
      .length;

  /// Doses the person took or skipped. A recorded miss is not counted, as in
  /// the Day sky, This week and the journal periods.
  int get recordedCount => entries
      .where(
        (e) => e.occurrence.state == 'taken' || e.occurrence.state == 'skipped',
      )
      .length;
}

/// Read failures remain stream errors. They cannot masquerade as an empty day.
class CareDayRepository {
  CareDayRepository({
    required this.database,
    required this.access,
    required this.context,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final WorkspaceContext context;
  final DateTime Function() _clock;

  Stream<CareDay> watch({
    required String localDate,
    String? personId,
  }) => database
      .customSelect(
        // Drift shares identical SQL streams; keep this dependency set distinct.
        'SELECT 1 AS care_day_changes',
        readsFrom: {
          database.profiles,
          database.pills,
          database.schedules,
          database.localRoutines,
          database.medicationOccurrences,
          database.occurrenceEvents,
          database.medicationDetails,
          database.careEventDetails,
          database.pendingOperations,
          database.pendingOperationEffects,
          database.effectSettlements,
          database.migrationIssues,
          database.workspaceGrants,
          database.careWorkspaces,
          database.workspaceAuthors,
          database.workspaceDeviceStates,
          database.importEvidence,
          database.importReceipts,
        },
      )
      .watch()
      .asyncMap((_) => load(localDate: localDate, personId: personId));

  /// The amount recorded with a dose's head event (taken, skipped or
  /// corrected), or unknown when none was recorded. Read-only: recorded
  /// history is shown as it was captured. Without a local detail row the
  /// event's synced amount is used.
  Future<MedicationAmount> _recordedAmount(
    WorkspaceContext context,
    OccurrenceEvent? head,
  ) async {
    if (head == null) return const MedicationAmount.unknown();
    final facts =
        await (database.select(database.careEventDetails)..where(
              (d) =>
                  d.workspaceId.equals(context.workspaceId) &
                  d.eventId.equals(head.id),
            ))
            .getSingleOrNull();
    return recordedAmountOf(head, detailAmountJson: facts?.amountJson);
  }

  Future<CareDay> load({
    required String localDate,
    String? personId,
  }) => access.withGrant(context, () async {
    final date = parseRoutineDate(localDate);
    if (personId != null) {
      await access.requireCurrent(context, profileId: personId);
    }
    if (context.isLocal) {
      await RoutineRepository(
        database: database,
        access: access,
        context: context,
        clock: _clock,
      ).ensureMaterialized(
        fromLocalDate: localDate,
        throughLocalDate: localDate,
      );
    }
    final allPeople = await database.profilesDao.getByUserId(
      context.ownerUserId,
    );
    final people = allPeople
        .where((p) => personId == null || p.id == personId)
        .toList();
    final pills = <String, Pill>{};
    final peopleById = {for (final p in people) p.id: p};
    for (final person in people) {
      for (final pill in await database.pillsDao.getByProfileId(person.id)) {
        pills[pill.id] = pill;
      }
    }
    final entries = <CareDayEntry>[];
    final rows = await database.medicationLedgerDao.getForUserLocalDateRange(
      context.ownerUserId,
      localDate,
      localDate,
    );
    final discardedCommands = await database.medicationLedgerDao
        .discardedCommandIds(context.ownerUserId);
    for (final record in rows) {
      final row = record.occurrence;
      final pill = pills[row.pillId];
      if (pill == null || row.supersededAt != null) continue;
      final snapshot = decodeScheduleSnapshot(
        jsonDecode(row.scheduleSnapshotJson) as Map<String, dynamic>,
      );
      if (!snapshotOwns(snapshot, context.ownerUserId, context.workspaceId) ||
          snapshot.timeZone != row.timeZone) {
        throw const MedicationCommandBlocked('occurrence_identity_unproven');
      }
      if (snapshot.profileId != pill.profileId) {
        if (await ImportDao(
          database,
        ).isDetachedOccurrence(context.workspaceId, row.id)) {
          continue;
        }
        throw const MedicationCommandBlocked('occurrence_identity_unproven');
      }
      final heads = headEventsAt(
        record.events,
        row.stateVersion,
        discardedCommandIds: discardedCommands,
      ).where((e) => e.userId == context.ownerUserId);
      final head = heads.singleOrNull;
      final operation = head == null
          ? null
          : await database.pendingOperationsDao.getByMutationId(
              context.ownerUserId,
              head.commandId,
            );
      final sharing = context.isLocal
          ? CareSharingOutcome.localOnly
          : operation != null
          ? await operationSharingOutcome(database, context, operation)
          : head?.serverId != null
          ? CareSharingOutcome.acknowledged
          : CareSharingOutcome.pending;
      entries.add(
        CareDayEntry(
          occurrence: row,
          person: peopleById[pill.profileId]!,
          pill: pill,
          snapshot: showsCurrentName(row.state)
              ? decodeScheduleSnapshot({
                  ...snapshot.toJson(),
                  'pillName': pill.name,
                })
              : snapshot,
          plannedAmount: snapshot is LocalOccurrenceSnapshot
              ? snapshot.amount
              : !context.isLocal &&
                    row.source == 'scheduled' &&
                    (row.state == 'pending' || row.state == 'missed')
              ? await doseAmountOrReviewed(
                  database,
                  pillId: pill.id,
                  amount: const MedicationAmount.unknown(),
                )
              : await _recordedAmount(context, head),
          head: head,
          sharing: sharing,
        ),
      );
    }
    entries.sort((a, b) {
      final at = a.occurrence.plannedAt;
      final bt = b.occurrence.plannedAt;
      if (at != null && bt != null) {
        final cmp = at.compareTo(bt);
        if (cmp != 0) return cmp;
      } else if (at != null) {
        return -1;
      } else if (bt != null) {
        return 1;
      }
      return a.occurrence.id.compareTo(b.occurrence.id);
    });
    final prn = <CarePrnOption>[];
    var hasRoutine = false;
    final now = _clock().toUtc();
    for (final pill in pills.values) {
      final versions =
          await (database.select(database.localRoutines)
                ..where(
                  (r) =>
                      r.workspaceId.equals(context.workspaceId) &
                      r.pillId.equals(pill.id),
                )
                ..orderBy([(r) => OrderingTerm.asc(r.revision)]))
              .get();
      if (versions.isNotEmpty) hasRoutine = true;
      final active = versions
          .where((v) => !v.effectiveFrom.isAfter(now))
          .lastOrNull;
      if (active != null) {
        final definition = RoutineDefinition.fromJson(
          jsonDecode(active.definitionJson) as Map<String, dynamic>,
        );
        if (definition.kind == RoutineKind.prn &&
            definition.isWithinDates(date)) {
          prn.add(
            CarePrnOption(
              person: peopleById[pill.profileId]!,
              pill: pill,
              routine: active,
              definition: definition,
            ),
          );
        }
      }
      if (!context.isLocal &&
          (await database.schedulesDao.getByPillId(
            pill.id,
          )).any((s) => !s.isDeleted)) {
        hasRoutine = true;
      }
    }
    final pending = entries
        .where((e) => e.occurrence.expected && e.occurrence.state == 'pending')
        .toList();
    final state = people.isEmpty
        ? CareDayState.noPeople
        : pills.isEmpty
        ? CareDayState.noMedications
        : !hasRoutine && entries.isEmpty
        ? CareDayState.noRoutine
        : pending.isNotEmpty
        ? (pending.every(
                (e) =>
                    e.occurrence.plannedAt != null &&
                    e.occurrence.plannedAt!.isAfter(now) &&
                    routineDateKey(
                          tz.TZDateTime.from(
                            now,
                            tz.getLocation(e.occurrence.timeZone),
                          ),
                        ) ==
                        localDate,
              )
              ? CareDayState.laterDue
              : CareDayState.pending)
        : entries.any((e) => e.occurrence.state != 'pending')
        ? CareDayState.recorded
        : prn.isNotEmpty
        ? CareDayState.asNeeded
        : CareDayState.dayOff;
    CareNextDose? nextDose;
    if (hasRoutine &&
        !entries.any(
          (e) => e.occurrence.expected || e.occurrence.state != 'pending',
        )) {
      final options = <CareNextDose>[];
      if (context.isLocal) {
        final routines = RoutineRepository(
          database: database,
          access: access,
          context: context,
          clock: _clock,
        );
        for (final pill in pills.values) {
          final next = await routines.nextPlannedForPill(
            pillId: pill.id,
            afterLocalDate: localDate,
          );
          if (next != null) {
            options.add(
              CareNextDose(
                person: peopleById[pill.profileId]!,
                pill: pill,
                routineId: next.routineId,
                planned: next.planned,
                amount: next.amount,
              ),
            );
          }
        }
      } else {
        // Connected recurrence remains owned by the existing server contract.
        // Only already saved exact future occurrences can prove this preview.
        final future = await database.medicationLedgerDao
            .getForUserLocalDateRange(
              context.ownerUserId,
              routineDateKey(DateTime.utc(date.year, date.month, date.day + 1)),
              '9999-12-31',
            );
        for (final record in future) {
          final row = record.occurrence;
          final pill = pills[row.pillId];
          if (pill == null ||
              row.supersededAt != null ||
              !row.expected ||
              row.state != 'pending' ||
              row.provenance != 'exact' ||
              row.plannedAt == null) {
            continue;
          }
          final snapshot = decodeScheduleSnapshot(
            jsonDecode(row.scheduleSnapshotJson) as Map<String, dynamic>,
          );
          if (!snapshotOwns(
                snapshot,
                context.ownerUserId,
                context.workspaceId,
              ) ||
              snapshot.profileId != pill.profileId ||
              snapshot.timeZone != row.timeZone ||
              snapshot.hour == null ||
              snapshot.minute == null) {
            throw const MedicationCommandBlocked(
              'occurrence_identity_unproven',
            );
          }
          options.add(
            CareNextDose(
              person: peopleById[pill.profileId]!,
              pill: pill,
              routineId: null,
              planned: RoutinePlannedEntry(
                slot: RoutineTime(
                  slotId: row.scheduleId ?? row.id,
                  hour: snapshot.hour!,
                  minute: snapshot.minute!,
                ),
                localDate: row.plannedLocalDate,
                timeZone: row.timeZone,
                plannedAt: row.plannedAt!,
              ),
              amount: await doseAmountOrReviewed(
                database,
                pillId: pill.id,
                amount: const MedicationAmount.unknown(),
              ),
            ),
          );
        }
      }
      options.sort(
        (a, b) => a.planned.plannedAt.compareTo(b.planned.plannedAt),
      );
      nextDose = options.firstOrNull;
    }
    return CareDay(
      localDate: localDate,
      state: state,
      people: people,
      entries: entries,
      prn: prn,
      nextDose: nextDose,
    );
  });
}
