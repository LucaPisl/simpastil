import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;

import '../db/database.dart';
import '../inventory/pill_stock.dart';
import '../medication/medication_amount.dart';
import '../medication/recorded_by.dart';
import '../medication/schedule_window.dart';
import '../utils/safe_diagnostics.dart';
import '../workspace/workspace_context.dart';
import 'component_merge_values.dart';
import 'held_stock.dart';
import 'sync_write_scope.dart';

/// Bridge doses, stock, occurrences, occurrence events and inventory events.
///
/// Runs inside the transaction opened by the caller of
/// `ComponentSyncMerger.merge`; it never opens its own and shares the same
/// [writeScope] as its siblings.
class MedicationProjectionMerger {
  MedicationProjectionMerger(this.db, {this.writeScope});

  final AppDatabase db;
  final SyncWriteScope? writeScope;
  Future<void> mergeBridgeDose(
    String userId,
    Map<String, dynamic> change,
    Map<String, dynamic> item,
    Map<String, String> scheduleIds,
    int? contractVersion,
  ) async {
    if (item.containsKey('parentPill') || item.containsKey('parentProfile')) {
      if (!const {3, 4, 5}.contains(contractVersion)) {
        throw const FormatException(
          'Historical ancestors require bridge contract v3.',
        );
      }
    }
    if (const {3, 4, 5}.contains(contractVersion) &&
        (item['parentSchedule'] != null ||
            item.containsKey('parentPill') ||
            item.containsKey('parentProfile'))) {
      _validateHistoricalAncestors(item);
      final source = change['sourceIdentity'];
      if (change['schemaVersion'] != 2 ||
          change['entityType'] != 'bridge_dose' ||
          change['operation'] != 'upsert' ||
          change['entityId'] != item['id'] ||
          source is! Map<String, dynamic> ||
          source['sourceKind'] != 'legacy_dose_log' ||
          source['sourceId'] != item['id'] ||
          source['sourceRevision'] != item['sourceRevision']) {
        throw const FormatException(
          'Historical ancestor source identity is invalid.',
        );
      }
    }
    final serverId = item['id'] as String;
    final existing = await db.doseLogsDao.getByServerId(serverId);
    if (existing != null) {
      try {
        await _restoreExactBridgeParent(
          change,
          item,
          existing,
          scheduleIds,
          contractVersion,
        );
        await writeScope?.requireEntity('doseLog', existing.id);
      } on WorkspaceAccessFailure catch (error) {
        await _reportExistingBridgeDoseRefusal(item, existing, error);
        rethrow;
      }
    }
    final localId = existing?.id ?? serverId;
    if (existing != null &&
        existing.syncStatus != 'synced' &&
        !await db.pendingOperationsDao.isLegacySourceSettled(
          userId,
          existing.id,
          kind: 'dose',
        )) {
      return;
    }
    final serverScheduleId = item['scheduleId'] as String;
    final mappedSchedule = await db.schedulesDao.getByMappedOrLocalId(
      serverScheduleId,
    );
    final parent = item['parentSchedule'];
    if (parent != null && !const {2, 3, 4, 5}.contains(contractVersion)) {
      throw const FormatException(
        'Historical parent requires bridge contract v2.',
      );
    }
    if (parent != null) _validateHistoricalSchedule(parent, serverScheduleId);
    if (mappedSchedule == null &&
        !scheduleIds.containsKey(serverScheduleId) &&
        parent != null) {
      try {
        await _materializeHistoricalSchedule(
          parent as Map<String, dynamic>,
          item: item,
          contractVersion: contractVersion,
        );
      } on WorkspaceAccessFailure catch (error) {
        SafeDiagnostics.logAccessRefusal(
          component: 'medicationBridge',
          payloadKind: 'bridgeDose',
          phase: 'bridge_parent_import',
          reason: error.code.name,
        );
        rethrow;
      }
    }
    final localScheduleId =
        scheduleIds[serverScheduleId] ?? mappedSchedule?.id ?? serverScheduleId;
    try {
      await writeScope?.requireEntity('schedule', localScheduleId);
    } on WorkspaceAccessFailure catch (error) {
      SafeDiagnostics.logAccessRefusal(
        component: 'medicationBridge',
        payloadKind: 'bridgeDose',
        phase: parent == null
            ? 'bridge_incoming_without_parent'
            : 'bridge_incoming_with_parent',
        reason: error.code.name,
      );
      rethrow;
    }
    final scheduledAt = syncDate(item['scheduledAt']);
    await db.doseLogsDao.upsert(
      DoseLogsCompanion(
        id: Value(localId),
        scheduleId: Value(localScheduleId),
        scheduledAt: Value(scheduledAt),
        takenAt: Value(syncNullableDate(item['takenAt'])),
        status: Value(item['status'] as String),
        note: Value(existing?.note),
        createdAt: Value(existing?.createdAt ?? scheduledAt),
        updatedAt: Value(
          item['deletedAt'] == null
              ? (existing?.updatedAt ?? scheduledAt)
              : syncDate(item['deletedAt']),
        ),
        serverId: Value(serverId),
        revision: Value(int.parse(item['sourceRevision'] as String)),
        syncStatus: const Value('synced'),
        isDeleted: Value(item['deletedAt'] != null),
      ),
    );
  }

  Future<void> _restoreExactBridgeParent(
    Map<String, dynamic> change,
    Map<String, dynamic> item,
    DoseLog existing,
    Map<String, String> scheduleIds,
    int? contractVersion,
  ) async {
    final parent = item['parentSchedule'];
    final source = change['sourceIdentity'];
    final revisionText = item['sourceRevision'];
    final revision =
        revisionText is String &&
            RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(revisionText)
        ? int.tryParse(revisionText)
        : null;
    if (!const {2, 3, 4, 5}.contains(contractVersion) ||
        parent is! Map<String, dynamic> ||
        source is! Map<String, dynamic> ||
        change['schemaVersion'] != 2 ||
        change['component'] != 'medicationBridge' ||
        change['entityType'] != 'bridge_dose' ||
        change['operation'] != 'upsert' ||
        change['entityId'] != item['id'] ||
        source['sourceKind'] != 'legacy_dose_log' ||
        source['sourceId'] != item['id'] ||
        source['sourceRevision'] != revisionText ||
        existing.serverId == null ||
        existing.serverId != item['id'] ||
        existing.syncStatus != 'synced' ||
        existing.scheduleId != item['scheduleId'] ||
        revision == null ||
        existing.revision <= 0 ||
        existing.revision > revision ||
        !existing.scheduledAt.isAtSameMomentAs(syncDate(item['scheduledAt'])) ||
        scheduleIds.containsKey(existing.scheduleId)) {
      return;
    }
    _validateHistoricalSchedule(parent, existing.scheduleId);
    final collision = await db.doseLogsDao.getById(item['id'] as String);
    if (collision != null && collision.id != existing.id) return;
    final localPillId =
        (await db.pillsDao.getByMappedOrLocalId(
          parent['pillId'] as String,
        ))?.id ??
        parent['pillId'] as String;
    final retained =
        await (db.select(db.medicationOccurrences)..where(
              (row) => row.occurrenceKey.isIn([
                'legacy:${existing.id}',
                'prn:${existing.id}',
              ]),
            ))
            .get();
    if (retained.any(
      (row) =>
          row.source == 'legacy' &&
          row.provenance == 'legacy_estimated' &&
          (row.userId != writeScope?.capability?.ownerId ||
              (row.pillId != null && row.pillId != localPillId)),
    )) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    final mappedSchedule = await db.schedulesDao.getByServerId(
      existing.scheduleId,
    );
    final directSchedule = await db.schedulesDao.getById(existing.scheduleId);
    if (mappedSchedule != null &&
        directSchedule != null &&
        mappedSchedule.id != directSchedule.id) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    final schedule = mappedSchedule ?? directSchedule;
    if (schedule != null) {
      final scope = writeScope;
      if (scope != null &&
          schedule.id == existing.scheduleId &&
          schedule.serverId == parent['id'] &&
          schedule.pillId == localPillId &&
          await _hasVerifiedCurrentBridgeAncestors(item, schedule)) {
        // A reviewed routine may legitimately differ from its historical
        // snapshot. Its complete canonical ownership chain needs no repair.
        await scope.requireEntity('doseLog', existing.id);
        return;
      }
      if (!const {3, 4, 5}.contains(contractVersion)) return;
      final days = parent['frequencyDays'];
      bool storedInstant(DateTime stored, Object? incoming) =>
          stored.millisecondsSinceEpoch ~/ 1000 ==
          syncDate(incoming).millisecondsSinceEpoch ~/ 1000;
      if (schedule.id != existing.scheduleId ||
          (schedule.serverId != null && schedule.serverId != parent['id']) ||
          schedule.pillId != localPillId ||
          schedule.syncStatus != 'synced' ||
          schedule.isActive ||
          schedule.revision != int.parse(parent['revision'] as String) ||
          schedule.hour != parent['hour'] ||
          schedule.minute != parent['minute'] ||
          schedule.frequency != parent['frequency'] ||
          schedule.frequencyDays != (days == null ? null : jsonEncode(days)) ||
          schedule.everyDays != parent['everyDays'] ||
          schedule.anchorDate != parent['anchorDate'] ||
          schedule.startDate != parent['startDate'] ||
          schedule.endDate != parent['endDate'] ||
          schedule.isDeleted != (parent['deletedAt'] != null) ||
          !storedInstant(schedule.createdAt, parent['createdAt']) ||
          !storedInstant(schedule.updatedAt, parent['updatedAt'])) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.wrongPerson,
        );
      }
      // Recover only missing ancestors. The retained schedule is never rebound
      // or overwritten, and its original ownership guard runs again.
      await _restoreHistoricalAncestors(item);
      await writeScope?.requireEntity('schedule', schedule.id);
      return;
    }
    // The durable mapping and immutable source identity authorize only this
    // exact missing node. The dose keeps its original schedule ID and note.
    await _materializeHistoricalSchedule(
      parent,
      item: item,
      contractVersion: contractVersion,
    );
    await writeScope?.requireEntity('schedule', existing.scheduleId);
  }

  Future<bool> _hasVerifiedCurrentBridgeAncestors(
    Map<String, dynamic> item,
    Schedule schedule,
  ) async {
    final pill = item['parentPill'];
    final profile = item['parentProfile'];
    if (pill is! Map<String, dynamic> || profile is! Map<String, dynamic>) {
      return false;
    }
    final pillId = pill['id'] as String;
    final profileId = profile['id'] as String;
    final mappedPill = await db.pillsDao.getByServerId(pillId);
    final directPill = await db.pillsDao.getById(pillId);
    final mappedProfile = await db.profilesDao.getByServerId(profileId);
    final directProfile = await db.profilesDao.getById(profileId);
    if ((mappedPill != null &&
            directPill != null &&
            mappedPill.id != directPill.id) ||
        (mappedProfile != null &&
            directProfile != null &&
            mappedProfile.id != directProfile.id)) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    return mappedPill != null &&
        mappedProfile != null &&
        mappedPill.id == schedule.pillId &&
        mappedPill.profileId == mappedProfile.id;
  }

  Future<void> _reportExistingBridgeDoseRefusal(
    Map<String, dynamic> item,
    DoseLog existing,
    WorkspaceAccessFailure error,
  ) async {
    var parentIdentity = 'unknown';
    var legacyOwnerEvidence = 'unknown';
    try {
      final parent = item['parentSchedule'];
      parentIdentity = parent == null
          ? 'absent'
          : parent is Map<String, dynamic> && parent['id'] is String
          ? parent['id'] == existing.scheduleId
                ? 'same_local_id'
                : 'different_local_id'
          : 'unknown';
      final retained =
          await (db.select(db.medicationOccurrences)..where(
                (row) => row.occurrenceKey.isIn([
                  'legacy:${existing.id}',
                  'prn:${existing.id}',
                ]),
              ))
              .get();
      final owners = retained
          .where(
            (row) =>
                row.source == 'legacy' &&
                row.provenance == 'legacy_estimated' &&
                row.scheduleId == existing.scheduleId,
          )
          .map((row) => row.userId)
          .toSet();
      legacyOwnerEvidence = owners.isEmpty
          ? 'none'
          : owners.length != 1
          ? 'ambiguous'
          : owners.single == writeScope?.capability?.ownerId
          ? 'current_owner'
          : 'other_owner';
    } on Object {
      // Diagnostic reads must never replace the original access refusal.
    }
    SafeDiagnostics.logAccessRefusal(
      component: 'medicationBridge',
      payloadKind: 'bridgeDose',
      phase: 'bridge_existing_dose',
      parentIdentity: parentIdentity,
      legacyOwnerEvidence: legacyOwnerEvidence,
      reason: error.code.name,
    );
  }

  void _validateHistoricalSchedule(Object parent, String serverScheduleId) {
    if (parent is! Map<String, dynamic>) {
      throw const FormatException('Historical schedule is invalid.');
    }
    final hour = parent['hour'];
    final minute = parent['minute'];
    final frequency = parent['frequency'];
    final days = parent['frequencyDays'];
    final revision = parent['revision'];
    final disposition = parent['disposition'];
    final deletedAt = parent['deletedAt'];
    final uuid = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    if (parent['id'] != serverScheduleId ||
        parent['id'] is! String ||
        !uuid.hasMatch(parent['id'] as String) ||
        parent['pillId'] is! String ||
        !uuid.hasMatch(parent['pillId'] as String) ||
        hour is! int ||
        hour < 0 ||
        hour > 23 ||
        minute is! int ||
        minute < 0 ||
        minute > 59 ||
        !const [
          'daily',
          'weekly',
          'custom',
          'interval',
          'prn',
        ].contains(frequency) ||
        (days != null &&
            (days is! List ||
                days.length > 4096 ||
                days.any(
                  (day) =>
                      day != null &&
                      (day is! int || day < -2147483648 || day > 2147483647),
                ))) ||
        revision is! String ||
        !RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(revision) ||
        int.tryParse(revision) == null ||
        (disposition != 'quarantined' && disposition != 'deleted') ||
        (disposition == 'quarantined' && deletedAt != null) ||
        (disposition == 'deleted' && deletedAt == null)) {
      throw const FormatException('Historical schedule is invalid.');
    }
    final validDays =
        days is List &&
        days.isNotEmpty &&
        days.every((day) => day is int && day >= 1 && day <= 7) &&
        days.toSet().length == days.length;
    final ScheduleWindow window;
    try {
      window = ScheduleWindow.fromJson(parent);
    } on TypeError {
      throw const FormatException('Historical schedule is invalid.');
    }
    final validFrequency = switch (frequency) {
      'daily' || 'prn' => days == null && window.isValidFor(frequency),
      'interval' => days == null && window.isValidFor(frequency),
      'weekly' => validDays && days.length == 1 && window.isValidFor(frequency),
      'custom' => validDays && window.isValidFor(frequency),
      _ => false,
    };
    if (disposition == 'quarantined' && validFrequency) {
      throw const FormatException(
        'Historical quarantine requires invalid frequency.',
      );
    }
    syncDate(parent['createdAt']);
    syncDate(parent['updatedAt']);
    syncNullableDate(deletedAt);
  }

  Future<void> _materializeHistoricalSchedule(
    Map<String, dynamic> parent, {
    required Map<String, dynamic> item,
    required int? contractVersion,
  }) async {
    final scope = writeScope;
    if (scope == null) {
      throw const WorkspaceAccessFailure(WorkspaceAccessFailureCode.staleGrant);
    }
    if (const {3, 4, 5}.contains(contractVersion)) {
      await _restoreHistoricalAncestors(item);
    }
    final serverId = parent['id'] as String;
    final serverPillId = parent['pillId'] as String;
    final localPillId =
        (await db.pillsDao.getByMappedOrLocalId(serverPillId))?.id ??
        serverPillId;
    // The parent is never authority by itself: its existing pill must belong to
    // the captured owner before a historical, inactive schedule is stored.
    await scope.requireEntity('pill', localPillId);
    final days = parent['frequencyDays'];
    await db.schedulesDao.upsert(
      SchedulesCompanion.insert(
        id: serverId,
        pillId: localPillId,
        hour: parent['hour'] as int,
        minute: parent['minute'] as int,
        frequency: parent['frequency'] as String,
        frequencyDays: Value(days == null ? null : jsonEncode(days)),
        everyDays: Value(parent['everyDays'] as int?),
        anchorDate: Value(parent['anchorDate'] as String?),
        startDate: Value(parent['startDate'] as String?),
        endDate: Value(parent['endDate'] as String?),
        isActive: const Value(false),
        createdAt: syncDate(parent['createdAt']),
        updatedAt: syncDate(parent['updatedAt']),
        serverId: Value(serverId),
        revision: Value(int.parse(parent['revision'] as String)),
        syncStatus: const Value('synced'),
        isDeleted: Value(parent['deletedAt'] != null),
      ),
    );
  }

  void _validateHistoricalAncestors(Map<String, dynamic> item) {
    final profile = item['parentProfile'];
    final pill = item['parentPill'];
    final schedule = item['parentSchedule'];
    if (profile is! Map<String, dynamic> ||
        pill is! Map<String, dynamic> ||
        schedule is! Map<String, dynamic> ||
        profile['kind'] != 'profile' ||
        pill['kind'] != 'pill' ||
        pill['profileId'] != profile['id'] ||
        schedule['pillId'] != pill['id']) {
      throw const FormatException('Historical ancestor chain is invalid.');
    }
    if (profile['userId'] is! String) {
      throw const FormatException('Historical ancestor owner is invalid.');
    }
    writeScope?.requireOwner(profile['userId'] as String);
    const common = {
      'kind',
      'id',
      'name',
      'revision',
      'deletedAt',
      'createdAt',
      'updatedAt',
    };
    const profileKeys = {...common, 'userId', 'avatarEmoji', 'isActive'};
    const pillKeys = {
      ...common,
      'profileId',
      'dosage',
      'notes',
      'color',
      'currentStock',
      'lowStockThreshold',
      'isPrn',
    };
    final uuid = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    for (final pair in [(profile, profileKeys), (pill, pillKeys)]) {
      final snapshot = pair.$1;
      if (snapshot.keys.toSet().difference(pair.$2).isNotEmpty ||
          pair.$2.difference(snapshot.keys.toSet()).isNotEmpty ||
          snapshot['id'] is! String ||
          !uuid.hasMatch(snapshot['id'] as String) ||
          snapshot['name'] is! String ||
          (snapshot['name'] as String).isEmpty ||
          (snapshot['name'] as String).length > 100) {
        throw const FormatException('Historical ancestor snapshot is invalid.');
      }
      _snapshotRevision(snapshot);
      syncDate(snapshot['createdAt']);
      syncDate(snapshot['updatedAt']);
      if (snapshot['deletedAt'] != null) syncDate(snapshot['deletedAt']);
    }
    if (profile['isActive'] is! bool ||
        profile['avatarEmoji'] is! String ||
        (profile['avatarEmoji'] as String).isEmpty ||
        (profile['avatarEmoji'] as String).length > 32 ||
        pill['isPrn'] is! bool) {
      throw const FormatException('Historical ancestor fields are invalid.');
    }
    for (final pair in [('dosage', 50), ('notes', 500)]) {
      final value = pill[pair.$1];
      if (value != null && (value is! String || value.length > pair.$2)) {
        throw const FormatException('Historical medication text is invalid.');
      }
    }
    final color = pill['color'];
    if (color != null &&
        (color is! String || !RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(color))) {
      throw const FormatException('Historical medication color is invalid.');
    }
    for (final key in ['currentStock', 'lowStockThreshold']) {
      final value = pill[key];
      if (value != null &&
          (value is! int ||
              value.abs() > 9007199254740991 ||
              (key == 'lowStockThreshold' && value < 0))) {
        throw const FormatException('Historical medication stock is invalid.');
      }
    }
  }

  int _snapshotRevision(Map<String, dynamic> snapshot) {
    final value = snapshot['revision'];
    final revision =
        value is String && RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(value)
        ? int.tryParse(value)
        : null;
    if (revision == null) {
      throw const FormatException('Historical ancestor revision is invalid.');
    }
    return revision;
  }

  Future<void> _restoreHistoricalAncestors(Map<String, dynamic> item) async {
    _validateHistoricalAncestors(item);
    final scope = writeScope;
    if (scope == null) {
      throw const WorkspaceAccessFailure(WorkspaceAccessFailureCode.staleGrant);
    }
    final profile = item['parentProfile'] as Map<String, dynamic>;
    final pill = item['parentPill'] as Map<String, dynamic>;
    final profileId = profile['id'] as String;
    final mappedProfile = await db.profilesDao.getByServerId(profileId);
    final directProfile = await db.profilesDao.getById(profileId);
    if (mappedProfile != null &&
        directProfile != null &&
        mappedProfile.id != directProfile.id) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    final existingProfile = mappedProfile ?? directProfile;
    final localProfileId = existingProfile?.id ?? profileId;
    if (existingProfile != null) {
      await scope.requireEntity('profile', existingProfile.id);
      if (existingProfile.syncStatus != 'synced' ||
          existingProfile.revision > _snapshotRevision(profile) ||
          (existingProfile.serverId != null &&
              existingProfile.serverId != profileId)) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.wrongPerson,
        );
      }
    } else {
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: profileId,
          userId: profile['userId'] as String,
          name: profile['name'] as String,
          avatarEmoji: Value(profile['avatarEmoji'] as String),
          isActive: Value(profile['isActive'] as bool),
          revision: Value(_snapshotRevision(profile)),
          serverId: Value(profileId),
          syncStatus: const Value('synced'),
          isDeleted: Value(profile['deletedAt'] != null),
          createdAt: syncDate(profile['createdAt']),
          updatedAt: syncDate(profile['updatedAt']),
        ),
      );
    }
    await scope.requireEntity('profile', localProfileId);
    final pillId = pill['id'] as String;
    final mappedPill = await db.pillsDao.getByServerId(pillId);
    final directPill = await db.pillsDao.getById(pillId);
    if (mappedPill != null &&
        directPill != null &&
        mappedPill.id != directPill.id) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    final existingPill = mappedPill ?? directPill;
    if (existingPill != null) {
      await scope.requireEntity('pill', existingPill.id);
      if (existingPill.profileId != localProfileId ||
          existingPill.syncStatus != 'synced' ||
          existingPill.revision > _snapshotRevision(pill) ||
          (existingPill.serverId != null && existingPill.serverId != pillId)) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.wrongPerson,
        );
      }
    } else {
      await db.pillsDao.upsert(
        PillsCompanion.insert(
          id: pillId,
          profileId: localProfileId,
          name: pill['name'] as String,
          dosage: Value(pill['dosage'] as String?),
          notes: Value(pill['notes'] as String?),
          color: Value(pill['color'] as String?),
          currentStock: Value(pill['currentStock'] as int?),
          lowStockThreshold: Value(pill['lowStockThreshold'] as int?),
          isPrn: Value(pill['isPrn'] as bool),
          revision: Value(_snapshotRevision(pill)),
          serverId: Value(pillId),
          syncStatus: const Value('synced'),
          isDeleted: Value(pill['deletedAt'] != null),
          createdAt: syncDate(pill['createdAt']),
          updatedAt: syncDate(pill['updatedAt']),
        ),
      );
    }
    await scope.requireEntity('pill', existingPill?.id ?? pillId);
  }

  Future<void> mergeBridgeStock(
    String userId,
    Map<String, dynamic> item,
    Map<String, String> pillIds,
  ) async {
    final serverId = item['pillId'] as String;
    final localId =
        pillIds[serverId] ??
        (await db.pillsDao.getByMappedOrLocalId(serverId))?.id;
    if (localId == null) {
      throw const FormatException('Bridge stock pill is not mapped locally.');
    }
    await writeScope?.requireEntity('pill', localId);
    final pill = await db.pillsDao.getById(localId);
    if (pill == null) return;
    if (pill.syncStatus != 'synced' &&
        (!await db.pendingOperationsDao.isLegacySourceSettled(
              userId,
              localId,
              kind: 'inventory',
            ) ||
            await db.pendingOperationsDao.hasUncommittedEntity(
              userId: userId,
              component: 'stable',
              entityType: 'pill',
              entityLocalId: localId,
            ))) {
      return;
    }
    // Bridge mode keeps a held stock correction on the phone; the server's
    // count must not replace it.
    if ((await heldStockPillIds(db, userId)).contains(localId) ||
        (await unsettledInventoryPillIds(db, userId)).contains(localId)) {
      return;
    }
    // Stock is a projection onto an existing medication, not a complete row
    // for insertion. Preserve its details and any locally pending edit.
    await (db.update(db.pills)..where((row) => row.id.equals(localId))).write(
      PillsCompanion(
        currentStock: wirePillStock(item).currentStock,
        stockQuantity: wirePillStock(item).stockQuantity,
        stockUnit: wirePillStock(item).stockUnit,
        updatedAt: Value(syncDate(item['updatedAt'])),
        syncStatus: const Value('synced'),
      ),
    );
  }

  Future<void> mergeBridgeOccurrence(
    String userId,
    Map<String, dynamic> change,
    Map<String, dynamic> item,
    Map<String, String> pillIds,
    Map<String, String> scheduleIds,
    int? contractVersion,
  ) async {
    final source = change['sourceIdentity'];
    final stateVersion = item['stateVersion'];
    final version =
        stateVersion is String &&
            RegExp(r'^(0|[1-9][0-9]{0,18})$').hasMatch(stateVersion)
        ? BigInt.tryParse(stateVersion)
        : null;
    final prn = item['source'] == 'prn';
    if (!const {4, 5}.contains(contractVersion) ||
        change['schemaVersion'] != 2 ||
        change['entityType'] != 'medication_occurrence' ||
        change['operation'] != 'upsert' ||
        change['entityId'] != item['id'] ||
        (item['source'] != 'scheduled' && !(prn && contractVersion == 5)) ||
        item['provenance'] != 'exact' ||
        version == null ||
        source is! Map<String, dynamic> ||
        source['sourceKind'] != 'occurrence' ||
        source['sourceId'] != item['id'] ||
        source['sourceRevision'] != (version + BigInt.one).toString()) {
      throw const FormatException(
        'Reviewed occurrence requires bridge v4 identity.',
      );
    }
    if (prn &&
        (item['occurrenceKey'] != 'prn:v1:${item['id']}' ||
            item['plannedAt'] != null ||
            item['plannedLocalTime'] != null ||
            item['expected'] != false)) {
      throw const FormatException('PRN occurrence has scheduled semantics.');
    }
    final scope = writeScope;
    if (scope == null) {
      throw const WorkspaceAccessFailure(WorkspaceAccessFailureCode.staleGrant);
    }
    final pill = await db.pillsDao.getByMappedOrLocalId(
      item['pillId'] as String,
    );
    final schedule = await db.schedulesDao.getByMappedOrLocalId(
      item['scheduleId'] as String,
    );
    if (pill == null || schedule == null || schedule.pillId != pill.id) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    await scope.requireEntity('pill', pill.id);
    await scope.requireEntity('schedule', schedule.id);
    final snapshot = item['scheduleSnapshot'];
    if (snapshot is! Map<String, dynamic> ||
        !const {1, 3}.contains(snapshot['version']) ||
        snapshot['profileId'] is! String ||
        snapshot['timeZone'] != item['timeZone']) {
      throw const FormatException('Reviewed occurrence snapshot is invalid.');
    }
    if (prn &&
        (snapshot['frequency'] != 'prn' ||
            snapshot['frequencyDays'] != null ||
            snapshot['hour'] != null ||
            snapshot['minute'] != null ||
            item['scheduleRevision'] is! String ||
            !RegExp(
              r'^[1-9][0-9]{0,18}$',
            ).hasMatch(item['scheduleRevision'] as String))) {
      throw const FormatException('PRN snapshot has scheduled semantics.');
    }
    final person = await db.profilesDao.getByMappedOrLocalId(
      snapshot['profileId'] as String,
    );
    if (person == null || person.id != pill.profileId) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    await scope.requireEntity('profile', person.id);
    final serverId = item['id'] as String;
    final mapped = await db.medicationLedgerDao.getOccurrenceByServerId(
      serverId,
    );
    final keyed = await db.medicationLedgerDao.getOccurrenceByKey(
      userId,
      item['occurrenceKey'] as String,
    );
    final direct = await db.medicationLedgerDao.getOccurrenceById(serverId);
    if ((mapped != null && keyed != null && mapped.id != keyed.id) ||
        (direct != null && direct.id != (mapped ?? keyed)?.id)) {
      throw const FormatException('Reviewed occurrence identity collision.');
    }
    final existing = mapped ?? keyed;
    if (existing != null) {
      scope.requireOwner(existing.userId);
      if (existing.serverId != null && existing.serverId != serverId) {
        throw const FormatException('Reviewed occurrence mapping collision.');
      }
      // This stream carries plans, not the phone's recorded care or Undo head.
      if (!prn &&
          (existing.stateVersion > 0 ||
              existing.state != 'pending' ||
              (await db.medicationLedgerDao.getEventsForOccurrence(
                existing.id,
              )).isNotEmpty)) {
        if (existing.serverId == null) {
          await _bindRecordedBridgeOccurrence(
            existing,
            item,
            pill,
            schedule,
            person,
            snapshot,
          );
        }
        return;
      }
    }
    await mergeOccurrence(
      userId,
      {
        ...item,
        // Bind the canonical snapshot to its proven local person projection.
        'scheduleSnapshot': {...snapshot, 'profileId': person.id},
      },
      pillIds,
      scheduleIds,
    );
  }

  Future<void> _bindRecordedBridgeOccurrence(
    MedicationOccurrence existing,
    Map<String, dynamic> item,
    Pill pill,
    Schedule schedule,
    Profile person,
    Map<String, dynamic> snapshot,
  ) async {
    // A recording made before the first plan pull still needs its server link.
    // Prove the immutable v1 plan; never replace its local care or Undo head.
    final key = item['occurrenceKey'] as String;
    if (!RegExp(r'^scheduled:v1:[0-9a-f]{64}$').hasMatch(key) ||
        item['stateVersion'] != '0' ||
        existing.occurrenceKey != key ||
        existing.source != 'scheduled' ||
        existing.provenance != 'exact' ||
        !existing.expected ||
        item['expected'] != true ||
        !const {1, 3}.contains(existing.snapshotVersion) ||
        item['snapshotVersion'] != existing.snapshotVersion ||
        existing.pillId != pill.id ||
        existing.scheduleId != schedule.id ||
        pill.serverId != item['pillId'] ||
        schedule.serverId != item['scheduleId'] ||
        person.serverId != snapshot['profileId'] ||
        existing.scheduleRevision !=
            syncNullableInt(item['scheduleRevision']) ||
        existing.plannedLocalDate != item['plannedLocalDate'] ||
        !_samePlannedLocalTime(
          existing.plannedLocalTime,
          item['plannedLocalTime'],
        ) ||
        existing.timeZone != item['timeZone'] ||
        existing.plannedAt == null ||
        existing.plannedAt?.toUtc() != syncNullableDate(item['plannedAt']) ||
        existing.supersededAt?.toUtc() !=
            syncNullableDate(item['supersededAt']) ||
        existing.supersededByOccurrenceId != item['supersededByOccurrenceId']) {
      throw const FormatException(
        'Recorded occurrence plan identity mismatch.',
      );
    }
    final localSnapshot = jsonDecode(existing.scheduleSnapshotJson);
    if (localSnapshot is! Map<String, dynamic> ||
        localSnapshot['version'] != existing.snapshotVersion ||
        localSnapshot['profileId'] != person.id ||
        !const DeepCollectionEquality().equals(
          [
            for (final field in [
              'frequency',
              'frequencyDays',
              'hour',
              'minute',
              'timeZone',
              if (existing.snapshotVersion == 3) ...[
                'everyDays',
                'anchorDate',
                'startDate',
                'endDate',
              ],
            ])
              localSnapshot[field],
          ],
          [
            for (final field in [
              'frequency',
              'frequencyDays',
              'hour',
              'minute',
              'timeZone',
              if (existing.snapshotVersion == 3) ...[
                'everyDays',
                'anchorDate',
                'startDate',
                'endDate',
              ],
            ])
              snapshot[field],
          ],
        )) {
      throw const FormatException(
        'Recorded occurrence snapshot identity mismatch.',
      );
    }
    final directPill = await db.pillsDao.getById(item['pillId'] as String);
    final directSchedule = await db.schedulesDao.getById(
      item['scheduleId'] as String,
    );
    final directPerson = await db.profilesDao.getById(
      snapshot['profileId'] as String,
    );
    if ((directPill != null && directPill.id != pill.id) ||
        (directSchedule != null && directSchedule.id != schedule.id) ||
        (directPerson != null && directPerson.id != person.id)) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    await writeScope!.requireEntity('occurrence', existing.id);
    final changed =
        await (db.update(db.medicationOccurrences)..where(
              (row) =>
                  row.id.equals(existing.id) &
                  row.userId.equals(existing.userId) &
                  row.serverId.isNull(),
            ))
            .write(
              MedicationOccurrencesCompanion(
                serverId: Value(item['id'] as String),
              ),
            );
    if (changed != 1) {
      throw StateError('Recorded occurrence mapping changed during binding.');
    }
  }

  bool _samePlannedLocalTime(String? local, Object? incoming) {
    final pattern = RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d(?::00)?$');
    return local != null &&
        incoming is String &&
        pattern.hasMatch(local) &&
        pattern.hasMatch(incoming) &&
        local.substring(0, 5) == incoming.substring(0, 5);
  }

  Future<void> mergeOccurrence(
    String userId,
    Map<String, dynamic> item,
    Map<String, String> pillIds,
    Map<String, String> scheduleIds,
  ) async {
    final serverId = item['id'] as String;
    final existing =
        await db.medicationLedgerDao.getOccurrenceByServerId(serverId) ??
        await db.medicationLedgerDao.getOccurrenceByKey(
          userId,
          item['occurrenceKey'] as String,
        );
    if (existing != null) writeScope?.requireOwner(existing.userId);
    final localId = existing?.id ?? serverId;
    final hasPending =
        existing != null &&
        await db.pendingOperationsDao.hasUncommittedEntity(
          userId: userId,
          component: 'medication',
          entityType: 'occurrence',
          entityLocalId: localId,
        );
    final serverPillId = item['pillId'] as String?;
    final serverScheduleId = item['scheduleId'] as String?;
    final localPillId = serverPillId == null
        ? null
        : pillIds[serverPillId] ??
              (await db.pillsDao.getByMappedOrLocalId(serverPillId))?.id ??
              serverPillId;
    final localScheduleId = serverScheduleId == null
        ? null
        : scheduleIds[serverScheduleId] ??
              (await db.schedulesDao.getByMappedOrLocalId(
                serverScheduleId,
              ))?.id ??
              serverScheduleId;
    if (localPillId != null) {
      await writeScope?.requireEntity('pill', localPillId);
    }
    if (localScheduleId != null) {
      await writeScope?.requireEntity('schedule', localScheduleId);
    }
    final snapshot = item['scheduleSnapshot'] as Map<String, dynamic>;
    await db.medicationLedgerDao.upsertOccurrence(
      MedicationOccurrencesCompanion(
        id: Value(localId),
        userId: Value(userId),
        serverId: Value(serverId),
        pillId: Value(localPillId),
        scheduleId: Value(localScheduleId),
        occurrenceKey: Value(item['occurrenceKey'] as String),
        source: Value(item['source'] as String),
        scheduleRevision: Value(syncNullableInt(item['scheduleRevision'])),
        plannedLocalDate: Value(item['plannedLocalDate'] as String),
        plannedLocalTime: Value(item['plannedLocalTime'] as String?),
        timeZone: Value(item['timeZone'] as String),
        plannedAt: Value(syncNullableDate(item['plannedAt'])),
        expected: Value(item['expected'] as bool),
        snapshotVersion: Value(item['snapshotVersion'] as int),
        scheduleSnapshotJson: Value(jsonEncode(snapshot)),
        provenance: Value(item['provenance'] as String),
        state: Value(
          hasPending ? existing.state : (existing?.state ?? 'pending'),
        ),
        stateVersion: Value(
          hasPending
              ? existing.stateVersion
              : int.parse(item['stateVersion'] as String),
        ),
        serverSequence: Value(existing?.serverSequence),
        supersededAt: Value(syncNullableDate(item['supersededAt'])),
        supersededByOccurrenceId: Value(
          item['supersededByOccurrenceId'] as String?,
        ),
        createdAt: Value(existing?.createdAt ?? DateTime.now().toUtc()),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  /// Event instants are stored as Unix seconds, while the server keeps the
  /// instant it was sent (milliseconds). Compare at stored precision.
  bool _sameStoredInstant(DateTime? stored, Object? wire) {
    final pulled = syncNullableDate(wire);
    if (stored == null || pulled == null) {
      return stored == null && pulled == null;
    }
    return db.typeMapping.mapToSqlVariable(stored.toUtc()) ==
        db.typeMapping.mapToSqlVariable(pulled.toUtc());
  }

  Future<void> mergeOccurrenceEvent(
    String userId,
    Map<String, dynamic> item,
  ) async {
    final serverId = item['id'] as String;
    final commandId = item['commandId'] as String;
    final occurrence = await db.medicationLedgerDao.getOccurrenceByServerId(
      item['occurrenceId'] as String,
    );
    if (occurrence == null) {
      throw const FormatException('Occurrence event parent is unavailable.');
    }
    writeScope?.requireOwner(occurrence.userId);
    final existing =
        await db.medicationLedgerDao.getOccurrenceEventByServerId(serverId) ??
        await db.medicationLedgerDao.getOccurrenceEventByCommandId(commandId);
    if (existing != null) writeScope?.requireOwner(existing.userId);
    if (existing != null &&
        (existing.commandId != commandId ||
            existing.occurrenceId != occurrence.id)) {
      throw const FormatException('Occurrence event identity changed.');
    }
    if (occurrence.source == 'prn' &&
        existing != null &&
        (existing.action != item['action'] ||
            existing.fromState != item['fromState'] ||
            existing.toState != item['toState'] ||
            existing.baseVersion.toString() != item['baseVersion'] ||
            existing.resultVersion.toString() != item['resultVersion'] ||
            !_sameStoredInstant(existing.actualAt, item['actualAt']) ||
            existing.actualTimeKnown != item['actualTimeKnown'] ||
            existing.note != item['note'])) {
      throw const FormatException('Immutable PRN event facts changed.');
    }
    final rawAmount = item['administrationAmount'];
    if (rawAmount != null) {
      MedicationAmount.fromJson(Map<String, Object?>.from(rawAmount as Map));
      if (existing?.administrationAmountJson != null &&
          !const DeepCollectionEquality().equals(
            jsonDecode(existing!.administrationAmountJson!),
            rawAmount,
          )) {
        throw const FormatException(
          'Occurrence administration amount changed.',
        );
      }
    }
    // The name the dose was recorded under is display-only and write-once: a
    // value this device already holds is never replaced, and a shape or
    // version it cannot read leaves the author unknown instead of failing the
    // page.
    final recordedBy = existing?.recordedByJson == null
        ? RecordedBy.fromWire(item['recordedBy'])
        : null;
    final localId = existing?.id ?? serverId;
    final serverRecordedAt = syncDate(item['recordedAt']);
    final companion = OccurrenceEventsCompanion(
      id: Value(localId),
      serverId: Value(serverId),
      userId: Value(userId),
      occurrenceId: Value(occurrence.id),
      commandId: Value(commandId),
      action: Value(item['action'] as String),
      fromState: Value(item['fromState'] as String),
      toState: Value(item['toState'] as String),
      reversesEventId: Value(item['reversesEventId'] as String?),
      rebasesCommandId: Value(item['rebasesCommandId'] as String?),
      actualAt: Value(syncNullableDate(item['actualAt'])),
      actualTimeKnown: Value(item['actualTimeKnown'] as bool),
      note: Value(item['note'] as String?),
      origin: Value(item['origin'] as String),
      administrationAmountJson: rawAmount == null
          ? const Value.absent()
          : Value(jsonEncode(rawAmount)),
      recordedByJson: recordedBy == null
          ? const Value.absent()
          : Value(recordedBy.toStoredJson()),
      baseVersion: Value(int.parse(item['baseVersion'] as String)),
      resultVersion: Value(int.parse(item['resultVersion'] as String)),
      serverSequence: Value(int.parse(item['serverSequence'] as String)),
      // The server stamps its own receive time. For an event this device
      // already holds, the device's moment of recording is the truth shown as
      // "Recorded in Simpastil"; a later server receive time (an offline or
      // retried send) must not replace it.
      recordedAt:
          existing != null && !serverRecordedAt.isBefore(existing.recordedAt)
          ? const Value.absent()
          : Value(serverRecordedAt),
    );
    if (existing == null) {
      await db.medicationLedgerDao.appendOccurrenceEvent(
        OccurrenceEventsCompanion.insert(
          id: localId,
          userId: userId,
          occurrenceId: occurrence.id,
          commandId: commandId,
          action: item['action'] as String,
          fromState: item['fromState'] as String,
          toState: item['toState'] as String,
          reversesEventId: Value(item['reversesEventId'] as String?),
          rebasesCommandId: Value(item['rebasesCommandId'] as String?),
          actualAt: Value(syncNullableDate(item['actualAt'])),
          actualTimeKnown: Value(item['actualTimeKnown'] as bool),
          note: Value(item['note'] as String?),
          origin: item['origin'] as String,
          administrationAmountJson: Value(
            rawAmount == null ? null : jsonEncode(rawAmount),
          ),
          recordedByJson: Value(recordedBy?.toStoredJson()),
          baseVersion: int.parse(item['baseVersion'] as String),
          resultVersion: int.parse(item['resultVersion'] as String),
          serverSequence: Value(int.parse(item['serverSequence'] as String)),
          recordedAt: syncDate(item['recordedAt']),
          serverId: Value(serverId),
        ),
      );
    } else {
      await db.medicationLedgerDao.updateOccurrenceEvent(localId, companion);
    }
    final pending = await db.pendingOperationsDao.hasUncommittedEntity(
      userId: userId,
      component: 'medication',
      entityType: 'occurrence',
      entityLocalId: occurrence.id,
    );
    if (!pending &&
        int.parse(item['resultVersion'] as String) >= occurrence.stateVersion) {
      await (db.update(
        db.medicationOccurrences,
      )..where((row) => row.id.equals(occurrence.id))).write(
        MedicationOccurrencesCompanion(
          state: Value(item['toState'] as String),
          stateVersion: Value(int.parse(item['resultVersion'] as String)),
          updatedAt: Value(syncDate(item['recordedAt'])),
        ),
      );
    }
  }

  Future<void> mergeInventoryEvent(
    String userId,
    Map<String, dynamic> item,
    Map<String, String> pillIds,
  ) async {
    final serverId = item['id'] as String;
    final commandId = item['commandId'] as String;
    final serverPillId = item['pillId'] as String;
    final localPillId =
        pillIds[serverPillId] ??
        (await db.pillsDao.getByMappedOrLocalId(serverPillId))?.id ??
        serverPillId;
    final existing =
        await db.medicationLedgerDao.getInventoryEventByServerId(serverId) ??
        await db.medicationLedgerDao.getInventoryEventByCommandId(commandId);
    if (existing != null) writeScope?.requireOwner(existing.userId);
    await writeScope?.requireEntity('pill', localPillId);
    final localId = existing?.id ?? serverId;
    if (existing == null) {
      await db.medicationLedgerDao.appendInventoryEvent(
        InventoryEventsCompanion.insert(
          id: localId,
          userId: userId,
          pillId: localPillId,
          commandId: commandId,
          kind: item['eventKind'] as String,
          delta: wireInventoryDelta(item),
          occurrenceEventId: Value(item['occurrenceEventId'] as String?),
          reversesInventoryEventId: Value(
            item['reversesInventoryEventId'] as String?,
          ),
          origin: item['provenance'] as String,
          provenanceJson: Value(jsonEncode({'note': item['note']})),
          serverSequence: Value(int.parse(item['serverSequence'] as String)),
          recordedAt: syncDate(item['recordedAt']),
          serverId: Value(serverId),
        ),
      );
    } else {
      await db.medicationLedgerDao.updateInventoryEvent(
        localId,
        InventoryEventsCompanion(
          serverId: Value(serverId),
          userId: Value(userId),
          pillId: Value(localPillId),
          commandId: Value(commandId),
          kind: Value(item['eventKind'] as String),
          delta: Value(wireInventoryDelta(item)),
          occurrenceEventId: Value(item['occurrenceEventId'] as String?),
          reversesInventoryEventId: Value(
            item['reversesInventoryEventId'] as String?,
          ),
          origin: Value(item['provenance'] as String),
          provenanceJson: Value(jsonEncode({'note': item['note']})),
          serverSequence: Value(int.parse(item['serverSequence'] as String)),
          recordedAt: Value(syncDate(item['recordedAt'])),
        ),
      );
    }
  }
}
