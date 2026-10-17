part of 'import_service.dart';

/// Full-replacement executor of [ImportService]: one protected-store
/// transaction with writer reservation, encrypted recovery and receipts.
extension _ImportFullApply on ImportService {
  Future<ImportResult> _applyFull(ImportPlan plan) async {
    if (_fullReplays[plan] case final replay?) {
      await _requireCurrent();
      final rechecked = await sourceRecheck!(replay.$1);
      if (importDigest(rechecked.document.toJson()) !=
          importDigest(replay.$1.document.toJson())) {
        throw const ImportFailure(ImportFailureCode.invalidSource);
      }
      return _fullReplayResult(replay.$2, context);
    }
    final execution = _fullPlans[plan];
    if (execution == null) {
      throw const ImportFailure(ImportFailureCode.invalidSelection);
    }
    if (execution.appliedContext case final applied?) {
      return _fullReplayResult(execution.receiptId, applied);
    }
    await beforeApply?.call();
    final rechecked = await sourceRecheck!(execution.source);
    if (importDigest(rechecked.document.toJson()) !=
        importDigest(execution.source.document.toJson())) {
      throw const ImportFailure(ImportFailureCode.invalidSource);
    }
    var committed = false;
    final fresh = WorkspaceContext(
      workspaceId: context.workspaceId,
      ownerUserId: context.ownerUserId,
      authorId: context.authorId,
      kind: WorkspaceKind.local,
      accessEpoch: execution.accessEpoch,
    );
    try {
      await drainRuntime!();
      await withProtectedStoreGate(
        store!.root,
        () => refreshGate!.run(
          (_) => projectionGate!.run(
            () => preferenceGate!.run(
              () => database.transaction(() async {
                await _requireCurrent();
                // This reservation is held continuously through all external reader
                // verification and the final atomic care activation.
                await database.customStatement(
                  'UPDATE workspace_grants SET epoch=epoch WHERE workspace_id=?',
                  [context.workspaceId],
                );
                for (final grant in execution.grants) {
                  await access.requireCurrent(grant);
                }
                await preferences.reload();
                final actual = portablePreferenceSnapshot(preferences);
                if (await _fullTargetDigest(actual) != execution.targetDigest ||
                    (await store!.manifest()).revision !=
                        execution.markerRevision) {
                  throw const ImportFailure(ImportFailureCode.staleTarget);
                }
                ProtectedReplacementRecovery recovery;
                try {
                  recovery = await createProtectedReplacementRecovery(
                    root: store!.root,
                    keyStore: store!.keyStore,
                    maximumSchema: store!.maximumSchema,
                    expectedManifestRevision: execution.markerRevision,
                    preferences: execution.beforePreferences,
                    syncDirectory: syncDirectory!,
                  );
                } catch (_) {
                  throw const ImportFailure(
                    ImportFailureCode.recoveryUnavailable,
                  );
                }
                requireInterfaceAccess?.call();
                await database.customStatement('PRAGMA defer_foreign_keys=ON');
                for (final table in database.allTables) {
                  await database.customStatement(
                    'DELETE FROM "${table.actualTableName}"',
                  );
                }
                final localWorkspace = Map<String, Object?>.of(
                  execution.baseRows['care_workspaces']!,
                );
                final sourceLocal = execution
                    .source
                    .document
                    .tables['care_workspaces']!
                    .where((w) => w['kind'] == 'local')
                    .firstOrNull;
                localWorkspace['selected_profile_id'] =
                    sourceLocal?['selected_profile_id'];
                localWorkspace['view_everyone'] =
                    sourceLocal?['view_everyone'] ?? 0;
                await _insertRow('users', execution.baseRows['users']!);
                await _insertRow('care_workspaces', localWorkspace);
                await _insertRow(
                  'workspace_authors',
                  execution.baseRows['workspace_authors']!,
                );
                final now = DateTime.now().toUtc();
                await database
                    .into(database.importReceipts)
                    .insert(
                      ImportReceiptsCompanion.insert(
                        id: execution.receiptId,
                        workspaceId: context.workspaceId,
                        sourceDigest: plan.sourceDigest,
                        sourceDocumentId: execution.source.document.id,
                        sourceCapturedAt: plan.sourceCapturedAt,
                        mode: 'full',
                        selectedProfileIdsJson: jsonEncode(
                          plan.people.map((p) => p.id).toList()..sort(),
                        ),
                        identityMapJson: canonicalImportJson(
                          execution.map.toJson(),
                        ),
                        appliedAt: now,
                      ),
                    );
                for (final row in execution.rows) {
                  await _evidence(
                    execution.receiptId,
                    row,
                    row.original,
                    'incoming',
                    row.conflict
                        ? 'conflict'
                        : row.quarantined
                        ? 'quarantined'
                        : row.detachedHistory
                        ? 'detachedHistory'
                        : row.identical
                        ? 'identical'
                        : 'imported',
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
                  if (!row.quarantined && row.current == null) {
                    await _insertRow(row.table, row.operational);
                  }
                }
                for (final workspace
                    in await database.select(database.careWorkspaces).get()) {
                  if (workspace.kind == 'connected') {
                    final author = const Uuid().v4();
                    await database
                        .into(database.workspaceAuthors)
                        .insert(
                          WorkspaceAuthorsCompanion.insert(
                            id: author,
                            workspaceId: workspace.id,
                            provenance: 'workspace',
                            createdAt: now,
                          ),
                        );
                    await (database.update(
                      database.careWorkspaces,
                    )..where((r) => r.id.equals(workspace.id))).write(
                      CareWorkspacesCompanion(currentAuthorId: Value(author)),
                    );
                  }
                  await database
                      .into(database.workspaceGrants)
                      .insert(
                        WorkspaceGrantsCompanion.insert(
                          workspaceId: workspace.id,
                          epoch: Value(execution.accessEpoch),
                          isGranted: Value(workspace.kind == 'local'),
                        ),
                      );
                }
                await database
                    .into(database.workspaceDeviceStates)
                    .insert(
                      WorkspaceDeviceStatesCompanion.insert(
                        id: 'device',
                        selectedWorkspaceId: Value(context.workspaceId),
                        networkEpoch: Value(execution.networkEpoch),
                        installationEpoch: Value(execution.installationEpoch),
                      ),
                    );
                await RestorePreferencesService(
                  database: database,
                  preferences: preferences,
                  effectsGate: preferenceGate!,
                ).stage(
                  id: execution.receiptId,
                  receiptId: execution.receiptId,
                  recoveryGeneration: recovery.generation,
                  before: execution.beforePreferences,
                  after: execution.afterPreferences,
                  retiredProjections: execution.retiredProjections,
                );
                await beforeCommit?.call();
                await access.requireCurrent(fresh);
                requireInterfaceAccess?.call();
                database.markTablesUpdated(database.allTables);
              }),
            ),
          ),
        ),
      );
      committed = true;
      execution.appliedContext = fresh;
    } on ImportFailure {
      rethrow;
    } catch (_) {
      throw const ImportFailure(ImportFailureCode.commitFailed);
    } finally {
      if (!committed) {
        try {
          await resumeRuntime!();
        } catch (_) {
          /* Care remains original; optional runtime retry is separate. */
        }
      }
    }
    database.refreshExternalChanges();
    var state = PreferenceRestoreState.pending;
    try {
      state = await RestorePreferencesService(
        database: database,
        preferences: preferences,
        effectsGate: preferenceGate!,
      ).reconcile();
    } catch (_) {
      /* Retain the durable pending intent. */
    }
    var projectionsPending = true;
    try {
      projectionsPending =
          !(await afterFullActivation?.call(execution.grants, fresh) ?? false);
      if (!projectionsPending) {
        await access.withGrant(fresh, () async {
          await (database.update(
            database.deviceRestoreIntents,
          )..where((r) => r.id.equals(execution.receiptId))).write(
            const DeviceRestoreIntentsCompanion(
              projectionsCompleted: Value(true),
            ),
          );
        });
      }
    } catch (_) {
      projectionsPending = true;
      /* Committed care does not imply observed platform completion. */
    }
    return ImportResult(
      added: plan.additions,
      conflicts: plan.conflicts,
      retainedWork: plan.retainedWork,
      alreadyApplied: false,
      recoveryChecked: true,
      projectionsPending: projectionsPending,
      preferences: switch (state) {
        PreferenceRestoreState.pending => ImportPreferenceState.pending,
        PreferenceRestoreState.needsReview => ImportPreferenceState.needsReview,
        _ => ImportPreferenceState.completed,
      },
    );
  }

  Future<ImportResult> _fullReplayResult(
    String receiptId,
    WorkspaceContext grant,
  ) async {
    await access.requireCurrent(grant);
    if (await _fullReceipt(receiptId) == null) {
      throw const ImportFailure(ImportFailureCode.staleTarget);
    }
    final intent = await (database.select(
      database.deviceRestoreIntents,
    )..where((r) => r.receiptId.equals(receiptId))).getSingleOrNull();
    var checked = false;
    if (intent != null) {
      try {
        final manifest = await store!.manifest();
        checked =
            manifest.recovery == intent.recoveryGeneration &&
            (await RecoveryCopyService(store!).check(manifest)).state ==
                RecoveryCopyState.checked;
      } catch (_) {
        // A previously checked recovery is not proof of current availability.
      }
    }
    await access.requireCurrent(grant);
    return ImportResult(
      added: 0,
      conflicts: 0,
      retainedWork: 0,
      alreadyApplied: true,
      recoveryChecked: checked,
      preferences: switch (intent?.state) {
        'completed' => ImportPreferenceState.completed,
        'conflict' => ImportPreferenceState.needsReview,
        'pending' => ImportPreferenceState.pending,
        _ => ImportPreferenceState.unchanged,
      },
      projectionsPending: intent?.projectionsCompleted != true,
    );
  }
}
