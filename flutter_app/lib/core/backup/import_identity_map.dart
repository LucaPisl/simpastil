import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../workspace/workspace_context.dart';
import 'import_plan.dart';

/// Translates the local container, retaining entity/command/author identities.
/// The service archives every exact incoming row before applying a copy.
class ImportIdentityMap {
  ImportIdentityMap(this.target, Map<String, String> workspaceOwners)
    : workspaceOwners = Map.unmodifiable(workspaceOwners);
  final WorkspaceContext target;
  final Map<String, String> workspaceOwners;

  Map<String, Object?> operational(
    String table,
    Map<String, Object?> original,
  ) {
    final row = Map<String, Object?>.from(original);
    if (workspaceOwners.values.contains(row['user_id'])) {
      row['user_id'] = target.ownerUserId;
    }
    final originalWorkspace = row['workspace_id'];
    if (workspaceOwners.containsKey(originalWorkspace)) {
      row['workspace_id'] = target.workspaceId;
    }
    if (table == 'workspace_authors' &&
        originalWorkspace != target.workspaceId) {
      row['provenance'] = 'imported';
    }
    if (table == 'setup_drafts' &&
        workspaceOwners.containsKey(originalWorkspace)) {
      // Continuing draft copy; the original author is retained in evidence.
      row['author_id'] = target.authorId;
    }
    if (table == 'medication_occurrences' &&
        row['snapshot_version'] == 2 &&
        workspaceOwners.values.contains(original['user_id'])) {
      try {
        final snapshot =
            jsonDecode(row['schedule_snapshot_json'] as String)
                as Map<String, dynamic>;
        if (!workspaceOwners.containsKey(snapshot['workspaceId']) ||
            workspaceOwners[snapshot['workspaceId']] !=
                snapshot['ownerUserId']) {
          throw const ImportFailure(ImportFailureCode.invalidSource);
        }
        snapshot['workspaceId'] = target.workspaceId;
        snapshot['ownerUserId'] = target.ownerUserId;
        row['schedule_snapshot_json'] = jsonEncode(snapshot);
        if (row['source'] == 'scheduled') {
          final planned = DateTime.fromMillisecondsSinceEpoch(
            (row['planned_at'] as int) * 1000,
            isUtc: true,
          );
          row['occurrence_key'] =
              'scheduled:local:v2:${sha256.convert(utf8.encode(jsonEncode([target.workspaceId, target.ownerUserId, snapshot['routineId'], snapshot['routineRevision'], snapshot['slotId'], row['planned_local_date'], row['planned_local_time'], row['time_zone'], planned.toIso8601String()])))}';
        }
      } on ImportFailure {
        rethrow;
      } catch (_) {
        throw const ImportFailure(ImportFailureCode.invalidSource);
      }
    }
    return row;
  }

  Map<String, Object?> toJson() => {
    'targetWorkspaceId': target.workspaceId,
    'targetOwnerUserId': target.ownerUserId,
    'sourceWorkspaceOwners': workspaceOwners,
    'historicalBytes': 'retained_in_import_evidence',
  };
}
