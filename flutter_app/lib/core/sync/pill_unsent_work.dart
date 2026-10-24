import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/database.dart';
import 'held_stock.dart';

/// The local pill ids for which the journal still holds unsent work: an
/// operation on the pill itself, a stock command for it, or an operation with
/// an effect on it, that has not settled.
///
/// [unknown] is set when an unsettled operation cannot be read. Its intent
/// cannot be ruled out for any pill, so callers must leave every row alone.
Future<({Set<String> ids, bool unknown})> pillsWithUnsentWork(
  AppDatabase db,
  String userId,
) async {
  final dao = db.pendingOperationsDao;
  final ids = <String>{};
  var unknown = false;
  for (final operation in await dao.getUnsettledForUser(userId)) {
    try {
      final payload = jsonDecode(operation.payloadJson);
      if (payload is Map) {
        if (payload['entityType'] == 'pill' &&
            payload['entityLocalId'] is String) {
          ids.add(payload['entityLocalId'] as String);
        }
        final command = payload['inventoryCommand'];
        if (command is Map && command['pillId'] is String) {
          ids.add(command['pillId'] as String);
        }
      }
    } on FormatException {
      unknown = true;
    }
    for (final effect in await dao.getEffects(operation.id)) {
      final id = effect.legacySourceId;
      if (id != null) ids.add(id);
    }
  }
  return (ids: ids, unknown: unknown);
}

/// Whether the journal still holds unsent work for this pill.
Future<bool> holdsUnsentPillWork(
  AppDatabase db,
  String userId,
  String localId,
) async {
  final work = await pillsWithUnsentWork(db, userId);
  return work.unknown || work.ids.contains(localId);
}

/// Whether a pill row flagged unsent holds nothing left to protect: the
/// journal flagged it and nothing in the journal is still waiting for it. A
/// flag without journal history came from the older, unjournaled writer and
/// still guards an edit that never reached the server.
Future<bool> unsentFlagIsSettled(
  AppDatabase db,
  String userId,
  String localId,
) async => (await PillJournal.read(db, userId)).flagIsSettled(localId);

/// Whether something unsent can still justify this phone's "needs a recount"
/// mark on a pill: a stock edit held for the ledger, a stock command not yet
/// settled, or a dose command for the pill. A dose whose amount the count
/// could not hold sets the mark here before the server has heard of it, so
/// the server's "no mark" is not yet an answer about that dose. An unreadable
/// medication command could be any of these, so it holds every mark.
Future<bool> recountMarkHeld(
  AppDatabase db,
  String userId,
  String localId,
) async => (await PillJournal.read(db, userId)).holdsRecountMark(localId);

/// One read of the journal, as every pill decision in a pull or merge batch
/// needs it. The journal does not change while a batch merges (a merge writes
/// pills, never operations), so reading it once per batch gives the same
/// answers as asking per pill, without rescanning the whole journal for each.
class PillJournal {
  PillJournal._({
    required this.unsentIds,
    required this.unknown,
    required this.journaledIds,
    required this.localStockIds,
    required this.doseIds,
    required this.doseUnknown,
  });

  /// Pills with unsent work ([pillsWithUnsentWork]).
  final Set<String> unsentIds;

  /// An unsettled operation could not be read: no pill can be ruled out.
  final bool unknown;

  /// Pills any operation, settled or not, ever touched.
  final Set<String> journaledIds;

  /// Pills whose stock stays as this device has it (a held stock edit or an
  /// unsettled stock command).
  final Set<String> localStockIds;

  /// Pills with an unsent dose command.
  final Set<String> doseIds;

  /// An unsettled medication operation could not be read.
  final bool doseUnknown;

  static Future<PillJournal> read(AppDatabase db, String userId) async {
    final work = await pillsWithUnsentWork(db, userId);
    final doses = await _pillsWithUnsentDoses(db, userId);
    return PillJournal._(
      unsentIds: work.ids,
      unknown: work.unknown,
      journaledIds: await _pillsWithJournalHistory(db, userId),
      localStockIds: {
        ...await heldStockPillIds(db, userId),
        ...await unsettledInventoryPillIds(db, userId),
      },
      doseIds: doses.ids,
      doseUnknown: doses.unknown,
    );
  }

  /// [holdsUnsentPillWork] for [localId].
  bool holdsUnsentWork(String localId) =>
      unknown || unsentIds.contains(localId);

  /// [unsentFlagIsSettled] for [localId].
  bool flagIsSettled(String localId) =>
      !holdsUnsentWork(localId) && journaledIds.contains(localId);

  /// Whether [localId]'s count stays as this device has it.
  bool keepsLocalStock(String localId) => localStockIds.contains(localId);

  /// [recountMarkHeld] for [localId].
  bool holdsRecountMark(String localId) =>
      doseUnknown ||
      localStockIds.contains(localId) ||
      doseIds.contains(localId);
}

/// The local pill ids with an unsettled medication command (a dose, skip,
/// miss, undo or correction) projected onto them; [unknown] when one cannot be
/// read.
Future<({Set<String> ids, bool unknown})> _pillsWithUnsentDoses(
  AppDatabase db,
  String userId,
) async {
  final ids = <String>{};
  var unknown = false;
  for (final operation in await db.pendingOperationsDao.getUnsettledForUser(
    userId,
  )) {
    if (operation.component != 'medication') continue;
    Object? payload;
    try {
      payload = jsonDecode(operation.payloadJson);
    } on FormatException {
      unknown = true;
      continue;
    }
    if (payload is! Map) {
      unknown = true;
      continue;
    }
    final projection = payload['localProjection'];
    if (payload['command'] is Map &&
        projection is Map &&
        projection['pillId'] is String) {
      ids.add(projection['pillId'] as String);
    }
  }
  return (ids: ids, unknown: unknown);
}

/// Marks pills synced that are still flagged unsent although nothing in the
/// journal is waiting for them.
///
/// An edit saved together with a stock change records a `pill.update` and a
/// stock command. The edit's acknowledgement keeps the row unsent while the
/// stock command waits; once the last of them settles the flag has nothing
/// left to protect. Only rows the server already knows are settled: a row
/// without a server id still needs its create. Pass [only] to settle one pill.
///
/// Only a flag the journal set is cleared: the pill must have journal history
/// of its own. A row marked unsent by the older, unjournaled writer (an edit
/// whose legacy PATCH failed and was only logged) has none, and its edit was
/// never delivered, so it stays unsent rather than be lost to the next pull.
Future<int> settleIdlePendingPills(
  AppDatabase db,
  String userId, {
  String? only,
}) async {
  final work = await pillsWithUnsentWork(db, userId);
  if (work.unknown) return 0;
  final journaled = await _pillsWithJournalHistory(db, userId);
  var settled = 0;
  final query =
      db.select(db.pills).join([
        innerJoin(db.profiles, db.profiles.id.equalsExp(db.pills.profileId)),
      ])..where(
        db.profiles.userId.equals(userId) &
            db.pills.syncStatus.equals('pending') &
            db.pills.serverId.isNotNull(),
      );
  for (final row in await query.get()) {
    final pill = row.readTable(db.pills);
    if (only != null && pill.id != only) continue;
    if (work.ids.contains(pill.id) || !journaled.contains(pill.id)) continue;
    await (db.update(db.pills)..where((t) => t.id.equals(pill.id))).write(
      const PillsCompanion(syncStatus: Value('synced')),
    );
    settled++;
  }
  return settled;
}

/// The local pill ids any journal operation (settled or not) ever touched:
/// the pill itself, a stock command for it, or an effect on it.
Future<Set<String>> _pillsWithJournalHistory(
  AppDatabase db,
  String userId,
) async {
  final dao = db.pendingOperationsDao;
  final ids = <String>{};
  for (final operation in await dao.getForUser(userId)) {
    try {
      final payload = jsonDecode(operation.payloadJson);
      if (payload is Map) {
        if (payload['entityType'] == 'pill' &&
            payload['entityLocalId'] is String) {
          ids.add(payload['entityLocalId'] as String);
        }
        final command = payload['inventoryCommand'];
        if (command is Map && command['pillId'] is String) {
          ids.add(command['pillId'] as String);
        }
      }
    } on FormatException {
      // Unreadable history proves nothing about any pill.
    }
    for (final effect in await dao.getEffects(operation.id)) {
      final id = effect.legacySourceId;
      if (id != null) ids.add(id);
    }
  }
  return ids;
}

/// The stable component's replay marker. It supersedes
/// `medication-details-v1`, so a device on either earlier marker replays the
/// component once from zero and settles idle pills inside that replay.
const stablePendingSettleRevision = 'stable-pending-settle-v1';

/// Whether this account's stable component has yet to run the one-time
/// settle and replay.
Future<bool> stablePendingSettleNeeded(AppDatabase db, String userId) async {
  final state = await db.syncStateDao.getState(userId, 'stable');
  final raw = state?.diagnosticMetadataJson;
  if (raw == null) return true;
  try {
    final metadata = jsonDecode(raw);
    return metadata is! Map ||
        metadata['projectionRevision'] != stablePendingSettleRevision;
  } on FormatException {
    return true;
  }
}
