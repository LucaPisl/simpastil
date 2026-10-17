import 'package:drift/drift.dart';

import '../db/database.dart';
import '../sync/sync_review_repository.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';

class CareSharingStatus {
  const CareSharingStatus({
    required this.isLocalOnly,
    required this.lastCarePullAt,
    required this.pendingCount,
    required this.needsReviewCount,
    required this.uncertainCount,
  });
  final bool isLocalOnly;
  final DateTime? lastCarePullAt;
  final int pendingCount;
  final int needsReviewCount;
  final int uncertainCount;
}

/// The captured grant establishes the connected workspace, not internet
/// reachability. Global preferences and push-success timestamps are excluded.
class CareSharingStatusRepository {
  const CareSharingStatusRepository({
    required this.database,
    required this.access,
    required this.context,
  });
  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final WorkspaceContext context;

  Future<CareSharingStatus> load() => access.withGrant(context, () async {
    if (context.isLocal) {
      return const CareSharingStatus(
        isLocalOnly: true,
        lastCarePullAt: null,
        pendingCount: 0,
        needsReviewCount: 0,
        uncertainCount: 0,
      );
    }
    final people = await database.profilesDao.getByUserId(context.ownerUserId);
    final checkpoints =
        await (database.select(database.workspaceSyncCheckpoints)..where(
              (c) =>
                  c.workspaceId.equals(context.workspaceId) &
                  c.channel.equals('carePull'),
            ))
            .get();
    final byPerson = {for (final c in checkpoints) c.profileId: c.completedAt};
    DateTime? lastCarePullAt;
    if (people.isNotEmpty && people.every((p) => byPerson.containsKey(p.id))) {
      // The oldest covered-person checkpoint bounds the whole care collection.
      lastCarePullAt = people
          .map((p) => byPerson[p.id]!)
          .reduce((a, b) => a.isBefore(b) ? a : b);
    }
    final review = await SyncReviewRepository(
      database: database,
      access: access,
      context: context,
    ).readQueueUnderGrant();
    return CareSharingStatus(
      isLocalOnly: false,
      lastCarePullAt: lastCarePullAt,
      pendingCount: review.pendingCount,
      needsReviewCount: review.needsReviewCount,
      uncertainCount: review.uncertainCount,
    );
  });

  Stream<CareSharingStatus> watch() => database
      .customSelect(
        // Drift shares identical SQL streams; keep this dependency set distinct.
        'SELECT 1 AS care_sharing_changes',
        readsFrom: {
          database.workspaceSyncCheckpoints,
          database.migrationIssues,
          database.profiles,
          ...SyncReviewRepository(
            database: database,
            access: access,
            context: context,
          ).queueDependencies,
        },
      )
      .watch()
      .asyncMap((_) => load());
}
