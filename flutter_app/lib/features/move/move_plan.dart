import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../core/db/database.dart';
import '../../core/inventory/stock_reading.dart';
import '../../core/medication/care_recording.dart' show careAuthorName;
import '../../core/medication/local_occurrence_snapshot.dart';
import '../../core/medication/medication_amount.dart';
import '../../core/medication/medication_command.dart';
import '../../core/medication/occurrence_materializer.dart';
import '../../core/medication/routine_definition.dart';
import '../../core/medication/routine_repository.dart';

/// The routine fields a connected schedule carries. The same shape describes
/// a schedule to create and the historical routine a moved dose was planned
/// under.
class MoveShape {
  const MoveShape({
    required this.frequency,
    this.frequencyDays,
    this.everyDays,
    this.anchorDate,
    this.startDate,
    this.endDate,
  });

  /// `daily`, `weekly`, `custom` or `interval`.
  final String frequency;
  final List<int>? frequencyDays;
  final int? everyDays;
  final String? anchorDate;
  final String? startDate;
  final String? endDate;

  /// Whether only a server with schedule windows can hold this shape.
  bool get needsWindows =>
      frequency == 'interval' || startDate != null || endDate != null;

  MoveShape withWindow({String? startDate, String? endDate}) => MoveShape(
    frequency: frequency,
    frequencyDays: frequencyDays,
    everyDays: everyDays,
    anchorDate: anchorDate,
    startDate: startDate,
    endDate: endDate,
  );

  Map<String, Object?> toJson() => {
    'frequency': frequency,
    'frequencyDays': frequencyDays,
    'everyDays': everyDays,
    'anchorDate': anchorDate,
    'startDate': startDate,
    'endDate': endDate,
  };

  @override
  bool operator ==(Object other) =>
      other is MoveShape && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;

  @override
  String toString() => 'MoveShape(${jsonEncode(toJson())})';
}

/// The connected shape of a scheduled device routine, with the routine's own
/// date window. Every-day intervals become plain daily routines that start on
/// their first day, so they need nothing new from the server.
MoveShape moveShapeFor(RoutineDefinition definition) {
  switch (definition.kind) {
    case RoutineKind.daily:
      return MoveShape(
        frequency: 'daily',
        startDate: definition.startDate,
        endDate: definition.endDate,
      );
    case RoutineKind.weekdays:
      final days = definition.weekdays;
      return MoveShape(
        frequency: days.length == 7
            ? 'daily'
            : days.length == 1
            ? 'weekly'
            : 'custom',
        frequencyDays: days.length == 7 ? null : List.unmodifiable(days),
        startDate: definition.startDate,
        endDate: definition.endDate,
      );
    case RoutineKind.interval:
      if (definition.everyDays == 1) {
        return MoveShape(
          frequency: 'daily',
          startDate: _laterDate(definition.anchorDate, definition.startDate),
          endDate: definition.endDate,
        );
      }
      return MoveShape(
        frequency: 'interval',
        everyDays: definition.everyDays,
        anchorDate: definition.anchorDate,
        startDate: definition.startDate,
        endDate: definition.endDate,
      );
    case RoutineKind.prn:
      throw ArgumentError('An as-needed routine has no schedule shape');
  }
}

String? _laterDate(String? a, String? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a.compareTo(b) >= 0 ? a : b;
}

String? _earlierDate(String? a, String? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a.compareTo(b) <= 0 ? a : b;
}

String _addDays(String date, int days) {
  final d = parseRoutineDate(date);
  return routineDateKey(DateTime.utc(d.year, d.month, d.day + days));
}

String _localDate(DateTime instant, String timeZone) {
  final local = tz.TZDateTime.from(instant, tz.getLocation(timeZone));
  return routineDateKey(DateTime.utc(local.year, local.month, local.day));
}

/// The first local date on which [slot]'s dose falls at or after [boundary].
String _firstDateFrom(DateTime boundary, RoutineTime slot, String timeZone) {
  final day = _localDate(boundary, timeZone);
  final planned = OccurrenceMaterializer.resolveReviewedLocalTime(
    localDate: day,
    hour: slot.hour,
    minute: slot.minute,
    timeZone: timeZone,
  );
  return planned.isBefore(boundary) ? _addDays(day, 1) : day;
}

/// The last local date on which [slot]'s dose falls before [boundary].
String _lastDateBefore(DateTime boundary, RoutineTime slot, String timeZone) {
  final day = _localDate(boundary, timeZone);
  final planned = OccurrenceMaterializer.resolveReviewedLocalTime(
    localDate: day,
    hour: slot.hour,
    minute: slot.minute,
    timeZone: timeZone,
  );
  return planned.isBefore(boundary) ? day : _addDays(day, -1);
}

/// One connected schedule the Move creates for one routine slot.
class MoveSchedule {
  const MoveSchedule({
    required this.routineId,
    required this.slotId,
    required this.revision,
    required this.pillId,
    required this.hour,
    required this.minute,
    required this.timeZone,
    required this.shape,
    required this.isActive,
  });

  final String routineId;
  final String slotId;

  /// Null for the slot's routine in force today (or the slot's only
  /// schedule); a later version's revision otherwise.
  final int? revision;

  /// The local medication this schedule belongs to.
  final String pillId;
  final int hour;
  final int minute;
  final String timeZone;
  final MoveShape shape;

  /// False for a slot that only exists in past history, or whose routine has
  /// already ended: it keeps its history but owes nothing new.
  final bool isActive;

  bool covers(String localDate) =>
      (shape.startDate == null || localDate.compareTo(shape.startDate!) >= 0) &&
      (shape.endDate == null || localDate.compareTo(shape.endDate!) <= 0);
}

/// The connected schedules a routine's [versions] (oldest first) become.
///
/// The version in force at [now] and every later version each get one
/// schedule per slot, windowed by the version's own dates and by the
/// boundaries where the next version takes over. A boundary only becomes a
/// start date when it is later than today, because a new schedule never
/// plans anything before the day it is created. A slot found only in older
/// versions gets an inactive schedule so its history has somewhere to go.
List<MoveSchedule> moveSchedulesFor(
  String pillId,
  List<LocalRoutine> versions,
  DateTime now,
) {
  if (versions.isEmpty) return const [];
  final definitions = [
    for (final v in versions)
      RoutineDefinition.fromJson(
        jsonDecode(v.definitionJson) as Map<String, dynamic>,
      ),
  ];
  var current = 0;
  for (var i = 0; i < versions.length; i++) {
    if (!versions[i].effectiveFrom.isAfter(now)) current = i;
  }
  final result = <MoveSchedule>[];
  final baseSlots = <String>{};
  for (var i = current; i < versions.length; i++) {
    final definition = definitions[i];
    if (definition.kind == RoutineKind.prn) continue;
    final shape = moveShapeFor(definition);
    final today = _localDate(now, definition.timeZone);
    final lower = versions[i].effectiveFrom;
    final upper = i + 1 < versions.length
        ? versions[i + 1].effectiveFrom
        : null;
    for (final slot in definition.times) {
      final fromBoundary = _firstDateFrom(lower, slot, definition.timeZone);
      var start = shape.startDate;
      if (fromBoundary.compareTo(today) > 0) {
        start = _laterDate(start, fromBoundary);
      }
      final end = upper == null
          ? shape.endDate
          : _earlierDate(
              shape.endDate,
              _lastDateBefore(upper, slot, definition.timeZone),
            );
      final empty = start != null && end != null && end.compareTo(start) < 0;
      final ended = end != null && end.compareTo(today) < 0;
      final base = i == current || !baseSlots.contains(slot.slotId);
      if (empty && !base) continue;
      if (base) baseSlots.add(slot.slotId);
      result.add(
        MoveSchedule(
          routineId: versions[i].routineId,
          slotId: slot.slotId,
          revision: base ? null : versions[i].revision,
          pillId: pillId,
          hour: slot.hour,
          minute: slot.minute,
          timeZone: definition.timeZone,
          // An ended or empty window owes nothing new: the schedule stays,
          // inactive, for its history, without dates an older app cannot read.
          shape: empty || ended
              ? shape.withWindow()
              : shape.withWindow(startDate: start, endDate: end),
          isActive: !empty && !ended,
        ),
      );
    }
  }
  // Slots that only older versions had keep their history on an inactive
  // schedule shaped like the last version that planned them.
  for (var i = current - 1; i >= 0; i--) {
    final definition = definitions[i];
    if (definition.kind == RoutineKind.prn) continue;
    for (final slot in definition.times) {
      if (!baseSlots.add(slot.slotId)) continue;
      result.add(
        MoveSchedule(
          routineId: versions[i].routineId,
          slotId: slot.slotId,
          revision: null,
          pillId: pillId,
          hour: slot.hour,
          minute: slot.minute,
          timeZone: definition.timeZone,
          shape: moveShapeFor(definition).withWindow(),
          isActive: false,
        ),
      );
    }
  }
  return result;
}

/// The state a copied dose ends in, and the facts of the entry that put it
/// there. Copying records only this final state: undone and corrected
/// entries along the way stay on the phone.
class MoveFinalState {
  const MoveFinalState({
    required this.action,
    required this.actualAt,
    required this.actualTimeKnown,
    required this.note,
    required this.amount,
    this.authorName,
  });

  final MedicationAction action;
  final DateTime? actualAt;
  final bool actualTimeKnown;
  final String? note;
  final MedicationAmount amount;

  /// Who gave the original dose, when this phone knows. Null names nobody, so
  /// the copy shares no name rather than the mover's.
  final String? authorName;
}

/// One past (or already recorded) scheduled dose to copy.
class MoveHistoryItem {
  const MoveHistoryItem({
    required this.occurrence,
    required this.schedule,
    required this.routine,
    required this.finalState,
  });

  final MedicationOccurrence occurrence;

  /// The connected schedule the dose belongs to.
  final MoveSchedule schedule;

  /// The routine the dose was planned under.
  final MoveShape routine;

  /// Null for a dose nobody recorded; it is copied as not recorded.
  final MoveFinalState? finalState;

  /// `HH:mm`, as the moved-history request takes it.
  String get plannedLocalTime => occurrence.plannedLocalTime!.substring(0, 5);
}

/// One recorded as-needed dose to copy.
class MovePrnDose {
  const MovePrnDose({
    required this.occurrence,
    required this.pillId,
    required this.personId,
    required this.finalState,
  });

  final MedicationOccurrence occurrence;
  final String pillId;
  final String personId;
  final MoveFinalState finalState;
}

class MoveMedication {
  const MoveMedication({
    required this.pill,
    required this.detail,
    required this.stock,
    required this.isPrn,
  });

  final Pill pill;
  final MedicationDetail? detail;
  final StockReading? stock;

  /// Whether the medication is taken as needed today.
  final bool isPrn;

  /// True when the phone's count has no exact decimal (a third of a tablet),
  /// which the account cannot hold: the person recounts it first.
  bool get needsRecount => stock != null && stock!.exact == null;

  /// True when the count is a part of a unit (half a tablet): only a server
  /// with exact stock can hold it. A whole count moves as a plain number.
  bool get needsFractionalStock =>
      stock?.exact != null && !stock!.exact!.isWhole;

  MedicationAmount get amount {
    final json = detail?.amountJson;
    if (json == null) return const MedicationAmount.unknown();
    try {
      return MedicationAmount.fromJson(
        Map<String, Object?>.from(jsonDecode(json) as Map),
      );
    } on Object {
      return const MedicationAmount.unknown();
    }
  }
}

/// What stays on the phone because the account has no place for it.
enum MoveLeftBehindKind {
  /// Doses recorded before routines existed, with estimated times.
  legacyHistory,

  /// As-needed doses of a medication that is no longer taken as needed.
  asNeededHistory,
}

class MoveLeftBehind {
  const MoveLeftBehind(this.kind, this.count);
  final MoveLeftBehindKind kind;
  final int count;
}

/// Everything the Move will copy, read from this phone's own care.
class MovePlan {
  const MovePlan({
    required this.localWorkspaceId,
    required this.localOwnerId,
    required this.people,
    required this.medications,
    required this.schedules,
    required this.history,
    required this.prnDoses,
    required this.leftBehind,
  });

  final String localWorkspaceId;
  final String localOwnerId;
  final List<Profile> people;
  final List<MoveMedication> medications;
  final List<MoveSchedule> schedules;
  final List<MoveHistoryItem> history;
  final List<MovePrnDose> prnDoses;
  final List<MoveLeftBehind> leftBehind;

  bool get isEmpty => people.isEmpty;

  /// Whether the server must accept every-few-days routines and dates.
  bool get needsScheduleWindows =>
      schedules.any((s) => s.shape.needsWindows) ||
      history.any((h) => h.routine.needsWindows);

  /// Whether the server must accept past scheduled doses.
  bool get needsMovedHistory => history.isNotEmpty;

  List<MoveMedication> medicationsOf(String personId) =>
      medications.where((m) => m.pill.profileId == personId).toList();
}

/// The final state of [occurrence], taken from the latest entry that put it
/// there. Null while the dose is still pending.
MoveFinalState? moveFinalState(
  MedicationOccurrence occurrence,
  List<OccurrenceEvent> events,
  Map<String, CareEventDetail> details,
) {
  final state = MedicationState.values.byName(occurrence.state);
  if (state == MedicationState.pending) return null;
  final reaching = events.where((e) => e.toState == occurrence.state).toList()
    ..sort((a, b) => a.resultVersion.compareTo(b.resultVersion));
  final last = reaching.isEmpty ? null : reaching.last;
  final amountJson =
      details[last?.id]?.amountJson ?? last?.administrationAmountJson;
  var amount = const MedicationAmount.unknown();
  if (amountJson != null) {
    try {
      amount = MedicationAmount.fromJson(
        Map<String, Object?>.from(jsonDecode(amountJson) as Map),
      );
    } on Object {
      amount = const MedicationAmount.unknown();
    }
  }
  final action = switch (state) {
    MedicationState.taken => MedicationAction.take,
    MedicationState.skipped => MedicationAction.skip,
    MedicationState.missed => MedicationAction.miss,
    MedicationState.pending => throw StateError('pending'),
  };
  // A miss carries no time; a take or skip keeps the time it was recorded
  // with, when that time was known.
  final known =
      action != MedicationAction.miss &&
      last?.actualTimeKnown == true &&
      last?.actualAt != null;
  return MoveFinalState(
    action: action,
    actualAt: known ? last!.actualAt!.toUtc() : null,
    actualTimeKnown: known,
    note: action == MedicationAction.miss ? null : last?.note,
    amount: action == MedicationAction.take
        ? amount
        : const MedicationAmount.unknown(),
    authorName: action == MedicationAction.miss
        ? null
        : last == null
        ? null
        : careAuthorName(details[last.id], last),
  );
}

/// Reads the plan for moving the care in the local workspace [local]. Reads
/// only; nothing on the phone changes.
Future<MovePlan> readMovePlan(
  AppDatabase db,
  CareWorkspace local, {
  DateTime? now,
}) async {
  final at = (now ?? DateTime.now()).toUtc();
  final owner = local.ownerUserId;
  final people =
      await (db.select(db.profiles)
            ..where((p) => p.userId.equals(owner) & p.isDeleted.equals(false))
            ..orderBy([(p) => OrderingTerm.asc(p.createdAt)]))
          .get();
  final personIds = {for (final p in people) p.id};
  final pills = personIds.isEmpty
      ? <Pill>[]
      : await (db.select(db.pills)
              ..where(
                (p) => p.profileId.isIn(personIds) & p.isDeleted.equals(false),
              )
              ..orderBy([(p) => OrderingTerm.asc(p.createdAt)]))
            .get();
  final pillIds = {for (final p in pills) p.id};
  final details = {
    for (final d in await (db.select(
      db.medicationDetails,
    )..where((d) => d.pillId.isIn(pillIds))).get())
      d.pillId: d,
  };
  final balances = {
    for (final b
        in await (db.select(db.reviewedStockBalances)..where(
              (b) => b.workspaceId.equals(local.id) & b.pillId.isIn(pillIds),
            ))
            .get())
      b.pillId: b,
  };
  final routineRows =
      await (db.select(db.localRoutines)
            ..where(
              (r) => r.workspaceId.equals(local.id) & r.pillId.isIn(pillIds),
            )
            ..orderBy([(r) => OrderingTerm.asc(r.revision)]))
          .get();
  final routines = <String, List<LocalRoutine>>{};
  for (final row in routineRows) {
    routines.putIfAbsent(row.routineId, () => []).add(row);
  }

  final medications = <MoveMedication>[];
  final schedules = <MoveSchedule>[];
  for (final pill in pills) {
    var isPrn = false;
    for (final versions in routines.values) {
      if (versions.first.pillId != pill.id) continue;
      final inForce = versions.lastWhere(
        (v) => !v.effectiveFrom.isAfter(at),
        orElse: () => versions.first,
      );
      final definition = RoutineDefinition.fromJson(
        jsonDecode(inForce.definitionJson) as Map<String, dynamic>,
      );
      if (definition.kind == RoutineKind.prn) {
        isPrn = true;
      } else {
        schedules.addAll(moveSchedulesFor(pill.id, versions, at));
      }
    }
    medications.add(
      MoveMedication(
        pill: pill,
        detail: details[pill.id],
        stock: readStock(
          pill,
          balances[pill.id],
          amountPerUse: amountOfDetailRow(details[pill.id]),
        ),
        isPrn: isPrn,
      ),
    );
  }

  final occurrences =
      await (db.select(db.medicationOccurrences)
            ..where(
              (o) =>
                  o.userId.equals(owner) &
                  o.supersededAt.isNull() &
                  o.pillId.isIn(pillIds),
            )
            ..orderBy([
              (o) => OrderingTerm.asc(o.plannedLocalDate),
              (o) => OrderingTerm.asc(o.createdAt),
            ]))
          .get();
  final occurrenceIds = [for (final o in occurrences) o.id];
  final eventsByOccurrence = <String, List<OccurrenceEvent>>{};
  for (final event in await (db.select(
    db.occurrenceEvents,
  )..where((e) => e.occurrenceId.isIn(occurrenceIds))).get()) {
    eventsByOccurrence.putIfAbsent(event.occurrenceId, () => []).add(event);
  }
  final eventDetails = {
    for (final d in await (db.select(
      db.careEventDetails,
    )..where((d) => d.workspaceId.equals(local.id))).get())
      d.eventId: d,
  };
  final prnPills = {
    for (final m in medications)
      if (m.isPrn) m.pill.id,
  };
  final pillsById = {for (final p in pills) p.id: p};

  final history = <MoveHistoryItem>[];
  final prnDoses = <MovePrnDose>[];
  var legacy = 0;
  var orphanPrn = 0;
  for (final occurrence in occurrences) {
    final events = eventsByOccurrence[occurrence.id] ?? const [];
    final finalState = moveFinalState(occurrence, events, eventDetails);
    switch (occurrence.source) {
      case 'legacy':
        legacy++;
      case 'prn':
        if (occurrence.state != 'taken') continue;
        if (!prnPills.contains(occurrence.pillId)) {
          orphanPrn++;
          continue;
        }
        prnDoses.add(
          MovePrnDose(
            occurrence: occurrence,
            pillId: occurrence.pillId!,
            personId: pillsById[occurrence.pillId]!.profileId,
            finalState: finalState!,
          ),
        );
      case 'scheduled':
        final planned = occurrence.plannedAt;
        if (planned == null || occurrence.plannedLocalTime == null) continue;
        // A future dose nobody recorded is planned again by the account.
        if (planned.isAfter(at) && finalState == null) continue;
        final snapshot = decodeScheduleSnapshot(
          jsonDecode(occurrence.scheduleSnapshotJson) as Map<String, dynamic>,
        );
        if (snapshot is! LocalOccurrenceSnapshot) continue;
        final target = _scheduleFor(
          schedules,
          snapshot.routineId,
          snapshot.slotId,
          occurrence.plannedLocalDate,
        );
        if (target == null) continue;
        history.add(
          MoveHistoryItem(
            occurrence: occurrence,
            schedule: target,
            routine: moveShapeFor(snapshot.routineDefinition),
            finalState: finalState,
          ),
        );
    }
  }
  return MovePlan(
    localWorkspaceId: local.id,
    localOwnerId: owner,
    people: people,
    medications: medications,
    schedules: schedules,
    history: history,
    prnDoses: prnDoses,
    leftBehind: [
      if (legacy > 0) MoveLeftBehind(MoveLeftBehindKind.legacyHistory, legacy),
      if (orphanPrn > 0)
        MoveLeftBehind(MoveLeftBehindKind.asNeededHistory, orphanPrn),
    ],
  );
}

/// The schedule of [routineId]'s [slotId] whose window holds [localDate]:
/// a later version's schedule when the date falls in it, else the slot's
/// plain schedule.
MoveSchedule? _scheduleFor(
  List<MoveSchedule> schedules,
  String routineId,
  String slotId,
  String localDate,
) {
  MoveSchedule? base;
  for (final s in schedules) {
    if (s.routineId != routineId || s.slotId != slotId) continue;
    if (s.revision == null) {
      base = s;
    } else if (s.covers(localDate)) {
      return s;
    }
  }
  return base;
}
