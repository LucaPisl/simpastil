import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:timezone/timezone.dart' as tz;
import '../db/database.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import 'local_occurrence_snapshot.dart';
import 'routine_definition.dart';
import 'routine_preview.dart';
import 'medication_amount.dart';

extension LocalRoutineBoundary on LocalRoutine {
  DateTime get effectiveFrom =>
      DateTime.fromMillisecondsSinceEpoch(effectiveFromMillis, isUtc: true);
}

class RoutineConflict implements Exception {
  const RoutineConflict();
}

class RoutineNextDose {
  const RoutineNextDose({
    required this.routineId,
    required this.planned,
    required this.amount,
  });
  final String routineId;
  final RoutinePlannedEntry planned;
  final MedicationAmount amount;
}

class ReviewedRoutinePreview {
  ReviewedRoutinePreview._({
    required RoutineRepository origin,
    required this.routineId,
    required this.pillId,
    required this.expectedRevision,
    required this.definition,
    required this.effectiveFrom,
    required this.fromLocalDate,
    required this.throughLocalDate,
    required String parentFingerprint,
    required String preservationFingerprint,
    required this.upcoming,
    required this.preservedRecords,
  }) : _origin = origin,
       _parentFingerprint = parentFingerprint,
       _preservationFingerprint = preservationFingerprint;
  final RoutineRepository _origin;
  final String _parentFingerprint;
  final String _preservationFingerprint;
  final String routineId;
  final String pillId;
  final int expectedRevision;
  final RoutineDefinition definition;
  final DateTime effectiveFrom;
  final String fromLocalDate;
  final String throughLocalDate;
  final List<RoutinePlannedEntry> upcoming;
  final List<MedicationOccurrence> preservedRecords;
}

class _Candidate {
  const _Candidate(this.version, this.entry);
  final LocalRoutine version;
  final RoutinePlannedEntry entry;
  String get scheduleId =>
      localRoutineScheduleId(version.routineId, entry.slot.slotId);
  String get logicalKey => '$scheduleId/${entry.localDate}';
}

/// The slots one routine's [versions] (oldest first) owe on the local days
/// [from] to [through], each under the version in force at its planned time.
/// Read-only: it materialises nothing.
List<_Candidate> _candidates(
  List<LocalRoutine> versions,
  String from,
  String through,
) {
  final result = <String, _Candidate>{};
  for (var i = 0; i < versions.length; i++) {
    final version = versions[i];
    final end = i + 1 == versions.length ? null : versions[i + 1].effectiveFrom;
    final definition = RoutineDefinition.fromJson(
      jsonDecode(version.definitionJson) as Map<String, dynamic>,
    );
    for (final entry in RoutineEngine().preview(
      definition: definition,
      fromLocalDate: from,
      throughLocalDate: through,
    )) {
      if (entry.plannedAt.isBefore(version.effectiveFrom) ||
          (end != null && !entry.plannedAt.isBefore(end))) {
        continue;
      }
      final candidate = _Candidate(version, entry);
      // A clock move across a boundary cannot create two obligations for the same slot/date.
      result.putIfAbsent(candidate.logicalKey, () => candidate);
    }
  }
  return result.values.toList()
    ..sort((a, b) => a.entry.plannedAt.compareTo(b.entry.plannedAt));
}

/// A slot of a local routine on one local day: [scheduleId] is the id its
/// occurrence rows carry, [entry] says which day, time and zone.
typedef PlannedRoutineSlot = ({String scheduleId, RoutinePlannedEntry entry});

/// The slots one local routine's [versions] (oldest first) owe on the local
/// days [from] to [through] (`yyyy-MM-dd`), whether or not their occurrence
/// rows have been written yet. Read-only: nothing is materialised, so it can
/// say which obligations have no row.
List<PlannedRoutineSlot> plannedRoutineSlots(
  List<LocalRoutine> versions,
  String from,
  String through,
) => [
  for (final c in _candidates(versions, from, through))
    (scheduleId: c.scheduleId, entry: c.entry),
];

String localRoutineScheduleId(String routineId, String slotId) => const Uuid()
    .v5(Namespace.url.value, 'simpastil-local-routine-slot:$routineId:$slotId');

String localRoutinePrnScheduleId(String routineId) => const Uuid().v5(
  Namespace.url.value,
  'simpastil-local-routine-prn:$routineId',
);

/// Local routines never enter connected queues or the server's v1 schedule format.
class RoutineRepository {
  RoutineRepository({
    required this.database,
    required this.access,
    required this.context,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final WorkspaceContext context;
  final DateTime Function() _clock;

  Future<({Pill pill, Profile person})> _parents(String pillId) async {
    if (!context.isLocal) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.unavailable,
      );
    }
    final pill = await database.pillsDao.getById(pillId);
    if (pill == null || pill.isDeleted) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    await access.workspaces.requirePerson(context.ownerUserId, pill.profileId);
    final person = (await database.profilesDao.getById(pill.profileId))!;
    return (pill: pill, person: person);
  }

  String _fingerprint(({Pill pill, Profile person}) parents) => jsonEncode([
    parents.pill.id,
    parents.pill.profileId,
    parents.pill.name,
    parents.pill.dosage,
    parents.person.id,
    parents.person.name,
  ]);
  Future<List<LocalRoutine>> _versions(String routineId) =>
      (database.select(database.localRoutines)
            ..where(
              (r) =>
                  r.routineId.equals(routineId) &
                  r.workspaceId.equals(context.workspaceId),
            )
            ..orderBy([(r) => OrderingTerm.asc(r.revision)]))
          .get();

  Future<List<LocalRoutine>> loadForPill(String pillId) =>
      access.withGrant(context, () async {
        await _parents(pillId);
        return (database.select(database.localRoutines)
              ..where(
                (r) =>
                    r.pillId.equals(pillId) &
                    r.workspaceId.equals(context.workspaceId),
              )
              ..orderBy([(r) => OrderingTerm.asc(r.revision)]))
            .get();
      });

  /// Reads the next obligation; it neither materializes future occurrences nor
  /// recreates a slot already recorded. Preserved pending snapshots win over an
  /// edited definition for the same logical slot/date.
  Future<RoutineNextDose?> nextPlannedForPill({
    required String pillId,
    required String afterLocalDate,
  }) => access.withGrant(context, () async {
    final parents = await _parents(pillId);
    final after = parseRoutineDate(afterLocalDate);
    final from = routineDateKey(
      DateTime.utc(after.year, after.month, after.day + 1),
    );
    final all = await loadForPill(pillId);
    final grouped = <String, List<LocalRoutine>>{};
    for (final version in all) {
      grouped.putIfAbsent(version.routineId, () => []).add(version);
    }
    final options = <RoutineNextDose>[];
    for (final versions in grouped.values) {
      final rows = await _rows(versions);
      final existing = {
        for (final row in rows)
          '${row.scheduleId}/${row.plannedLocalDate}': row,
      };
      for (final row in rows) {
        if (!row.expected ||
            row.state != 'pending' ||
            row.provenance != 'exact' ||
            row.plannedAt == null ||
            row.plannedLocalDate.compareTo(afterLocalDate) <= 0) {
          continue;
        }
        final snapshot = decodeScheduleSnapshot(
          jsonDecode(row.scheduleSnapshotJson) as Map<String, dynamic>,
        );
        if (snapshot is! LocalOccurrenceSnapshot ||
            !snapshotOwns(snapshot, context.ownerUserId, context.workspaceId) ||
            snapshot.profileId != parents.person.id ||
            row.pillId != pillId ||
            snapshot.timeZone != row.timeZone ||
            snapshot.routineId != versions.first.routineId ||
            row.scheduleId !=
                localRoutineScheduleId(snapshot.routineId, snapshot.slotId) ||
            !versions.any((v) => v.revision == snapshot.routineRevision)) {
          throw const RoutineConflict();
        }
        final slot = RoutineTime(
          slotId: snapshot.slotId,
          hour: snapshot.hour!,
          minute: snapshot.minute!,
        );
        if (slot.localTime != row.plannedLocalTime) {
          throw const RoutineConflict();
        }
        options.add(
          RoutineNextDose(
            routineId: snapshot.routineId,
            planned: RoutinePlannedEntry(
              slot: slot,
              localDate: row.plannedLocalDate,
              timeZone: row.timeZone,
              plannedAt: row.plannedAt!,
            ),
            amount: snapshot.amount,
          ),
        );
      }
      for (var index = 0; index < versions.length; index++) {
        final version = versions[index];
        final before = index + 1 == versions.length
            ? null
            : versions[index + 1].effectiveFrom;
        final definition = RoutineDefinition.fromJson(
          jsonDecode(version.definitionJson) as Map<String, dynamic>,
        );
        var boundary = version.effectiveFrom;
        while (true) {
          final entry = RoutineEngine().next(
            definition: definition,
            fromLocalDate: from,
            notBefore: boundary,
            before: before,
          );
          if (entry == null) break;
          final key =
              '${localRoutineScheduleId(version.routineId, entry.slot.slotId)}/${entry.localDate}';
          if (!existing.containsKey(key)) {
            options.add(
              RoutineNextDose(
                routineId: version.routineId,
                planned: entry,
                amount: definition.amount,
              ),
            );
            break;
          }
          boundary = entry.plannedAt.add(const Duration(microseconds: 1));
        }
      }
    }
    options.sort((a, b) => a.planned.plannedAt.compareTo(b.planned.plannedAt));
    return options.firstOrNull;
  });

  Future<List<MedicationOccurrence>> _rows(List<LocalRoutine> versions) async {
    final scheduleIds = <String>{};
    for (final v in versions) {
      final d = RoutineDefinition.fromJson(
        jsonDecode(v.definitionJson) as Map<String, dynamic>,
      );
      for (final slot in d.times) {
        scheduleIds.add(localRoutineScheduleId(v.routineId, slot.slotId));
      }
    }
    if (scheduleIds.isEmpty) return [];
    return (database.select(database.medicationOccurrences)..where(
          (r) =>
              r.userId.equals(context.ownerUserId) &
              r.scheduleId.isIn(scheduleIds) &
              r.supersededAt.isNull(),
        ))
        .get();
  }

  Future<bool> _untouched(MedicationOccurrence row) async =>
      row.state == 'pending' &&
      row.stateVersion == 0 &&
      (await database.medicationLedgerDao.getEventsForOccurrence(
        row.id,
      )).isEmpty;

  Future<String> _preservation(
    List<MedicationOccurrence> rows,
    DateTime boundary,
  ) async {
    final decisions = <String>[];
    final now = _clock().toUtc();
    for (final row in rows) {
      if (row.plannedAt!.isBefore(boundary)) continue;
      final untouched = await _untouched(row);
      if (!untouched || row.plannedAt!.isBefore(now)) {
        decisions.add(
          jsonEncode([
            row.id,
            row.state,
            row.stateVersion,
            untouched ? 'past' : 'recorded',
          ]),
        );
      }
    }
    return jsonEncode(decisions..sort());
  }

  Future<ReviewedRoutinePreview> preview({
    required String pillId,
    String? routineId,
    required int expectedRevision,
    required RoutineDefinition definition,
    required DateTime effectiveFrom,
    required String fromLocalDate,
    required String throughLocalDate,
  }) => access.withGrant(context, () async {
    // Review and persistence use the same explicit millisecond boundary.
    effectiveFrom = DateTime.fromMillisecondsSinceEpoch(
      effectiveFrom.millisecondsSinceEpoch,
      isUtc: true,
    );
    parseRoutineDate(fromLocalDate);
    parseRoutineDate(throughLocalDate);
    final parents = await _parents(pillId);
    final id = routineId ?? const Uuid().v4();
    final versions = await _versions(id);
    if ((versions.lastOrNull?.revision ?? 0) != expectedRevision ||
        versions.any((v) => v.pillId != pillId) ||
        (versions.isNotEmpty &&
            (effectiveFrom.toUtc().isBefore(versions.last.effectiveFrom) ||
                effectiveFrom.toUtc().isBefore(_clock().toUtc())))) {
      throw const RoutineConflict();
    }
    if (versions.isEmpty && (await loadForPill(pillId)).isNotEmpty) {
      throw const RoutineConflict();
    }
    final proposed = LocalRoutine(
      routineId: id,
      revision: expectedRevision + 1,
      workspaceId: context.workspaceId,
      authorId: context.authorId,
      pillId: pillId,
      effectiveFromMillis: effectiveFrom.toUtc().millisecondsSinceEpoch,
      definitionJson: jsonEncode(definition.toJson()),
      createdAt: _clock().toUtc(),
    );
    final rows = await _rows(versions);
    final retained = <MedicationOccurrence>[];
    final blocked = <String>{};
    for (final row in rows) {
      if (!await _untouched(row) ||
          row.plannedAt!.isBefore(effectiveFrom.toUtc()) ||
          row.plannedAt!.isBefore(_clock().toUtc())) {
        blocked.add('${row.scheduleId}/${row.plannedLocalDate}');
        if (!await _untouched(row) &&
            !row.plannedAt!.isBefore(effectiveFrom.toUtc())) {
          retained.add(row);
        }
      }
    }
    final candidates = _candidates(
      [...versions, proposed],
      fromLocalDate,
      throughLocalDate,
    );
    return ReviewedRoutinePreview._(
      origin: this,
      routineId: id,
      pillId: pillId,
      expectedRevision: expectedRevision,
      definition: definition,
      effectiveFrom: effectiveFrom.toUtc(),
      fromLocalDate: fromLocalDate,
      throughLocalDate: throughLocalDate,
      parentFingerprint: _fingerprint(parents),
      preservationFingerprint: await _preservation(rows, effectiveFrom.toUtc()),
      upcoming: List.unmodifiable(
        candidates
            .where((c) => !blocked.contains(c.logicalKey))
            .map((c) => c.entry),
      ),
      preservedRecords: List.unmodifiable(retained),
    );
  });

  Future<LocalRoutine> saveReviewed(
    ReviewedRoutinePreview preview,
  ) => access.withGrant(context, () async {
    if (!identical(preview._origin, this)) throw const RoutineConflict();
    final parents = await _parents(preview.pillId);
    final versions = await _versions(preview.routineId);
    final encoded = jsonEncode(preview.definition.toJson());
    if (versions.isNotEmpty &&
        versions.last.revision == preview.expectedRevision + 1 &&
        versions.last.definitionJson == encoded &&
        versions.last.effectiveFrom == preview.effectiveFrom &&
        versions.last.pillId == preview.pillId) {
      return versions.last;
    }
    if ((versions.lastOrNull?.revision ?? 0) != preview.expectedRevision ||
        _fingerprint(parents) != preview._parentFingerprint ||
        versions.any((v) => v.pillId != preview.pillId)) {
      throw const RoutineConflict();
    }
    if (versions.isEmpty && (await loadForPill(preview.pillId)).isNotEmpty) {
      throw const RoutineConflict();
    }
    final affected = await _rows(versions);
    if (await _preservation(affected, preview.effectiveFrom) !=
        preview._preservationFingerprint) {
      throw const RoutineConflict();
    }
    final now = _clock().toUtc();
    await database
        .into(database.localRoutines)
        .insert(
          LocalRoutinesCompanion.insert(
            routineId: preview.routineId,
            revision: preview.expectedRevision + 1,
            workspaceId: context.workspaceId,
            authorId: context.authorId,
            pillId: preview.pillId,
            effectiveFromMillis: preview.effectiveFrom.millisecondsSinceEpoch,
            definitionJson: encoded,
            createdAt: now,
          ),
        );
    // Bridge rows remain readable for recorded or removed slots; expected work lives in occurrences.
    for (final slot in preview.definition.times) {
      final id = localRoutineScheduleId(preview.routineId, slot.slotId);
      if (await database.schedulesDao.getById(id) != null) continue;
      await database.schedulesDao.upsert(
        SchedulesCompanion.insert(
          id: id,
          pillId: preview.pillId,
          hour: slot.hour,
          minute: slot.minute,
          frequency: 'local-v2',
          syncStatus: const Value('local'),
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    if (preview.definition.kind == RoutineKind.prn) {
      final id = localRoutinePrnScheduleId(preview.routineId);
      if (await database.schedulesDao.getById(id) == null) {
        await database.schedulesDao.upsert(
          SchedulesCompanion.insert(
            id: id,
            pillId: preview.pillId,
            hour: 0,
            minute: 0,
            frequency: 'prn',
            syncStatus: const Value('local'),
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
    }
    var from = preview.fromLocalDate;
    var through = preview.throughLocalDate;
    for (final row in affected) {
      if (row.plannedAt!.isBefore(preview.effectiveFrom) ||
          row.plannedAt!.isBefore(now)) {
        continue;
      }
      if (row.plannedLocalDate.compareTo(from) < 0) from = row.plannedLocalDate;
      if (row.plannedLocalDate.compareTo(through) > 0) {
        through = row.plannedLocalDate;
      }
    }
    await _materialize(
      [...versions, (await _versions(preview.routineId)).last],
      from,
      through,
    );
    return (await _versions(preview.routineId)).last;
  });

  Future<void> ensureMaterialized({
    required String fromLocalDate,
    required String throughLocalDate,
  }) => access.withGrant(context, () async {
    if (!context.isLocal) return;
    parseRoutineDate(fromLocalDate);
    parseRoutineDate(throughLocalDate);
    final all =
        await (database.select(database.localRoutines)
              ..where((r) => r.workspaceId.equals(context.workspaceId))
              ..orderBy([(r) => OrderingTerm.asc(r.revision)]))
            .get();
    final groups = <String, List<LocalRoutine>>{};
    for (final version in all) {
      (groups[version.routineId] ??= []).add(version);
    }
    for (final versions in groups.values) {
      final pill = await database.pillsDao.getById(versions.first.pillId);
      if (pill == null || pill.isDeleted) continue;
      final person = await database.profilesDao.getById(pill.profileId);
      if (person?.isDeleted == true && person?.userId == context.ownerUserId) {
        // A local person deletion preserves their care rows, but their future
        // reminders must retire. Do not let that tombstone abort reconciliation
        // before the projection layer can cancel the platform alarms.
        continue;
      }
      await _parents(pill.id);
      await _materialize(versions, fromLocalDate, throughLocalDate);
    }
  });

  Future<void> _materialize(
    List<LocalRoutine> versions,
    String from,
    String through,
  ) async {
    final parents = await _parents(versions.first.pillId);
    final current = versions
        .where((v) => !v.effectiveFrom.isAfter(_clock().toUtc()))
        .lastOrNull;
    final currentDefinition = current == null
        ? null
        : RoutineDefinition.fromJson(
            jsonDecode(current.definitionJson) as Map<String, dynamic>,
          );
    final prn =
        currentDefinition != null &&
        currentDefinition.kind == RoutineKind.prn &&
        currentDefinition.isWithinDates(
          tz.TZDateTime.from(
            _clock(),
            tz.getLocation(currentDefinition.timeZone),
          ),
        );
    if (parents.pill.isPrn != prn) {
      await (database.update(database.pills)
            ..where((r) => r.id.equals(parents.pill.id)))
          .write(PillsCompanion(isPrn: Value(prn)));
    }
    final candidates = _candidates(versions, from, through);
    final rows = await _rows(versions);
    final existing = {
      for (final row in rows) '${row.scheduleId}/${row.plannedLocalDate}': row,
    };
    final selected = <String>{};
    final now = _clock().toUtc();
    for (final c in candidates) {
      selected.add(c.logicalKey);
      final key =
          'scheduled:local:v2:${sha256.convert(utf8.encode(jsonEncode([context.workspaceId, context.ownerUserId, c.version.routineId, c.version.revision, c.entry.slot.slotId, c.entry.localDate, c.entry.localTime, c.entry.timeZone, c.entry.plannedAt.toIso8601String()])))}';
      final prior = existing[c.logicalKey];
      if (prior != null &&
          (prior.occurrenceKey == key ||
              !await _untouched(prior) ||
              prior.plannedAt!.isBefore(c.version.effectiveFrom) ||
              prior.plannedAt!.isBefore(now))) {
        continue;
      }
      final byKey = await database.medicationLedgerDao.getOccurrenceByKey(
        context.ownerUserId,
        key,
      );
      final id = byKey?.id ?? const Uuid().v4();
      if (prior != null) {
        await database.medicationLedgerDao.supersedeOccurrence(
          id: prior.id,
          supersededAt: now,
          supersededByOccurrenceId: id,
        );
      }
      if (byKey != null) continue;
      final d = RoutineDefinition.fromJson(
        jsonDecode(c.version.definitionJson) as Map<String, dynamic>,
      );
      final snapshot = LocalOccurrenceSnapshot(
        pillName: parents.pill.name,
        dosage: parents.pill.dosage,
        hour: c.entry.slot.hour,
        minute: c.entry.slot.minute,
        timeZone: c.entry.timeZone,
        profileId: parents.person.id,
        profileName: parents.person.name,
        workspaceId: context.workspaceId,
        ownerUserId: context.ownerUserId,
        routineId: c.version.routineId,
        routineRevision: c.version.revision,
        slotId: c.entry.slot.slotId,
        amount: d.amount,
        routineDefinition: d,
      );
      await database.medicationLedgerDao.upsertOccurrence(
        MedicationOccurrencesCompanion.insert(
          id: id,
          userId: context.ownerUserId,
          pillId: Value(parents.pill.id),
          scheduleId: Value(c.scheduleId),
          occurrenceKey: key,
          source: 'scheduled',
          scheduleRevision: Value(c.version.revision),
          plannedLocalDate: c.entry.localDate,
          plannedLocalTime: Value(c.entry.localTime),
          timeZone: c.entry.timeZone,
          plannedAt: Value(c.entry.plannedAt),
          expected: const Value(true),
          snapshotVersion: const Value(2),
          scheduleSnapshotJson: jsonEncode(snapshot.toJson()),
          provenance: 'exact',
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    // Removed times and days stop only untouched future work at the reviewed boundary.
    for (final row in rows) {
      if (row.plannedLocalDate.compareTo(from) < 0 ||
          row.plannedLocalDate.compareTo(through) > 0 ||
          selected.contains('${row.scheduleId}/${row.plannedLocalDate}') ||
          row.plannedAt!.isBefore(now) ||
          !await _untouched(row)) {
        continue;
      }
      final applicable = versions
          .where((v) => !v.effectiveFrom.isAfter(row.plannedAt!))
          .lastOrNull;
      if (applicable == null ||
          applicable.revision <= (row.scheduleRevision ?? 0)) {
        continue;
      }
      await database.medicationLedgerDao.supersedeOccurrence(
        id: row.id,
        supersededAt: now,
        supersededByOccurrenceId: null,
      );
    }
  }
}
