import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../db/database.dart';
import '../auth/credential_refresh_coordinator.dart';
import '../projections/projection_effects_gate.dart';
import '../projections/restore_projection_retirement.dart';
import '../storage/protected_database.dart';
import '../storage/protected_file_store.dart';
import '../storage/protected_store_gate.dart';
import '../storage/recovery_copy_service.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import 'backup_inventory.dart';
import 'backup_manifest.dart';
import 'backup_service.dart';
import 'import_identity_map.dart';
import 'import_plan.dart';
import 'restore_preferences.dart';
export 'import_plan.dart';

export 'import_rows.dart' show canonicalImportJson;
import 'import_rows.dart';
part 'import_service_preview.dart';
part 'import_service_full_apply.dart';

class _Execution {
  _Execution(
    this.source,
    this.receiptId,
    this.targetDigest,
    this.map,
    this.rows,
    this.connected,
  );
  final CheckedBackup source;
  final String receiptId, targetDigest;
  final ImportIdentityMap map;
  final List<ImportRow> rows;
  final List<_ConnectedPartition> connected;
}

class _ConnectedPartition {
  _ConnectedPartition(this.source, this.previous, this.grant, this.grantDigest);
  final Map<String, Object?> source;
  final CareWorkspace? previous;
  final WorkspaceContext? grant;
  final String? grantDigest;
  String get owner => source['owner_user_id'] as String;
  String get id => source['id'] as String;
}

class _FullExecution {
  _FullExecution({
    required this.source,
    required this.rows,
    required this.map,
    required this.targetDigest,
    required this.markerRevision,
    required this.beforePreferences,
    required this.afterPreferences,
    required this.grants,
    required this.baseRows,
    required this.receiptId,
    required this.accessEpoch,
    required this.networkEpoch,
    required this.installationEpoch,
    required this.retiredProjections,
  });
  final CheckedBackup source;
  final List<ImportRow> rows;
  final ImportIdentityMap map;
  final String targetDigest, markerRevision, receiptId;
  final Map<String, Object?> beforePreferences, afterPreferences;
  final List<WorkspaceContext> grants;
  final Map<String, Map<String, Object?>> baseRows;
  final int accessEpoch, networkEpoch, installationEpoch;
  final List<RestoreProjectionRetirement> retiredProjections;
  WorkspaceContext? appliedContext;
}

class _ImportHashSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest value) {
    this.value = value;
  }

  @override
  void close() {}
}

class ImportService {
  ImportService({
    required this.database,
    required this.access,
    required this.preferences,
    required this.context,
    this.beforeApply,
    this.requireInterfaceAccess,
    this.beforeCommit,
    this.store,
    this.refreshGate,
    this.projectionGate,
    this.preferenceGate,
    this.syncDirectory,
    this.drainRuntime,
    this.resumeRuntime,
    this.sourceRecheck,
    this.afterFullActivation,
  });
  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final SharedPreferences preferences;
  final WorkspaceContext context;
  final Future<void> Function()? beforeApply, beforeCommit;
  final void Function()? requireInterfaceAccess;
  final ProtectedFileStore? store;
  final CredentialRefreshGate? refreshGate;
  final ProjectionEffectsGate? projectionGate, preferenceGate;
  final Future<void> Function(String)? syncDirectory;
  final Future<void> Function()? drainRuntime, resumeRuntime;
  final Future<CheckedBackup> Function(CheckedBackup)? sourceRecheck;
  final Future<bool> Function(List<WorkspaceContext>, WorkspaceContext)?
  afterFullActivation;
  final _plans = Expando<_Execution>();
  final _fullPlans = Expando<_FullExecution>();
  final _fullReplays = Expando<(CheckedBackup, String)>();

  Future<void> _requireCurrent() async {
    try {
      await access.requireCurrent(context);
      requireInterfaceAccess?.call();
    } on WorkspaceAccessFailure {
      throw const ImportFailure(ImportFailureCode.staleAccess);
    }
  }

  /// Preview never ensures a workspace, writes receipts or starts reminders.
  Future<ImportPlan> preview(
    CheckedBackup source,
    ImportSelection selection,
  ) async {
    requireInterfaceAccess?.call();
    final plan = await (selection.mode == ImportMode.full
        ? _previewFull(source)
        : _previewSelected(source, selection));
    requireInterfaceAccess?.call();
    return plan;
  }

  Future<ImportResult> apply(ImportPlan plan) async {
    requireInterfaceAccess?.call();
    if (plan.mode == ImportMode.full) return _applyFull(plan);
    final execution = _plans[plan];
    if (execution == null) {
      throw const ImportFailure(ImportFailureCode.invalidSelection);
    }
    await beforeApply?.call();
    if (sourceRecheck case final recheck?) {
      final actual = await recheck(execution.source);
      if (importDigest(actual.document.toJson()) !=
          importDigest(execution.source.document.toJson())) {
        throw const ImportFailure(ImportFailureCode.invalidSource);
      }
    }
    try {
      return await database.transaction(() async {
        await _requireCurrent();
        await _requireSelectedGrants(execution.connected);
        await database.customStatement(
          'UPDATE workspace_grants SET epoch=epoch WHERE workspace_id=?',
          [context.workspaceId],
        );
        if (await (database.select(database.importReceipts)
                  ..where((r) => r.id.equals(execution.receiptId)))
                .getSingleOrNull() !=
            null) {
          return const ImportResult(
            added: 0,
            conflicts: 0,
            retainedWork: 0,
            alreadyApplied: true,
          );
        }
        if (await _currentSelectedDigest(execution.connected) !=
            execution.targetDigest) {
          throw const ImportFailure(ImportFailureCode.staleTarget);
        }
        final now = DateTime.now().toUtc();
        for (final partition in execution.connected.where(
          (p) => p.previous == null,
        )) {
          final owner = execution.source.document.tables['users']!.singleWhere(
            (u) => u['id'] == partition.owner,
          );
          await _insertRow('users', owner);
          final author = const Uuid().v4();
          await _insertRow('care_workspaces', {
            ...partition.source,
            'singleton_key': null,
            'current_author_id': author,
            'selected_profile_id': null,
            'view_everyone': 0,
          });
          await database
              .into(database.workspaceAuthors)
              .insert(
                WorkspaceAuthorsCompanion.insert(
                  id: author,
                  workspaceId: partition.id,
                  provenance: 'workspace',
                  createdAt: now,
                ),
              );
          await database
              .into(database.workspaceGrants)
              .insert(
                WorkspaceGrantsCompanion.insert(workspaceId: partition.id),
              );
        }
        await database
            .into(database.importReceipts)
            .insert(
              ImportReceiptsCompanion.insert(
                id: execution.receiptId,
                workspaceId: context.workspaceId,
                sourceDigest: plan.sourceDigest,
                sourceDocumentId: execution.source.document.id,
                sourceCapturedAt: plan.sourceCapturedAt,
                mode: plan.mode.name,
                selectedProfileIdsJson: jsonEncode(
                  plan.people.map((p) => p.id).toList()..sort(),
                ),
                identityMapJson: canonicalImportJson(execution.map.toJson()),
                appliedAt: now,
              ),
            );
        var added = 0;
        for (final row in execution.rows) {
          final disposition = row.conflict || row.blocked
              ? 'conflict'
              : row.quarantined
              ? 'quarantined'
              : row.detachedHistory
              ? 'detachedHistory'
              : row.identical
              ? 'identical'
              : 'imported';
          await _evidence(
            execution.receiptId,
            row,
            row.original,
            'incoming',
            disposition,
          );
          if (row.conflict) {
            await _evidence(
              execution.receiptId,
              row,
              row.current!,
              'current',
              'conflict',
            );
            await database
                .into(database.importConflicts)
                .insert(
                  ImportConflictsCompanion.insert(
                    id: importDigest([
                      execution.receiptId,
                      row.table,
                      importKey(row.table, row.original),
                    ]),
                    receiptId: execution.receiptId,
                    workspaceId: context.workspaceId,
                    entityTable: row.table,
                    entityKey: importKey(row.table, row.original),
                    currentDigest: importDigest(row.current),
                    incomingDigest: importDigest(row.original),
                    createdAt: now,
                  ),
                );
          }
          if (!row.quarantined && !row.blocked && row.current == null) {
            final columns = row.operational.keys.toList();
            await database.customStatement(
              'INSERT INTO "${row.table}" (${columns.map((c) => '"$c"').join(',')}) VALUES (${columns.map((_) => '?').join(',')})',
              [for (final column in columns) row.operational[column]],
            );
            added++;
          }
        }
        await beforeCommit?.call();
        await _requireCurrent();
        await _requireSelectedGrants(execution.connected);
        requireInterfaceAccess?.call();
        database.markTablesUpdated(database.allTables);
        return ImportResult(
          added: added,
          conflicts: plan.conflicts,
          retainedWork: plan.retainedWork,
          alreadyApplied: false,
        );
      });
    } on ImportFailure {
      rethrow;
    } catch (_) {
      throw const ImportFailure(ImportFailureCode.commitFailed);
    }
  }

  Future<void> _insertRow(
    String table,
    Map<String, Object?> row,
  ) => database.customStatement(
    'INSERT INTO "$table" (${row.keys.map((c) => '"$c"').join(',')}) VALUES (${row.keys.map((_) => '?').join(',')})',
    row.values.toList(),
  );

  Future<void> _evidence(
    String receipt,
    ImportRow row,
    Map<String, Object?> value,
    String version,
    String disposition,
  ) async {
    final bytes = Uint8List.fromList(utf8.encode(canonicalImportJson(value)));
    final digest = sha256.convert(bytes).toString();
    const chunkSize = 384 * 1024;
    for (
      var at = 0, ordinal = 0;
      at < bytes.length;
      at += chunkSize, ordinal++
    ) {
      final end = (at + chunkSize).clamp(0, bytes.length);
      await database
          .into(database.importEvidence)
          .insert(
            ImportEvidenceCompanion.insert(
              receiptId: receipt,
              entityTable: row.table,
              entityKey: importKey(row.table, row.original),
              version: version,
              ordinal: ordinal,
              sourceDigest: digest,
              payloadBase64: base64.encode(
                Uint8List.sublistView(bytes, at, end),
              ),
              disposition: disposition,
            ),
          );
    }
  }

  String _targetDigest(Map<String, List<Map<String, Object?>>> tables) =>
      importDigest({
        'tables': tables,
        'preferences': {
          for (final k in preferences.getKeys())
            if (BackupInventory.preferenceAllowed(k)) k: preferences.get(k),
        },
        'context': [
          context.workspaceId,
          context.ownerUserId,
          context.authorId,
          context.accessEpoch,
        ],
      });

  Future<bool> _hasRow(String table, Map<String, Object?> key) async =>
      (await database
              .customSelect(
                'SELECT COUNT(*) AS n FROM "$table" WHERE ${key.keys.map((k) => '"$k"=?').join(' AND ')}',
                variables: [for (final value in key.values) Variable(value)],
              )
              .getSingle())
          .read<int>('n') !=
      0;

  Future<void> _requireSelectedGrants(
    List<_ConnectedPartition> partitions,
  ) async {
    try {
      for (final partition in partitions) {
        if (partition.grant case final grant?) {
          await access.requireCurrent(grant);
        }
      }
    } on WorkspaceAccessFailure {
      throw const ImportFailure(ImportFailureCode.staleAccess);
    }
  }

  Future<String?> _selectedGrantDigest(String workspaceId) async {
    final row = await (database.select(
      database.workspaceGrants,
    )..where((g) => g.workspaceId.equals(workspaceId))).getSingleOrNull();
    return row == null ? null : importDigest(row.toJson());
  }

  Future<Map<String, List<Map<String, Object?>>>> _selectedTargetRows(
    List<_ConnectedPartition> partitions,
  ) async {
    final result = await _targetRows();
    for (final partition in partitions) {
      if (partition.grant case final grant?) {
        await access.requireCurrent(grant);
        final rows = await _targetRows(grant);
        for (final entry in rows.entries) {
          result[entry.key]!.addAll(entry.value);
        }
      }
    }
    return result;
  }

  String _selectedDigest(
    Map<String, List<Map<String, Object?>>> rows,
    List<_ConnectedPartition> partitions,
  ) => importDigest({
    'target': _targetDigest(rows),
    'connectedMetadata': [
      for (final p in partitions) [p.previous?.toJson(), p.grantDigest],
    ],
  });

  Future<String> _currentSelectedDigest(
    List<_ConnectedPartition> partitions,
  ) async {
    final current = <_ConnectedPartition>[];
    for (final p in partitions) {
      final matches = await (database.select(
        database.careWorkspaces,
      )..where((w) => w.id.equals(p.id) | w.ownerUserId.equals(p.owner))).get();
      if (matches.length > 1 ||
          (p.previous == null && await _hasRow('users', {'id': p.owner}))) {
        throw const ImportFailure(ImportFailureCode.staleTarget);
      }
      current.add(
        _ConnectedPartition(
          p.source,
          matches.firstOrNull,
          p.grant,
          await _selectedGrantDigest(p.id),
        ),
      );
    }
    return _selectedDigest(await _selectedTargetRows(partitions), current);
  }

  Future<Map<String, List<Map<String, Object?>>>> _targetRows([
    WorkspaceContext? selected,
  ]) async {
    final target = selected ?? context;
    final owner = target.ownerUserId, workspace = target.workspaceId;
    final filters = <String, (String, String)>{
      'users': ('id=?', owner),
      'care_workspaces': ('id=?', workspace),
      'workspace_authors': ('workspace_id=?', workspace),
      'profiles': ('user_id=?', owner),
      'pills': (
        'profile_id IN (SELECT id FROM profiles WHERE user_id=?)',
        owner,
      ),
      'schedules': (
        'pill_id IN (SELECT p.id FROM pills p JOIN profiles f ON f.id=p.profile_id WHERE f.user_id=?)',
        owner,
      ),
      'dose_logs': (
        'schedule_id IN (SELECT s.id FROM schedules s JOIN pills p ON p.id=s.pill_id JOIN profiles f ON f.id=p.profile_id WHERE f.user_id=?)',
        owner,
      ),
      'medication_occurrences': ('user_id=?', owner),
      'occurrence_events': ('user_id=?', owner),
      'inventory_events': ('user_id=?', owner),
      'migration_issues': ('user_id=?', owner),
      'local_routines': ('workspace_id=?', workspace),
      'care_event_details': ('workspace_id=?', workspace),
      'reviewed_stock_balances': ('workspace_id=?', workspace),
      'setup_drafts': ('workspace_id=?', workspace),
      'medication_details': (
        'pill_id IN (SELECT p.id FROM pills p JOIN profiles f ON f.id=p.profile_id WHERE f.user_id=?)',
        owner,
      ),
      'device_person_reminders': (
        'profile_id IN (SELECT id FROM profiles WHERE user_id=?)',
        owner,
      ),
      'device_schedule_reminders': ('workspace_id=?', workspace),
      'device_reminder_settings': ('workspace_id=?', workspace),
      'pending_operations': ('user_id=?', owner),
      'pending_operation_effects': (
        'operation_id IN (SELECT id FROM pending_operations WHERE user_id=?)',
        owner,
      ),
      'sync_staging_runs': ('user_id=?', owner),
      'sync_staging_items': (
        'run_id IN (SELECT id FROM sync_staging_runs WHERE user_id=?)',
        owner,
      ),
      'import_receipts': ('workspace_id=?', workspace),
      'import_conflicts': ('workspace_id=?', workspace),
      'import_evidence': (
        'receipt_id IN (SELECT id FROM import_receipts WHERE workspace_id=?)',
        workspace,
      ),
    };
    return {
      for (final entry in filters.entries)
        entry.key:
            (await database
                    .customSelect(
                      'SELECT ${BackupInventory.portableColumns(entry.key).map((c) => '"$c"').join(',')} FROM "${entry.key}" WHERE ${entry.value.$1} ORDER BY rowid',
                      variables: [Variable<String>(entry.value.$2)],
                    )
                    .get())
                .map((r) => r.data)
                .toList(),
    };
  }
}
