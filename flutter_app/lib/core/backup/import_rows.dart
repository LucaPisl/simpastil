/// Pure row model and row-building helpers for backup import planning.
///
/// Nothing here touches the database, files or preferences: these functions
/// turn already-checked backup tables into classified import rows.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../medication/local_occurrence_snapshot.dart';
import 'backup_inventory.dart';
import 'import_identity_map.dart';
import 'import_plan.dart';

String canonicalImportJson(Object? value) {
  Object? ordered(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final k in keys) k: ordered(v[k])};
    }
    if (v is List) return v.map(ordered).toList();
    return v;
  }

  return jsonEncode(ordered(value));
}

String importDigest(Object? value) =>
    sha256.convert(utf8.encode(canonicalImportJson(value))).toString();
String importKey(String table, Map<String, Object?> row) => jsonEncode([
  for (final column in BackupInventory.primaryKeys[table]!) row[column],
]);

class ImportRow {
  ImportRow(
    this.table,
    this.original,
    Set<String> people, {
    required this.quarantined,
    this.detachedHistory = false,
  }) : people = Set.of(people);
  final String table;
  final Map<String, Object?> original;
  final Set<String> people;
  bool quarantined;
  final bool detachedHistory;
  late Map<String, Object?> operational;
  Map<String, Object?>? current;
  bool identical = false, conflict = false, blocked = false;
}

List<ImportDoseConflict> importDoseConflicts(List<ImportRow> rows) {
  final result = <ImportDoseConflict>[];
  for (final row in rows) {
    if (row.table != 'medication_occurrences' ||
        !row.conflict ||
        row.quarantined ||
        row.current == null) {
      continue;
    }
    final localState = _importDoseState(row.current!['state']);
    final importedState = _importDoseState(row.operational['state']);
    if (localState == null ||
        importedState == null ||
        localState == importedState) {
      continue;
    }
    final local = _importDoseContext(row.current!, localState);
    final imported = _importDoseContext(row.operational, importedState);
    if (local != null && imported != null) {
      result.add(ImportDoseConflict(local: local, imported: imported));
    }
  }
  result.sort((a, b) {
    final date = a.local.localDate.compareTo(b.local.localDate);
    if (date != 0) return date;
    final time = (a.local.localTime ?? '').compareTo(b.local.localTime ?? '');
    if (time != 0) return time;
    return a.local.medicationName.compareTo(b.local.medicationName);
  });
  return result;
}

ImportDoseState? _importDoseState(Object? value) => switch (value) {
  'pending' => ImportDoseState.pending,
  'taken' => ImportDoseState.taken,
  'skipped' => ImportDoseState.skipped,
  'missed' => ImportDoseState.missed,
  _ => null,
};

ImportDoseContext? _importDoseContext(
  Map<String, Object?> row,
  ImportDoseState state,
) {
  try {
    final snapshot = decodeScheduleSnapshot(
      Map<String, dynamic>.from(
        jsonDecode(row['schedule_snapshot_json'] as String) as Map,
      ),
    );
    final localDate = row['planned_local_date'];
    if (localDate is! String ||
        localDate.isEmpty ||
        snapshot.profileName.isEmpty ||
        snapshot.pillName.isEmpty) {
      return null;
    }
    return ImportDoseContext(
      personName: snapshot.profileName,
      medicationName: snapshot.pillName,
      localDate: localDate,
      localTime: row['planned_local_time'] as String?,
      state: state,
    );
  } on Object {
    return null;
  }
}

String importRowNode(String table, Map<String, Object?> row) => jsonEncode([
  table,
  [for (final key in BackupInventory.primaryKeys[table]!) row[key]],
]);

/// Enumerates every portable source row, including personless work. Proven
/// operational graphs may activate; detached/orphan work stays exact evidence.
List<ImportRow> fullImportRows(
  Map<String, List<Map<String, Object?>>> tables,
  ImportIdentityMap map,
  Map<String, String> ownership,
) {
  final workspaces = tables['care_workspaces']!;
  final owners = workspaces.map((w) => w['owner_user_id'] as String).toSet();
  final connectedOwners = workspaces
      .where((w) => w['kind'] == 'connected')
      .map((w) => w['owner_user_id'] as String)
      .toSet();
  final people = tables['profiles']!.map((p) => p['id'] as String).toSet();
  final selected = selectedImportRows(
    tables,
    people,
    owners,
    workspaces.map((w) => w['id'] as String).toSet(),
    ownership,
  );
  final annotated = {
    for (final row in selected) importRowNode(row.table, row.original): row,
  };
  final profiles = {
    for (final row in tables['profiles']!) row['id']: row['user_id'],
  };
  final pills = {
    for (final row in tables['pills']!) row['id']: row['profile_id'],
  };
  final result = <ImportRow>[];
  for (final entry in tables.entries) {
    for (final original in entry.value) {
      final node = importRowNode(entry.key, original),
          annotation = annotated[importRowNode(entry.key, original)];
      if (ownership[node] != null && !owners.contains(ownership[node])) {
        throw const ImportFailure(ImportFailureCode.invalidSource);
      }
      var quarantined =
          ownership[node] == null || (annotation?.quarantined ?? true);
      if (entry.key == 'users') {
        quarantined = map.workspaceOwners.values.contains(original['id']);
      }
      if (entry.key == 'care_workspaces') {
        quarantined = original['kind'] == 'local';
      }
      if (entry.key == 'device_reminder_settings') quarantined = false;
      if (entry.key == 'setup_drafts') {
        final profile = original['profile_id'], pill = original['pill_id'];
        quarantined =
            (profile != null && profiles[profile] != ownership[node]) ||
            (pill != null && (profile == null || pills[pill] != profile));
      }
      // A later account sign-in is not proof of current shared membership or
      // server acceptance. Only a current pull can populate this empty cache.
      if (connectedOwners.contains(ownership[node]) &&
          !const {'users', 'care_workspaces'}.contains(entry.key)) {
        quarantined = true;
      }
      final row = ImportRow(
        entry.key,
        original,
        annotation?.people ?? {},
        quarantined: quarantined,
        detachedHistory: annotation?.detachedHistory ?? false,
      );
      row.operational = quarantined
          ? Map.of(original)
          : map.operational(entry.key, original);
      if (entry.key == 'care_workspaces' && !quarantined) {
        row.operational['current_author_id'] = null;
        row.operational['selected_profile_id'] = null;
        row.operational['view_everyone'] = 0;
      }
      result.add(row);
    }
  }
  return result;
}

List<ImportRow> selectedImportRows(
  Map<String, List<Map<String, Object?>>> tables,
  Set<String> people,
  Set<String> owners,
  Set<String> workspaces,
  Map<String, String> ownership,
) {
  final allProfiles = <String, String>{
    for (final p in tables['pills']!)
      p['id'] as String: p['profile_id'] as String,
  };
  final allSchedules = <String, String>{
    for (final s in tables['schedules']!)
      if (allProfiles.containsKey(s['pill_id']))
        s['id'] as String: allProfiles[s['pill_id']]!,
  };
  final profileOwners = {
    for (final p in tables['profiles']!) p['id']: p['user_id'],
  };
  final workspaceByOwner = {
    for (final w in tables['care_workspaces']!) w['owner_user_id']: w['id'],
  };
  final allOccurrences = <String, String>{};
  for (final o in tables['medication_occurrences']!) {
    try {
      final snapshot = decodeScheduleSnapshot(
        jsonDecode(o['schedule_snapshot_json'] as String)
            as Map<String, dynamic>,
      );
      if (profileOwners[snapshot.profileId] == o['user_id'] &&
          snapshotOwns(
            snapshot,
            o['user_id'] as String,
            workspaceByOwner[o['user_id']] as String?,
          ) &&
          snapshot.timeZone == o['time_zone']) {
        allOccurrences[o['id'] as String] = snapshot.profileId;
      }
    } catch (_) {
      // Person-unproven history remains isolated original evidence.
    }
  }
  final allEvents = <String, String>{
    for (final e in tables['occurrence_events']!)
      if (allOccurrences.containsKey(e['occurrence_id']))
        e['id'] as String: allOccurrences[e['occurrence_id']]!,
  };
  final profileOf = <String, String>{
    for (final p in tables['pills']!)
      if (people.contains(p['profile_id']))
        p['id'] as String: p['profile_id'] as String,
  };
  final scheduleOf = <String, String>{
    for (final s in tables['schedules']!)
      if (profileOf.containsKey(s['pill_id']))
        s['id'] as String: profileOf[s['pill_id']]!,
  };
  final occurrenceOf = <String, String>{
    for (final entry in allOccurrences.entries)
      if (people.contains(entry.value)) entry.key: entry.value,
  };
  final eventOf = <String, String>{
    for (final e in tables['occurrence_events']!)
      if (occurrenceOf.containsKey(e['occurrence_id']))
        e['id'] as String: occurrenceOf[e['occurrence_id']]!,
  };
  final operations = tables['pending_operations']!
      .where((r) => owners.contains(r['user_id']))
      .map((r) => r['id'])
      .toSet();
  final runs = tables['sync_staging_runs']!
      .where((r) => owners.contains(r['user_id']))
      .map((r) => r['id'])
      .toSet();
  final receipts = (tables['import_receipts'] ?? [])
      .where((r) => workspaces.contains(r['workspace_id']))
      .map((r) => r['id'])
      .toSet();
  final rows = <ImportRow>[];
  for (final entry in tables.entries) {
    for (final row in entry.value) {
      String? person;
      var shared = false, quarantine = false;
      switch (entry.key) {
        case 'profiles':
          person = people.contains(row['id']) ? row['id'] as String : null;
        case 'pills':
          person = profileOf[row['id']];
        case 'schedules':
          person = scheduleOf[row['id']];
        case 'dose_logs':
          person = scheduleOf[row['schedule_id']];
        case 'medication_occurrences':
          person = occurrenceOf[row['id']];
        case 'occurrence_events':
          person = eventOf[row['id']];
        case 'care_event_details':
          person = eventOf[row['event_id']];
        case 'inventory_events':
          final capturedPerson = row['occurrence_event_id'] == null
              ? allProfiles[row['pill_id']]
              : allEvents[row['occurrence_event_id']];
          person = people.contains(capturedPerson) ? capturedPerson : null;
          quarantine =
              person != null &&
              (allProfiles[row['pill_id']] != person ||
                  !profileOf.containsKey(row['pill_id']));
        case 'local_routines':
        case 'medication_details':
        case 'medication_photos':
        case 'reviewed_stock_balances':
          person = profileOf[row['pill_id']];
        case 'setup_drafts':
          person = people.contains(row['profile_id'])
              ? row['profile_id'] as String
              : null;
        case 'device_person_reminders':
          person = people.contains(row['profile_id'])
              ? row['profile_id'] as String
              : null;
        case 'device_schedule_reminders':
          person = scheduleOf[row['schedule_id']];
        case 'workspace_authors':
          shared = workspaces.contains(row['workspace_id']);
        case 'users':
          shared = owners.contains(row['id']);
          quarantine = true;
        case 'care_workspaces':
          shared = workspaces.contains(row['id']);
          quarantine = true;
        case 'device_reminder_settings':
          shared = workspaces.contains(row['workspace_id']);
          quarantine = true;
        case 'pending_operations':
          shared = operations.contains(row['id']);
          quarantine = true;
        case 'pending_operation_effects':
          shared = operations.contains(row['operation_id']);
          quarantine = true;
        case 'sync_staging_runs':
          shared = runs.contains(row['id']);
          quarantine = true;
        case 'sync_staging_items':
          shared = runs.contains(row['run_id']);
          quarantine = true;
        case 'migration_issues':
          shared = owners.contains(row['user_id']);
          quarantine = true;
        case 'import_receipts':
          shared = receipts.contains(row['id']);
          quarantine = true;
        case 'import_evidence':
        case 'import_conflicts':
          shared = receipts.contains(row['receipt_id']);
          quarantine = true;
      }
      // Deleted-parent rows can have proven workspace ownership without a
      // provable person. Retain them as uncertainty, never fabricate live care.
      if (person == null && !shared) {
        final knownPerson = switch (entry.key) {
          'pills' => row['profile_id'] as String?,
          'inventory_events' =>
            row['occurrence_event_id'] == null
                ? allProfiles[row['pill_id']]
                : allEvents[row['occurrence_event_id']],
          'schedules' ||
          'local_routines' ||
          'medication_details' ||
          'medication_photos' ||
          'reviewed_stock_balances' => allProfiles[row['pill_id']],
          'dose_logs' => allSchedules[row['schedule_id']],
          'medication_occurrences' => allOccurrences[row['id']],
          'occurrence_events' => allOccurrences[row['occurrence_id']],
          'care_event_details' => allEvents[row['event_id']],
          'setup_drafts' ||
          'device_person_reminders' => row['profile_id'] as String?,
          'device_schedule_reminders' => allSchedules[row['schedule_id']],
          _ => 'excluded',
        };
        final provenOwner =
            ownership[jsonEncode([
              entry.key,
              [for (final c in BackupInventory.primaryKeys[entry.key]!) row[c]],
            ])];
        if (knownPerson == null && owners.contains(provenOwner)) {
          shared = true;
          quarantine = true;
        }
      }
      if ((person != null || shared) &&
          ownership.containsKey(importRowNode(entry.key, row))) {
        final provenOwner = ownership[importRowNode(entry.key, row)];
        rows.add(
          ImportRow(
            entry.key,
            row,
            person == null
                ? people.where((p) => profileOwners[p] == provenOwner).toSet()
                : {person},
            quarantined: quarantine,
            detachedHistory:
                entry.key == 'medication_occurrences' &&
                person != null &&
                allProfiles[row['pill_id']] != person,
          ),
        );
      }
    }
  }
  for (final author in rows.where((r) => r.table == 'workspace_authors')) {
    final dependants = rows.where(
      (r) =>
          !r.quarantined &&
          r.table != 'workspace_authors' &&
          r.original['author_id'] == author.original['id'],
    );
    final neededBy = {for (final dependant in dependants) ...dependant.people};
    author.people
      ..clear()
      ..addAll(neededBy);
  }
  return rows;
}
