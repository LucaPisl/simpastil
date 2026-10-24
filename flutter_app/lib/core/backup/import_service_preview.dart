part of 'import_service.dart';

/// Read-only planning half of [ImportService]: validates a checked backup
/// and builds an [ImportPlan] without writing receipts or starting reminders.
extension _ImportPreview on ImportService {
  Future<ImportPlan> _previewFull(CheckedBackup source) async {
    if (!context.isLocal ||
        store == null ||
        refreshGate == null ||
        projectionGate == null ||
        preferenceGate == null ||
        syncDirectory == null ||
        drainRuntime == null ||
        resumeRuntime == null ||
        sourceRecheck == null) {
      throw const ImportFailure(ImportFailureCode.invalidSelection);
    }
    await preferences.reload();
    return database.transaction(() async {
      await _requireCurrent();
      final sourceDigest = importDigest(source.document.tables);
      final receipt = importDigest([
        sourceDigest,
        'full',
        context.workspaceId,
        source.document.preferences,
      ]);
      if (await _fullReceipt(receipt) != null) {
        // A repeat is not a new destructive review. In particular, do not read
        // newly locked connected care or replace records made since this import.
        final plan = ImportPlan(
          sourceDigest: sourceDigest,
          sourceCapturedAt: source.document.capturedAt,
          mode: ImportMode.full,
          target: context,
          people: const [],
          ownershipTranslations: const [],
          preservation: const ImportPreservation(
            exactOriginalsRetained: true,
            historicalAuthorshipRetained: true,
            pendingWorkIsolated: true,
            targetAuthorPreserved: true,
            targetPreferencesPreserved: true,
          ),
          additions: 0,
          identical: 0,
          conflicts: 0,
          retainedWork: 0,
          alreadyApplied: true,
        );
        _fullReplays[plan] = (source, receipt);
        return plan;
      }
      final grants = <WorkspaceContext>[];
      final existing = await database.select(database.careWorkspaces).get();
      for (final workspace in existing) {
        final grant = await access.contextForOwner(workspace.ownerUserId);
        if (grant == null) {
          throw const ImportFailure(ImportFailureCode.staleAccess);
        }
        await access.requireCurrent(grant);
        grants.add(grant);
      }
      final tables = source.document.tables;
      final ownership = BackupOwnership.validate(
        tables,
        tables['users']!.map((r) => r['id'] as String).toSet(),
        allowUnattributedHistory: source.document.scope == BackupScope.full,
      );
      final sourceWorkspaces = tables['care_workspaces']!;
      if (sourceWorkspaces.any(
        (w) =>
            !const {'local', 'connected'}.contains(w['kind']) ||
            (w['kind'] == 'local' && w['binding_state'] != 'local'),
      )) {
        throw const ImportFailure(ImportFailureCode.invalidSource);
      }
      for (final incoming in sourceWorkspaces.where(
        (w) => w['kind'] == 'connected',
      )) {
        final previous = existing.where(
          (w) =>
              w.id == incoming['id'] ||
              w.ownerUserId == incoming['owner_user_id'],
        );
        if (previous.any(
          (w) =>
              w.kind != 'connected' ||
              w.id != incoming['id'] ||
              w.ownerUserId != incoming['owner_user_id'] ||
              w.endpoint != incoming['endpoint'],
        )) {
          throw const ImportFailure(ImportFailureCode.invalidSource);
        }
      }
      final map = ImportIdentityMap(context, {
        for (final w in sourceWorkspaces.where((w) => w['kind'] == 'local'))
          w['id'] as String: w['owner_user_id'] as String,
      });
      final rows = fullImportRows(tables, map, ownership);
      final base = <String, Map<String, Object?>>{};
      for (final entry in {
        'users': ('id', context.ownerUserId),
        'care_workspaces': ('id', context.workspaceId),
        'workspace_authors': ('id', context.authorId),
      }.entries) {
        base[entry.key] =
            (await database
                    .customSelect(
                      'SELECT * FROM "${entry.key}" WHERE "${entry.value.$1}"=?',
                      variables: [Variable(entry.value.$2)],
                    )
                    .getSingle())
                .data;
      }
      for (final row in rows.where(
        (r) =>
            r.table == 'workspace_authors' &&
            r.original['id'] == context.authorId,
      )) {
        if (row.operational['workspace_id'] != context.workspaceId) {
          throw const ImportFailure(ImportFailureCode.invalidSource);
        }
        row.current = base['workspace_authors'];
        row.identical =
            importDigest(row.operational) == importDigest(row.current);
        row.conflict = !row.identical;
      }
      final before = Map<String, Object?>.unmodifiable(
        portablePreferenceSnapshot(preferences),
      );
      final after = Map<String, Object?>.of(source.document.preferences)
        ..['selected_workspace_id'] = context.workspaceId;
      for (final key in after.keys.toList()) {
        final owner = BackupInventory.preferenceOwner(key);
        if (owner != null && map.workspaceOwners.values.contains(owner)) {
          final name =
              key.substring(0, key.length - owner.length) + context.ownerUserId;
          if (after.containsKey(name) &&
              canonicalImportJson(after[name]) !=
                  canonicalImportJson(after[key])) {
            throw const ImportFailure(ImportFailureCode.invalidSource);
          }
          after[name] = after.remove(key);
        }
      }
      final marker = await store!.manifest();
      final device = await (database.select(
        database.workspaceDeviceStates,
      )..where((r) => r.id.equals('device'))).getSingle();
      final epoch =
          (await database
                  .customSelect('SELECT MAX(epoch) AS n FROM workspace_grants')
                  .getSingle())
              .read<int>('n') +
          1;
      final replacements = await _replacementWorkspaces(existing);
      final unattributed = <String, int>{};
      for (final table in BackupInventory.portableTableNames) {
        final total =
            (await database
                    .customSelect('SELECT COUNT(*) AS n FROM "$table"')
                    .getSingle())
                .read<int>('n');
        final attributed = replacements.fold<int>(
          0,
          (n, w) => n + w.tableCounts[table]!,
        );
        if (attributed > total) {
          throw const ImportFailure(ImportFailureCode.invalidSource);
        }
        if (attributed < total) unattributed[table] = total - attributed;
      }
      final plan = ImportPlan(
        sourceDigest: sourceDigest,
        sourceCapturedAt: source.document.capturedAt,
        mode: ImportMode.full,
        target: context,
        people: [
          for (final p in tables['profiles']!)
            ImportPerson(
              p['id'] as String,
              p['name'] as String,
              connected: sourceWorkspaces.any(
                (w) =>
                    w['owner_user_id'] == p['user_id'] &&
                    w['kind'] == 'connected',
              ),
              connectedEvidenceOnly: sourceWorkspaces.any(
                (w) =>
                    w['owner_user_id'] == p['user_id'] &&
                    w['kind'] == 'connected',
              ),
              outcome:
                  sourceWorkspaces.any(
                    (w) =>
                        w['owner_user_id'] == p['user_id'] &&
                        w['kind'] == 'connected',
                  )
                  ? ImportPersonOutcome.locked
                  : ImportPersonOutcome.added,
              addedRows: rows
                  .where((r) => r.people.contains(p['id']) && !r.quarantined)
                  .length,
              conflictingRows: rows
                  .where((r) => r.people.contains(p['id']) && r.conflict)
                  .length,
              retainedRows: rows
                  .where((r) => r.people.contains(p['id']) && r.quarantined)
                  .length,
              detachedHistoryRows: rows
                  .where((r) => r.people.contains(p['id']) && r.detachedHistory)
                  .length,
            ),
        ],
        affectedPeople: [
          for (final p in await database.select(database.profiles).get())
            ImportPerson(
              p.id,
              p.name,
              connected: existing.any(
                (w) => w.ownerUserId == p.userId && w.kind == 'connected',
              ),
              outcome: ImportPersonOutcome.replaced,
              addedRows: 0,
              conflictingRows: 0,
              retainedRows: 0,
              detachedHistoryRows: 0,
            ),
        ],
        workspaces: [
          for (final w in sourceWorkspaces)
            ImportWorkspaceReview(
              workspaceId: w['id'] as String,
              ownerId: w['owner_user_id'] as String,
              connected: w['kind'] == 'connected',
              rows: rows
                  .where(
                    (r) =>
                        ownership[importRowNode(r.table, r.original)] ==
                        w['owner_user_id'],
                  )
                  .length,
              retainedRows: rows
                  .where(
                    (r) =>
                        r.quarantined &&
                        ownership[importRowNode(r.table, r.original)] ==
                            w['owner_user_id'],
                  )
                  .length,
            ),
        ],
        replacedWorkspaces: replacements,
        unattributedTargetCounts: unattributed,
        preferenceChanges: [
          for (final key in {...before.keys, ...after.keys}.toList()..sort())
            if (before.containsKey(key) != after.containsKey(key) ||
                canonicalImportJson(before[key]) !=
                    canonicalImportJson(after[key]))
              ImportPreferenceChange(key, before[key], after[key]),
        ],
        ownershipTranslations: [
          for (final entry in map.workspaceOwners.entries)
            ImportOwnershipTranslation(
              sourceWorkspaceId: entry.key,
              sourceOwnerId: entry.value,
              targetWorkspaceId: context.workspaceId,
              targetOwnerId: context.ownerUserId,
            ),
        ],
        preservation: const ImportPreservation(
          exactOriginalsRetained: true,
          historicalAuthorshipRetained: true,
          pendingWorkIsolated: true,
          targetAuthorPreserved: true,
          targetPreferencesPreserved: false,
        ),
        additions: rows
            .where((r) => !r.quarantined && r.current == null)
            .length,
        identical: rows.where((r) => r.identical).length,
        conflicts: rows.where((r) => r.conflict).length,
        retainedWork: rows.where((r) => r.quarantined).length,
        alreadyApplied: false,
      );
      for (final grant in grants) {
        await access.requireCurrent(grant);
      }
      _fullPlans[plan] = _FullExecution(
        source: source,
        rows: rows,
        map: map,
        targetDigest: await _fullTargetDigest(before),
        markerRevision: marker.revision,
        beforePreferences: before,
        afterPreferences: Map.unmodifiable(after),
        grants: grants,
        baseRows: base,
        receiptId: receipt,
        accessEpoch: epoch,
        networkEpoch: device.networkEpoch + 1,
        installationEpoch: device.installationEpoch + 1,
        retiredProjections: RestoreProjectionRetirement.combine([
          for (final grant in grants)
            RestoreProjectionRetirement(
              grant.workspaceId,
              grant.ownerUserId,
              grant.accessEpoch,
            ),
          ...await RestoreProjectionRetirement.unfinished(database),
        ]),
      );
      return plan;
    });
  }

  Future<ImportReceipt?> _fullReceipt(String id) =>
      (database.select(database.importReceipts)..where(
            (r) =>
                r.id.equals(id) &
                r.workspaceId.equals(context.workspaceId) &
                r.mode.equals('full'),
          ))
          .getSingleOrNull();

  Future<List<ImportReplacementWorkspaceReview>> _replacementWorkspaces(
    List<CareWorkspace> workspaces,
  ) async {
    final result = <ImportReplacementWorkspaceReview>[];
    for (final workspace in workspaces) {
      final counts = <String, int>{};
      for (final table in BackupInventory.portableTableNames) {
        final columns = BackupInventory.portableColumns(table);
        late String condition;
        late String parameter;
        if (columns.contains('workspace_id')) {
          condition = 'r.workspace_id=?';
          parameter = workspace.id;
        } else if (columns.contains('user_id')) {
          condition = 'r.user_id=?';
          parameter = workspace.ownerUserId;
        } else {
          parameter = workspace.ownerUserId;
          condition = switch (table) {
            'users' => 'r.id=?',
            'care_workspaces' => 'r.owner_user_id=?',
            'pills' =>
              'r.profile_id IN (SELECT id FROM profiles WHERE user_id=?)',
            'schedules' || 'medication_details' || 'medication_photos' =>
              'r.pill_id IN (SELECT p.id FROM pills p JOIN profiles f ON f.id=p.profile_id WHERE f.user_id=?)',
            'dose_logs' =>
              'r.schedule_id IN (SELECT s.id FROM schedules s JOIN pills p ON p.id=s.pill_id JOIN profiles f ON f.id=p.profile_id WHERE f.user_id=?)',
            'device_person_reminders' =>
              'r.profile_id IN (SELECT id FROM profiles WHERE user_id=?)',
            'pending_operation_effects' =>
              'r.operation_id IN (SELECT id FROM pending_operations WHERE user_id=?)',
            'sync_staging_items' =>
              'r.run_id IN (SELECT id FROM sync_staging_runs WHERE user_id=?)',
            'import_evidence' =>
              'r.receipt_id IN (SELECT i.id FROM import_receipts i JOIN care_workspaces w ON w.id=i.workspace_id WHERE w.owner_user_id=?)',
            _ => throw const ImportFailure(ImportFailureCode.invalidSource),
          };
        }
        counts[table] =
            (await database
                    .customSelect(
                      'SELECT COUNT(*) AS n FROM "$table" r WHERE $condition',
                      variables: [Variable(parameter)],
                    )
                    .getSingle())
                .read<int>('n');
      }
      result.add(
        ImportReplacementWorkspaceReview(
          workspaceId: workspace.id,
          ownerId: workspace.ownerUserId,
          connected: workspace.kind == 'connected',
          tableCounts: counts,
          operationStates: {
            for (final row
                in await database
                    .customSelect(
                      'SELECT state,COUNT(*) AS n FROM pending_operations WHERE user_id=? GROUP BY state',
                      variables: [Variable(workspace.ownerUserId)],
                    )
                    .get())
              row.read<String>('state'): row.read<int>('n'),
          },
          effectStates: {
            for (final row
                in await database
                    .customSelect(
                      'SELECT e.state,COUNT(*) AS n FROM pending_operation_effects e JOIN pending_operations p ON p.id=e.operation_id WHERE p.user_id=? GROUP BY e.state',
                      variables: [Variable(workspace.ownerUserId)],
                    )
                    .get())
              row.read<String>('state'): row.read<int>('n'),
          },
        ),
      );
    }
    return result;
  }

  Future<String> _fullTargetDigest(Map<String, Object?> prefs) async {
    final sink = _ImportHashSink();
    // Use one connection's reviewed SQLite snapshot; never a second reader's
    // potentially newer view for target planning.
    final conversion = sha256.startChunkedConversion(sink);
    conversion.add(
      utf8.encode(
        canonicalImportJson([
          context.workspaceId,
          context.ownerUserId,
          context.authorId,
          prefs,
        ]),
      ),
    );
    for (final entry in BackupInventory.sourceColumns.entries) {
      conversion.add(utf8.encode(jsonEncode(entry.key)));
      int? after;
      while (true) {
        final rows = await database
            .customSelect(
              'SELECT rowid AS import_rowid,* FROM "${entry.key}" '
              '${after == null ? '' : 'WHERE rowid > $after '}ORDER BY rowid LIMIT 16',
            )
            .get();
        if (rows.isEmpty) break;
        for (final row in rows) {
          final value = Map<String, Object?>.of(row.data);
          after = value.remove('import_rowid') as int;
          conversion.add(utf8.encode(canonicalImportJson(value)));
        }
      }
    }
    conversion.close();
    return sink.value!.toString();
  }

  Future<ImportPlan> _previewSelected(
    CheckedBackup source,
    ImportSelection selection,
  ) => database.transaction(() async {
    await _requireCurrent();
    if (selection.mode != ImportMode.selected ||
        selection.profileIds.isEmpty ||
        !context.isLocal) {
      throw const ImportFailure(ImportFailureCode.invalidSelection);
    }
    final tables = source.document.tables;
    final people = tables['profiles']!
        .where((r) => selection.profileIds.contains(r['id']))
        .toList();
    if (people.length != selection.profileIds.length) {
      throw const ImportFailure(ImportFailureCode.invalidSelection);
    }
    final owners = people.map((r) => r['user_id'] as String).toSet();
    final workspaces = tables['care_workspaces']!
        .where((w) => owners.contains(w['owner_user_id']))
        .toList();
    if (workspaces.length != owners.length ||
        workspaces.any(
          (w) =>
              !const {'local', 'connected'}.contains(w['kind']) ||
              (w['kind'] == 'local' && w['binding_state'] != 'local'),
        )) {
      throw const ImportFailure(ImportFailureCode.invalidSelection);
    }
    final ownership = BackupOwnership.validate(
      tables,
      tables['users']!.map((r) => r['id'] as String).toSet(),
      allowUnattributedHistory: source.document.scope == BackupScope.full,
    );
    final map = ImportIdentityMap(context, {
      for (final w in workspaces.where((w) => w['kind'] == 'local'))
        w['id'] as String: w['owner_user_id'] as String,
    });
    final sourceDigest = importDigest({
      for (final entry in tables.entries)
        entry.key: (entry.value.toList()
          ..sort(
            (a, b) =>
                importKey(entry.key, a).compareTo(importKey(entry.key, b)),
          )),
    });
    final receiptId = importDigest([
      sourceDigest,
      selection.mode.name,
      (selection.profileIds.toList()..sort()),
      context.workspaceId,
    ]);
    final existingReceipt = await (database.select(
      database.importReceipts,
    )..where((r) => r.id.equals(receiptId))).getSingleOrNull();
    final rows = selectedImportRows(
      tables,
      selection.profileIds,
      owners,
      workspaces.map((w) => w['id'] as String).toSet(),
      ownership,
    );
    final connected = <_ConnectedPartition>[];
    for (final w in workspaces.where((w) => w['kind'] == 'connected')) {
      final previous =
          await (database.select(database.careWorkspaces)..where(
                (r) =>
                    r.id.equals(w['id'] as String) |
                    r.ownerUserId.equals(w['owner_user_id'] as String),
              ))
              .get();
      if (previous.length > 1 ||
          previous.any(
            (p) =>
                p.kind != 'connected' ||
                p.id != w['id'] ||
                p.ownerUserId != w['owner_user_id'] ||
                p.bindingState != w['binding_state'] ||
                p.endpoint != w['endpoint'] ||
                p.legacyEndpointHint != w['legacy_endpoint_hint'],
          )) {
        throw const ImportFailure(ImportFailureCode.invalidSource);
      }
      if (previous.isEmpty &&
          await _hasRow('users', {'id': w['owner_user_id']})) {
        // An unmapped retained owner is not a new server account.
        throw const ImportFailure(ImportFailureCode.invalidSource);
      }
      connected.add(
        _ConnectedPartition(
          w,
          previous.firstOrNull,
          await access.contextForOwner(w['owner_user_id'] as String),
          await _selectedGrantDigest(w['id'] as String),
        ),
      );
    }
    final target = await _selectedTargetRows(connected), blocked = <String>{};
    final indexedTarget = {
      for (final entry in target.entries)
        entry.key: {
          for (final row in entry.value) importKey(entry.key, row): row,
        },
    };
    final connectedOwners = {for (final p in connected) p.owner: p};
    for (final row in rows.where(
      (r) =>
          !r.quarantined &&
          const {'profiles', 'pills', 'schedules'}.contains(r.table),
    )) {
      final owner = ownership[importRowNode(row.table, row.original)];
      final partition = connectedOwners[owner];
      if (partition?.grant != null) {
        final current =
            indexedTarget[row.table]?[importKey(row.table, row.original)];
        if (current == null || current['is_deleted'] == 1) {
          blocked.addAll(row.people);
        }
      }
    }
    for (final row in rows) {
      final partition =
          connectedOwners[ownership[importRowNode(row.table, row.original)]];
      if (partition != null) {
        if (partition.grant == null || row.quarantined) {
          row.quarantined = true;
          continue;
        }
        // Archived account facts cannot establish accepted server state. Read
        // only the captured authorized partition; missing rows stay evidence.
        row.operational = Map.of(row.original);
        row.current =
            indexedTarget[row.table]?[importKey(row.table, row.original)];
        if (row.current == null) {
          row.quarantined = true;
          continue;
        }
        row.identical = _sameImportedRow(row);
        row.conflict = !row.identical;
        if (row.conflict) blocked.addAll(row.people);
        continue;
      }
      if (row.quarantined) continue;
      row.operational = map.operational(row.table, row.original);
      final key = importKey(row.table, row.operational);
      row.current = indexedTarget[row.table]?[key];
      if (row.current == null) {
        // Never read a colliding row from another owner's private collection.
        final columns = BackupInventory.primaryKeys[row.table]!;
        final collision = await database
            .customSelect(
              'SELECT COUNT(*) AS n FROM "${row.table}" WHERE ${columns.map((c) => '"$c"=?').join(' AND ')}',
              variables: [
                for (final c in columns) Variable(row.operational[c]),
              ],
            )
            .getSingle();
        if (collision.read<int>('n') != 0) {
          throw const ImportFailure(ImportFailureCode.invalidSource);
        }
      } else {
        row.identical = _sameImportedRow(row);
        row.conflict = !row.identical;
        if (row.conflict) blocked.addAll(row.people);
      }
    }
    for (final row in rows) {
      row.blocked = row.table == 'workspace_authors' && !row.conflict
          ? row.people.isNotEmpty && row.people.every(blocked.contains)
          : row.people.any(blocked.contains);
    }
    await _requireCurrent();
    await _requireSelectedGrants(connected);
    final plan = ImportPlan(
      sourceDigest: sourceDigest,
      sourceCapturedAt: source.document.capturedAt,
      mode: selection.mode,
      target: context,
      people: [
        for (final p in people)
          ImportPerson(
            p['id'] as String,
            p['name'] as String,
            connected: connectedOwners.containsKey(p['user_id']),
            connectedEvidenceOnly: connectedOwners.containsKey(p['user_id']),
            outcome: connectedOwners.containsKey(p['user_id'])
                ? connectedOwners[p['user_id']]!.grant == null
                      ? ImportPersonOutcome.locked
                      : blocked.contains(p['id'])
                      ? ImportPersonOutcome.needsReview
                      : ImportPersonOutcome.unchanged
                : blocked.contains(p['id'])
                ? ImportPersonOutcome.needsReview
                : rows.any(
                    (r) =>
                        r.table == 'profiles' &&
                        r.original['id'] == p['id'] &&
                        r.current == null,
                  )
                ? ImportPersonOutcome.added
                : rows.any(
                    (r) =>
                        !r.quarantined &&
                        !r.blocked &&
                        r.current == null &&
                        r.people.contains(p['id']),
                  )
                ? ImportPersonOutcome.merged
                : ImportPersonOutcome.unchanged,
            addedRows: rows
                .where(
                  (r) =>
                      !r.quarantined &&
                      !r.blocked &&
                      r.current == null &&
                      r.people.contains(p['id']),
                )
                .length,
            conflictingRows: rows
                .where((r) => r.conflict && r.people.contains(p['id']))
                .length,
            retainedRows: rows
                .where(
                  (r) =>
                      (r.quarantined || r.blocked) &&
                      r.people.contains(p['id']),
                )
                .length,
            detachedHistoryRows: rows
                .where(
                  (r) =>
                      r.table == 'medication_occurrences' &&
                      r.people.contains(p['id']) &&
                      !tables['pills']!.any(
                        (pill) =>
                            pill['id'] == r.original['pill_id'] &&
                            pill['profile_id'] == p['id'],
                      ),
                )
                .length,
          ),
      ],
      ownershipTranslations: [
        for (final w in workspaces.where((w) => w['kind'] == 'local'))
          ImportOwnershipTranslation(
            sourceWorkspaceId: w['id'] as String,
            sourceOwnerId: w['owner_user_id'] as String,
            targetWorkspaceId: context.workspaceId,
            targetOwnerId: context.ownerUserId,
          ),
      ],
      workspaces: [
        for (final w in workspaces)
          ImportWorkspaceReview(
            workspaceId: w['id'] as String,
            ownerId: w['owner_user_id'] as String,
            connected: w['kind'] == 'connected',
            rows: rows
                .where(
                  (r) =>
                      ownership[importRowNode(r.table, r.original)] ==
                      w['owner_user_id'],
                )
                .length,
            retainedRows: rows
                .where(
                  (r) =>
                      (r.quarantined || r.blocked) &&
                      ownership[importRowNode(r.table, r.original)] ==
                          w['owner_user_id'],
                )
                .length,
          ),
      ],
      preservation: const ImportPreservation(
        exactOriginalsRetained: true,
        historicalAuthorshipRetained: true,
        pendingWorkIsolated: true,
        targetAuthorPreserved: true,
        targetPreferencesPreserved: true,
      ),
      additions: rows
          .where((r) => !r.quarantined && !r.blocked && r.current == null)
          .length,
      identical: rows.where((r) => r.identical).length,
      conflicts: rows.where((r) => r.conflict).length,
      doseConflicts: importDoseConflicts(rows),
      retainedWork: rows.where((r) => r.quarantined || r.blocked).length,
      alreadyApplied: existingReceipt != null,
    );
    _plans[plan] = _Execution(
      source,
      receiptId,
      _selectedDigest(target, connected),
      map,
      rows,
      connected,
    );
    return plan;
  });
}

const _scheduleWindowColumns = {
  'every_days',
  'anchor_date',
  'start_date',
  'end_date',
};

/// Columns a later schema added to a table, with every one nullable.
const _laterColumns = <String, Set<String>>{
  'schedules': _scheduleWindowColumns,
  'pills': {
    'shape',
    'stock_quantity',
    'stock_unit',
    'stock_needs_recount',
    'prn_max_per_24h',
    'prn_min_gap_minutes',
    'expires_on',
    'prescriber_name',
    'prescriber_phone',
    'pharmacy_name',
    'pharmacy_phone',
  },
  'occurrence_events': {recordedByColumn},
};

/// The name a dose was recorded under is write-once evidence: a document that
/// lacks it, or carries it where the stored row has none, never contradicts the
/// stored row, and a stored name is never replaced by a document without one.
const recordedByColumn = 'recorded_by_json';

/// Whether the incoming row already equals the stored one.
///
/// A document written before a column existed (schedule windows in schema 19,
/// the picked pill shape in schema 20) lacks it, while the stored row always
/// has it (null unless one was set). Those null columns carry no information
/// the document could contradict, so they are ignored when the incoming row
/// omits them.
bool _sameImportedRow(ImportRow row) {
  final current = row.current!;
  // A column the document predates is ignored only while the stored one is
  // still null, so a value the document could contradict is never skipped.
  final ignored = {
    for (final column in _laterColumns[row.table] ?? const <String>{})
      if (column == recordedByColumn
          ? row.operational[column] == null || current[column] == null
          : !row.operational.containsKey(column) &&
                (current[column] == null ||
                    // The recount mark defaults to false rather than null.
                    (column == 'stock_needs_recount' &&
                        (current[column] == 0 || current[column] == false))))
        column,
  };
  final comparable = ignored.isEmpty
      ? current
      : {
          for (final e in current.entries)
            if (!ignored.contains(e.key)) e.key: e.value,
        };
  return importDigest(comparable) == importDigest(row.operational);
}
