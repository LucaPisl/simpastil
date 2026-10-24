import 'package:drift/drift.dart';

import '../../inventory/exact_stock.dart';
import '../database.dart';
import '../tables/inventory_events_table.dart';
import '../tables/medication_occurrences_table.dart';
import '../tables/occurrence_events_table.dart';

part 'medication_ledger_dao.g.dart';

class MedicationOccurrenceRecord {
  const MedicationOccurrenceRecord({
    required this.occurrence,
    required this.events,
  });

  final MedicationOccurrence occurrence;
  final List<OccurrenceEvent> events;
}

/// The events that compete for an occurrence's head at [version].
///
/// An unsent event whose command was discarded never reached the server and
/// was left behind by the occurrence repair on purpose; it must not compete
/// with the event that really holds the version.
List<OccurrenceEvent> headEventsAt(
  Iterable<OccurrenceEvent> events,
  int version, {
  Set<String> discardedCommandIds = const {},
}) => [
  for (final e in events)
    if (e.resultVersion == version &&
        !(e.serverId == null && discardedCommandIds.contains(e.commandId)))
      e,
];

@DriftAccessor(
  tables: [MedicationOccurrences, OccurrenceEvents, InventoryEvents],
)
class MedicationLedgerDao extends DatabaseAccessor<AppDatabase>
    with _$MedicationLedgerDaoMixin {
  MedicationLedgerDao(super.db);

  Future<MedicationOccurrence?> getOccurrenceById(String id) => (select(
    medicationOccurrences,
  )..where((row) => row.id.equals(id))).getSingleOrNull();

  Future<MedicationOccurrence?> getOccurrenceByKey(
    String userId,
    String occurrenceKey,
  ) =>
      (select(medicationOccurrences)..where(
            (row) =>
                row.userId.equals(userId) &
                row.occurrenceKey.equals(occurrenceKey),
          ))
          .getSingleOrNull();

  Future<MedicationOccurrence?> getOccurrenceByServerId(String serverId) =>
      (select(
        medicationOccurrences,
      )..where((row) => row.serverId.equals(serverId))).getSingleOrNull();

  Future<List<MedicationOccurrence>> getOccurrencesForUser(String userId) =>
      (select(medicationOccurrences)
            ..where((row) => row.userId.equals(userId))
            ..orderBy([
              (row) => OrderingTerm.asc(row.plannedAt),
              (row) => OrderingTerm.asc(row.id),
            ]))
          .get();

  Future<List<MedicationOccurrence>> getOccurrencesForSchedule(
    String scheduleId,
  ) =>
      (select(medicationOccurrences)
            ..where((row) => row.scheduleId.equals(scheduleId))
            ..orderBy([
              (row) => OrderingTerm.asc(row.plannedLocalDate),
              (row) => OrderingTerm.asc(row.plannedAt),
            ]))
          .get();

  Future<List<MedicationOccurrenceRecord>> getForUserLocalDateRange(
    String userId,
    String fromLocalDate,
    String throughLocalDate,
  ) async {
    final query = _occurrenceRangeQuery(
      userId,
      fromLocalDate,
      throughLocalDate,
    );
    return _groupJoinedOccurrenceRows(await query.get());
  }

  Stream<List<MedicationOccurrenceRecord>> watchForUserLocalDateRange(
    String userId,
    String fromLocalDate,
    String throughLocalDate,
  ) {
    final query = _occurrenceRangeQuery(
      userId,
      fromLocalDate,
      throughLocalDate,
    );
    return query.watch().map(_groupJoinedOccurrenceRows);
  }

  Selectable<TypedResult> _occurrenceRangeQuery(
    String userId,
    String fromLocalDate,
    String throughLocalDate,
  ) {
    final query =
        select(medicationOccurrences).join([
            leftOuterJoin(
              occurrenceEvents,
              occurrenceEvents.occurrenceId.equalsExp(medicationOccurrences.id),
            ),
          ])
          ..where(
            medicationOccurrences.userId.equals(userId) &
                medicationOccurrences.plannedLocalDate.isBiggerOrEqualValue(
                  fromLocalDate,
                ) &
                medicationOccurrences.plannedLocalDate.isSmallerOrEqualValue(
                  throughLocalDate,
                ),
          )
          ..orderBy([
            OrderingTerm.asc(medicationOccurrences.plannedLocalDate),
            OrderingTerm.asc(medicationOccurrences.plannedAt),
            OrderingTerm.asc(occurrenceEvents.resultVersion),
          ]);
    return query;
  }

  List<MedicationOccurrenceRecord> _groupJoinedOccurrenceRows(
    List<TypedResult> rows,
  ) {
    final grouped =
        <
          String,
          ({MedicationOccurrence occurrence, List<OccurrenceEvent> events})
        >{};
    for (final row in rows) {
      final occurrence = row.readTable(medicationOccurrences);
      final record = grouped.putIfAbsent(
        occurrence.id,
        () => (occurrence: occurrence, events: <OccurrenceEvent>[]),
      );
      final event = row.readTableOrNull(occurrenceEvents);
      if (event != null) record.events.add(event);
    }
    return [
      for (final value in grouped.values)
        MedicationOccurrenceRecord(
          occurrence: value.occurrence,
          events: List.unmodifiable(value.events),
        ),
    ];
  }

  /// Occurrences are mutable projections; their audit events are append-only.
  Future<void> upsertOccurrence(MedicationOccurrencesCompanion occurrence) =>
      into(medicationOccurrences).insertOnConflictUpdate(occurrence);

  Future<int> supersedeOccurrence({
    required String id,
    required DateTime supersededAt,
    required String? supersededByOccurrenceId,
  }) =>
      (update(medicationOccurrences)..where((row) => row.id.equals(id))).write(
        MedicationOccurrencesCompanion(
          supersededAt: Value(supersededAt),
          supersededByOccurrenceId: Value(supersededByOccurrenceId),
          updatedAt: Value(supersededAt),
        ),
      );

  Future<void> appendOccurrenceEvent(OccurrenceEventsCompanion event) =>
      into(occurrenceEvents).insert(event);

  Future<OccurrenceEvent?> getOccurrenceEventByServerId(String serverId) =>
      (select(
        occurrenceEvents,
      )..where((row) => row.serverId.equals(serverId))).getSingleOrNull();

  Future<OccurrenceEvent?> getOccurrenceEventByCommandId(String commandId) =>
      (select(
        occurrenceEvents,
      )..where((row) => row.commandId.equals(commandId))).getSingleOrNull();

  Future<int> updateOccurrenceEvent(
    String localId,
    OccurrenceEventsCompanion event,
  ) => (update(
    occurrenceEvents,
  )..where((row) => row.id.equals(localId))).write(event);

  Future<List<OccurrenceEvent>> getEventsForOccurrence(String occurrenceId) =>
      (select(occurrenceEvents)
            ..where((row) => row.occurrenceId.equals(occurrenceId))
            ..orderBy([(row) => OrderingTerm.asc(row.recordedAt)]))
          .get();

  /// Command ids of this person's discarded pending operations.
  Future<Set<String>> discardedCommandIds(String userId) async {
    final rows = await customSelect(
      'SELECT mutation_id FROM pending_operations '
      "WHERE user_id = ? AND state = 'discarded'",
      variables: [Variable<String>(userId)],
    ).get();
    return {for (final r in rows) r.read<String>('mutation_id')};
  }

  Future<void> appendInventoryEvent(InventoryEventsCompanion event) =>
      into(inventoryEvents).insert(event);

  Future<InventoryEvent?> getInventoryEventByServerId(String serverId) =>
      (select(
        inventoryEvents,
      )..where((row) => row.serverId.equals(serverId))).getSingleOrNull();

  Future<InventoryEvent?> getInventoryEventByCommandId(String commandId) =>
      (select(
        inventoryEvents,
      )..where((row) => row.commandId.equals(commandId))).getSingleOrNull();

  Future<int> updateInventoryEvent(
    String localId,
    InventoryEventsCompanion event,
  ) => (update(
    inventoryEvents,
  )..where((row) => row.id.equals(localId))).write(event);

  Future<List<InventoryEvent>> getInventoryEventsForPill(String pillId) =>
      (select(inventoryEvents)
            ..where((row) => row.pillId.equals(pillId))
            ..orderBy([(row) => OrderingTerm.asc(row.recordedAt)]))
          .get();

  Future<ExactStock> getInventoryBalance(String pillId) async {
    final rows =
        await (selectOnly(inventoryEvents)
              ..addColumns([inventoryEvents.delta])
              ..where(inventoryEvents.pillId.equals(pillId)))
            .get();
    return sumExact(
      rows.map((row) => ExactStock.parseWire(row.read(inventoryEvents.delta)!)),
    );
  }
}
