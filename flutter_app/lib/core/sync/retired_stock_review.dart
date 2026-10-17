import 'dart:convert';

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:uuid/uuid.dart';

import '../db/database.dart';

/// Classifies a legacy stock deletion notice, without resolving the issue or
/// changing care. Migration 0015 emits bridge_stock tombstones for deleted pills.
/// The old client retained these as generic reviews, losing source revision
/// details; therefore a current acknowledged deletion and no unsettled intent
/// are required. This does not establish an old dose or stock outcome.
/// The note is keyed by entity and kind; notes written before the kind joined
/// the id carry the entity-only id.
bool _isReviewIssueId(MigrationIssue issue) {
  const ids = Uuid();
  final entity =
      'simpastil:sync-review:${issue.userId}:sync:bridge_stock:${issue.entityId}';
  return issue.id == ids.v5(Namespace.url.value, entity) ||
      issue.id == ids.v5(Namespace.url.value, '$entity:tombstone');
}

Future<bool> isRetiredStockReview(AppDatabase db, MigrationIssue issue) async {
  if (issue.serverId != null ||
      issue.resolutionState != 'unresolved' ||
      issue.revision != 1 ||
      issue.entityType != 'bridge_stock' ||
      issue.issueCode != 'sync_item_needs_review' ||
      !_isReviewIssueId(issue)) {
    return false;
  }
  if (issue.snapshotJson.length > 1024) return false;
  try {
    final snapshot = jsonDecode(issue.snapshotJson);
    if (snapshot is! Map ||
        snapshot.length != 4 ||
        snapshot['component'] != 'sync' ||
        snapshot['kind'] != 'tombstone' ||
        snapshot['entityType'] != issue.entityType ||
        snapshot['entityId'] != issue.entityId) {
      return false;
    }
  } on FormatException {
    return false;
  }

  // Check all aliases before ownership: a preferred match would hide ambiguity.
  final pills =
      await (db.select(db.pills)..where(
            (p) =>
                p.id.equals(issue.entityId) | p.serverId.equals(issue.entityId),
          ))
          .get();
  if (pills.length != 1) return false;
  final pill = pills.single;
  if (pill.serverId != issue.entityId ||
      pill.revision < 1 ||
      pill.syncStatus != 'synced' ||
      !pill.isDeleted) {
    return false;
  }
  final person = await db.profilesDao.getById(pill.profileId);
  if (person?.userId != issue.userId) return false;

  // Fail closed even for unknown/effect-free operations. Use the existing
  // authenticated settlement receipts rather than inferring delivery from UI.
  return (await db.pendingOperationsDao.getUnsettledForUser(
    issue.userId,
  )).isEmpty;
}
