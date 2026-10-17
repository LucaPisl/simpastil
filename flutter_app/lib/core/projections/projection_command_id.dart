import 'dart:convert';

import 'package:uuid/uuid.dart';

/// Stable command identity shared by native medication actions and sync.
class ProjectionCommandIdentity {
  const ProjectionCommandIdentity({
    required this.userId,
    required this.occurrenceId,
    required this.action,
    required this.actualAt,
    required this.note,
  });

  final String userId;
  final String occurrenceId;
  final String action;
  final String? actualAt;
  final String? note;

  String get canonicalKey =>
      jsonEncode([1, userId, occurrenceId, action, actualAt, note]);
}

/// Uses UUID v5 with the DNS namespace to match the versioned shared fixture.
String projectionCommandIdForKey(String canonicalKey) =>
    const Uuid().v5(Namespace.dns.value, canonicalKey);

String projectionCommandId(ProjectionCommandIdentity identity) =>
    projectionCommandIdForKey(identity.canonicalKey);

/// Canonical key of an automatic miss. It is derived from the owner (the
/// server account, or the local owner of a standalone workspace) and the
/// occurrence key only. Both are shared by every device of one account, while
/// a workspace ID is minted per install and must not take part: two devices
/// that mark the same dose then produce the same command ID, so the server
/// replays the first receipt (an identical payload) instead of recording a
/// second miss or answering with a stale-version conflict. A retry or a
/// re-sweep on one install reuses the ID as well.
String autoMissCommandKey({
  required String ownerUserId,
  required String occurrenceKey,
}) => jsonEncode([1, 'auto-miss', ownerUserId, occurrenceKey]);

String autoMissCommandId({
  required String ownerUserId,
  required String occurrenceKey,
}) => projectionCommandIdForKey(
  autoMissCommandKey(ownerUserId: ownerUserId, occurrenceKey: occurrenceKey),
);

/// A reminder's identity is stable for one authenticated projection generation.
String reminderProjectionId({
  required String userId,
  required int sessionGeneration,
  required String occurrenceId,
  required String kind,
  String? workspaceId,
  int? grantEpoch,
  int? stateVersion,
}) => projectionCommandIdForKey(
  widgetProjectionCanonicalKey(
    userId: userId,
    sessionGeneration: sessionGeneration,
    occurrenceId: occurrenceId,
    kind: kind,
    workspaceId: workspaceId,
    grantEpoch: grantEpoch,
    stateVersion: stateVersion,
  ),
);

String widgetProjectionCanonicalKey({
  required String userId,
  required int sessionGeneration,
  required String occurrenceId,
  required String kind,
  String? workspaceId,
  int? grantEpoch,
  int? stateVersion,
}) {
  if ((workspaceId == null) != (grantEpoch == null)) {
    throw ArgumentError('A projection requires both workspace and grant');
  }
  if (workspaceId != null && stateVersion == null) {
    throw ArgumentError(
      'A protected projection requires its delivered version',
    );
  }
  if (stateVersion != null && (workspaceId == null || stateVersion < 0)) {
    throw ArgumentError(
      'Delivered occurrence version needs a protected projection',
    );
  }
  return workspaceId == null
      ? jsonEncode([1, userId, sessionGeneration, occurrenceId, kind])
      : jsonEncode([
          2,
          workspaceId,
          grantEpoch,
          userId,
          occurrenceId,
          kind,
          stateVersion,
        ]);
}

String widgetProjectionId({
  required String userId,
  required int sessionGeneration,
  required String occurrenceId,
  String? workspaceId,
  int? grantEpoch,
  int? stateVersion,
}) => reminderProjectionId(
  userId: userId,
  sessionGeneration: sessionGeneration,
  occurrenceId: occurrenceId,
  kind: 'widget',
  workspaceId: workspaceId,
  grantEpoch: grantEpoch,
  stateVersion: stateVersion,
);

String widgetActionCommandKey({
  required String projectionId,
  required String occurrenceId,
  required String action,
}) {
  if (!const {'take', 'skip'}.contains(action)) {
    throw ArgumentError.value(action, 'action');
  }
  return jsonEncode([1, projectionId, occurrenceId, action]);
}

String widgetActionCommandId({
  required String projectionId,
  required String occurrenceId,
  required String action,
}) => projectionCommandIdForKey(
  widgetActionCommandKey(
    projectionId: projectionId,
    occurrenceId: occurrenceId,
    action: action,
  ),
);

/// Re-delivery of the same OS action reuses its command ID. A later action
/// after an occurrence state transition gets a new ID via [stateVersion].
String notificationActionCommandId({
  required String projectionId,
  required String occurrenceId,
  required String action,
  required int stateVersion,
}) => projectionCommandIdForKey(
  jsonEncode([
    1,
    'notification-action',
    projectionId,
    occurrenceId,
    action,
    stateVersion,
  ]),
);

/// Follow-ups use a distinct projection ID while keeping the exact dose target.
String followUpReminderKind(int minutes) {
  if (minutes <= 0) throw ArgumentError.value(minutes, 'minutes');
  return 'followUp:$minutes';
}

bool isFollowUpReminderKind(String kind) {
  final match = RegExp(r'^followUp:([1-9][0-9]*)$').firstMatch(kind);
  return match != null && int.tryParse(match.group(1)!) != null;
}
