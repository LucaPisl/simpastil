import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/database.dart';
import '../sync/pending_operation_repository.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import '../../features/setup/setup_state.dart';
import 'medication_amount.dart';
import 'medication_detail_wire.dart';

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
      if (!context.isLocal && detailFieldsChanged && !supportedFieldsChanged) {
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
      // Stock reuses the existing pills.current_stock column. It is only
      // written for local workspaces; connected stock goes through the
      // inventory commands of the pill editor.
      if (context.isLocal &&
          currentStock != null &&
          currentStock != current.pill.currentStock) {
        await (database.update(
          database.pills,
        )..where((p) => p.id.equals(current.pill.id))).write(
          PillsCompanion(
            currentStock: Value(currentStock),
            updatedAt: Value(DateTime.now().toUtc()),
            syncStatus: const Value('local'),
          ),
        );
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

    if (!context.isLocal && (supportedFieldsChanged || detailFieldsChanged)) {
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
      sharing:
          !context.isLocal && (supportedFieldsChanged || detailFieldsChanged)
          ? SetupSharingState.pending
          : SetupSharingState.localOnly,
      reviewedDetailsLocalOnly: context.isLocal,
    );
  });
}
