import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../db/database.dart';
import '../medication/medication_amount.dart';
import 'account_settlement_merger.dart';
import 'component_merge_values.dart';
import 'held_stock.dart';
import 'sync_write_scope.dart';

/// Profiles, pills, schedules and stable tombstones.
///
/// Runs inside the transaction opened by the caller of
/// `ComponentSyncMerger.merge`; it never opens its own and shares the same
/// [writeScope] as its siblings.
class StableRecordMerger {
  StableRecordMerger(this.db, {this.writeScope, required this.reviews});

  final AppDatabase db;
  final SyncWriteScope? writeScope;
  final AccountSettlementMerger reviews;
  Future<void> mergeProfile(
    String userId,
    Map<String, dynamic> item,
    Map<String, String> profileIds,
  ) async {
    final serverId = item['id'] as String;
    final existing = await db.profilesDao.getByMappedOrLocalId(serverId);
    if (existing != null) {
      await writeScope?.requireEntity('profile', existing.id);
    }
    final localId = existing?.id ?? serverId;
    profileIds[serverId] = localId;
    final revision = int.parse(item['revision'] as String);
    if (item['deletedAt'] != null) {
      if (existing != null && existing.syncStatus == 'synced') {
        await (db.update(
          db.profiles,
        )..where((row) => row.id.equals(localId))).write(
          ProfilesCompanion(
            isDeleted: const Value(true),
            syncStatus: const Value('synced'),
            revision: Value(revision),
            updatedAt: Value(syncDate(item['deletedAt'])),
          ),
        );
      }
      return;
    }
    if (existing != null && existing.syncStatus != 'synced') return;
    await db.profilesDao.upsert(
      ProfilesCompanion(
        id: Value(localId),
        userId: Value(userId),
        name: Value(item['name'] as String),
        avatarEmoji: Value(item['avatarEmoji'] as String),
        isActive: Value(item['isActive'] as bool),
        createdAt: Value(syncDate(item['createdAt'])),
        updatedAt: Value(syncDate(item['updatedAt'])),
        serverId: Value(serverId),
        revision: Value(revision),
        syncStatus: const Value('synced'),
        isDeleted: const Value(false),
      ),
    );
  }

  Future<void> mergePill(
    Map<String, dynamic> item,
    Map<String, String> profileIds,
    Map<String, String> pillIds, {
    String? userId,
  }) async {
    final serverId = item['id'] as String;
    final existing = await db.pillsDao.getByMappedOrLocalId(serverId);
    if (existing != null) await writeScope?.requireEntity('pill', existing.id);
    final localId = existing?.id ?? serverId;
    pillIds[serverId] = localId;
    final revision = int.parse(item['revision'] as String);
    if (item['deletedAt'] != null) {
      if (existing != null && existing.syncStatus == 'synced') {
        await (db.update(
          db.pills,
        )..where((row) => row.id.equals(localId))).write(
          PillsCompanion(
            isDeleted: const Value(true),
            syncStatus: const Value('synced'),
            revision: Value(revision),
            updatedAt: Value(syncDate(item['deletedAt'])),
          ),
        );
      }
      return;
    }
    if (existing != null && existing.syncStatus != 'synced') return;
    // A bridge acknowledgement can adopt a pill revision that no stable change
    // carries. A replayed older stable change must not move it backwards, or
    // the next edit is sent with a stale base and lost to a server-wins 409.
    final adoptedRevision = existing != null && existing.revision > revision
        ? existing.revision
        : revision;
    final serverProfileId = item['profileId'] as String;
    final localProfileId =
        profileIds[serverProfileId] ??
        (await db.profilesDao.getByMappedOrLocalId(serverProfileId))?.id ??
        serverProfileId;
    await writeScope?.requireEntity('profile', localProfileId);
    // In bridge mode a stock edit is held for the ledger and the count stays
    // on this phone, so the server's count must not replace it.
    final keepLocalStock =
        existing != null &&
        userId != null &&
        ((await heldStockPillIds(db, userId)).contains(existing.id) ||
            (await unsettledInventoryPillIds(
              db,
              userId,
            )).contains(existing.id));
    await db.pillsDao.upsert(
      PillsCompanion(
        id: Value(localId),
        profileId: Value(localProfileId),
        name: Value(item['name'] as String),
        dosage: Value(item['dosage'] as String?),
        notes: Value(item['notes'] as String?),
        color: Value(item['color'] as String?),
        currentStock: Value(
          keepLocalStock ? existing.currentStock : item['currentStock'] as int?,
        ),
        lowStockThreshold: Value(item['lowStockThreshold'] as int?),
        isPrn: Value(item['isPrn'] as bool),
        createdAt: Value(syncDate(item['createdAt'])),
        updatedAt: Value(syncDate(item['updatedAt'])),
        serverId: Value(serverId),
        revision: Value(adoptedRevision),
        syncStatus: const Value('synced'),
        isDeleted: const Value(false),
      ),
    );
    await _mergePillDetails(item, localId);
  }

  /// The reviewed details that travel with a pill.
  ///
  /// A server that does not store them, and every change row written before
  /// they existed, carries none of these keys. Absent is not empty: writing
  /// nothing then is what keeps a review made on this device from being
  /// erased by the first pull. The caller has already refused to touch a pill
  /// holding unsent local work, so reaching here means the server's copy wins.
  Future<void> _mergePillDetails(
    Map<String, dynamic> item,
    String localId,
  ) async {
    const keys = [
      'amountPerUse',
      'packageStrength',
      'form',
      'legacyDosageReviewed',
    ];
    if (!keys.any(item.containsKey)) return;
    final amount = item['amountPerUse'];
    var decoded = const MedicationAmount.unknown();
    if (amount is Map) {
      try {
        decoded = MedicationAmount.fromJson(Map<String, Object?>.from(amount));
      } on FormatException {
        // An amount this build cannot read is left unset rather than stored
        // as text the medicine page would later fail to open.
        decoded = const MedicationAmount.unknown();
      }
    }
    await db
        .into(db.medicationDetails)
        .insertOnConflictUpdate(
          MedicationDetailsCompanion.insert(
            pillId: localId,
            packageStrength: Value(item['packageStrength'] as String?),
            form: Value(item['form'] as String?),
            amountJson: jsonEncode(decoded.toJson()),
            legacyDosageReviewed: Value(item['legacyDosageReviewed'] == true),
          ),
        );
  }

  Future<void> mergeSchedule(
    Map<String, dynamic> item,
    Map<String, String> pillIds,
    Map<String, String> scheduleIds,
  ) async {
    final serverId = item['id'] as String;
    final existing = await db.schedulesDao.getByMappedOrLocalId(serverId);
    if (existing != null) {
      await writeScope?.requireEntity('schedule', existing.id);
    }
    final localId = existing?.id ?? serverId;
    scheduleIds[serverId] = localId;
    final revision = int.parse(item['revision'] as String);
    if (item['deletedAt'] != null) {
      if (existing != null && existing.syncStatus == 'synced') {
        await (db.update(
          db.schedules,
        )..where((row) => row.id.equals(localId))).write(
          SchedulesCompanion(
            isDeleted: const Value(true),
            syncStatus: const Value('synced'),
            revision: Value(revision),
            updatedAt: Value(syncDate(item['deletedAt'])),
          ),
        );
      }
      return;
    }
    if (existing != null && existing.syncStatus != 'synced') return;
    final serverPillId = item['pillId'] as String;
    final localPillId =
        pillIds[serverPillId] ??
        (await db.pillsDao.getByMappedOrLocalId(serverPillId))?.id ??
        serverPillId;
    await writeScope?.requireEntity('pill', localPillId);
    final rawDays = item['frequencyDays'];
    await db.schedulesDao.upsert(
      SchedulesCompanion(
        id: Value(localId),
        pillId: Value(localPillId),
        hour: Value(item['hour'] as int),
        minute: Value(item['minute'] as int),
        frequency: Value(item['frequency'] as String),
        frequencyDays: Value(rawDays is List ? jsonEncode(rawDays) : null),
        timeZone: Value(item['timeZone'] as String?),
        timeZoneStatus: Value(
          item['timeZoneStatus'] as String? ?? 'legacy_unknown',
        ),
        isActive: Value(item['isActive'] as bool),
        createdAt: Value(syncDate(item['createdAt'])),
        updatedAt: Value(syncDate(item['updatedAt'])),
        serverId: Value(serverId),
        revision: Value(revision),
        syncStatus: const Value('synced'),
        isDeleted: const Value(false),
      ),
    );
  }

  Future<void> mergeTombstone(
    String userId,
    Map<String, dynamic> item,
    Map<String, String> profileIds,
    Map<String, String> pillIds,
    Map<String, String> scheduleIds,
  ) async {
    final id = item['id'] as String;
    final entityType = item['entityType'] as String;
    final revision = int.parse(item['revision'] as String);
    switch (entityType) {
      case 'profile':
        final localId =
            profileIds[id] ??
            (await db.profilesDao.getByMappedOrLocalId(id))?.id;
        final row = localId == null
            ? null
            : await db.profilesDao.getById(localId);
        if (row != null) await writeScope?.requireEntity('profile', row.id);
        if (row != null && row.syncStatus == 'synced') {
          await (db.update(
            db.profiles,
          )..where((value) => value.id.equals(localId!))).write(
            ProfilesCompanion(
              isDeleted: const Value(true),
              syncStatus: const Value('synced'),
              revision: Value(revision),
              updatedAt: Value(syncDate(item['deletedAt'])),
            ),
          );
        }
        break;
      case 'pill':
        final localId =
            pillIds[id] ?? (await db.pillsDao.getByMappedOrLocalId(id))?.id;
        final row = localId == null ? null : await db.pillsDao.getById(localId);
        if (row != null) await writeScope?.requireEntity('pill', row.id);
        if (row != null && row.syncStatus == 'synced') {
          await (db.update(
            db.pills,
          )..where((value) => value.id.equals(localId!))).write(
            PillsCompanion(
              isDeleted: const Value(true),
              syncStatus: const Value('synced'),
              revision: Value(revision),
              updatedAt: Value(syncDate(item['deletedAt'])),
            ),
          );
        }
        break;
      case 'schedule':
        final localId =
            scheduleIds[id] ??
            (await db.schedulesDao.getByMappedOrLocalId(id))?.id;
        final row = localId == null
            ? null
            : await db.schedulesDao.getById(localId);
        if (row != null) await writeScope?.requireEntity('schedule', row.id);
        if (row != null && row.syncStatus == 'synced') {
          await (db.update(
            db.schedules,
          )..where((value) => value.id.equals(localId!))).write(
            SchedulesCompanion(
              isDeleted: const Value(true),
              syncStatus: const Value('synced'),
              revision: Value(revision),
              updatedAt: Value(syncDate(item['deletedAt'])),
            ),
          );
        }
        break;
      case 'bridge_dose':
        final row = await db.doseLogsDao.getByServerId(id);
        if (row != null) await writeScope?.requireEntity('doseLog', row.id);
        if (row != null && row.syncStatus == 'synced') {
          await (db.update(
            db.doseLogs,
          )..where((value) => value.id.equals(row.id))).write(
            DoseLogsCompanion(
              isDeleted: const Value(true),
              syncStatus: const Value('synced'),
              revision: Value(revision),
              updatedAt: Value(syncDate(item['deletedAt'])),
            ),
          );
        }
        break;
      case 'medication_occurrence':
        await reviews.recordReviewIssue(userId, {
          'component': 'sync',
          'entityType': entityType,
          'entityId': id,
          'operation': 'tombstone',
        }, item);
        break;
      case 'migration_issue':
      case 'account':
      case 'bridge_stock':
      case 'occurrence_event':
      case 'inventory_event':
      case 'legacy_medication_history':
        await reviews.recordReviewIssue(userId, {
          'component': 'sync',
          'entityType': entityType,
          'entityId': id,
          'operation': 'tombstone',
        }, item);
        break;
    }
  }
}
