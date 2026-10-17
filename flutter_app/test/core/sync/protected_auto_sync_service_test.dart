import 'dart:async';
import 'dart:ui';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/projections/projection_identity.dart';
import 'package:simpastil/core/projections/projection_reconciler.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/core/sync/auto_sync_service.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/sync_service.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

const _owner = '00000000-0000-4000-8000-000000000001';

class _SyncProbe extends SyncService {
  _SyncProbe(AppDatabase db, Dio dio, SyncWriteScope scope)
    : super(db: db, dio: dio, writeScope: scope);
  int flushes = 0;
  Future<void> Function()? afterPull;

  @override
  Future<void> flushPending({String? userId}) async {
    flushes++;
  }

  @override
  Future<bool> pullFromServer({required String userId}) async {
    await afterPull?.call();
    return true;
  }

  @override
  Future<int> countPending({String? userId}) async => 0;
  @override
  Future<SyncOperationCounts> countOperations({String? userId}) async =>
      SyncOperationCounts.none;

  @override
  Future<void> purgeSyncedTombstones({
    Duration maxAge = const Duration(days: 90),
  }) async {}
}

class _ReconcileProbe extends Mock implements ProjectionReconciler {
  final identities = <ProjectionIdentity?>[];

  @override
  Future<ProjectionReconciliationReport?> reconcile({
    SessionIdentity? identity,
    Locale? locale,
    ProjectionIdentity? projectionIdentity,
  }) async {
    identities.add(projectionIdentity);
    return null;
  }

  int allWorkspacePasses = 0;

  @override
  Future<ReconcileAllResult> reconcileAll({
    Locale? locale,
    bool refreshActiveActions = false,
    String? buildKey,
  }) async {
    allWorkspacePasses++;
    return const ReconcileAllResult(ready: true);
  }
}

Future<WorkspaceContext> _activate(
  WorkspaceAccessRepository access,
  String slot,
) async {
  const endpoint = 'https://fictional-auto-sync.test/care';
  await access.configureEndpoint(endpoint);
  await access.database
      .into(access.database.credentialSlots)
      .insert(
        CredentialSlotsCompanion.insert(
          id: slot,
          ownerId: _owner,
          endpoint: endpoint,
          state: 'staged',
          createdAt: DateTime.now().toUtc(),
        ),
      );
  final activated = await access.authenticate(
    ownerId: _owner,
    endpoint: endpoint,
    expectedNetworkEpoch: await access.revokeNetwork(),
    sessionGeneration: 1,
    credentialId: slot,
  );
  if (activated.workspace.bindingState != 'bound') {
    await access.confirmOriginalServer(
      workspaceId: activated.workspace.id,
      reviewedOriginalEndpoint: endpoint,
      expectedNetworkEpoch: activated.network.epoch,
    );
  }
  return (await access.contextForOwner(_owner))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final scenario in [
    'current',
    'replaced after pull',
    'revoked before run',
  ]) {
    test('foreground sync freezes projection grant: $scenario', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      final access = WorkspaceAccessRepository(
        db,
        effectsGate: SerialProjectionEffectsGate(),
      );
      await _activate(access, 'fictional-slot-a');
      final dio = Dio();
      addTearDown(() => dio.close(force: true));
      final scope = SyncWriteScope(
        access: access,
        capability: await access.currentNetworkCapability(),
      );
      final sync = _SyncProbe(db, dio, scope);
      final projections = _ReconcileProbe();
      final connectivity =
          StreamController<List<ConnectivityResult>>.broadcast();
      addTearDown(connectivity.close);
      late AutoSyncService auto;
      final provider = Provider<AutoSyncService>((ref) {
        auto = AutoSyncService(
          ref: ref,
          connectivityStream: connectivity.stream,
          generationRepository: SessionGenerationRepository(
            preferences,
            access: access,
          ),
        );
        ref.onDispose(auto.stop);
        return auto;
      });
      final container = ProviderContainer(
        overrides: [
          syncServiceProvider.overrideWithValue(sync),
          projectionReconcilerProvider.overrideWithValue(projections),
        ],
      );
      addTearDown(container.dispose);
      if (scenario == 'replaced after pull') {
        sync.afterPull = () async {
          await _activate(access, 'fictional-slot-b');
        };
      } else if (scenario == 'revoked before run') {
        await access.revokeNetwork();
      }
      await container.read(provider).syncNow(_owner, generation: 1);
      if (scenario == 'current') {
        expect(projections.allWorkspacePasses, 1);
        expect(sync.flushes, 1);
      } else {
        expect(projections.allWorkspacePasses, 0);
        expect(sync.flushes, scenario == 'revoked before run' ? 0 : 1);
      }
    });
  }
}
