import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/daos/medication_ledger_dao.dart';
import '../db/database.dart';
import '../inventory/stock_reading.dart';
import '../sync/sync_review_repository.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import 'care_recording.dart';
import 'current_name_display.dart';
import 'local_occurrence_snapshot.dart';
import 'medication_amount.dart';
import 'medication_repository.dart';
import 'occurrence_materializer.dart';
import 'recorded_amount.dart';
import 'reviewed_stock.dart';
import 'stock_effect.dart' show stockUnitToAdopt;
import 'stock_plan.dart';
import '../inventory/exact_stock.dart';
import '../inventory/pill_stock.dart';
import '../sync/ledger_mode_hint.dart';

/// Captured labels are historical facts, even when their live parents change.
/// Missing legacy identity/authorship stays unknown and cannot grant writes.
class OccurrenceCareDetail {
  OccurrenceCareDetail({
    required this.occurrence,
    required this.snapshot,
    required this.personId,
    required this.personName,
    required this.medicationName,
    required this.originalDosage,
    required this.currentPerson,
    required this.currentMedication,
    required this.plannedAmount,
    required List<CareEventFacts> audit,
    required this.head,
    required this.sharing,
    required this.canRecord,
    required this.canUndo,
    this.currentStock,
    this.exactAfterTaking,
  }) : audit = List.unmodifiable(audit);

  final MedicationOccurrence occurrence;
  final ScheduleSnapshotV1? snapshot;
  final String? personId;
  final String? personName;
  final String? medicationName;
  final String? originalDosage;
  final Profile? currentPerson;
  final Pill? currentMedication;
  final MedicationAmount plannedAmount;
  final List<CareEventFacts> audit;
  final CareEventFacts? head;
  final CareSharingOutcome? sharing;
  final bool canRecord;
  final bool canUndo;

  /// The medication's stock as every screen shows it (see [readStock]).
  final StockReading? currentStock;

  /// What is left after taking this dose when a plain whole count would adopt
  /// the reviewed tablet unit and subtract the exact amount (for example
  /// 29.5 after half a tablet from 30). Null when the dose counts as one.
  final ExactStock? exactAfterTaking;
}

/// Resolves one occurrence, without a selected person, date or history window.
/// Every read revalidates the same captured workspace grant transactionally.
class OccurrenceDetailRepository {
  const OccurrenceDetailRepository({
    required this.database,
    required this.access,
    required this.context,
  });
  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final WorkspaceContext context;

  Future<OccurrenceCareDetail> load(
    String occurrenceId,
  ) => access.withGrant(context, () async {
    final occurrence = await database.medicationLedgerDao.getOccurrenceById(
      occurrenceId,
    );
    if (occurrence == null || occurrence.userId != context.ownerUserId) {
      throw const MedicationCommandBlocked('occurrence_missing');
    }
    final raw =
        jsonDecode(occurrence.scheduleSnapshotJson) as Map<String, dynamic>;
    if (!const {1, 2, 3}.contains(raw['version'])) {
      throw const MedicationCommandBlocked('occurrence_identity_unproven');
    }
    ScheduleSnapshotV1? snapshot;
    try {
      snapshot = decodeScheduleSnapshot(raw);
    } on Object {
      if (occurrence.provenance == 'exact' || raw['version'] != 1) {
        throw const MedicationCommandBlocked('occurrence_identity_unproven');
      }
      // Legacy estimates can lack labels/identity. They remain read-only.
    }
    if (snapshot != null &&
        (!snapshotOwns(snapshot, context.ownerUserId, context.workspaceId) ||
            snapshot.timeZone != occurrence.timeZone)) {
      throw const MedicationCommandBlocked('occurrence_identity_unproven');
    }
    String? text(String key) => raw[key] is String ? raw[key] as String : null;
    final personId = text('profileId');
    final candidatePerson = personId == null
        ? null
        : await database.profilesDao.getById(personId);
    final person = candidatePerson?.userId == context.ownerUserId
        ? candidatePerson
        : null;
    final candidatePill = occurrence.pillId == null
        ? null
        : await database.pillsDao.getById(occurrence.pillId!);
    final pill = person != null && candidatePill?.profileId == person.id
        ? candidatePill
        : null;
    final schedule = occurrence.scheduleId == null
        ? null
        : await database.schedulesDao.getById(occurrence.scheduleId!);

    final events = await database.medicationLedgerDao.getEventsForOccurrence(
      occurrence.id,
    );
    events.sort((a, b) {
      final version = a.resultVersion.compareTo(b.resultVersion);
      return version != 0 ? version : a.recordedAt.compareTo(b.recordedAt);
    });
    final audit = <CareEventFacts>[];
    for (final event in events) {
      if (event.userId != context.ownerUserId) {
        throw const MedicationCommandBlocked('occurrence_identity_unproven');
      }
      final facts =
          await (database.select(database.careEventDetails)..where(
                (d) =>
                    d.workspaceId.equals(context.workspaceId) &
                    d.eventId.equals(event.id),
              ))
              .getSingleOrNull();
      audit.add(
        CareEventFacts(
          event: event,
          amount: recordedAmountOf(event, detailAmountJson: facts?.amountJson),
          authorId: facts?.authorId,
          authorName: careAuthorName(facts, event),
          localReversalEventId: facts?.localReversalEventId,
          stock: facts == null
              ? CareStockOutcome.notTracked
              : CareStockOutcome.values.byName(facts.stockOutcome),
        ),
      );
    }
    // The same head rule as Today: an unsent event of a discarded command
    // does not compete with the event that really holds the version.
    final headIds = headEventsAt(
      audit.map((f) => f.event),
      occurrence.stateVersion,
      discardedCommandIds: await database.medicationLedgerDao
          .discardedCommandIds(context.ownerUserId),
    ).map((e) => e.id).toList();
    final head = headIds.length == 1
        ? audit.firstWhere((f) => f.event.id == headIds.single)
        : null;
    final operation = head == null
        ? null
        : await database.pendingOperationsDao.getByMutationId(
            context.ownerUserId,
            head.event.commandId,
          );
    final sharing = head == null
        ? null
        : context.isLocal
        ? CareSharingOutcome.localOnly
        : operation != null
        ? await operationSharingOutcome(database, context, operation)
        : head.event.serverId != null
        ? CareSharingOutcome.acknowledged
        : CareSharingOutcome.uncertain;
    final canRecord =
        snapshot != null &&
        occurrence.provenance == 'exact' &&
        occurrence.occurrenceKey.isNotEmpty &&
        occurrence.supersededAt == null &&
        (occurrence.source != 'scheduled' || occurrence.plannedAt != null) &&
        person != null &&
        !person.isDeleted &&
        pill != null &&
        !pill.isDeleted &&
        (occurrence.scheduleId == null ||
            (schedule != null &&
                !schedule.isDeleted &&
                schedule.pillId == pill.id)) &&
        (occurrence.stateVersion == 0 || head != null);
    // A pending dose shows the medication's current name, like Today; a
    // recorded dose keeps the name it was recorded under.
    final currentName = pill != null && showsCurrentName(occurrence.state)
        ? pill.name
        : null;
    final displayName = currentName != null && currentName.trim().isNotEmpty
        ? currentName
        : text('pillName');
    final unrecorded =
        occurrence.state == 'pending' || occurrence.state == 'missed';
    final reviewed = pill == null || snapshot is LocalOccurrenceSnapshot
        ? null
        : await reviewedAmountPerUse(database, pill.id);
    final plannedAmount = snapshot is LocalOccurrenceSnapshot
        ? snapshot.amount
        : !context.isLocal &&
              unrecorded &&
              occurrence.source == 'scheduled' &&
              reviewed != null
        ? reviewed
        : const MedicationAmount.unknown();
    ExactStock? exactAfterTaking;
    if (pill != null &&
        reviewed != null &&
        unrecorded &&
        !context.isLocal &&
        occurrence.source == 'scheduled' &&
        pill.currentStock != null) {
      final current = exactStockOf(pill);
      final unit = stockUnitToAdopt(
        tracked: true,
        stockUnit: pill.stockUnit,
        wholeCount: current?.isWhole ?? false,
        commandAmount: reviewed,
        amountPerUse: reviewed,
      );
      final dose = ExactStock.fromAmount(reviewed);
      if (current != null &&
          unit != null &&
          dose != null &&
          await LedgerModeHint.readFractionalStock()) {
        exactAfterTaking = current - dose;
      }
    }
    return OccurrenceCareDetail(
      occurrence: occurrence,
      snapshot: snapshot,
      personId: personId,
      personName: text('profileName'),
      medicationName: displayName,
      originalDosage: text('dosage'),
      currentPerson: person,
      currentMedication: pill,
      plannedAmount: plannedAmount,
      exactAfterTaking: exactAfterTaking,
      audit: audit,
      head: head,
      sharing: sharing,
      canRecord: canRecord,
      canUndo:
          canRecord &&
          head != null &&
          head.event.action != 'undo' &&
          head.event.origin != 'legacy_handoff',
      currentStock: pill == null
          ? null
          : readStock(
              pill,
              await (database.select(database.reviewedStockBalances)..where(
                    (b) =>
                        b.workspaceId.equals(context.workspaceId) &
                        b.pillId.equals(pill.id),
                  ))
                  .getSingleOrNull(),
              amountPerUse: snapshot is LocalOccurrenceSnapshot
                  ? snapshot.amount
                  : null,
            ),
    );
  });

  Stream<OccurrenceCareDetail> watch(String occurrenceId) => database
      .customSelect(
        // Drift shares identical SQL streams; keep this dependency set distinct.
        'SELECT 1 AS occurrence_detail_changes',
        readsFrom: {
          database.medicationOccurrences,
          database.occurrenceEvents,
          database.careEventDetails,
          database.pendingOperations,
          database.pendingOperationEffects,
          database.effectSettlements,
          database.migrationIssues,
          database.profiles,
          database.pills,
          database.reviewedStockBalances,
          database.schedules,
          database.careWorkspaces,
          database.workspaceGrants,
          database.workspaceAuthors,
          database.workspaceDeviceStates,
        },
      )
      .watch()
      .asyncMap((_) => load(occurrenceId));
}
