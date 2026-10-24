import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../db/database.dart';
import '../inventory/pill_stock.dart';
import '../medication/medication_amount.dart';
import '../medication/medication_extras.dart';
import 'account_settlement_merger.dart';
import 'component_merge_values.dart';
import 'pill_unsent_work.dart';
import 'sync_write_scope.dart';

/// Profiles, pills, schedules and stable tombstones.
///
/// Runs inside the transaction opened by the caller of
/// `ComponentSyncMerger.merge`; it never opens its own and shares the same
/// [writeScope] as its siblings.
class StableRecordMerger {
  StableRecordMerger(
    this.db, {
    this.writeScope,
    required this.reviews,
    this.medicationDetailsExtra = false,
    this.medicationPhoto = false,
  });

  /// Whether the server stores the medication extras. A server that does
  /// carries every set extra on each pill, so an absent key means the person
  /// cleared it. Without the contract an absent key means nothing was sent
  /// and the extras on this device are left alone.
  final bool medicationDetailsExtra;

  /// Whether the server keeps medication photos. A server that does names each
  /// pill's photo (`photo: {sha256, revision}`) only while it has one, so an
  /// absent key means there is none. Without the contract nothing is said about
  /// photos and this device's are left alone.
  final bool medicationPhoto;

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
    Future<PillJournal> Function()? journal,
  }) async {
    final serverId = item['id'] as String;
    final existing = await db.pillsDao.getByMappedOrLocalId(serverId);
    if (existing != null) await writeScope?.requireEntity('pill', existing.id);
    final localId = existing?.id ?? serverId;
    pillIds[serverId] = localId;
    final revision = int.parse(item['revision'] as String);
    // The flag is a projection of the journal. A row still marked unsent
    // after every operation touching it has settled holds nothing to protect,
    // so the server's copy is taken; skipping it would leave the row behind
    // for good, because nothing else ever clears the mark. A flag the journal
    // never set still guards the older writer's undelivered edit.
    // [journal] is the batch's one read of the journal; without one (a
    // single merge outside a batch) it is read here.
    Future<PillJournal> pillJournal() =>
        journal?.call() ?? PillJournal.read(db, userId!);
    final guarded =
        existing != null &&
        existing.syncStatus != 'synced' &&
        (userId == null || !(await pillJournal()).flagIsSettled(existing.id));
    if (item['deletedAt'] != null) {
      if (existing != null && !guarded) {
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
    if (guarded) {
      // The pill's own fields wait for its unsent edit, but the photo row has
      // a state of its own and is judged on it.
      await _mergePhoto(item, localId);
      return;
    }
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
    // on this phone, so the server's count must not replace it. An unsent
    // dose keeps the recount mark it may have set, too.
    final known = existing != null && userId != null
        ? await pillJournal()
        : null;
    final keepLocalStock = known != null && known.keepsLocalStock(existing!.id);
    final keepRecountMark =
        known != null && known.holdsRecountMark(existing!.id);
    await db.pillsDao.upsert(
      wirePillCompanion(
        item,
        medicationDetailsExtra: medicationDetailsExtra,
        keepStockOf: keepLocalStock ? existing : null,
        keepRecountMarkOf: keepRecountMark ? existing : null,
      ).copyWith(
        id: Value(localId),
        profileId: Value(localProfileId),
        createdAt: Value(syncDate(item['createdAt'])),
        updatedAt: Value(syncDate(item['updatedAt'])),
        serverId: Value(serverId),
        revision: Value(adoptedRevision),
        syncStatus: const Value('synced'),
        isDeleted: const Value(false),
      ),
    );
    await mergeWirePillDetails(db, item, localId);
    await _mergePhoto(item, localId);
  }

  /// Records what the account says about this pill's photo.
  ///
  /// The photo row is never overwritten while it holds work this device has not
  /// sent (`pending`, `removing`) or a choice only it keeps (`local`,
  /// `rejected`). Otherwise a different hash marks the row for download, which
  /// runs after the pull; the same hash is simply confirmed, and no photo on
  /// the account means none here.
  Future<void> _mergePhoto(Map<String, dynamic> item, String localId) async {
    if (!medicationPhoto) return;
    final ref = item['photo'];
    final remoteSha = ref is Map ? ref['sha256'] : null;
    final remoteRevision = ref is Map
        ? int.tryParse('${ref['revision']}') ?? 0
        : 0;
    final row = await (db.select(
      db.medicationPhotos,
    )..where((t) => t.pillId.equals(localId))).getSingleOrNull();
    if (row != null &&
        (row.syncStatus == 'pending' ||
            row.syncStatus == 'removing' ||
            row.syncStatus == 'local' ||
            row.syncStatus == 'rejected')) {
      return;
    }
    if (remoteSha is! String || remoteSha.isEmpty) {
      if (row != null) {
        await (db.delete(
          db.medicationPhotos,
        )..where((t) => t.pillId.equals(localId))).go();
      }
      return;
    }
    if (row == null) {
      await db
          .into(db.medicationPhotos)
          .insert(
            MedicationPhotosCompanion.insert(
              pillId: localId,
              sha256: remoteSha,
              revision: Value(remoteRevision),
              syncStatus: const Value('fetch'),
              remoteSha256: Value(remoteSha),
            ),
          );
      return;
    }
    final haveIt = row.sha256 == remoteSha && row.bytesBase64.isNotEmpty;
    await (db.update(
      db.medicationPhotos,
    )..where((t) => t.pillId.equals(localId))).write(
      MedicationPhotosCompanion(
        syncStatus: Value(haveIt ? 'synced' : 'fetch'),
        revision: Value(remoteRevision),
        remoteSha256: Value(haveIt ? null : remoteSha),
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
        // Servers without schedule windows omit these keys: missing is null.
        everyDays: Value(item['everyDays'] as int?),
        anchorDate: Value(item['anchorDate'] as String?),
        startDate: Value(item['startDate'] as String?),
        endDate: Value(item['endDate'] as String?),
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

/// Whether a pill's stock stays as this device has it: a stock edit held for
/// the server's ledger, or a stock command not yet settled, means the count
/// on this phone is newer than the server's copy.
Future<bool> keepsLocalPillStock(
  AppDatabase db,
  String userId,
  String localId,
) async => (await PillJournal.read(db, userId)).keepsLocalStock(localId);

/// Every field of a server pill item that this device adopts, as the
/// companion to write.
///
/// The pull merge and the server-wins conflict both take a pill through this,
/// so the two cannot drift apart again. The caller adds the identity, dates,
/// revision and sync state. Pass [keepStockOf] when [keepsLocalPillStock]
/// holds: its count stays, and a local recount mark is never cleared by a
/// server false (a server true is still taken). Pass [keepRecountMarkOf] when
/// [recountMarkHeld] holds (an unsent dose may have set the mark): the mark
/// is kept the same way, while the count is the server's.
PillsCompanion wirePillCompanion(
  Map<String, dynamic> item, {
  required bool medicationDetailsExtra,
  Pill? keepStockOf,
  Pill? keepRecountMarkOf,
}) {
  final stock = wirePillStock(item);
  final extras = _wireExtras(item, medicationDetailsExtra);
  final kept = keepStockOf;
  final localMark =
      (kept?.stockNeedsRecount ?? false) ||
      (keepRecountMarkOf?.stockNeedsRecount ?? false);
  return PillsCompanion(
    name: Value(item['name'] as String),
    dosage: Value(item['dosage'] as String?),
    notes: Value(item['notes'] as String?),
    color: Value(item['color'] as String?),
    currentStock: kept != null ? Value(kept.currentStock) : stock.currentStock,
    stockQuantity: kept != null
        ? Value(kept.stockQuantity)
        : stock.stockQuantity,
    stockUnit: kept != null ? Value(kept.stockUnit) : stock.stockUnit,
    stockNeedsRecount: Value(localMark || item['stockNeedsRecount'] == true),
    lowStockThreshold: Value(item['lowStockThreshold'] as int?),
    isPrn: Value(item['isPrn'] as bool),
    // Absent means a server (or change row) that does not carry shapes:
    // leave the device's pick alone. Present, null or not, is the truth.
    shape: item.containsKey('shape')
        ? Value(_wireShape(item['shape']))
        : const Value.absent(),
    prnMaxPer24h: extras.prnMaxPer24h,
    prnMinGapMinutes: extras.prnMinGapMinutes,
    expiresOn: extras.expiresOn,
    prescriberName: extras.prescriberName,
    prescriberPhone: extras.prescriberPhone,
    pharmacyName: extras.pharmacyName,
    pharmacyPhone: extras.pharmacyPhone,
  );
}

/// The extras of a pill item, as the companion values to write.
///
/// Against a server with the contract the item is the whole truth, so an
/// absent or wrong-typed key is an unset extra. Without it nothing was sent
/// and the device's values stay (`Value.absent`).
_ExtrasValues _wireExtras(
  Map<String, dynamic> item,
  bool medicationDetailsExtra,
) {
  if (!medicationDetailsExtra) return const _ExtrasValues.keep();
  return _ExtrasValues(
    prnMaxPer24h: Value(
      wireExtrasInt(item['prnMaxPer24h'], max: wireMaxPrnPer24h),
    ),
    prnMinGapMinutes: Value(
      wireExtrasInt(item['prnMinGapMinutes'], max: wireMaxPrnGapMinutes),
    ),
    expiresOn: Value(wireExtrasDate(item['expiresOn'])),
    prescriberName: Value(wireExtrasName(item['prescriberName'])),
    prescriberPhone: Value(wireExtrasPhone(item['prescriberPhone'])),
    pharmacyName: Value(wireExtrasName(item['pharmacyName'])),
    pharmacyPhone: Value(wireExtrasPhone(item['pharmacyPhone'])),
  );
}

/// The shape name as stored. An unknown name from a newer server is kept
/// verbatim (the reader maps it to the derived shape), so a pull never
/// rejects and a later build that knows the name can draw it.
String? _wireShape(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return raw.length > 32 ? raw.substring(0, 32) : raw;
}

class _ExtrasValues {
  const _ExtrasValues({
    required this.prnMaxPer24h,
    required this.prnMinGapMinutes,
    required this.expiresOn,
    required this.prescriberName,
    required this.prescriberPhone,
    required this.pharmacyName,
    required this.pharmacyPhone,
  });
  const _ExtrasValues.keep()
    : prnMaxPer24h = const Value.absent(),
      prnMinGapMinutes = const Value.absent(),
      expiresOn = const Value.absent(),
      prescriberName = const Value.absent(),
      prescriberPhone = const Value.absent(),
      pharmacyName = const Value.absent(),
      pharmacyPhone = const Value.absent();

  final Value<int?> prnMaxPer24h;
  final Value<int?> prnMinGapMinutes;
  final Value<String?> expiresOn;
  final Value<String?> prescriberName;
  final Value<String?> prescriberPhone;
  final Value<String?> pharmacyName;
  final Value<String?> pharmacyPhone;
}

/// The reviewed details that travel with a pill.
///
/// A server that does not store them, and every change row written before
/// they existed, carries none of these keys. Absent is not empty: writing
/// nothing then is what keeps a review made on this device from being
/// erased by the first pull. The caller has already refused to touch a pill
/// holding unsent local work, so reaching here means the server's copy wins.
Future<void> mergeWirePillDetails(
  AppDatabase db,
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
