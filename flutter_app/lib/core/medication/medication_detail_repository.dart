import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/database.dart';
import '../inventory/stock_reading.dart';
import '../sync/pending_operation_repository.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import '../../features/setup/setup_state.dart';
import 'medication_amount.dart';
import 'medication_extras.dart';
import 'medication_detail_wire.dart';
import 'reviewed_stock.dart';

class MedicationDetailConflict implements Exception {
  const MedicationDetailConflict();
}

/// A protected, immutable medication preimage for display and explicit review.
class MedicationCareDetail {
  MedicationCareDetail._({
    required MedicationDetailRepository origin,
    required this.pill,
    required this.person,
    required MedicationDetail? metadata,
    required this.review,
    required List<LocalRoutine> routineVersions,
    required List<Schedule> schedules,
    required this.stockBalance,
    this.stockNeedsRecount = false,
  }) : _origin = origin,
       _metadata = metadata,
       routineVersions = List.unmodifiable(routineVersions),
       schedules = List.unmodifiable(schedules);

  final MedicationDetailRepository _origin;
  final MedicationDetail? _metadata;
  final Pill pill;
  final Profile person;
  final MedicationReview review;
  final List<LocalRoutine> routineVersions;
  final List<Schedule> schedules;

  /// The reviewed physical balance in this workspace, if one was started.
  final ReviewedStockBalance? stockBalance;

  /// Whether a connected count is only a last known count (see
  /// [stockNeedsRecount]).
  final bool stockNeedsRecount;

  /// The stock every screen shows: see [readStock].
  StockReading? get stock => readStock(
    pill,
    stockBalance,
    amountPerUse: amountOfDetailRow(_metadata),
    needsRecount: stockNeedsRecount,
  );
}

class MedicationDetailSave {
  const MedicationDetailSave({
    required this.detail,
    required this.sharing,
    required this.reviewedDetailsLocalOnly,
  });
  final MedicationCareDetail detail;
  final SetupSharingState sharing;

  /// True when the reviewed details were written to this device alone. A
  /// connected workspace now hands them to the account with the medicine, so
  /// whether a particular server stores them yet is reported by sync rather
  /// than here.
  final bool reviewedDetailsLocalOnly;
}

/// Captures one workspace grant. Reviewed amounts never imply stock conversion,
/// and additive metadata never enters an unsupported connected wire format.
class MedicationDetailRepository {
  const MedicationDetailRepository({
    required this.database,
    required this.access,
    required this.context,
  });
  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final WorkspaceContext context;

  /// Saves a counted stock in a local workspace. The count goes to the
  /// pills.current_stock column, and, when the medication has a unit, to the
  /// reviewed balance that recording lowers, so a taken dose moves the same
  /// number every screen reads. A count in the balance's own unit keeps its
  /// review, so undoing a dose taken before the count still puts it back; a
  /// new balance or a new unit starts a new review, and undo then leaves the
  /// count alone rather than guess.
  Future<void> _saveLocalStock(
    MedicationCareDetail current,
    int count,
    MedicationAmount amount,
  ) => database.transaction(() async {
    final pillId = current.pill.id;
    final now = DateTime.now().toUtc();
    if (count != current.pill.currentStock) {
      await (database.update(
        database.pills,
      )..where((p) => p.id.equals(pillId))).write(
        PillsCompanion(
          currentStock: Value(count),
          updatedAt: Value(now),
          syncStatus: const Value('local'),
        ),
      );
    }
    final row =
        await (database.select(database.reviewedStockBalances)..where(
              (b) =>
                  b.workspaceId.equals(context.workspaceId) &
                  b.pillId.equals(pillId),
            ))
            .getSingleOrNull();
    StockQuantity? before;
    if (row != null) {
      try {
        before = StockQuantity.fromJson(
          Map<String, dynamic>.from(jsonDecode(row.quantityJson) as Map),
        );
      } on Object {
        before = null;
      }
    }
    // Without a unit of its own the medication keeps the balance it has, in
    // that unit; with neither there is nothing for a dose to lower.
    final unit = amount.isUnknown ? before?.unit : amount.unit;
    if (unit == null) return;
    final after = StockQuantity(BigInt.from(count), BigInt.one, unit);
    if (before != null &&
        before.unit == unit &&
        before.numerator == after.numerator &&
        before.denominator == after.denominator) {
      return;
    }
    final quantityJson = jsonEncode(after.toJson());
    if (row != null && before?.unit == unit) {
      await (database.update(database.reviewedStockBalances)..where(
            (b) =>
                b.workspaceId.equals(context.workspaceId) &
                b.pillId.equals(pillId),
          ))
          .write(
            ReviewedStockBalancesCompanion(
              quantityJson: Value(quantityJson),
              authorId: Value(context.authorId),
              revision: Value(row.revision + 1),
              updatedAt: Value(now),
            ),
          );
      return;
    }
    await database
        .into(database.reviewedStockBalances)
        .insertOnConflictUpdate(
          ReviewedStockBalancesCompanion.insert(
            workspaceId: context.workspaceId,
            pillId: pillId,
            authorId: context.authorId,
            quantityJson: quantityJson,
            reviewRevision: (row?.reviewRevision ?? 0) + 1,
            revision: (row?.revision ?? 0) + 1,
            updatedAt: now,
          ),
        );
  });

  Future<MedicationCareDetail> _load(String pillId) async {
    final pill = await database.pillsDao.getById(pillId);
    if (pill == null || pill.isDeleted) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    await access.requireCurrent(context, profileId: pill.profileId);
    final person = (await database.profilesDao.getById(pill.profileId))!;
    final metadata = await (database.select(
      database.medicationDetails,
    )..where((r) => r.pillId.equals(pillId))).getSingleOrNull();
    final routines = context.isLocal
        ? await (database.select(database.localRoutines)
                ..where(
                  (r) =>
                      r.pillId.equals(pillId) &
                      r.workspaceId.equals(context.workspaceId),
                )
                ..orderBy([
                  (r) => OrderingTerm.asc(r.routineId),
                  (r) => OrderingTerm.asc(r.revision),
                ]))
              .get()
        : <LocalRoutine>[];
    return MedicationCareDetail._(
      origin: this,
      pill: pill,
      person: person,
      metadata: metadata,
      review: MedicationReview(
        name: pill.name,
        notes: pill.notes,
        originalDosage: pill.dosage,
        packageStrength: metadata?.packageStrength,
        form: metadata?.form,
        legacyDosageReviewed: metadata?.legacyDosageReviewed ?? false,
        amount: metadata == null
            ? const MedicationAmount.unknown()
            : MedicationAmount.fromJson(
                Map<String, Object?>.from(
                  jsonDecode(metadata.amountJson) as Map,
                ),
              ),
      ),
      routineVersions: routines,
      schedules: await database.schedulesDao.getByPillId(pillId),
      stockBalance:
          await (database.select(database.reviewedStockBalances)..where(
                (b) =>
                    b.workspaceId.equals(context.workspaceId) &
                    b.pillId.equals(pillId),
              ))
              .getSingleOrNull(),
      stockNeedsRecount: !context.isLocal && pill.stockNeedsRecount,
    );
  }

  Future<MedicationCareDetail> load(String pillId) =>
      access.withGrant(context, () => _load(pillId));

  Set<TableInfo> get _watchedTables => {
    database.pills,
    database.profiles,
    database.medicationDetails,
    database.localRoutines,
    database.schedules,
    database.reviewedStockBalances,
    database.careEventDetails,
    database.inventoryEvents,
    database.workspaceGrants,
    database.careWorkspaces,
    database.workspaceDeviceStates,
    database.workspaceAuthors,
  };

  Stream<void> _changes() => database
      .customSelect(
        'SELECT workspace_id FROM workspace_grants WHERE workspace_id=?',
        variables: [Variable(context.workspaceId)],
        readsFrom: _watchedTables,
      )
      .watch()
      .map((_) {});

  /// Re-read inside the captured grant after every relevant table invalidation.
  /// Emitting query rows first would allow stale care to escape after revocation.
  Stream<MedicationCareDetail> watch(String pillId) =>
      _changes().asyncMap((_) => load(pillId));

  Stream<Map<String, List<LocalRoutine>>> watchRoutineVersions() =>
      _changes().asyncMap(
        (_) => access.withGrant(context, () async {
          if (!context.isLocal) return const <String, List<LocalRoutine>>{};
          final query =
              database.select(database.localRoutines).join([
                  innerJoin(
                    database.pills,
                    database.pills.id.equalsExp(database.localRoutines.pillId),
                  ),
                  innerJoin(
                    database.profiles,
                    database.profiles.id.equalsExp(database.pills.profileId),
                  ),
                ])
                ..where(
                  database.localRoutines.workspaceId.equals(
                        context.workspaceId,
                      ) &
                      database.profiles.userId.equals(context.ownerUserId) &
                      database.profiles.isDeleted.equals(false) &
                      database.pills.isDeleted.equals(false),
                )
                ..orderBy([
                  OrderingTerm.asc(database.localRoutines.routineId),
                  OrderingTerm.asc(database.localRoutines.revision),
                ]);
          final grouped = <String, List<LocalRoutine>>{};
          for (final row in await query.get()) {
            final version = row.readTable(database.localRoutines);
            (grouped[version.pillId] ??= []).add(version);
          }
          return Map.unmodifiable({
            for (final entry in grouped.entries)
              entry.key: List<LocalRoutine>.unmodifiable(entry.value),
          });
        }),
      );

  Stream<List<MedicationCareDetail>> watchList() => _changes().asyncMap(
    (_) => access.withGrant(context, () async {
      final workspace = (await access.workspaces.byId(context.workspaceId))!;
      if (!workspace.viewEveryone && workspace.selectedProfileId == null) {
        return const <MedicationCareDetail>[];
      }
      final query =
          database.select(database.pills).join([
            innerJoin(
              database.profiles,
              database.profiles.id.equalsExp(database.pills.profileId),
            ),
          ])..where(
            database.profiles.userId.equals(context.ownerUserId) &
                database.profiles.isDeleted.equals(false) &
                database.pills.isDeleted.equals(false),
          );
      if (!workspace.viewEveryone) {
        await access.requireCurrent(
          context,
          profileId: workspace.selectedProfileId!,
        );
        query.where(database.profiles.id.equals(workspace.selectedProfileId!));
      }
      query.orderBy([
        OrderingTerm.asc(database.pills.name),
        OrderingTerm.asc(database.pills.id),
      ]);
      return List<MedicationCareDetail>.unmodifiable([
        for (final row in await query.get())
          await _load(row.readTable(database.pills).id),
      ]);
    }),
  );

  Future<MedicationDetailSave> updateReviewed({
    required MedicationCareDetail expected,
    required MedicationReview review,
    int? currentStock,
    String? color,
    String? shape,

    /// The limits, expiry and contacts; null leaves the stored ones alone.
    MedicationExtras? extras,
  }) => access.withGrant(context, () async {
    if (!identical(expected._origin, this)) {
      throw const MedicationDetailConflict();
    }
    review.validateForSave();
    // Legacy free text remains evidence; strength and amount cannot overwrite it.
    if (review.originalDosage != expected.pill.dosage) {
      throw const FormatException('Preserve the original dosage text');
    }
    final current = await _load(expected.pill.id);
    if (current.pill != expected.pill ||
        current.person != expected.person ||
        current._metadata != expected._metadata) {
      throw const MedicationDetailConflict();
    }
    final name = review.name.trim();
    final amountJson = jsonEncode(review.amount.toJson());
    final supportedFieldsChanged =
        name != current.pill.name || review.notes != current.pill.notes;
    // The reviewed details live in their own table but belong to the medicine,
    // so a review that only touches them still has to reach the account.
    final extrasChanged =
        extras != null && extras != MedicationExtras.fromPill(current.pill);
    final metadata = current._metadata;
    final detailFieldsChanged =
        review.packageStrength != metadata?.packageStrength ||
        review.form != metadata?.form ||
        amountJson != metadata?.amountJson ||
        review.legacyDosageReviewed !=
            (metadata?.legacyDosageReviewed ?? false);
    Future<void> apply() async {
      // A review of nothing but the details still leaves the medicine unsent,
      // and the mark is what stops a pull from overwriting it in the meantime.
      if (!context.isLocal &&
          (detailFieldsChanged || extrasChanged) &&
          !supportedFieldsChanged) {
        await (database.update(database.pills)
              ..where((p) => p.id.equals(current.pill.id)))
            .write(const PillsCompanion(syncStatus: Value('pending')));
      }
      if (supportedFieldsChanged) {
        await (database.update(
          database.pills,
        )..where((p) => p.id.equals(current.pill.id))).write(
          PillsCompanion(
            name: Value(name),
            notes: Value(review.notes),
            updatedAt: Value(DateTime.now().toUtc()),
            syncStatus: Value(context.isLocal ? 'local' : 'pending'),
          ),
        );
      }
      if (extrasChanged) {
        await (database.update(
          database.pills,
        )..where((p) => p.id.equals(current.pill.id))).write(
          PillsCompanion(
            prnMaxPer24h: Value(extras.prnMaxPer24h),
            prnMinGapMinutes: Value(extras.prnMinGapMinutes),
            expiresOn: Value(extras.expiresOn),
            prescriberName: Value(extras.prescriberName),
            prescriberPhone: Value(extras.prescriberPhone),
            pharmacyName: Value(extras.pharmacyName),
            pharmacyPhone: Value(extras.pharmacyPhone),
            updatedAt: Value(DateTime.now().toUtc()),
            syncStatus: Value(context.isLocal ? 'local' : 'pending'),
          ),
        );
      }
      // Stock is only written for local workspaces; connected stock goes
      // through the inventory commands of the pill editor.
      if (context.isLocal && currentStock != null) {
        await _saveLocalStock(current, currentStock, review.amount);
      }
      // The identity colour reuses the existing pills.color column, local
      // workspaces only, like stock above.
      if (context.isLocal && color != null && color != current.pill.color) {
        await (database.update(
          database.pills,
        )..where((p) => p.id.equals(current.pill.id))).write(
          PillsCompanion(
            color: Value(color),
            updatedAt: Value(DateTime.now().toUtc()),
            syncStatus: const Value('local'),
          ),
        );
      }
      // The picked silhouette is local only, like the colour.
      if (context.isLocal && shape != null && shape != current.pill.shape) {
        await (database.update(
          database.pills,
        )..where((p) => p.id.equals(current.pill.id))).write(
          PillsCompanion(
            shape: Value(shape),
            updatedAt: Value(DateTime.now().toUtc()),
            syncStatus: const Value('local'),
          ),
        );
      }
      await database
          .into(database.medicationDetails)
          .insertOnConflictUpdate(
            MedicationDetailsCompanion.insert(
              pillId: current.pill.id,
              packageStrength: Value(review.packageStrength),
              form: Value(review.form),
              amountJson: amountJson,
              legacyDosageReviewed: Value(review.legacyDosageReviewed),
            ),
          );
    }

    final sharedChange =
        supportedFieldsChanged || detailFieldsChanged || extrasChanged;
    if (!context.isLocal && sharedChange) {
      await PendingOperationRepository(
        database,
        access: access,
        context: context,
      ).recordAtomically(
        operations: [
          PendingOperationDraft(
            userId: context.ownerUserId,
            operationType: 'pill.update',
            entityType: 'pill',
            entityLocalId: current.pill.id,
            parentEntityType: 'profile',
            parentEntityLocalId: current.person.id,
            payload: {
              'action': 'update',
              'data': {
                'name': name,
                'dosage': current.pill.dosage,
                'notes': review.notes,
                'color': current.pill.color,
                'lowStockThreshold': current.pill.lowStockThreshold,
                'isPrn': current.pill.isPrn,
                if (extrasChanged) ...extras.toPayload(),
                ...medicationDetailWire(
                  amount: review.amount,
                  packageStrength: review.packageStrength,
                  form: review.form,
                  legacyDosageReviewed: review.legacyDosageReviewed,
                ),
              },
            },
          ),
        ],
        applyProjection: apply,
      );
    } else {
      await apply();
    }
    return MedicationDetailSave(
      detail: await _load(current.pill.id),
      sharing: !context.isLocal && sharedChange
          ? SetupSharingState.pending
          : SetupSharingState.localOnly,
      reviewedDetailsLocalOnly: context.isLocal,
    );
  });
}
