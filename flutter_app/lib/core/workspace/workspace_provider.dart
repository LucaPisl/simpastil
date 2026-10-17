import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';
import '../projections/projection_effects_gate.dart';
import '../storage/shared_preferences_provider.dart';
import 'workspace_access_repository.dart';
import 'workspace_context.dart';
import 'workspace_repository.dart';

final workspaceRepositoryProvider = Provider<WorkspaceRepository>(
  (ref) => WorkspaceRepository(ref.watch(databaseProvider)),
);

final workspaceAccessRepositoryProvider = Provider<WorkspaceAccessRepository>(
  (ref) => WorkspaceAccessRepository(
    ref.watch(databaseProvider),
    effectsGate: privateProjectionEffectsGate,
  ),
);

/// Availability remains asynchronous: a protected-store failure cannot become
/// an empty profile collection or a fabricated authenticated local account.
final workspaceContextProvider = StreamProvider<WorkspaceContext>((ref) {
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final preferences = ref.watch(sharedPreferencesProvider);
  return access.watchContext().asyncMap((context) async {
    await access.adoptLegacySelection(
      context,
      selectedId: preferences.getString(
        'selected_profile_id_${context.ownerUserId}',
      ),
      primaryId: preferences.getString(
        'primary_profile_id_${context.ownerUserId}',
      ),
    );
    return context;
  });
});

typedef ProtectedWorkspaceSelection = ({
  String? selectedProfileId,
  bool viewEveryone,
});

/// Observes display selection independently from the authorization context.
/// Selection writes must wake profile-scoped views without rebuilding every
/// provider that depends on the stable workspace capability.
final protectedWorkspaceSelectionProvider =
    StreamProvider<ProtectedWorkspaceSelection>((ref) async* {
      final context = await ref.watch(workspaceContextProvider.future);
      final db = ref.watch(databaseProvider);
      final access = ref.watch(workspaceAccessRepositoryProvider);
      final selectionQuery = db.select(db.careWorkspaces)
        ..where((row) => row.id.equals(context.workspaceId));
      yield* selectionQuery
          .watchSingle()
          .asyncMap(
            (_) => access.withGrant(context, () async {
              final workspace = await access.workspaces.byId(
                context.workspaceId,
              );
              if (workspace == null) {
                throw const WorkspaceAccessFailure(
                  WorkspaceAccessFailureCode.unavailable,
                );
              }
              return (
                selectedProfileId: workspace.selectedProfileId,
                viewEveryone: workspace.viewEveryone,
              );
            }),
          )
          .distinct();
    });

/// A retained unresolved account is reported separately from available local
/// care, so its absence never masquerades as an empty/new connected collection.
/// The signed-in account's workspace wins; otherwise the oldest unresolved
/// connected workspace is reported so a launch can point at care that waits for
/// original-server review before anyone has signed in.
final retainedAccountWorkspaceProvider = StreamProvider<CareWorkspace?>((ref) {
  final db = ref.watch(databaseProvider);
  final workspaces = ref.watch(workspaceRepositoryProvider);
  return db
      .customSelect(
        '''
    SELECT COALESCE(
      (SELECT w.id FROM workspace_device_states d
         JOIN care_workspaces w ON w.owner_user_id=d.network_owner_id
         WHERE d.id='device'),
      (SELECT w.id FROM care_workspaces w
         WHERE w.kind='connected' AND w.binding_state='unresolved'
         ORDER BY w.created_at, w.id LIMIT 1)
    ) AS id
  ''',
        readsFrom: {db.workspaceDeviceStates, db.careWorkspaces},
      )
      .watch()
      .asyncMap((rows) async {
        final id = rows.firstOrNull?.readNullable<String>('id');
        return id == null ? null : workspaces.byId(id);
      });
});

final networkCapabilityProvider = StreamProvider<NetworkCapability?>((ref) {
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final db = access.database;
  return db
      .select(db.workspaceDeviceStates)
      .watch()
      .asyncMap((_) => access.currentNetworkCapability())
      .distinct();
});

final connectionDeviceStateProvider = StreamProvider<WorkspaceDeviceState?>((
  ref,
) {
  final db = ref.watch(databaseProvider);
  return (db.select(
    db.workspaceDeviceStates,
  )..where((row) => row.id.equals('device'))).watchSingleOrNull();
});

NetworkCapability? networkCapabilityFromState(WorkspaceDeviceState state) {
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
