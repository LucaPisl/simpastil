import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/db/database.dart';
import '../../core/medication/care_provider.dart';
import '../../core/sync/auto_sync_service.dart';
import '../../core/sync/capabilities_client.dart';
import '../../core/workspace/workspace_provider.dart';
import '../pills/pill_provider.dart';
import '../pills/schedule_provider.dart';
import '../profiles/profile_provider.dart';
import 'move_care_service.dart';
import 'move_plan.dart';
import 'moved_history_client.dart';

/// What the Move screen opens on: the plan, the account people whose names
/// match, and whether the server can hold all of it.
class MovePreview {
  const MovePreview({
    required this.local,
    required this.plan,
    required this.duplicates,
    required this.serverGap,
  });

  final CareWorkspace local;
  final MovePlan plan;
  final Map<String, Profile> duplicates;
  final MoveFailureCode? serverGap;
}

/// Reads the Move preview while a connected account is shown. Reads only.
final movePreviewProvider = FutureProvider.autoDispose<MovePreview>((
  ref,
) async {
  // Every dependency is read before the first await: a Ref must not be used
  // once the provider may have been disposed or rebuilt.
  final connectedFuture = ref.watch(workspaceContextProvider.future);
  final database = ref.watch(databaseProvider);
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final capabilities = ref.read(capabilitiesClientProvider);
  final connected = await connectedFuture;
  if (connected.isLocal) throw StateError('Move needs a connected account');
  final local = await access.workspaces.ensureLocal();
  final plan = await readMovePlan(database, local);
  final duplicates = await moveDuplicates(database, plan, connected);
  final snapshot = await capabilities.refresh();
  return MovePreview(
    local: local,
    plan: plan,
    duplicates: duplicates,
    serverGap: moveServerGap(plan, snapshot.capabilities),
  );
});

/// The Move service for the account shown now.
final moveCareServiceProvider = FutureProvider.autoDispose<MoveCareService>((
  ref,
) async {
  // The repositories need the account context, so it comes first; every
  // other dependency is read before the next await.
  final connected = await ref.watch(workspaceContextProvider.future);
  final recordingFuture = ref.watch(careRecordingServiceProvider.future);
  final autoSync = ref.watch(autoSyncServiceProvider);
  final database = ref.watch(databaseProvider);
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final profiles = ref.watch(profileRepositoryProvider);
  final pills = ref.watch(pillRepositoryProvider);
  final schedules = ref.watch(scheduleRepositoryProvider);
  final dio = ref.watch(apiClientProvider).dio;
  return MoveCareService(
    database: database,
    access: access,
    connected: connected,
    profiles: profiles,
    pills: pills,
    schedules: schedules,
    recording: await recordingFuture,
    movedHistory: MovedHistoryClient(dio),
    sync: () => autoSync.syncNow(connected.ownerUserId),
  );
});
