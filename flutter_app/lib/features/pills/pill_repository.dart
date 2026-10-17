import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../core/db/daos/profiles_dao.dart';
import '../../core/db/daos/pills_dao.dart';
import '../../core/db/daos/schedules_dao.dart';
import '../../core/db/database.dart';
import '../../core/errors/app_error.dart';
import '../../core/inventory/inventory_service.dart';
import '../../core/medication/medication_amount.dart';
import '../../core/medication/medication_detail_wire.dart';
import '../../core/projections/projection_command_id.dart';
import '../../core/sync/pending_operation_repository.dart';
import '../../core/workspace/workspace_context.dart';
import '../../core/utils/app_logger.dart';

// ── Abstract interface ────────────────────────────────────────────────────────

abstract class PillRepository {
  /// The reviewed details ([amount], [packageStrength], [form],
  /// [legacyDosageReviewed]) are saved with the medicine rather than after it,
  /// so the account receives them in the one `pill.create` and a medicine added
  /// here is never left with its amount only on this device.
  Future<Result<Pill>> create({
    required String profileId,
    required String name,
    String? dosage,
    String? notes,
    String? color,
    int? currentStock,
    int? lowStockThreshold,
    bool isPrn = false,
    MedicationAmount amount = const MedicationAmount.unknown(),
    String? packageStrength,
    String? form,
    bool legacyDosageReviewed = false,
  });

  Future<Result<Pill>> update(
    String localId, {
    required String name,
    String? dosage,
    String? notes,
    String? color,
    int? currentStock,
    int? lowStockThreshold,
    bool isPrn = false,
  });

  Future<Result<void>> delete(String localId);
}

// ── Concrete implementation ───────────────────────────────────────────────────

class PillRepositoryImpl implements PillRepository {
  const PillRepositoryImpl({
    required AppDatabase db,
    required PillsDao dao,
    required ProfilesDao profilesDao,
    required SchedulesDao schedulesDao,
    required PendingOperationRepository pendingOperations,
    required Future<void> Function() reconcileProjections,
    Duration effectsTimeout = const Duration(seconds: 5),
  }) : _effectsTimeout = effectsTimeout,
       _db = db,
       _dao = dao,
       _profilesDao = profilesDao,
       _schedulesDao = schedulesDao,
       _pendingOperations = pendingOperations,
       _reconcileProjections = reconcileProjections;

  final AppDatabase _db;
  final PillsDao _dao;
  final ProfilesDao _profilesDao;
  final SchedulesDao _schedulesDao;
  final PendingOperationRepository _pendingOperations;
  final Future<void> Function() _reconcileProjections;

  static const _uuid = Uuid();

  Future<Profile?> _readProfile(String id) =>
      _pendingOperations.withCareGrant(() async {
        final profile = await _profilesDao.getById(id);
        if (profile != null) {
          _pendingOperations.requireCareOwner(profile.userId);
          if (profile.isDeleted) {
            throw const WorkspaceAccessFailure(
              WorkspaceAccessFailureCode.wrongPerson,
            );
          }
        }
        return profile;
      });

  Future<Pill?> _readPill(String id) =>
      _pendingOperations.withCareGrant(() async {
        final pill = await _dao.getById(id);
        if (pill != null && await _readProfile(pill.profileId) == null) {
          throw const WorkspaceAccessFailure(
            WorkspaceAccessFailureCode.wrongPerson,
          );
        }
        return pill;
      });

  Future<List<Schedule>> _readSchedules(String pillId) =>
      _pendingOperations.withCareGrant(() async {
        if (await _readPill(pillId) == null) {
          throw const WorkspaceAccessFailure(
            WorkspaceAccessFailureCode.wrongPerson,
          );
        }
        return _schedulesDao.getByPillId(pillId);
      });

  Future<void> _requireUnchangedPill(Pill expected) async {
    if (await _readPill(expected.id) != expected) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.unavailable,
      );
    }
  }

  /// Post-commit projection effects must never hold a save open: they are
  /// bounded by [_effectsTimeout]. On timeout the effect keeps running (it is
  /// not cancelled) and the save completes; its eventual failure is logged.
  final Duration _effectsTimeout;

  Future<void> _effects(Future<void> Function() action) async {
    try {
      final running = action();
      // A failure that lands after the timeout is intentionally dropped.
      running.ignore();
      await running.timeout(_effectsTimeout);
    } on Object catch (error) {
      AppLogger.warning(
        'PillRepository',
        'Optional projection unavailable: ${error.runtimeType}',
      );
    }
  }

  Future<void> _recordCare({
    required List<PendingOperationDraft> operations,
    required Future<void> Function() applyProjection,
  }) async {
    if (_pendingOperations.context?.isLocal != true) {
      await _pendingOperations.recordAtomically(
        operations: operations,
        applyProjection: applyProjection,
      );
      return;
    }
    await _pendingOperations.withCareGrant(() async {
      for (final operation in operations) {
        _pendingOperations.requireCareOwner(operation.userId);
      }
      await applyProjection();
      for (final operation in operations) {
        if (operation.entityType == 'pill') {
          await (_db.update(_db.pills)
                ..where((row) => row.id.equals(operation.entityLocalId)))
              .write(const PillsCompanion(syncStatus: Value('local')));
        } else if (operation.entityType == 'schedule') {
          await (_db.update(_db.schedules)
                ..where((row) => row.id.equals(operation.entityLocalId)))
              .write(const SchedulesCompanion(syncStatus: Value('local')));
        }
      }
    });
  }

  // ── create ─────────────────────────────────────────────────────────────────

  /// Maps unexpected failures to [Err] so a user save never throws. Workspace
  /// access failures keep their typed exception for the callers that match it.
  Future<Result<T>> _guard<T>(Future<Result<T>> Function() action) async {
    try {
      return await action();
    } on WorkspaceAccessFailure {
      rethrow;
    } on Object catch (error) {
      AppLogger.warning('PillRepository', 'Save failed: ${error.runtimeType}');
      return Err(UnknownError('Save failed: ${error.runtimeType}'));
    }
  }

  @override
  Future<Result<Pill>> create({
    required String profileId,
    required String name,
    String? dosage,
    String? notes,
    String? color,
    int? currentStock,
    int? lowStockThreshold,
    bool isPrn = false,
    MedicationAmount amount = const MedicationAmount.unknown(),
    String? packageStrength,
    String? form,
    bool legacyDosageReviewed = false,
  }) => _guard(
    () => _create(
      profileId: profileId,
      name: name,
      dosage: dosage,
      notes: notes,
      color: color,
      currentStock: currentStock,
      lowStockThreshold: lowStockThreshold,
      isPrn: isPrn,
      amount: amount,
      packageStrength: packageStrength,
      form: form,
      legacyDosageReviewed: legacyDosageReviewed,
    ),
  );

  Future<Result<Pill>> _create({
    required String profileId,
    required String name,
    String? dosage,
    String? notes,
    String? color,
    int? currentStock,
    int? lowStockThreshold,
    bool isPrn = false,
    MedicationAmount amount = const MedicationAmount.unknown(),
    String? packageStrength,
    String? form,
    bool legacyDosageReviewed = false,
  }) async {
    final profile = await _readProfile(profileId);
    if (profile == null) return const Err(NotFoundError());

    final localId = _uuid.v4();
    final now = DateTime.now();
    final sentinelId = isPrn ? _uuid.v4() : null;

    final companion = PillsCompanion.insert(
      id: localId,
      profileId: profileId,
      name: name,
      dosage: Value(dosage),
      notes: Value(notes),
      color: Value(color),
      currentStock: Value(currentStock),
      lowStockThreshold: Value(lowStockThreshold),
      isPrn: Value(isPrn),
      createdAt: now,
      updatedAt: now,
    );

    final drafts = <PendingOperationDraft>[
      PendingOperationDraft(
        userId: profile.userId,
        operationType: 'pill.create',
        entityType: 'pill',
        entityLocalId: localId,
        parentEntityType: 'profile',
        parentEntityLocalId: profileId,
        payload: {
          'action': 'create',
          'data': {
            'name': name,
            'dosage': dosage,
            'notes': notes,
            'color': color,
            'lowStockThreshold': lowStockThreshold,
            'isPrn': isPrn,
            ...medicationDetailWire(
              amount: amount,
              packageStrength: packageStrength,
              form: form,
              legacyDosageReviewed: legacyDosageReviewed,
            ),
          },
        },
      ),
    ];
    final inventory = currentStock == null
        ? null
        : _inventoryOperation(
            userId: profile.userId,
            pillId: localId,
            action: 'start',
            targetStock: currentStock,
          );
    if (inventory != null) drafts.add(inventory.draft);
    if (sentinelId != null) {
      drafts.add(
        PendingOperationDraft(
          userId: profile.userId,
          operationType: 'schedule.create',
          entityType: 'schedule',
          entityLocalId: sentinelId,
          parentEntityType: 'pill',
          parentEntityLocalId: localId,
          payload: {
            'action': 'create',
            'data': {
              'hour': 0,
              'minute': 0,
              'frequency': 'prn',
              'frequencyDays': null,
              'isActive': true,
              'timeZone': tz.local.name,
            },
          },
        ),
      );
    }

    await _recordCare(
      operations: drafts,
      applyProjection: () async {
        if (await _readProfile(profileId) == null) {
          throw const WorkspaceAccessFailure(
            WorkspaceAccessFailureCode.wrongPerson,
          );
        }
        await _dao.upsert(companion);
        // The detail row belongs to the medicine and is written in the same
        // transaction, so a medicine can never exist without the details its
        // `pill.create` already claims.
        await _db
            .into(_db.medicationDetails)
            .insert(
              MedicationDetailsCompanion.insert(
                pillId: localId,
                packageStrength: Value(packageStrength),
                form: Value(form),
                amountJson: jsonEncode(amount.toJson()),
                legacyDosageReviewed: Value(legacyDosageReviewed),
              ),
            );
        if (inventory != null) {
          await _appendInventoryEvent(
            userId: profile.userId,
            pillId: localId,
            commandId: inventory.commandId,
            oldStock: null,
            newStock: currentStock!,
            recordedAt: now,
          );
        }
        if (sentinelId != null) {
          await _schedulesDao.upsert(
            SchedulesCompanion.insert(
              id: sentinelId,
              pillId: localId,
              hour: 0,
              minute: 0,
              frequency: 'prn',
              createdAt: now,
              updatedAt: now,
            ),
          );
        }
      },
    );
    final local = await _readPill(localId);
    if (local == null) {
      return const Err(UnknownError('Failed to read pill after insert'));
    }

    final updated = await _readPill(localId);
    return Ok(updated ?? local);
  }

  // ── update ─────────────────────────────────────────────────────────────────

  @override
  Future<Result<Pill>> update(
    String localId, {
    required String name,
    String? dosage,
    String? notes,
    String? color,
    int? currentStock,
    int? lowStockThreshold,
    bool isPrn = false,
  }) => _guard(
    () => _update(
      localId,
      name: name,
      dosage: dosage,
      notes: notes,
      color: color,
      currentStock: currentStock,
      lowStockThreshold: lowStockThreshold,
      isPrn: isPrn,
    ),
  );

  Future<Result<Pill>> _update(
    String localId, {
    required String name,
    String? dosage,
    String? notes,
    String? color,
    int? currentStock,
    int? lowStockThreshold,
    bool isPrn = false,
  }) async {
    final existing = await _readPill(localId);
    if (existing == null) return const Err(NotFoundError());

    final parentProfile = await _readProfile(existing.profileId);
    if (parentProfile == null) return const Err(NotFoundError());
    if (existing.currentStock != null && currentStock == null) {
      return const Err(
        UnknownError(
          'Inventory tracking cannot be disabled by this server contract',
        ),
      );
    }

    final companion = PillsCompanion(
      id: Value(localId),
      profileId: Value(existing.profileId),
      name: Value(name),
      dosage: Value(dosage),
      notes: Value(notes),
      color: Value(color),
      currentStock: Value(currentStock),
      lowStockThreshold: Value(lowStockThreshold),
      isPrn: Value(isPrn),
      createdAt: Value(existing.createdAt),
      updatedAt: Value(DateTime.now()),
      serverId: Value(existing.serverId),
      revision: Value(existing.revision),
      syncStatus: const Value('pending'),
      lastSyncAt: Value(existing.lastSyncAt),
      isDeleted: Value(existing.isDeleted),
    );

    // Handle PRN sentinel toggle: create when switching to PRN, remove when
    // switching away. The sentinel exists so dose logs have an FK target.
    final schedulesToDelete = <Schedule>[];
    String? sentinelId;
    if (isPrn && !existing.isPrn) {
      sentinelId = _uuid.v4();
    } else if (!isPrn && existing.isPrn) {
      final schedules = await _readSchedules(localId);
      schedulesToDelete.addAll(schedules.where((s) => s.frequency == 'prn'));
    }

    final drafts = <PendingOperationDraft>[
      PendingOperationDraft(
        userId: parentProfile.userId,
        operationType: 'pill.update',
        entityType: 'pill',
        entityLocalId: localId,
        parentEntityType: 'profile',
        parentEntityLocalId: existing.profileId,
        payload: {
          'action': 'update',
          'data': {
            'name': name,
            'dosage': dosage,
            'notes': notes,
            'color': color,
            'lowStockThreshold': lowStockThreshold,
            'isPrn': isPrn,
          },
        },
      ),
    ];
    final now = DateTime.now();
    final inventory = currentStock == existing.currentStock
        ? null
        : _inventoryOperation(
            userId: parentProfile.userId,
            pillId: localId,
            action: existing.currentStock == null ? 'start' : 'correct',
            targetStock: currentStock!,
            baseRevision: existing.revision,
            intentOrdinal:
                (await _db.medicationLedgerDao.getInventoryEventsForPill(
                  localId,
                )).length,
          );
    if (inventory != null) drafts.add(inventory.draft);
    if (sentinelId != null) {
      drafts.add(
        PendingOperationDraft(
          userId: parentProfile.userId,
          operationType: 'schedule.create',
          entityType: 'schedule',
          entityLocalId: sentinelId,
          parentEntityType: 'pill',
          parentEntityLocalId: localId,
          payload: {
            'action': 'create',
            'data': {
              'hour': 0,
              'minute': 0,
              'frequency': 'prn',
              'frequencyDays': null,
              'isActive': true,
              'timeZone': tz.local.name,
            },
          },
        ),
      );
    }
    for (final schedule in schedulesToDelete) {
      drafts.add(
        PendingOperationDraft(
          userId: parentProfile.userId,
          operationType: 'schedule.delete',
          entityType: 'schedule',
          entityLocalId: schedule.id,
          parentEntityType: 'pill',
          parentEntityLocalId: localId,
          payload: {'action': 'delete', 'data': <String, Object?>{}},
        ),
      );
    }

    await _recordCare(
      operations: drafts,
      applyProjection: () async {
        await _requireUnchangedPill(existing);
        await _dao.update_(companion);
        if (inventory != null) {
          await _appendInventoryEvent(
            userId: parentProfile.userId,
            pillId: localId,
            commandId: inventory.commandId,
            oldStock: existing.currentStock,
            newStock: currentStock!,
            recordedAt: now,
          );
        }
        if (sentinelId != null) {
          await _schedulesDao.upsert(
            SchedulesCompanion.insert(
              id: sentinelId,
              pillId: localId,
              hour: 0,
              minute: 0,
              frequency: 'prn',
              createdAt: now,
              updatedAt: now,
            ),
          );
        }
        for (final schedule in schedulesToDelete) {
          await _schedulesDao.softDelete(schedule.id);
        }
      },
    );

    // Clear the low-stock-fired flag if stock rose above threshold (refill).
    await _effects(
      () => InventoryService(
        _db,
        access: _pendingOperations.access,
        context: _pendingOperations.context,
      ).clearFiredIfAboveThreshold(localId),
    );
    await _effects(_reconcileProjections);

    final result = await _readPill(localId);
    return Ok(result!);
  }

  // ── delete ─────────────────────────────────────────────────────────────────

  @override
  Future<Result<void>> delete(String localId) => _guard(() => _delete(localId));

  Future<Result<void>> _delete(String localId) async {
    final existing = await _readPill(localId);
    if (existing == null) return const Ok(null);

    final profile = await _readProfile(existing.profileId);
    if (profile == null) return const Err(NotFoundError());
    await _recordCare(
      operations: [
        PendingOperationDraft(
          userId: profile.userId,
          operationType: 'pill.delete',
          entityType: 'pill',
          entityLocalId: localId,
          parentEntityType: 'profile',
          parentEntityLocalId: existing.profileId,
          payload: {'action': 'delete', 'data': <String, Object?>{}},
        ),
      ],
      applyProjection: () async {
        await _requireUnchangedPill(existing);
        await _dao.softDelete(localId);
      },
    );

    // The soft-deleted pill no longer appears in getByProfileId, so its
    // schedules will not be re-scheduled. Cancel stale notifications now.
    await _effects(_reconcileProjections);

    return const Ok(null);
  }

  _InventoryOperation? _inventoryOperation({
    required String userId,
    required String pillId,
    required String action,
    required int targetStock,
    int? baseRevision,
    int intentOrdinal = 0,
  }) {
    // intentOrdinal counts the inventory events already recorded for the pill.
    // It makes the id unique per save intent (a stock edit 10 -> 8 -> 10 -> 8
    // made offline must not reuse an id) while a retry of a save that rolled
    // back sees the same ordinal and so keeps the same id.
    final commandId = projectionCommandIdForKey(
      'inventory-command-v1:$pillId:${baseRevision ?? 'new'}:$action:$targetStock:$intentOrdinal',
    );
    final command = <String, Object?>{
      'commandId': commandId,
      'action': action,
      'pillId': pillId,
      if (action == 'start') 'initialStock': targetStock,
      if (action == 'correct') 'targetStock': targetStock,
      'note': null,
    };
    final fingerprint = sha256
        .convert(utf8.encode(jsonEncode(command)))
        .toString();
    return _InventoryOperation(
      commandId: commandId,
      draft: PendingOperationDraft(
        userId: userId,
        mutationId: commandId,
        component: 'medication',
        contractVersion: 2,
        operationType: 'inventory.$action',
        entityType: 'pill',
        entityLocalId: pillId,
        payload: {'inventoryCommand': command},
        effects: [
          PendingOperationEffectDraft(
            kind: 'inventory',
            legacySourceId: pillId,
            requestFingerprint: fingerprint,
          ),
        ],
      ),
    );
  }

  Future<void> _appendInventoryEvent({
    required String userId,
    required String pillId,
    required String commandId,
    required int? oldStock,
    required int newStock,
    required DateTime recordedAt,
  }) => _db.medicationLedgerDao.appendInventoryEvent(
    InventoryEventsCompanion.insert(
      id: _uuid.v4(),
      userId: userId,
      pillId: pillId,
      commandId: commandId,
      kind: oldStock == null ? 'opening' : 'correction',
      delta: oldStock == null ? newStock : newStock - oldStock,
      origin: 'native',
      provenanceJson: Value(
        jsonEncode({'oldStock': oldStock, 'newStock': newStock}),
      ),
      recordedAt: recordedAt.toUtc(),
    ),
  );
}

class _InventoryOperation {
  const _InventoryOperation({required this.commandId, required this.draft});

  final String commandId;
  final PendingOperationDraft draft;
}
