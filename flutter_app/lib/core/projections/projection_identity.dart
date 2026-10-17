import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import 'restore_projection_retirement.dart';

/// Device projections identify a workspace grant, independently of the viewer
/// and network account. Payloads only carry a hint; protected storage grants
/// authority when an action is actually applied.
class ProjectionIdentity {
  const ProjectionIdentity({
    required this.workspaceId,
    required this.ownerId,
    required this.grantEpoch,
  });
  factory ProjectionIdentity.fromContext(WorkspaceContext context) =>
      ProjectionIdentity(
        workspaceId: context.workspaceId,
        ownerId: context.ownerUserId,
        grantEpoch: context.accessEpoch,
      );
  final String workspaceId;
  final String ownerId;
  final int grantEpoch;
  Map<String, Object> toJson() => {
    'version': 2,
    'workspaceId': workspaceId,
    'userId': ownerId,
    'grantEpoch': grantEpoch,
  };
  static ProjectionIdentity? fromJson(Object? raw) {
    if (raw is! Map ||
        raw['version'] != 2 ||
        raw['workspaceId'] is! String ||
        raw['userId'] is! String ||
        raw['grantEpoch'] is! int) {
      return null;
    }
    final identity = ProjectionIdentity(
      workspaceId: raw['workspaceId'] as String,
      ownerId: raw['userId'] as String,
      grantEpoch: raw['grantEpoch'] as int,
    );
    return identity.workspaceId.isEmpty ||
            identity.ownerId.isEmpty ||
            identity.grantEpoch < 1
        ? null
        : identity;
  }

  Future<WorkspaceContext?> resolve(WorkspaceAccessRepository access) async {
    final context = await access.contextForOwner(ownerId);
    return context?.workspaceId == workspaceId &&
            context?.accessEpoch == grantEpoch
        ? context
        : null;
  }

  /// Retirement needs positive protected metadata. Missing/future ownership is
  /// unavailable, rather than permission to cancel an unrelated projection.
  Future<bool> retirementRequired(WorkspaceAccessRepository access) =>
      access.database.transaction(() async {
        final workspace = await access.workspaces.byId(workspaceId);
        final grant =
            await (access.database.select(access.database.workspaceGrants)
                  ..where((row) => row.workspaceId.equals(workspaceId)))
                .getSingleOrNull();
        if (workspace == null ||
            workspace.ownerUserId != ownerId ||
            !const {'local', 'connected'}.contains(workspace.kind) ||
            grant == null ||
            grant.epoch < grantEpoch) {
          // A replacement can remove the old workspace entirely. Its locally
          // staged proof survives a crash and authorizes clearing only; it
          // never participates in resolve() or care action authorization.
          if (await resolve(access) != null) return false;
          for (final proof in await RestoreProjectionRetirement.unfinished(
            access.database,
          )) {
            if (proof.workspaceId == workspaceId &&
                proof.ownerId == ownerId &&
                grantEpoch >= 1 &&
                grantEpoch <= proof.ceiling) {
              return true;
            }
          }
          throw const FormatException('Unrecognized projection grant');
        }
        if (!grant.isGranted || grant.epoch > grantEpoch) return true;
        if (await resolve(access) == null) {
          throw const WorkspaceAccessFailure(
            WorkspaceAccessFailureCode.unavailable,
          );
        }
        return false;
      });

  bool owns(Object? raw) => fromJson(raw) == this;
  @override
  bool operator ==(Object other) =>
      other is ProjectionIdentity &&
      other.workspaceId == workspaceId &&
      other.ownerId == ownerId &&
      other.grantEpoch == grantEpoch;
  @override
  int get hashCode => Object.hash(workspaceId, ownerId, grantEpoch);
}
