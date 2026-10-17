enum WorkspaceKind { local, connected }

enum WorkspaceAccessFailureCode {
  unavailable,
  staleGrant,
  wrongPerson,
  unresolvedOrigin,
  endpointMismatch,
  ownerCollision,
  staleNetworkTransition,
}

class WorkspaceAccessFailure implements Exception {
  const WorkspaceAccessFailure(this.code);
  final WorkspaceAccessFailureCode code;
  @override
  String toString() => 'WorkspaceAccessFailure(${code.name})';
}

/// A captured capability, revalidated inside the transaction using it.
/// ownerUserId bridges the existing schema; it is never a human author ID.
class WorkspaceContext {
  const WorkspaceContext({
    required this.workspaceId,
    required this.ownerUserId,
    required this.authorId,
    required this.kind,
    required this.accessEpoch,
    this.endpoint,
    this.sessionGeneration,
    this.networkEpoch,
  });
  final String workspaceId;
  final String ownerUserId;
  final String authorId;
  final WorkspaceKind kind;
  final int accessEpoch;
  final String? endpoint;
  final int? sessionGeneration;
  final int? networkEpoch;
  bool get isLocal => kind == WorkspaceKind.local;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkspaceContext &&
          other.workspaceId == workspaceId &&
          other.ownerUserId == ownerUserId &&
          other.authorId == authorId &&
          other.kind == kind &&
          other.accessEpoch == accessEpoch &&
          other.endpoint == endpoint &&
          other.sessionGeneration == sessionGeneration &&
          other.networkEpoch == networkEpoch;

  @override
  int get hashCode => Object.hash(
    workspaceId,
    ownerUserId,
    authorId,
    kind,
    accessEpoch,
    endpoint,
    sessionGeneration,
    networkEpoch,
  );
}

class NetworkCapability {
  const NetworkCapability({
    required this.ownerId,
    required this.endpoint,
    required this.epoch,
    required this.generation,
  });
  final String ownerId;
  final String endpoint;
  final int epoch;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is NetworkCapability &&
      other.ownerId == ownerId &&
      other.endpoint == endpoint &&
      other.epoch == epoch &&
      other.generation == generation;
  @override
  int get hashCode => Object.hash(ownerId, endpoint, epoch, generation);
}

class InstallationCapability {
  const InstallationCapability({
    required this.endpoint,
    required this.epoch,
    required this.networkEpoch,
  });
  final String endpoint;
  final int epoch;
  final int networkEpoch;
}

/// An installation endpoint includes its path. Matching a hostname alone
/// cannot establish that two installations or their account UUIDs are equal.
String canonicalServerEndpoint(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      value.contains('\\')) {
    throw ArgumentError(
      'Server endpoint must be an HTTPS installation address',
    );
  }
  final host = uri.host.toLowerCase();
  final authority = host.contains(':') ? '[$host]' : host;
  final port = uri.hasPort && uri.port != 443 ? ':${uri.port}' : '';
  final path = uri.normalizePath().path.replaceFirst(RegExp(r'/+$'), '');
  return 'https://$authority$port$path';
}
