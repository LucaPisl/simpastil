import 'package:drift/drift.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../core/db/database.dart';
import '../../core/errors/app_error.dart';
import '../../core/medication/care_recording.dart';
import '../../core/medication/medication_extras.dart';
import '../../core/medication/medication_repository.dart';
import '../../core/medication/recorded_by.dart';
import '../../core/medication/routine_definition.dart';
import '../../core/medication/stock_effect.dart' show isCountableStockUnit;
import '../../core/medication/schedule_window.dart';
import '../../core/sync/capabilities_client.dart';
import '../../core/workspace/workspace_access_repository.dart';
import '../../core/workspace/workspace_context.dart';
import '../pills/pill_repository.dart';
import '../pills/schedule_repository.dart';
import '../profiles/profile_repository.dart';
import 'move_ids.dart';
import 'move_plan.dart';
import 'moved_history_client.dart';

/// The Move's steps, in order, for progress on screen.
enum MoveStep { copying, history, recording, stock, checking }

/// Why a Move stopped. Every step can run again: copied records keep stable
/// ids, so a second run continues where the first one stopped.
enum MoveFailureCode {
  /// The server cannot hold part of this care yet.
  serverNeedsUpdate,

  /// The server did not take the copied people, medications or routines.
  copyNotSent,

  /// A copied dose could not be found on the account after sending it.
  historyNotFound,

  /// Something was copied but the account does not show it yet.
  notVerified,

  /// A stock count on the phone has no exact decimal (a third of a tablet), so
  /// it must be recounted before it can move.
  stockNeedsRecount,

  /// A count on this phone is a part of a unit and the account's server is
  /// too old to hold it.
  stockServerNeedsUpdate,
}

class MoveFailure implements Exception {
  const MoveFailure(this.code);
  final MoveFailureCode code;
  @override
  String toString() => 'MoveFailure(${code.name})';
}

/// What the server must offer before [plan] can move. Null when it is ready.
MoveFailureCode? moveServerGap(MovePlan plan, ServerCapabilities? server) {
  if (server == null) return MoveFailureCode.serverNeedsUpdate;
  if (plan.medications.any((m) => m.needsRecount)) {
    return MoveFailureCode.stockNeedsRecount;
  }
  if (!server.fractionalStock &&
      plan.medications.any((m) => m.needsFractionalStock)) {
    return MoveFailureCode.stockServerNeedsUpdate;
  }
  final hasDoses = plan.history.any((h) => h.finalState != null);
  if ((hasDoses || plan.prnDoses.isNotEmpty) &&
      !server.medicationLedgerActive) {
    return MoveFailureCode.serverNeedsUpdate;
  }
  if (plan.needsScheduleWindows && !server.scheduleWindows) {
    return MoveFailureCode.serverNeedsUpdate;
  }
  if (plan.needsMovedHistory && !server.movedHistory) {
    return MoveFailureCode.serverNeedsUpdate;
  }
  if (plan.prnDoses.isNotEmpty && !server.ledgerPrn) {
    return MoveFailureCode.serverNeedsUpdate;
  }
  return null;
}

/// The people on the account whose names match one of the phone's people,
/// keyed by the phone's person id. The Move asks about each before copying;
/// it never merges two people on its own.
Future<Map<String, Profile>> moveDuplicates(
  AppDatabase db,
  MovePlan plan,
  WorkspaceContext connected,
) async {
  final ids = MoveIds(connected.ownerUserId);
  final account =
      await (db.select(db.profiles)..where(
            (p) =>
                p.userId.equals(connected.ownerUserId) &
                p.isDeleted.equals(false),
          ))
          .get();
  String key(String name) => name.trim().toLowerCase();
  final result = <String, Profile>{};
  for (final person in plan.people) {
    final copyId = ids.person(person.id);
    for (final other in account) {
      // A person this Move already copied is not a duplicate.
      if (other.id == copyId) continue;
      if (key(other.name) == key(person.name)) {
        result[person.id] = other;
        break;
      }
    }
  }
  return result;
}

/// What a finished Move did.
class MoveOutcome {
  const MoveOutcome({
    required this.people,
    required this.medications,
    required this.doses,
  });
  final int people;
  final int medications;

  /// Recorded doses now on the account, scheduled and as needed.
  final int doses;
}

/// Copies the phone's own care to the signed-in account, as the account's
/// own records, then checks the account shows all of it. Nothing on the
/// phone changes; removing the phone's copy is a separate choice made after
/// the check passes.
class MoveCareService {
  MoveCareService({
    required this.database,
    required this.access,
    required this.connected,
    required this.profiles,
    required this.pills,
    required this.schedules,
    required this.recording,
    required this.movedHistory,
    required this.sync,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final WorkspaceContext connected;
  final ProfileRepository profiles;
  final PillRepository pills;
  final ScheduleRepository schedules;
  final CareRecordingService recording;
  final MovedHistoryClient movedHistory;

  /// Sends everything waiting and pulls the account's current state.
  final Future<void> Function() sync;
  final DateTime Function() _clock;

  MoveIds get _ids => MoveIds(connected.ownerUserId);

  Future<MoveOutcome> run(
    MovePlan plan, {
    Set<String> skipPeople = const {},
    void Function(MoveStep step)? onStep,
  }) async {
    final people = [
      for (final p in plan.people)
        if (!skipPeople.contains(p.id)) p,
    ];
    final kept = {for (final p in people) p.id};
    final medications = [
      for (final m in plan.medications)
        if (kept.contains(m.pill.profileId)) m,
    ];
    final pillIds = {for (final m in medications) m.pill.id};
    final scheduleList = [
      for (final s in plan.schedules)
        if (pillIds.contains(s.pillId)) s,
    ];
    final history = [
      for (final h in plan.history)
        if (pillIds.contains(h.schedule.pillId)) h,
    ];
    final prnDoses = [
      for (final d in plan.prnDoses)
        if (pillIds.contains(d.pillId)) d,
    ];

    onStep?.call(MoveStep.copying);
    await _copyCare(people, medications, scheduleList);
    await sync();
    await _requireSent(people, medications, scheduleList);

    onStep?.call(MoveStep.history);
    final now = _clock().toUtc();
    final past = [
      for (final h in history)
        if (!h.occurrence.plannedAt!.isAfter(now)) h,
    ];
    await _sendHistory(past);
    await sync();

    onStep?.call(MoveStep.recording);
    final personOf = {for (final m in medications) m.pill.id: m.pill.profileId};
    var doses = 0;
    for (final item in history) {
      if (item.finalState == null) continue;
      await _recordScheduled(item, personOf[item.schedule.pillId]!);
      doses++;
    }
    for (final dose in prnDoses) {
      await _recordPrn(dose);
      doses++;
    }

    onStep?.call(MoveStep.stock);
    await _setStock(medications);

    onStep?.call(MoveStep.checking);
    await sync();
    await _verify(history, prnDoses);
    return MoveOutcome(
      people: people.length,
      medications: medications.length,
      doses: doses,
    );
  }

  T _ok<T>(Result<T> result) => switch (result) {
    Ok(:final value) => value,
    Err() => throw const MoveFailure(MoveFailureCode.copyNotSent),
  };

  String _scheduleId(MoveSchedule s) =>
      _ids.schedule(s.routineId, s.slotId, revision: s.revision);

  Future<void> _copyCare(
    List<Profile> people,
    List<MoveMedication> medications,
    List<MoveSchedule> scheduleList,
  ) async {
    for (final person in people) {
      final id = _ids.person(person.id);
      if (await database.profilesDao.getById(id) != null) continue;
      _ok(await profiles.create(person.name, person.avatarEmoji, id: id));
    }
    for (final medication in medications) {
      final pill = medication.pill;
      final id = _ids.medication(pill.id);
      if (await database.pillsDao.getById(id) != null) continue;
      // Stock starts untracked: copied doses must not lower it, and the
      // phone's own count is set once they are all recorded.
      _ok(
        await pills.create(
          profileId: _ids.person(pill.profileId),
          name: pill.name,
          dosage: pill.dosage,
          notes: pill.notes,
          color: pill.color,
          lowStockThreshold: pill.lowStockThreshold,
          isPrn: medication.isPrn,
          amount: medication.amount,
          packageStrength: medication.detail?.packageStrength,
          form: medication.detail?.form,
          legacyDosageReviewed:
              medication.detail?.legacyDosageReviewed ?? false,
          shape: pill.shape,
          extras: MedicationExtras.fromPill(pill),
          id: id,
        ),
      );
    }
    for (final schedule in scheduleList) {
      final id = _scheduleId(schedule);
      if (await database.schedulesDao.getById(id) != null) continue;
      final shape = schedule.shape;
      _ok(
        await schedules.create(
          pillId: _ids.medication(schedule.pillId),
          hour: schedule.hour,
          minute: schedule.minute,
          frequency: shape.frequency,
          frequencyDays: shape.frequencyDays,
          isActive: schedule.isActive,
          timeZone: schedule.timeZone,
          window: ScheduleWindow(
            everyDays: shape.everyDays,
            anchorDate: shape.anchorDate,
            startDate: shape.startDate,
            endDate: shape.endDate,
          ),
          id: id,
        ),
      );
    }
  }

  Future<void> _requireSent(
    List<Profile> people,
    List<MoveMedication> medications,
    List<MoveSchedule> scheduleList,
  ) async {
    for (final person in people) {
      final row = await database.profilesDao.getById(_ids.person(person.id));
      if (row?.serverId == null) {
        throw const MoveFailure(MoveFailureCode.copyNotSent);
      }
    }
    for (final medication in medications) {
      final row = await database.pillsDao.getById(
        _ids.medication(medication.pill.id),
      );
      if (row?.serverId == null) {
        throw const MoveFailure(MoveFailureCode.copyNotSent);
      }
    }
    for (final schedule in scheduleList) {
      final row = await database.schedulesDao.getById(_scheduleId(schedule));
      if (row?.serverId == null) {
        throw const MoveFailure(MoveFailureCode.copyNotSent);
      }
    }
  }

  Future<void> _sendHistory(List<MoveHistoryItem> past) async {
    final bySchedule = <String, List<MoveHistoryItem>>{};
    for (final item in past) {
      bySchedule.putIfAbsent(_scheduleId(item.schedule), () => []).add(item);
    }
    for (final entry in bySchedule.entries) {
      final items = entry.value;
      for (var i = 0; i < items.length; i += MovedHistoryClient.maxItems) {
        final end = i + MovedHistoryClient.maxItems < items.length
            ? i + MovedHistoryClient.maxItems
            : items.length;
        await movedHistory.send(
          scheduleId: entry.key,
          items: items.sublist(i, end),
          ids: _ids,
        );
      }
    }
  }

  /// The account's dose for [item]: the one its schedule holds for the same
  /// day and time, whichever side planned it.
  Future<MedicationOccurrence?> _connectedOccurrence(
    MoveHistoryItem item,
  ) async {
    final rows = await database.medicationLedgerDao.getOccurrencesForSchedule(
      _scheduleId(item.schedule),
    );
    for (final row in rows) {
      if (row.userId == connected.ownerUserId &&
          row.supersededAt == null &&
          row.plannedLocalDate == item.occurrence.plannedLocalDate &&
          row.plannedLocalTime == item.occurrence.plannedLocalTime) {
        return row;
      }
    }
    return null;
  }

  Future<void> _recordScheduled(MoveHistoryItem item, String personId) async {
    final target = await _connectedOccurrence(item);
    if (target == null) {
      throw const MoveFailure(MoveFailureCode.historyNotFound);
    }
    // Already recorded, by an earlier run of this Move or on the account.
    if (target.stateVersion > 0) return;
    final state = item.finalState!;
    await access.withGrant(
      connected,
      () => MedicationRepository(database, access: access, context: connected)
          .apply(
            userId: connected.ownerUserId,
            occurrenceId: target.id,
            action: state.action,
            actualAt: state.actualAt,
            actualTimeKnown: state.actualTimeKnown,
            note: state.note,
            amount: state.amount,
            commandIdOverride: _ids.command(item.occurrence.id),
            expectedStateVersion: target.stateVersion,
            expectedPersonId: _ids.person(personId),
            recordedByOverride: RecordedByOverride(state.authorName),
          ),
    );
  }

  Future<void> _recordPrn(MovePrnDose dose) async {
    final occurrenceId = _ids.occurrence(dose.occurrence.id);
    if (await database.medicationLedgerDao.getOccurrenceById(occurrenceId) !=
        null) {
      return;
    }
    final pillId = _ids.medication(dose.pillId);
    final sentinel = (await database.schedulesDao.getByPillId(pillId))
        .where((s) => s.isActive && !s.isDeleted && s.frequency == 'prn')
        .firstOrNull;
    if (sentinel == null) {
      throw const MoveFailure(MoveFailureCode.copyNotSent);
    }
    final state = dose.finalState;
    final zone = sentinel.timeZone ?? dose.occurrence.timeZone;
    // The account files an as-needed dose under the day it was taken, in
    // the routine's own zone.
    final localDate = state.actualAt == null
        ? dose.occurrence.plannedLocalDate
        : _dateIn(state.actualAt!, zone);
    final intent = await recording.prepareConnectedPrn(
      personId: _ids.person(dose.personId),
      pillId: pillId,
      sentinelId: sentinel.id,
      reviewedLocalDate: localDate,
      amount: state.amount,
      actualAt: state.actualAt,
      actualTimeKnown: state.actualTimeKnown,
      note: state.note,
      occurrenceId: occurrenceId,
      commandId: _ids.command(dose.occurrence.id),
      recordedByOverride: RecordedByOverride(state.authorName),
    );
    await recording.commit(intent);
  }

  String _dateIn(DateTime instant, String zone) {
    final local = tz.TZDateTime.from(instant, tz.getLocation(zone));
    return routineDateKey(DateTime.utc(local.year, local.month, local.day));
  }

  Future<void> _setStock(List<MoveMedication> medications) async {
    for (final medication in medications) {
      final stock = medication.stock;
      final exact = stock?.exact;
      if (stock == null || exact == null) continue;
      final id = _ids.medication(medication.pill.id);
      final pill = await database.pillsDao.getById(id);
      // Set once: a later run keeps whatever the account counts since.
      if (pill == null || pill.currentStock != null) continue;
      _ok(
        await pills.update(
          id,
          name: pill.name,
          dosage: pill.dosage,
          notes: pill.notes,
          color: pill.color,
          // A part tablet, or a count in tablets or capsules, moves as an
          // exact quantity in its unit; any other count stays a plain number.
          currentStock: exact.isWhole && !isCountableStockUnit(stock.unit)
              ? exact.floor
              : null,
          stockQuantity: exact.isWhole && !isCountableStockUnit(stock.unit)
              ? null
              : exact,
          stockUnit: exact.isWhole && !isCountableStockUnit(stock.unit)
              ? null
              : stock.unit,
          lowStockThreshold: pill.lowStockThreshold,
          isPrn: pill.isPrn,
        ),
      );
    }
  }

  Future<void> _verify(
    List<MoveHistoryItem> history,
    List<MovePrnDose> prnDoses,
  ) async {
    for (final item in history) {
      final target = await _connectedOccurrence(item);
      if (target == null) {
        throw const MoveFailure(MoveFailureCode.notVerified);
      }
      // A dose recorded on the account in the meantime is the account's
      // answer; only a dose still waiting means the copy is incomplete.
      if (item.finalState != null && target.state == 'pending') {
        throw const MoveFailure(MoveFailureCode.notVerified);
      }
    }
    for (final dose in prnDoses) {
      final row = await database.medicationLedgerDao.getOccurrenceById(
        _ids.occurrence(dose.occurrence.id),
      );
      if (row == null || row.state != 'taken') {
        throw const MoveFailure(MoveFailureCode.notVerified);
      }
    }
    // Anything still unsettled, waiting or held for review, means the
    // account does not have all of it yet.
    final waiting = await database.pendingOperationsDao.getUnsettledForUser(
      connected.ownerUserId,
    );
    if (waiting.isNotEmpty) {
      throw const MoveFailure(MoveFailureCode.notVerified);
    }
  }
}
