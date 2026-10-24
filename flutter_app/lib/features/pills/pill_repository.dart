import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../core/db/daos/profiles_dao.dart';
import '../../core/db/daos/pills_dao.dart';
import '../../core/db/daos/schedules_dao.dart';
import '../../core/db/database.dart';
import '../../core/inventory/exact_stock.dart';
import '../../core/inventory/pill_stock.dart';
import '../../core/errors/app_error.dart';
import '../../core/inventory/inventory_service.dart';
import '../../core/medication/medication_amount.dart';
import '../../core/medication/medication_detail_wire.dart';
import '../../core/medication/medication_extras.dart';
import '../../core/projections/projection_command_id.dart';
import '../../core/sync/ledger_mode_hint.dart';
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
    ExactStock? stockQuantity,
    String? stockUnit,
    int? lowStockThreshold,
    bool isPrn = false,
    MedicationAmount amount = const MedicationAmount.unknown(),
    String? packageStrength,
    String? form,
    bool legacyDosageReviewed = false,
    String? shape,
    MedicationExtras? extras,
    String? id,
  });

  /// [shape] is the wire name of the picked pill shape; null leaves the stored
  /// pick untouched (there is no way to clear one, only to choose another).
  /// [stockCounted] says the person entered the stock themselves (the recount
  /// dialog, or an edit of the stock field). Only then does an unchanged count
  /// confirm a pending recount; saving other fields leaves the mark.
  Future<Result<Pill>> update(
    String localId, {
    required String name,
    String? dosage,
    String? notes,
    String? color,
    int? currentStock,
    ExactStock? stockQuantity,
    String? stockUnit,
    int? lowStockThreshold,
    bool isPrn = false,
    String? shape,
    MedicationExtras? extras,
    bool stockCounted = false,
  });

  /// Records a refill: [amount] is added to the stock the medicine already
  /// counts. It is a delta, so a dose taken meanwhile on another device is
  /// never overwritten, and it is its own history entry (a refill, not a
  /// correction). It does not settle a pending recount; only a count does.
  /// Fails when stock is not tracked yet, or for a part in a plain count.
  Future<Result<Pill>> refill(String localId, ExactStock amount);

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
    ExactStock? stockQuantity,
    String? stockUnit,
    int? lowStockThreshold,
    bool isPrn = false,
    MedicationAmount amount = const MedicationAmount.unknown(),
    String? packageStrength,
    String? form,
    bool legacyDosageReviewed = false,
    String? shape,
    MedicationExtras? extras,
    String? id,
  }) => _guard(
    () => _create(
      profileId: profileId,
      name: name,
      dosage: dosage,
      notes: notes,
      color: color,
      currentStock: currentStock,
      stockQuantity: stockQuantity,
      stockUnit: stockUnit,
      lowStockThreshold: lowStockThreshold,
      isPrn: isPrn,
      amount: amount,
      packageStrength: packageStrength,
      form: form,
      legacyDosageReviewed: legacyDosageReviewed,
      shape: shape,
      extras: extras,
      id: id,
    ),
  );

  Future<Result<Pill>> _create({
    required String profileId,
    required String name,
    String? dosage,
    String? notes,
    String? color,
    int? currentStock,
    ExactStock? stockQuantity,
    String? stockUnit,
    int? lowStockThreshold,
    bool isPrn = false,
    MedicationAmount amount = const MedicationAmount.unknown(),
    String? packageStrength,
    String? form,
    bool legacyDosageReviewed = false,
    String? shape,
    MedicationExtras? extras,
    String? id,
  }) async {
    // A server without exact stock (1.2.0) knows only whole counts: a part
    // count cannot be saved, and a whole quantity is sent as the plain count.
    final fractional = await LedgerModeHint.readFractionalStock();
    if (!fractional && stockQuantity != null) {
      if (!stockQuantity.isWhole) {
        return const Err(
          UnknownError('Part counts need a server that supports them'),
        );
      }
      currentStock = stockQuantity.floor;
      stockQuantity = null;
      stockUnit = null;
    }
    final profile = await _readProfile(profileId);
    if (profile == null) return const Err(NotFoundError());

    final localId = id ?? _uuid.v4();
    final now = DateTime.now();
    final sentinelId = isPrn ? _uuid.v4() : null;
    final createStock =
        stockQuantity ??
        (currentStock == null ? null : ExactStock.fromInt(currentStock));
    final createUnit = createStock == null ? null : stockUnit;

    final companion = PillsCompanion.insert(
      id: localId,
      profileId: profileId,
      name: name,
      dosage: Value(dosage),
      notes: Value(notes),
      color: Value(color),
      currentStock: Value(createStock?.floor),
      stockQuantity: Value(createUnit == null ? null : createStock!.toWire()),
      stockUnit: Value(createUnit),
      lowStockThreshold: Value(lowStockThreshold),
      isPrn: Value(isPrn),
      shape: Value(shape),
      prnMaxPer24h: Value(extras?.prnMaxPer24h),
      prnMinGapMinutes: Value(extras?.prnMinGapMinutes),
      expiresOn: Value(extras?.expiresOn),
      prescriberName: Value(extras?.prescriberName),
      prescriberPhone: Value(extras?.prescriberPhone),
      pharmacyName: Value(extras?.pharmacyName),
      pharmacyPhone: Value(extras?.pharmacyPhone),
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
            'shape': ?shape,
            if (extras != null) ...extras.toPayload(),
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
    final inventory = createStock == null
        ? null
        : _inventoryOperation(
            userId: profile.userId,
            pillId: localId,
            action: 'start',
            targetStock: createStock,
            unit: createUnit,
            exactAllowed: fractional,
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
            newStock: createStock!,
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
    ExactStock? stockQuantity,
    String? stockUnit,
    int? lowStockThreshold,
    bool isPrn = false,
    String? shape,
    MedicationExtras? extras,
    bool stockCounted = false,
  }) => _guard(
    () => _update(
      localId,
      name: name,
      dosage: dosage,
      notes: notes,
      color: color,
      currentStock: currentStock,
      stockQuantity: stockQuantity,
      stockUnit: stockUnit,
      lowStockThreshold: lowStockThreshold,
      isPrn: isPrn,
      shape: shape,
      extras: extras,
      stockCounted: stockCounted,
    ),
  );

  Future<Result<Pill>> _update(
    String localId, {
    required String name,
    String? dosage,
    String? notes,
    String? color,
    int? currentStock,
    ExactStock? stockQuantity,
    String? stockUnit,
    int? lowStockThreshold,
    bool isPrn = false,
    String? shape,
    MedicationExtras? extras,
    bool stockCounted = false,
  }) async {
    // A server without exact stock (1.2.0) knows only whole counts: a part
    // count cannot be saved, and a whole quantity is sent as the plain count.
    final fractional = await LedgerModeHint.readFractionalStock();
    if (!fractional && stockQuantity != null) {
      if (!stockQuantity.isWhole) {
        return const Err(
          UnknownError('Part counts need a server that supports them'),
        );
      }
      currentStock = stockQuantity.floor;
      stockQuantity = null;
      stockUnit = null;
    }
    final existing = await _readPill(localId);
    if (existing == null) return const Err(NotFoundError());

    final parentProfile = await _readProfile(existing.profileId);
    if (parentProfile == null) return const Err(NotFoundError());
    final existingStock = exactStockOf(existing);
    final updateStock =
        stockQuantity ??
        (currentStock == null ? null : ExactStock.fromInt(currentStock));
    // A whole count typed for a medicine already counted in a unit stays in
    // that unit; a quantity the caller names carries its own unit.
    final updateUnit = updateStock == null
        ? null
        : (stockQuantity != null ? stockUnit : existing.stockUnit);
    if (existingStock != null && updateStock == null) {
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
      currentStock: Value(updateStock?.floor),
      stockQuantity: Value(updateUnit == null ? null : updateStock!.toWire()),
      stockUnit: Value(updateUnit),
      lowStockThreshold: Value(lowStockThreshold),
      isPrn: Value(isPrn),
      shape: Value(shape ?? existing.shape),
      // No extras given means the caller does not edit them: keep what is stored.
      prnMaxPer24h: Value(
        extras == null ? existing.prnMaxPer24h : extras.prnMaxPer24h,
      ),
      prnMinGapMinutes: Value(
        extras == null ? existing.prnMinGapMinutes : extras.prnMinGapMinutes,
      ),
      expiresOn: Value(extras == null ? existing.expiresOn : extras.expiresOn),
      prescriberName: Value(
        extras == null ? existing.prescriberName : extras.prescriberName,
      ),
      prescriberPhone: Value(
        extras == null ? existing.prescriberPhone : extras.prescriberPhone,
      ),
      pharmacyName: Value(
        extras == null ? existing.pharmacyName : extras.pharmacyName,
      ),
      pharmacyPhone: Value(
        extras == null ? existing.pharmacyPhone : extras.pharmacyPhone,
      ),
      // The row is replaced whole: keep the recount mark, which only a count
      // clears (below).
      stockNeedsRecount: Value(existing.stockNeedsRecount),
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
            'shape': ?shape,
            if (extras != null) ...extras.toPayload(),
          },
        },
      ),
    ];
    final now = DateTime.now();
    final countUnchanged =
        updateStock == existingStock && updateUnit == existing.stockUnit;
    // Entering the stock while the count needs a recount is a count, even when
    // the number is the same: the command clears the mark on the server, and
    // so on every device. It adds no ledger event (nothing changed). Saving
    // only other fields is not a count, so the mark stays.
    final confirmsCount =
        stockCounted &&
        countUnchanged &&
        existingStock != null &&
        existing.stockNeedsRecount;
    final inventory = countUnchanged && !confirmsCount
        ? null
        : _inventoryOperation(
            userId: parentProfile.userId,
            pillId: localId,
            action: existingStock == null ? 'start' : 'correct',
            targetStock: updateStock!,
            unit: updateUnit,
            exactAllowed: fractional,
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
        if (inventory != null && existing.stockNeedsRecount) {
          await (_db.update(_db.pills)..where((p) => p.id.equals(localId)))
              .write(const PillsCompanion(stockNeedsRecount: Value(false)));
        }
        if (inventory != null && !confirmsCount) {
          await _appendInventoryEvent(
            userId: parentProfile.userId,
            pillId: localId,
            commandId: inventory.commandId,
            oldStock: existingStock,
            newStock: updateStock!,
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

  // ── refill ─────────────────────────────────────────────────────────────────

  @override
  Future<Result<Pill>> refill(String localId, ExactStock amount) =>
      _guard(() => _refill(localId, amount));

  Future<Result<Pill>> _refill(String localId, ExactStock amount) async {
    if (amount.isNegative ||
        amount.isZero ||
        !amount.inRange ||
        amount.floor > 2147483647) {
      return const Err(UnknownError('A refill must add a positive amount'));
    }
    // A refill is a ledger command. A server known to lack an active ledger
    // (an inactive one, or an older server) cannot take it: refuse before the
    // local stock moves, so the phone never shows stock the server will never
    // receive. The stock editor (an absolute count) still works there. While
    // the server is unknown the refill is queued; a legacy server found later
    // refuses it at send time (`LegacyMedicationSyncAdapter`).
    if (_pendingOperations.context?.isLocal != true &&
        await LedgerModeHint.refillRefused()) {
      return const Err(
        UnknownError('A refill needs a server with the medication ledger'),
      );
    }
    final fractional = await LedgerModeHint.readFractionalStock();
    final existing = await _readPill(localId);
    if (existing == null) return const Err(NotFoundError());
    final parentProfile = await _readProfile(existing.profileId);
    if (parentProfile == null) return const Err(NotFoundError());
    final existingStock = exactStockOf(existing);
    if (existingStock == null) {
      return const Err(UnknownError('Start counting stock before a refill'));
    }
    // A part needs a server that knows exact stock and a count kept in a unit,
    // exactly as the server's own refill check.
    if (!amount.isWhole && (!fractional || existing.stockUnit == null)) {
      return const Err(
        UnknownError('A part needs stock counted in a unit on this server'),
      );
    }
    final newStock = existingStock + amount;
    if (!newStock.inRange) {
      return const Err(UnknownError('The new total is out of range'));
    }
    final inventory = _inventoryOperation(
      userId: parentProfile.userId,
      pillId: localId,
      action: 'refill',
      targetStock: amount,
      exactAllowed: fractional,
      baseRevision: existing.revision,
      intentOrdinal: (await _db.medicationLedgerDao.getInventoryEventsForPill(
        localId,
      )).length,
    )!;
    final now = DateTime.now();
    await _recordCare(
      operations: [inventory.draft],
      applyProjection: () async {
        await _requireUnchangedPill(existing);
        await (_db.update(_db.pills)..where((p) => p.id.equals(localId))).write(
          pillStockColumns(newStock, unit: existing.stockUnit),
        );
        await _appendInventoryEvent(
          userId: parentProfile.userId,
          pillId: localId,
          commandId: inventory.commandId,
          oldStock: existingStock,
          newStock: newStock,
          recordedAt: now,
          kind: 'refill',
        );
      },
    );
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
    required ExactStock targetStock,
    String? unit,
    int? baseRevision,
    int intentOrdinal = 0,
    bool exactAllowed = true,
  }) {
    // intentOrdinal counts the inventory events already recorded for the pill.
    // It makes the id unique per save intent (a stock edit 10 -> 8 -> 10 -> 8
    // made offline must not reuse an id) while a retry of a save that rolled
    // back sees the same ordinal and so keeps the same id.
    // A plain count keeps the integer fields and the exact id it always had,
    // so a legacy command is byte-identical; a unit or a fraction sends the
    // exact quantity and its unit instead.
    // A refill's [targetStock] is the amount added: it has no unit field (the
    // server keeps the pill's own), and only a part sends the exact field.
    final exact =
        exactAllowed &&
        (action == 'refill'
            ? !targetStock.isWhole
            : (unit != null || !targetStock.isWhole));
    final commandId = projectionCommandIdForKey(
      'inventory-command-v1:$pillId:${baseRevision ?? 'new'}:$action:'
      '${exact ? '${targetStock.toWire()}:${unit ?? ''}' : targetStock.floor}:'
      '$intentOrdinal',
    );
    final command = <String, Object?>{
      'commandId': commandId,
      'action': action,
      'pillId': pillId,
      if (action == 'start')
        if (exact) ...{
          'initialQuantity': targetStock.toWire(),
          'stockUnit': ?unit,
        } else
          'initialStock': targetStock.floor,
      if (action == 'refill')
        if (exact)
          'refillQuantity': targetStock.toWire()
        else
          'amount': targetStock.floor,
      if (action == 'correct')
        if (exact) ...{
          'targetQuantity': targetStock.toWire(),
          'stockUnit': ?unit,
        } else
          'targetStock': targetStock.floor,
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
    required ExactStock? oldStock,
    required ExactStock newStock,
    required DateTime recordedAt,
    String? kind,
  }) => _db.medicationLedgerDao.appendInventoryEvent(
    InventoryEventsCompanion.insert(
      id: _uuid.v4(),
      userId: userId,
      pillId: pillId,
      commandId: commandId,
      kind: kind ?? (oldStock == null ? 'opening' : 'correction'),
      delta: (oldStock == null ? newStock : newStock - oldStock).toWire(),
      origin: 'native',
      provenanceJson: Value(
        jsonEncode({
          'oldStock': oldStock?.toWire(),
          'newStock': newStock.toWire(),
        }),
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
