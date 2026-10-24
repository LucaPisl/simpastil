import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../db/database.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import 'backup_codec.dart';
import 'backup_file_access.dart';
import 'backup_inventory.dart';
import 'backup_manifest.dart';

typedef InterfaceAccessCheck = void Function();
typedef CaptureInterfaceAccess = InterfaceAccessCheck Function();

class CapturedBackup {
  CapturedBackup._(
    this.document,
    List<WorkspaceContext> grants,
    this._interfaceAccess,
  ) : _grants = List.unmodifiable(grants);
  final BackupDocument document;
  final List<WorkspaceContext> _grants;
  final InterfaceAccessCheck? _interfaceAccess;
}

enum BackupSaveStatus {
  cancelled,
  saveFailedMayBePartial,
  savedUnchecked,
  savedCheckFailed,
  savedChecked,
}

class BackupSaveResult {
  const BackupSaveResult(
    this.status, {
    this.location,
    this.capturedAt,
    this.checkedAt,
  });
  final BackupSaveStatus status;
  final BackupFileLocation? location;
  final DateTime? capturedAt, checkedAt;
}

class SelectedBackupSource {
  const SelectedBackupSource._(
    this.location,
    this.passwordProtected,
    this._fingerprint,
    this._interfaceAccess,
  );
  final BackupFileLocation location;
  final bool passwordProtected;
  final Digest _fingerprint;
  final InterfaceAccessCheck? _interfaceAccess;
}

/// An in-memory handle to a user-chosen source. It contains no file contents
/// or authorization lease; opening it always starts a new protected operation.
class BackupSourceChoice {
  const BackupSourceChoice._(this._location);
  final BackupFileLocation _location;
  String get displayName => _location.displayName;
}

/// An in-memory handle to a user-chosen destination. It contains no care data
/// or authorization lease; writing it always requires a fresh snapshot.
class BackupDestinationChoice {
  const BackupDestinationChoice._(this._location);
  final BackupFileLocation _location;
  String get displayName => _location.displayName;
}

class CheckedBackup {
  const CheckedBackup(
    this.document,
    this.location,
    this.checkedAt, {
    required this.passwordProtected,
  });
  final BackupDocument document;
  final BackupFileLocation location;
  final DateTime checkedAt;
  final bool passwordProtected;
}

class BackupService {
  BackupService({
    required this.database,
    required this.access,
    required this.preferences,
    required this.files,
    this.codec = const BackupCodec(),
    DateTime Function()? clock,
    this.beforeDisclosure,
    this.captureInterfaceAccess,
  }) : clock = clock ?? DateTime.now;
  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final SharedPreferences preferences;
  final BackupFileAccess files;
  final BackupCodec codec;
  final DateTime Function() clock;
  final Future<void> Function()? beforeDisclosure;
  final CaptureInterfaceAccess? captureInterfaceAccess;

  /// Selecting and checking a file never activates care, preferences, access,
  /// sync or reminders. Keep password prompts bound to the chosen document.
  Future<BackupSourceChoice?> chooseSource() async {
    final location = await files.chooseOpen();
    return location == null ? null : BackupSourceChoice._(location);
  }

  /// Opens a prior chooser result under a newly captured access lease.
  /// Nothing is read while the app is locked or while returning from SAF.
  Future<SelectedBackupSource> openSource(BackupSourceChoice choice) async {
    final requireInterfaceAccess = captureInterfaceAccess?.call();
    requireInterfaceAccess?.call();
    await beforeDisclosure?.call();
    requireInterfaceAccess?.call();
    final bytes = await files.read(choice._location);
    requireInterfaceAccess?.call();
    return SelectedBackupSource._(
      choice._location,
      codec.isPasswordProtected(bytes),
      sha256.convert(bytes),
      requireInterfaceAccess,
    );
  }

  /// Combined operation retains its original picker-bound lease semantics.
  /// Protected screens that explicitly pause at a locked return can split the
  /// chooser from opening via [chooseSource] and [openSource].
  Future<SelectedBackupSource?> selectSource() async {
    final requireInterfaceAccess = captureInterfaceAccess?.call();
    requireInterfaceAccess?.call();
    final location = await files.chooseOpen();
    if (location == null) return null;
    await beforeDisclosure?.call();
    requireInterfaceAccess?.call();
    final bytes = await files.read(location);
    requireInterfaceAccess?.call();
    return SelectedBackupSource._(
      location,
      codec.isPasswordProtected(bytes),
      sha256.convert(bytes),
      requireInterfaceAccess,
    );
  }

  Future<CheckedBackup> checkSource(
    SelectedBackupSource source, {
    String? password,
  }) async {
    source._interfaceAccess?.call();
    final requireInterfaceAccess = captureInterfaceAccess?.call();
    await beforeDisclosure?.call();
    requireInterfaceAccess?.call();
    source._interfaceAccess?.call();
    final stored = await files.read(source.location);
    if (sha256.convert(stored) != source._fingerprint) {
      throw const BackupFailure(BackupFailureCode.sourceChanged);
    }
    final document = await codec.decode(stored, password: password);
    requireInterfaceAccess?.call();
    source._interfaceAccess?.call();
    return CheckedBackup(
      document,
      source.location,
      clock().toUtc(),
      passwordProtected: source.passwordProtected,
    );
  }

  /// All retained workspaces must have current access before any portable
  /// table is read. A locked collection is never silently omitted from Full.
  Future<CapturedBackup> captureFull() async {
    final requireInterfaceAccess = captureInterfaceAccess?.call();
    requireInterfaceAccess?.call();
    final captured = await database.transaction(() async {
      _checkInventory();
      final workspaces = await database.select(database.careWorkspaces).get();
      if (workspaces.isEmpty) {
        throw const BackupFailure(BackupFailureCode.fullBackupUnavailable);
      }
      final grants = <WorkspaceContext>[];
      for (final workspace in workspaces) {
        final grant = await access.contextForOwner(workspace.ownerUserId);
        if (grant == null) {
          throw const BackupFailure(BackupFailureCode.fullBackupUnavailable);
        }
        grants.add(grant);
      }
      await _requireGrants(grants);
      final capturedAt = clock().toUtc();
      final tables = <String, List<Map<String, Object?>>>{};
      var count = 0, minimumBytes = 1024, serializedBytes = 1024;
      // Aggregate lengths stay inside SQLite. No oversized cell/table is sent
      // to Dart merely to discover that it cannot fit in a supported backup.
      for (final name in BackupInventory.portableTableNames) {
        final columns = BackupInventory.portableColumns(name);
        final lengths = columns
            .map((c) => 'COALESCE(length(CAST("$c" AS BLOB)),0)')
            .toList();
        final sizes =
            (await database
                    .customSelect(
                      'SELECT COUNT(*) AS rows, COALESCE(SUM(${lengths.join('+')}),0) AS bytes, '
                      'COALESCE(MAX(max(${lengths.join(',')})),0) AS widest FROM "$name"',
                    )
                    .getSingle())
                .data;
        final rowCount = sizes['rows'] as int;
        count += rowCount;
        // Photos are the one table that can fill a backup on their own; say so
        // instead of reporting a generic size failure.
        if (name == 'medication_photos' &&
            (sizes['bytes'] as int) > maximumBackupPhotoBytes) {
          throw const BackupFailure(BackupFailureCode.photosTooLarge);
        }
        minimumBytes += sizes['bytes'] as int;
        minimumBytes +=
            rowCount * columns.fold<int>(3, (n, c) => n + c.length + 4);
        if (count > maximumBackupRows ||
            minimumBytes > maximumBackupBytes ||
            (sizes['widest'] as int) > maximumBackupStringBytes) {
          throw const BackupFailure(BackupFailureCode.tooLarge);
        }
      }
      for (final name in BackupInventory.portableTableNames) {
        final columns = BackupInventory.portableColumns(
          name,
        ).map((c) => '"$c"').join(',');
        final captured = <Map<String, Object?>>[];
        int? after;
        while (true) {
          final rows = await database
              .customSelect(
                'SELECT rowid AS backup_rowid,$columns FROM "$name" '
                '${after == null ? '' : 'WHERE rowid > $after '}ORDER BY rowid LIMIT 16',
              )
              .get();
          if (rows.isEmpty) break;
          for (final row in rows) {
            final value = Map<String, Object?>.from(row.data);
            after = value.remove('backup_rowid') as int;
            serializedBytes += utf8.encode(jsonEncode(value)).length + 1;
            if (serializedBytes > maximumBackupBytes) {
              throw const BackupFailure(BackupFailureCode.tooLarge);
            }
            captured.add(value);
          }
        }
        tables[name] = captured;
      }
      BackupOwnership.validate(
        tables,
        grants.map((g) => g.ownerUserId).toSet(),
        allowUnattributedHistory: true,
      );
      final prefs = <String, Object?>{};
      for (final key in preferences.getKeys()) {
        if (!BackupInventory.preferenceAllowed(key) ||
            key == 'selected_workspace_id') {
          continue;
        }
        final scopedOwner = BackupInventory.preferenceOwner(key);
        if (scopedOwner != null &&
            !grants.any((g) => g.ownerUserId == scopedOwner)) {
          throw const BackupFailure(BackupFailureCode.fullBackupUnavailable);
        }
        prefs[key] = preferences.get(key);
      }
      final device = await (database.select(
        database.workspaceDeviceStates,
      )..where((row) => row.id.equals('device'))).getSingleOrNull();
      if (device?.selectedWorkspaceId case final String id) {
        prefs['selected_workspace_id'] = id;
      }
      serializedBytes += utf8.encode(jsonEncode(prefs)).length;
      if (serializedBytes > maximumBackupBytes) {
        throw const BackupFailure(BackupFailureCode.tooLarge);
      }
      final document = BackupDocument(
        id: const Uuid().v4(),
        capturedAt: capturedAt,
        sourceSchema: database.schemaVersion,
        scope: BackupScope.full,
        tables: tables,
        preferences: prefs,
      );
      await _requireGrants(grants);
      requireInterfaceAccess?.call();
      return CapturedBackup._(document, grants, requireInterfaceAccess);
    });
    requireInterfaceAccess?.call();
    return captured;
  }

  void _checkInventory() {
    if (database.schemaVersion != AppDatabase.supportedSchemaVersion ||
        !const SetEquality<String>().equals(
          database.allTables.map((t) => t.actualTableName).toSet(),
          BackupInventory.sourceColumns.keys.toSet(),
        )) {
      throw const BackupFailure(BackupFailureCode.unsupportedSchema);
    }
    for (final table in database.allTables) {
      if (!const SetEquality<String>().equals(
        table.$columns.map((c) => c.$name).toSet(),
        BackupInventory.sourceColumns[table.actualTableName]!.toSet(),
      )) {
        throw const BackupFailure(BackupFailureCode.unsupportedSchema);
      }
    }
  }

  Future<void> _requireGrants(List<WorkspaceContext> grants) async {
    try {
      for (final grant in grants) {
        await access.requireCurrent(grant);
      }
    } on WorkspaceAccessFailure {
      throw const BackupFailure(BackupFailureCode.staleAccess);
    }
  }

  Future<BackupSaveResult> save(
    CapturedBackup snapshot, {
    String? password,
    bool allowClear = false,
  }) async {
    snapshot._interfaceAccess?.call();
    final requireInterfaceAccess = captureInterfaceAccess?.call();
    requireInterfaceAccess?.call();
    // Encryption and the external chooser stay outside the snapshot transaction.
    final bytes = await codec.encode(
      snapshot.document,
      password: password,
      allowClear: allowClear,
    );
    final date = snapshot.document.capturedAt.toIso8601String().substring(
      0,
      10,
    );
    requireInterfaceAccess?.call();
    snapshot._interfaceAccess?.call();
    final location = await files.chooseSave('Simpastil-$date.simpbak');
    if (location == null) {
      return const BackupSaveResult(BackupSaveStatus.cancelled);
    }
    return _writeAndVerify(
      snapshot,
      location,
      bytes,
      password: password,
      requireInterfaceAccess: requireInterfaceAccess,
    );
  }

  Future<BackupDestinationChoice?> chooseDestination({
    String? suggestedName,
  }) async {
    final date = clock().toIso8601String().substring(0, 10);
    final location = await files.chooseSave(
      suggestedName ?? 'Simpastil-$date.simpbak',
    );
    return location == null ? null : BackupDestinationChoice._(location);
  }

  /// Writes a new snapshot to a prior chooser result. The snapshot itself
  /// must have been captured after the latest successful unlock; its original
  /// lease is still checked in addition to this operation's fresh lease.
  Future<BackupSaveResult> saveToDestination(
    CapturedBackup snapshot,
    BackupDestinationChoice choice, {
    String? password,
    bool allowClear = false,
  }) async {
    snapshot._interfaceAccess?.call();
    final requireInterfaceAccess = captureInterfaceAccess?.call();
    requireInterfaceAccess?.call();
    final bytes = await codec.encode(
      snapshot.document,
      password: password,
      allowClear: allowClear,
    );
    requireInterfaceAccess?.call();
    snapshot._interfaceAccess?.call();
    return _writeAndVerify(
      snapshot,
      choice._location,
      bytes,
      password: password,
      requireInterfaceAccess: requireInterfaceAccess,
    );
  }

  Future<BackupSaveResult> _writeAndVerify(
    CapturedBackup snapshot,
    BackupFileLocation location,
    Uint8List bytes, {
    required String? password,
    required InterfaceAccessCheck? requireInterfaceAccess,
  }) async {
    await beforeDisclosure?.call();
    await database.transaction(() => _requireGrants(snapshot._grants));
    // No asynchronous work separates this exact lease check from dispatch.
    requireInterfaceAccess?.call();
    snapshot._interfaceAccess?.call();
    try {
      // Dispatch follows the last grant check. Once dispatched, a provider
      // failure may leave a partial file; do not call it a clean cancellation.
      await files.write(location, bytes);
    } catch (_) {
      return BackupSaveResult(
        BackupSaveStatus.saveFailedMayBePartial,
        location: location,
        capturedAt: snapshot.document.capturedAt,
      );
    }
    Uint8List stored;
    try {
      stored = await files.read(location);
    } on BackupFailure {
      return BackupSaveResult(
        BackupSaveStatus.savedCheckFailed,
        location: location,
        capturedAt: snapshot.document.capturedAt,
      );
    } catch (_) {
      return BackupSaveResult(
        BackupSaveStatus.savedUnchecked,
        location: location,
        capturedAt: snapshot.document.capturedAt,
      );
    }
    try {
      if (sha256.convert(stored) != sha256.convert(bytes)) {
        throw const BackupFailure(BackupFailureCode.integrity);
      }
      await codec.decode(stored, password: password);
    } catch (_) {
      return BackupSaveResult(
        BackupSaveStatus.savedCheckFailed,
        location: location,
        capturedAt: snapshot.document.capturedAt,
      );
    }
    return BackupSaveResult(
      BackupSaveStatus.savedChecked,
      location: location,
      capturedAt: snapshot.document.capturedAt,
      checkedAt: clock().toUtc(),
    );
  }
}

/// Ownership constraints include historical identifiers whose parent was
/// deleted. A missing join cannot silently discard retained evidence. All
/// connected constraints must resolve to exactly one currently granted owner.
class BackupOwnership {
  static Map<String, String> validate(
    Map<String, List<Map<String, Object?>>> tables,
    Set<String> allowedOwners, {
    bool allowUnattributedHistory = false,
  }) {
    final graph = <String, Set<String>>{}, owners = <String, Set<String>>{};
    final rowNodes = <String>[];
    final archivalRows = <String>{};
    String node(String type, Object id) => jsonEncode([type, id]);
    void link(String a, String b) {
      (graph[a] ??= {}).add(b);
      (graph[b] ??= {}).add(a);
    }

    String? entity(String type, Object? id) =>
        id == null ? null : node(type, id);
    String? historicalType(Object? type) => const {
      'profile': 'profile',
      'profiles': 'profile',
      'pill': 'pill',
      'pills': 'pill',
      'schedule': 'schedule',
      'schedules': 'schedule',
      'dose_log': 'dose',
      'occurrence': 'occurrence',
      'occurrence_event': 'event',
      'inventory_event': 'inventory',
      'medication_command': 'command',
    }[type];
    for (final entry in tables.entries) {
      final table = entry.key;
      for (final row in entry.value) {
        final r = node(table, [
          for (final key in BackupInventory.primaryKeys[table]!) row[key],
        ]);
        rowNodes.add(r);
        graph.putIfAbsent(r, () => {});
        void relate(String type, Object? id) {
          final e = entity(type, id);
          if (e != null) link(r, e);
        }

        void owner(Object? value) {
          if (value is! String || !allowedOwners.contains(value)) {
            throw const BackupFailure(BackupFailureCode.ownershipUnproven);
          }
          (owners[r] ??= {}).add(value);
        }

        switch (table) {
          case 'users':
            owner(row['id']);
          case 'care_workspaces':
            owner(row['owner_user_id']);
            relate('workspace', row['id']);
            relate('author', row['current_author_id']);
            relate('profile', row['selected_profile_id']);
          case 'profiles':
            owner(row['user_id']);
            relate('profile', row['id']);
          case 'pills':
            relate('pill', row['id']);
            relate('profile', row['profile_id']);
          case 'schedules':
            relate('schedule', row['id']);
            relate('pill', row['pill_id']);
          case 'dose_logs':
            archivalRows.add(r);
            relate('dose', row['id']);
            relate('schedule', row['schedule_id']);
          case 'medication_occurrences':
            owner(row['user_id']);
            relate('occurrence', row['id']);
            relate('pill', row['pill_id']);
            relate('schedule', row['schedule_id']);
          case 'occurrence_events':
            owner(row['user_id']);
            relate('event', row['id']);
            relate('occurrence', row['occurrence_id']);
            relate('event', row['reverses_event_id']);
            relate('command', row['command_id']);
          case 'inventory_events':
            owner(row['user_id']);
            relate('inventory', row['id']);
            relate('pill', row['pill_id']);
            relate('event', row['occurrence_event_id']);
            relate('inventory', row['reverses_inventory_event_id']);
            relate('command', row['command_id']);
          case 'pending_operations':
            owner(row['user_id']);
            relate('operation', row['id']);
            relate('operation', row['depends_on_operation_id']);
          case 'pending_operation_effects':
            relate('operation', row['operation_id']);
            relate(
              row['kind'] == 'dose' ? 'dose' : 'pill',
              row['legacy_source_id'],
            );
          case 'sync_staging_runs':
            owner(row['user_id']);
            relate('run', row['id']);
          case 'sync_staging_items':
            relate('run', row['run_id']);
            final type = historicalType(row['entity_type']);
            if (type != null) relate(type, row['entity_id']);
            // Interrupted legacy cleanup could leave a payload without its run.
            // Retain its explicit constraints; a missing parent is never proof
            // of ownership, nor permission to activate it during restoration.
            Object? decoded;
            try {
              decoded = jsonDecode(row['payload_json'] as String);
            } on Object {
              break;
            }
            final payload = decoded is Map ? decoded['payload'] : null;
            if (payload is! Map) break;
            switch (payload['kind']) {
              case 'account':
                owner(payload['id']);
              case 'profile':
                owner(payload['userId']);
                relate('profile', payload['id']);
              case 'pill':
                relate('pill', payload['id']);
                relate('profile', payload['profileId']);
              case 'schedule':
                relate('schedule', payload['id']);
                relate('pill', payload['pillId']);
              case 'bridgeDose':
                relate('dose', payload['id']);
                relate('schedule', payload['scheduleId']);
                final schedule = payload['parentSchedule'];
                final pill = payload['parentPill'];
                final profile = payload['parentProfile'];
                if (schedule != null) {
                  if (schedule is! Map ||
                      schedule['id'] != payload['scheduleId']) {
                    throw const BackupFailure(
                      BackupFailureCode.ownershipUnproven,
                    );
                  }
                  relate('pill', schedule['pillId']);
                }
                if (pill != null || profile != null) {
                  if (schedule is! Map ||
                      pill is! Map ||
                      profile is! Map ||
                      schedule['pillId'] != pill['id'] ||
                      pill['profileId'] != profile['id']) {
                    throw const BackupFailure(
                      BackupFailureCode.ownershipUnproven,
                    );
                  }
                  owner(profile['userId']);
                  relate('profile', profile['id']);
                }
                archivalRows.add(r);
              case 'bridgeStock':
                relate('pill', payload['pillId']);
                archivalRows.add(r);
              case 'legacyEstimatedHistory':
                relate('pill', payload['pillId']);
                relate('schedule', payload['scheduleId']);
                if (payload['legacySourceKind'] == 'dose_log') {
                  relate('dose', payload['legacySourceId']);
                } else if (payload['legacySourceKind'] == 'pill_stock') {
                  relate('pill', payload['legacySourceId']);
                }
                archivalRows.add(r);
              case 'medicationOccurrence':
                relate('occurrence', payload['id']);
                relate('pill', payload['pillId']);
                relate('schedule', payload['scheduleId']);
                final snapshot = payload['scheduleSnapshot'];
                if (snapshot is Map) relate('profile', snapshot['profileId']);
                archivalRows.add(r);
              case 'migrationIssue':
                relate('issue', payload['id']);
                final type = historicalType(payload['entityType']);
                if (type != null) relate(type, payload['entityId']);
              case 'occurrenceEvent':
                relate('event', payload['id']);
                relate('occurrence', payload['occurrenceId']);
              case 'inventoryEvent':
                relate('inventory', payload['id']);
                relate('pill', payload['pillId']);
            }
          case 'migration_issues':
            owner(row['user_id']);
            relate('issue', row['id']);
            final type = historicalType(row['entity_type']);
            if (type != null) relate(type, row['entity_id']);
          case 'workspace_authors':
            relate('author', row['id']);
            relate('workspace', row['workspace_id']);
          case 'local_routines':
            relate('workspace', row['workspace_id']);
            relate('author', row['author_id']);
            relate('pill', row['pill_id']);
          case 'care_event_details':
            relate('event', row['event_id']);
            relate('workspace', row['workspace_id']);
            relate('author', row['author_id']);
            relate('command', row['command_id']);
          case 'reviewed_stock_balances':
            relate('workspace', row['workspace_id']);
            relate('author', row['author_id']);
            relate('pill', row['pill_id']);
          case 'setup_drafts':
            relate('workspace', row['workspace_id']);
            relate('author', row['author_id']);
            relate('profile', row['profile_id']);
            relate('pill', row['medication_id']);
          case 'medication_details':
          case 'medication_photos':
            relate('pill', row['pill_id']);
          case 'device_person_reminders':
            relate('profile', row['profile_id']);
          case 'device_reminder_settings':
            relate('workspace', row['workspace_id']);
          case 'device_schedule_reminders':
            relate('workspace', row['workspace_id']);
            relate('schedule', row['schedule_id']);
          case 'import_receipts':
            relate('receipt', row['id']);
            relate('workspace', row['workspace_id']);
          case 'import_evidence':
            relate('receipt', row['receipt_id']);
          case 'import_conflicts':
            relate('receipt', row['receipt_id']);
            relate('workspace', row['workspace_id']);
          default:
            throw const BackupFailure(BackupFailureCode.unsupportedSchema);
        }
      }
    }
    final seen = <String>{}, rows = rowNodes.toSet();
    final proven = <String, String>{};
    for (final start in rowNodes) {
      if (seen.contains(start)) continue;
      final pending = [start], proof = <String>{}, componentRows = <String>[];
      while (pending.isNotEmpty) {
        final current = pending.removeLast();
        if (!seen.add(current)) continue;
        if (rows.contains(current)) componentRows.add(current);
        proof.addAll(owners[current] ?? const {});
        pending.addAll(graph[current] ?? const {});
      }
      if (proof.isEmpty &&
          allowUnattributedHistory &&
          componentRows.every(archivalRows.contains)) {
        // Full app-data archival exception: preserve exact orphan history,
        // deliberately OMIT ownership. Full import must quarantine these rows.
        continue;
      }
      if (proof.length != 1) {
        throw const BackupFailure(BackupFailureCode.ownershipUnproven);
      }
      for (final row in componentRows) {
        proven[row] = proof.single;
      }
    }
    return proven;
  }
}
