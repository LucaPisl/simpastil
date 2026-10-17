import '../projections/projection_command_id.dart';

/// Deterministic identities of one legacy split checkpoint effect.
///
/// The recorded issue and its resolution command are derived from the
/// operation's command id and the effect ordinal, so every reader that links
/// an effect to its server review must derive them here.
class LegacySplitIdentity {
  const LegacySplitIdentity(this.commandId, this.ordinal);

  final String commandId;
  final int ordinal;

  /// Effect fingerprint prefix once the server recorded a review issue.
  static const recordedMarkerPrefix = 'reconciliation-recorded:';

  String get issueId =>
      projectionCommandIdForKey('legacy-split-issue-v1:$commandId:$ordinal');

  String get resolutionCommandId =>
      projectionCommandIdForKey('legacy-split-command-v1:$commandId:$ordinal');

  String get bundleId =>
      projectionCommandIdForKey('legacy-split-bundle-v1:$commandId');

  String get correlationId =>
      projectionCommandIdForKey('legacy-split-correlation-v1:$commandId');

  /// Fingerprint of an effect whose review issue is [issueId].
  String get recordedMarker => '$recordedMarkerPrefix$issueId';

  /// The id split effects are keyed by: the medication command's id, else the
  /// inventory command's id, else [mutationId]. The result is not validated.
  static Object? sourceCommandId(
    Map<Object?, Object?> payload,
    String mutationId,
  ) {
    final command = payload['command'];
    final inventory = payload['inventoryCommand'];
    return command is Map
        ? command['commandId']
        : inventory is Map
        ? inventory['commandId']
        : mutationId;
  }
}
