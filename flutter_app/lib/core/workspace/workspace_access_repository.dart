import 'package:drift/drift.dart';
import 'package:drift/isolate.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../db/database.dart';
import '../projections/projection_effects_gate.dart';
import 'workspace_context.dart';
import 'workspace_repository.dart';

class AuthenticatedWorkspace {
  const AuthenticatedWorkspace(this.workspace, this.network);
  final CareWorkspace workspace;
  final NetworkCapability network;
}

class RevokedNetworkState {
  const RevokedNetworkState(
    this.epoch,
    this.credentialId,
    this.installationKeyId,
  );
  final int epoch;
  final String? credentialId;
  final String? installationKeyId;
}

class WorkspaceAccessRepository {
  WorkspaceAccessRepository(this.database, {this.onWriteBusy, this.effectsGate})
    : workspaces = WorkspaceRepository(database);
  final AppDatabase database;
  final WorkspaceRepository workspaces;
  static const _ids = Uuid();
  final void Function()? onWriteBusy;
  final ProjectionEffectsGate? effectsGate;

  Future<T> _retryTransaction<T>(Future<T> Function() action) async {
    final elapsed = Stopwatch()..start();
    while (true) {
      try {
        return await database.transaction(action);
      } catch (error) {
        final cause = error is DriftRemoteException ? error.remoteCause : error;
        if (cause is! SqliteException ||
            !const {5, 6}.contains(cause.resultCode)) {
          rethrow;
        }
        if (elapsed.elapsed >= const Duration(seconds: 3)) {
          throw const WorkspaceAccessFailure(
            WorkspaceAccessFailureCode.unavailable,
          );
        }
        onWriteBusy?.call();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }
  }

  /// Revoke before waiting for network/platform teardown. Local access and its
  /// epoch remain independent. This state is visible to background isolates.
  Future<int> revokeNetwork() => _retryTransaction(_revokeNetworkInTransaction);

  Future<int> _revokeNetworkInTransaction() async {
    final local = await workspaces.ensureLocal();
    final state = await workspaces.deviceState();
    for (final workspace in await (database.select(
      database.careWorkspaces,
    )..where((row) => row.kind.equals('connected'))).get()) {
      await database.customUpdate(
        'UPDATE workspace_grants SET is_granted=0, epoch=epoch+1, session_generation=NULL, network_epoch=NULL, endpoint=NULL WHERE workspace_id=?',
        variables: [Variable<String>(workspace.id)],
        updates: {database.workspaceGrants},
      );
    }
    final epoch = state.networkEpoch + 1;
    await (database.update(
      database.workspaceDeviceStates,
    )..where((row) => row.id.equals('device'))).write(
      WorkspaceDeviceStatesCompanion(
        networkEpoch: Value(epoch),
        networkOwnerId: const Value(null),
        networkEndpoint: const Value(null),
        networkGeneration: const Value(null),
        networkCredentialId: const Value(null),
        selectedWorkspaceId: Value(local.id),
      ),
    );
    return epoch;
  }

  Future<bool> networkIsCurrent(NetworkCapability capability) async {
    final state = await workspaces.deviceState();
    return state.networkOwnerId == capability.ownerId &&
        state.networkEndpoint == capability.endpoint &&
        state.networkEpoch == capability.epoch &&
        state.networkGeneration == capability.generation;
  }

  Future<int?> revokeTransition(int expectedEpoch) =>
      _retryTransaction(() async {
        if ((await workspaces.deviceState()).networkEpoch != expectedEpoch) {
          return null;
        }
        return _revokeNetworkInTransaction();
      });

  Future<InstallationCapability?> captureInstallation(String endpoint) async {
    final canonical = canonicalServerEndpoint(endpoint);
    final state = await workspaces.deviceState();
    if (state.configuredEndpoint != canonical) return null;
    return InstallationCapability(
      endpoint: canonical,
      epoch: state.installationEpoch,
      networkEpoch: state.networkEpoch,
    );
  }

  Future<bool> installationIsCurrent(InstallationCapability capability) async {
    final state = await workspaces.deviceState();
    return state.configuredEndpoint == capability.endpoint &&
        state.installationEpoch == capability.epoch &&
        state.networkEpoch == capability.networkEpoch;
  }

  Future<int> configureEndpoint(String endpoint) => _retryTransaction(() async {
    final canonical = canonicalServerEndpoint(endpoint);
    await workspaces.ensureLocal();
    final prior = await workspaces.deviceState();
    if (prior.configuredEndpoint == canonical) return prior.networkEpoch;
    final epoch = await _revokeNetworkInTransaction();
    await (database.update(
      database.workspaceDeviceStates,
    )..where((row) => row.id.equals('device'))).write(
      WorkspaceDeviceStatesCompanion(
        configuredEndpoint: Value(canonical),
        installationEpoch: Value(prior.installationEpoch + 1),
        installationKeyId: const Value(null),
      ),
    );
    return epoch;
  });

  /// Forgets a server whose sign-in never finished, so the device works
  /// locally again. A signed-in device leaves through Log out instead, so
  /// this refuses (false) while a session holds the network.
  Future<bool> forgetEndpoint(String endpoint) => _retryTransaction(() async {
    final canonical = canonicalServerEndpoint(endpoint);
    final prior = await workspaces.deviceState();
    if (prior.configuredEndpoint != canonical || prior.networkOwnerId != null) {
      return false;
    }
    await _revokeNetworkInTransaction();
    await (database.update(
      database.workspaceDeviceStates,
    )..where((row) => row.id.equals('device'))).write(
      WorkspaceDeviceStatesCompanion(
        configuredEndpoint: const Value(null),
        installationEpoch: Value(prior.installationEpoch + 1),
        installationKeyId: const Value(null),
      ),
    );
    return true;
  });

  /// Call only after authentication on the captured endpoint. An unresolved
  /// cache keeps its old owner and remains locked until original-server review.
  Future<AuthenticatedWorkspace> authenticate({
    required String ownerId,
    required String endpoint,
    required int expectedNetworkEpoch,
    required int sessionGeneration,
    required String credentialId,
    InstallationCapability? installation,
  }) => _activateWithEffectsBarrier(
    () => database.transaction(() async {
      final canonical = canonicalServerEndpoint(endpoint);
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(credentialId)) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.unavailable,
        );
      }
      final state = await workspaces.deviceState();
      if (state.networkEpoch != expectedNetworkEpoch ||
          (installation != null &&
              (installation.endpoint != canonical ||
                  !await installationIsCurrent(installation)))) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.staleNetworkTransition,
        );
      }
      final slot = await (database.select(
        database.credentialSlots,
      )..where((row) => row.id.equals(credentialId))).getSingleOrNull();
      if (slot == null ||
          slot.state != 'staged' ||
          slot.ownerId != ownerId ||
          slot.endpoint != canonical) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.unavailable,
        );
      }
      var workspace = await workspaces.byOwner(ownerId);
      if (workspace != null &&
          (workspace.kind != 'connected' ||
              (workspace.bindingState == 'bound' &&
                  workspace.endpoint != canonical))) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.ownerCollision,
        );
      }
      if (workspace == null) {
        // A previously unmapped populated owner is also uncertain; do not turn
        // historical rows into a new server's cache through this fallback.
        // Retained rows alone make an owner populated, even with no users row.
        final existingOwner = await database.usersDao.getById(ownerId);
        final populated =
            existingOwner != null ||
            await database.ownerHasRetainedRows(ownerId);
        if (existingOwner == null) {
          final now = DateTime.now().toUtc();
          await database.usersDao.upsert(
            UsersCompanion.insert(
              id: ownerId,
              email: '',
              createdAt: now,
              updatedAt: now,
              serverId: Value(ownerId),
              syncStatus: const Value('synced'),
            ),
          );
        }
        final id = _ids.v4();
        await database
            .into(database.careWorkspaces)
            .insert(
              CareWorkspacesCompanion.insert(
                id: id,
                ownerUserId: ownerId,
                kind: 'connected',
                bindingState: populated ? 'unresolved' : 'bound',
                endpoint: populated ? const Value(null) : Value(canonical),
                legacyViewerMigrated: Value(!populated),
                createdAt: DateTime.now().toUtc(),
              ),
            );
        await database
            .into(database.workspaceGrants)
            .insert(WorkspaceGrantsCompanion.insert(workspaceId: id));
        workspace = (await workspaces.byId(id))!;
      }
      final activatedEpoch = state.networkEpoch + 1;
      await (database.update(database.credentialSlots)
            ..where((row) => row.id.equals(credentialId)))
          .write(const CredentialSlotsCompanion(state: Value('published')));
      await (database.update(
        database.workspaceDeviceStates,
      )..where((row) => row.id.equals('device'))).write(
        WorkspaceDeviceStatesCompanion(
          networkOwnerId: Value(ownerId),
          networkEndpoint: Value(canonical),
          networkGeneration: Value(sessionGeneration),
          networkCredentialId: Value(credentialId),
          networkEpoch: Value(activatedEpoch),
        ),
      );
      if (workspace.bindingState == 'bound') {
        await _grant(workspace, sessionGeneration, activatedEpoch);
      }
      return AuthenticatedWorkspace(
        (await workspaces.byId(workspace.id))!,
        NetworkCapability(
          ownerId: ownerId,
          endpoint: canonical,
          epoch: activatedEpoch,
          generation: sessionGeneration,
        ),
      );
    }),
  );

  Future<T> _activateWithEffectsBarrier<T>(Future<T> Function() action) =>
      effectsGate?.run(action) ?? action();

  /// The refresh gate must be held by the caller. A fresh login may retire
  /// old refresh evidence only after the previous account was durably revoked.
  Future<void> requireFreshCredentialTransition({
    required String credentialId,
    required String ownerId,
    required String endpoint,
    required int expectedTransition,
    InstallationCapability? installation,
  }) => _retryTransaction(() async {
    final state = await workspaces.deviceState();
    final slot = await (database.select(
      database.credentialSlots,
    )..where((row) => row.id.equals(credentialId))).getSingleOrNull();
    if (state.networkEpoch != expectedTransition ||
        state.networkOwnerId != null ||
        state.networkEndpoint != null ||
        state.networkGeneration != null ||
        state.networkCredentialId != null ||
        slot == null ||
        slot.state != 'staged' ||
        slot.ownerId != ownerId ||
        slot.endpoint != endpoint ||
        (installation != null && installation.endpoint != endpoint) ||
        (installation != null && !await installationIsCurrent(installation))) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.staleNetworkTransition,
      );
    }
  });

  Future<NetworkCapability?> currentNetworkCapability() async {
    final state = await workspaces.deviceState();
    if (state.networkOwnerId == null ||
        state.networkEndpoint == null ||
        state.networkGeneration == null ||
        state.networkCredentialId == null) {
      return null;
    }
    return NetworkCapability(
      ownerId: state.networkOwnerId!,
      endpoint: state.networkEndpoint!,
      epoch: state.networkEpoch,
      generation: state.networkGeneration!,
    );
  }

  Future<bool> replaceCredentials(
    NetworkCapability capability, {
    required String expectedCredentialId,
    required String stagedCredentialId,
  }) => database.transaction(() async {
    if (!await networkIsCurrent(capability)) return false;
    final slot = await (database.select(
      database.credentialSlots,
    )..where((row) => row.id.equals(stagedCredentialId))).getSingleOrNull();
    if (slot == null ||
        slot.state != 'staged' ||
        slot.ownerId != capability.ownerId ||
        slot.endpoint != capability.endpoint) {
      return false;
    }
    final count =
        await (database.update(database.workspaceDeviceStates)..where(
              (row) =>
                  row.id.equals('device') &
                  row.networkCredentialId.equals(expectedCredentialId),
            ))
            .write(
              WorkspaceDeviceStatesCompanion(
                networkCredentialId: Value(stagedCredentialId),
              ),
            );
    if (count != 1) return false;
    await (database.update(database.credentialSlots)
          ..where((row) => row.id.equals(stagedCredentialId)))
        .write(const CredentialSlotsCompanion(state: Value('published')));
    return true;
  });

  /// Claim deletion durably before secure I/O, so activation and cleanup cannot
  /// race a check-then-delete. Discarded random identities never publish again.
  Future<bool> claimCredentialDiscard(String id) =>
      database.transaction(() async {
        if ((await workspaces.deviceState()).networkCredentialId == id) {
          return false;
        }
        final slot = await (database.select(
          database.credentialSlots,
        )..where((row) => row.id.equals(id))).getSingleOrNull();
        if (slot == null) return false;
        await (database.update(database.credentialSlots)
              ..where((row) => row.id.equals(id)))
            .write(const CredentialSlotsCompanion(state: Value('discarded')));
        return true;
      });

  Future<bool> revokeIfCurrent(NetworkCapability capability) =>
      _retryTransaction(() async {
        if (!await networkIsCurrent(capability)) return false;
        await _revokeNetworkInTransaction();
        return true;
      });

  Future<RevokedNetworkState?> revokeCurrentSession(
    NetworkCapability capability, {
    bool clearInstallationKey = false,
  }) => _retryTransaction(() async {
    if (!await networkIsCurrent(capability)) return null;
    final prior = await workspaces.deviceState();
    if (clearInstallationKey) {
      await (database.update(
        database.workspaceDeviceStates,
      )..where((row) => row.id.equals('device'))).write(
        WorkspaceDeviceStatesCompanion(
          installationKeyId: const Value(null),
          installationEpoch: Value(prior.installationEpoch + 1),
        ),
      );
    }
    final epoch = await _revokeNetworkInTransaction();
    return RevokedNetworkState(
      epoch,
      prior.networkCredentialId,
      clearInstallationKey ? prior.installationKeyId : null,
    );
  });

  Future<WorkspaceContext> confirmOriginalServer({
    required String workspaceId,
    required String reviewedOriginalEndpoint,
    required int expectedNetworkEpoch,
  }) => _activateWithEffectsBarrier(
    () => database.transaction(() async {
      final workspace = await workspaces.byId(workspaceId);
      final state = await workspaces.deviceState();
      final endpoint = canonicalServerEndpoint(reviewedOriginalEndpoint);
      if (workspace == null ||
          workspace.kind != 'connected' ||
          workspace.bindingState != 'unresolved' ||
          state.networkEpoch != expectedNetworkEpoch ||
          state.networkOwnerId != workspace.ownerUserId ||
          state.networkEndpoint != endpoint ||
          state.networkGeneration == null) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.unresolvedOrigin,
        );
      }
      await (database.update(
        database.careWorkspaces,
      )..where((row) => row.id.equals(workspaceId))).write(
        CareWorkspacesCompanion(
          bindingState: const Value('bound'),
          endpoint: Value(endpoint),
        ),
      );
      await _grant(
        (await workspaces.byId(workspaceId))!,
        state.networkGeneration!,
        state.networkEpoch,
      );
      return (await contextForOwner(workspace.ownerUserId))!;
    }),
  );

  Future<void> _grant(
    CareWorkspace workspace,
    int generation,
    int networkEpoch,
  ) async {
    await workspaces.ensureAuthor(workspace);
    await database.customUpdate(
      '''
      UPDATE workspace_grants SET epoch=epoch+1, is_granted=1,
      session_generation=?, network_epoch=?, endpoint=? WHERE workspace_id=?
    ''',
      variables: [
        Variable<int>(generation),
        Variable<int>(networkEpoch),
        Variable<String>(workspace.endpoint!),
        Variable<String>(workspace.id),
      ],
      updates: {database.workspaceGrants},
    );
    await (database.update(
      database.workspaceDeviceStates,
    )..where((row) => row.id.equals('device'))).write(
      WorkspaceDeviceStatesCompanion(selectedWorkspaceId: Value(workspace.id)),
    );
  }

  Future<WorkspaceContext?> contextForOwner(String ownerId) async {
    final workspace = await workspaces.byOwner(ownerId);
    if (workspace == null || workspace.currentAuthorId == null) return null;
    final grant = await (database.select(
      database.workspaceGrants,
    )..where((row) => row.workspaceId.equals(workspace.id))).getSingleOrNull();
    if (grant == null || !grant.isGranted) return null;
    final context = WorkspaceContext(
      workspaceId: workspace.id,
      ownerUserId: ownerId,
      authorId: workspace.currentAuthorId!,
      kind: WorkspaceKind.values.byName(workspace.kind),
      accessEpoch: grant.epoch,
      endpoint: grant.endpoint,
      sessionGeneration: grant.sessionGeneration,
      networkEpoch: grant.networkEpoch,
    );
    try {
      await requireCurrent(context);
      return context;
    } on WorkspaceAccessFailure {
      return null;
    }
  }

  Future<WorkspaceContext> currentContext() => database.transaction(() async {
    final local = await workspaces.ensureLocal();
    final state = await workspaces.deviceState();
    final viewed = state.selectedWorkspaceId == null
        ? null
        : await workspaces.byId(state.selectedWorkspaceId!);
    final available =
        (viewed == null ? null : await contextForOwner(viewed.ownerUserId)) ??
        await contextForOwner(local.ownerUserId);
    if (available == null) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.unavailable,
      );
    }
    return available;
  });

  Future<void> requireCurrent(
    WorkspaceContext context, {
    String? profileId,
  }) async {
    final workspace = await workspaces.byId(context.workspaceId);
    final grant =
        await (database.select(database.workspaceGrants)
              ..where((row) => row.workspaceId.equals(context.workspaceId)))
            .getSingleOrNull();
    final author = await (database.select(
      database.workspaceAuthors,
    )..where((row) => row.id.equals(context.authorId))).getSingleOrNull();
    if (workspace == null ||
        workspace.ownerUserId != context.ownerUserId ||
        workspace.kind != context.kind.name ||
        workspace.currentAuthorId != context.authorId ||
        author?.workspaceId != workspace.id ||
        grant == null ||
        !grant.isGranted ||
        grant.epoch != context.accessEpoch ||
        grant.endpoint != context.endpoint ||
        grant.sessionGeneration != context.sessionGeneration ||
        grant.networkEpoch != context.networkEpoch) {
      throw const WorkspaceAccessFailure(WorkspaceAccessFailureCode.staleGrant);
    }
    if (!context.isLocal &&
        (workspace.bindingState != 'bound' ||
            workspace.endpoint != context.endpoint ||
            context.endpoint == null ||
            context.networkEpoch == null ||
            context.sessionGeneration == null ||
            !await networkIsCurrent(
              NetworkCapability(
                ownerId: context.ownerUserId,
                endpoint: context.endpoint!,
                epoch: context.networkEpoch!,
                generation: context.sessionGeneration!,
              ),
            ))) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.endpointMismatch,
      );
    }
    if (profileId != null) {
      await workspaces.requirePerson(context.ownerUserId, profileId);
    }
  }

  Future<T> withGrant<T>(
    WorkspaceContext context,
    Future<T> Function() action, {
    String? profileId,
  }) => database.transaction(() async {
    await requireCurrent(context, profileId: profileId);
    final result = await action();
    await requireCurrent(context);
    return result;
  });

  Future<void> viewWorkspace(WorkspaceContext context) =>
      withGrant(context, () async {
        await (database.update(
          database.workspaceDeviceStates,
        )..where((row) => row.id.equals('device'))).write(
          WorkspaceDeviceStatesCompanion(
            selectedWorkspaceId: Value(context.workspaceId),
          ),
        );
      });

  Future<void> viewPerson(
    WorkspaceContext context,
    String? profileId, {
    bool everyone = false,
  }) => withGrant(context, () async {
    if (profileId == null && !everyone) {
      throw ArgumentError('Choose a person or Everyone explicitly');
    }
    await (database.update(
      database.careWorkspaces,
    )..where((row) => row.id.equals(context.workspaceId))).write(
      CareWorkspacesCompanion(
        selectedProfileId: Value(profileId),
        viewEveryone: Value(everyone),
        legacyViewerMigrated: const Value(true),
      ),
    );
  }, profileId: profileId);

  Future<void> adoptLegacySelection(
    WorkspaceContext context, {
    String? selectedId,
    String? primaryId,
  }) => withGrant(context, () async {
    final workspace = (await workspaces.byId(context.workspaceId))!;
    if (workspace.legacyViewerMigrated) return;
    final people = await database.profilesDao.getByUserId(context.ownerUserId);
    final ids = people.map((person) => person.id).toSet();
    final selected = ids.contains(selectedId)
        ? selectedId
        : ids.contains(primaryId)
        ? primaryId
        : people.firstOrNull?.id;
    await (database.update(
      database.careWorkspaces,
    )..where((row) => row.id.equals(context.workspaceId))).write(
      CareWorkspacesCompanion(
        selectedProfileId: Value(selected),
        viewEveryone: const Value(false),
        legacyViewerMigrated: const Value(true),
      ),
    );
  });

  Stream<WorkspaceContext> watchContext() async* {
    await currentContext();
    yield* database
        .customSelect(
          '''
      SELECT d.id FROM workspace_device_states d
      LEFT JOIN care_workspaces w ON w.id=d.selected_workspace_id
      LEFT JOIN workspace_grants g ON g.workspace_id=w.id
      LEFT JOIN workspace_authors a ON a.id=w.current_author_id
    ''',
          readsFrom: {
            database.workspaceDeviceStates,
            database.careWorkspaces,
            database.workspaceGrants,
            database.workspaceAuthors,
          },
        )
        .watch()
        .asyncMap((_) => currentContext())
        .distinct();
  }
}
