import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/db/database.dart';
import '../../core/errors/app_error.dart';
import '../../core/medication/medication_amount.dart';
import '../../core/sync/pending_operation_repository.dart';
import '../../core/workspace/workspace_access_repository.dart';
import '../../core/workspace/workspace_context.dart';
import '../pills/pill_repository.dart';
import '../profiles/profile_repository.dart';
import 'setup_state.dart';

/// Captured workspace commands. No platform work runs inside a care transaction.
class SetupRepository {
  SetupRepository({
    required this.database,
    required this.access,
    required this.context,
    this.afterCareSave,
  });
  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final WorkspaceContext context;
  final Future<void> Function()? afterCareSave;

  PendingOperationRepository get _pending =>
      PendingOperationRepository(database, access: access, context: context);

  SetupDraftData _data(SetupDraft row) => SetupDraftData(
    id: row.id,
    workspaceId: row.workspaceId,
    authorId: row.authorId,
    purpose: SetupPurpose.values.byName(row.purpose),
    step: SetupStep.values.byName(row.step),
    revision: row.revision,
    review: SetupReview.decode(row.payloadJson),
    personId: row.profileId,
    medicationId: row.medicationId,
  );

  Future<SetupDraft> _read(String id) async {
    final row = await (database.select(
      database.setupDrafts,
    )..where((r) => r.id.equals(id))).getSingleOrNull();
    if (row == null ||
        row.workspaceId != context.workspaceId ||
        row.authorId != context.authorId) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.unavailable,
      );
    }
    if (row.profileId != null) {
      await access.workspaces.requirePerson(
        context.ownerUserId,
        row.profileId!,
      );
    }
    if (row.medicationId != null) {
      final pill = await database.pillsDao.getById(row.medicationId!);
      if (pill == null || pill.isDeleted || pill.profileId != row.profileId) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.wrongPerson,
        );
      }
    }
    return row;
  }

  Future<SetupDraftData> resume(String id) =>
      access.withGrant(context, () async => _data(await _read(id)));

  /// Router readiness must not create or advance a setup draft.
  Future<SetupDraftData?> findUnfinishedDraft({
    SetupPurpose purpose = SetupPurpose.onboarding,
    String? fixedPersonId,
  }) => access.withGrant(context, () async {
    if (fixedPersonId != null) {
      await access.requireCurrent(context, profileId: fixedPersonId);
    }
    final rows =
        await (database.select(database.setupDrafts)
              ..where(
                (r) =>
                    r.workspaceId.equals(context.workspaceId) &
                    r.authorId.equals(context.authorId) &
                    r.purpose.equals(purpose.name) &
                    r.step.isNotValue(SetupStep.complete.name) &
                    // First-run onboarding parked at its start step holds
                    // nothing the person entered: it is the welcome, not an
                    // unfinished setup (Back from the first step lands here).
                    (purpose == SetupPurpose.onboarding
                        ? r.step.isNotValue(SetupStep.start.name)
                        : const Constant(true)) &
                    (fixedPersonId == null
                        ? const Constant(true)
                        : r.profileId.equals(fixedPersonId)),
              )
              ..orderBy([(r) => OrderingTerm.desc(r.updatedAt)]))
            .get();
    return rows.isEmpty ? null : _data(await _read(rows.first.id));
  });

  Future<SetupDraftData> resumeOrCreateDraft({
    String? fixedPersonId,
    SetupPurpose purpose = SetupPurpose.onboarding,
  }) => access.withGrant(context, () async {
    Profile? person;
    if (fixedPersonId != null) {
      await access.workspaces.requirePerson(context.ownerUserId, fixedPersonId);
      person = await database.profilesDao.getById(fixedPersonId);
    }
    if (purpose == SetupPurpose.medication && person == null) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    final existing =
        await (database.select(database.setupDrafts)
              ..where(
                (r) =>
                    r.workspaceId.equals(context.workspaceId) &
                    r.purpose.equals(purpose.name) &
                    (purpose == SetupPurpose.onboarding
                        ? const Constant(true)
                        : r.step.isNotValue(SetupStep.complete.name)) &
                    (fixedPersonId == null
                        ? const Constant(true)
                        : r.profileId.equals(fixedPersonId)),
              )
              ..orderBy([(r) => OrderingTerm.desc(r.updatedAt)]))
            .get();
    // Onboarding has one stable identity, including after a person was saved.
    final onboardingId = 'setup:${context.workspaceId}';
    final id = purpose == SetupPurpose.onboarding
        ? onboardingId
        : existing.firstOrNull?.id;
    final existingDraft = id == null
        ? null
        : await (database.select(
            database.setupDrafts,
          )..where((r) => r.id.equals(id))).getSingleOrNull();
    if (id != null && existingDraft != null) {
      final deletedParent = existingDraft.profileId == null
          ? null
          : await database.profilesDao.getById(existingDraft.profileId!);
      if (purpose == SetupPurpose.onboarding &&
          existingDraft.step == SetupStep.complete.name &&
          deletedParent?.isDeleted == true &&
          deletedParent?.userId == context.ownerUserId) {
        final updated =
            await (database.update(database.setupDrafts)..where(
                  (r) =>
                      r.id.equals(id) &
                      r.revision.equals(existingDraft.revision) &
                      r.step.equals(SetupStep.complete.name) &
                      r.profileId.equals(existingDraft.profileId!),
                ))
                .write(
                  SetupDraftsCompanion(
                    step: Value(SetupStep.start.name),
                    profileId: const Value(null),
                    medicationId: const Value(null),
                    payloadJson: Value(const SetupReview().encode()),
                    revision: Value(existingDraft.revision + 1),
                    updatedAt: Value(DateTime.now().toUtc()),
                  ),
                );
        if (updated != 1) throw const SetupConflict();
      }
      final row = await _read(id);
      if (fixedPersonId != null && row.profileId != fixedPersonId) {
        throw const SetupConflict();
      }
      return _data(row);
    }
    final newId = id ?? const Uuid().v4();
    await database
        .into(database.setupDrafts)
        .insert(
          SetupDraftsCompanion.insert(
            id: newId,
            workspaceId: context.workspaceId,
            authorId: context.authorId,
            purpose: purpose.name,
            step:
                (person != null
                        ? SetupStep.medication
                        : purpose == SetupPurpose.onboarding
                        ? SetupStep.start
                        : SetupStep.person)
                    .name,
            profileId: Value(fixedPersonId),
            payloadJson: SetupReview(
              personName: person?.name ?? '',
              avatar: person?.avatarEmoji ?? '🙂',
            ).encode(),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
    return _data(await _read(newId));
  });

  void _revision(SetupDraft row, int expected) {
    if (row.revision != expected) throw const SetupConflict();
  }

  Future<SetupDraftData> _update(
    SetupDraft row, {
    SetupReview? review,
    SetupStep? step,
    String? personId,
    String? medicationId,
  }) async {
    await (database.update(
      database.setupDrafts,
    )..where((r) => r.id.equals(row.id))).write(
      SetupDraftsCompanion(
        payloadJson: review == null
            ? const Value.absent()
            : Value(review.encode()),
        step: step == null ? const Value.absent() : Value(step.name),
        profileId: personId == null ? const Value.absent() : Value(personId),
        medicationId: medicationId == null
            ? const Value.absent()
            : Value(medicationId),
        revision: Value(row.revision + 1),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    return _data(await _read(row.id));
  }

  Future<SetupDraftData> saveDraft(
    String draftId,
    int expectedRevision,
    SetupReview review,
  ) => access.withGrant(context, () async {
    final row = await _read(draftId);
    _revision(row, expectedRevision);
    final prior = SetupReview.decode(row.payloadJson);
    if (row.medicationId != null &&
        jsonEncode(prior.medication.toJson()) !=
            jsonEncode(review.medication.toJson())) {
      throw const SetupConflict();
    }
    if (row.profileId != null &&
        (prior.personName != review.personName ||
            prior.avatar != review.avatar)) {
      throw const SetupConflict();
    }
    if (!['myself', 'someoneElse', 'both'].contains(review.audience) ||
        review.encode().length > 65536 ||
        (review.routine == null) != (review.routineEffectiveFrom == null)) {
      throw const FormatException('Invalid setup review');
    }
    return _update(row, review: review);
  });

  Future<SetupSave> _result(SetupDraftData draft, String id) async {
    var effects = SetupEffectState.notRequested;
    if (afterCareSave != null) {
      try {
        await access.requireCurrent(context);
        await afterCareSave!();
        effects = SetupEffectState.ready;
      } on Object {
        effects = SetupEffectState.unavailable;
      }
    }
    return SetupSave(
      savedId: id,
      draft: draft,
      sharing: context.isLocal
          ? SetupSharingState.localOnly
          : SetupSharingState.pending,
      effects: effects,
    );
  }

  Future<SetupSave> savePerson(
    String draftId,
    int expectedRevision, {
    required String name,
    required String avatar,
  }) async {
    final draft = await access.withGrant(context, () async {
      final row = await _read(draftId);
      final review = SetupReview.decode(row.payloadJson);
      if (row.profileId != null) {
        if (name.trim() != review.personName || avatar != review.avatar) {
          throw const SetupConflict();
        }
        return _data(row);
      }
      _revision(row, expectedRevision);
      if (name.trim().isEmpty) {
        throw const FormatException('Person name is required');
      }
      final repository = ProfileRepositoryImpl(
        dao: database.profilesDao,
        pendingOperations: _pending,
        userId: context.ownerUserId,
        access: access,
        context: context,
        reconcileProjections: () async {},
      );
      final saved = await repository.create(name.trim(), avatar);
      if (saved case Err<Profile>(:final error)) throw error;
      final person = (saved as Ok<Profile>).value;
      return _update(
        row,
        personId: person.id,
        step: SetupStep.medication,
        review: SetupReview(
          personName: person.name,
          avatar: avatar,
          audience: review.audience,
          medication: review.medication,
          routine: review.routine,
          routineEffectiveFrom: review.routineEffectiveFrom,
        ),
      );
    });
    return _result(draft, draft.personId!);
  }

  Future<SetupSave> saveMedication(
    String draftId,
    int expectedRevision,
    MedicationReview review,
  ) async {
    final draft = await access.withGrant(context, () async {
      final row = await _read(draftId);
      final prior = SetupReview.decode(row.payloadJson);
      if (row.medicationId != null) {
        if (jsonEncode(prior.medication.toJson()) !=
            jsonEncode(review.toJson())) {
          throw const SetupConflict();
        }
        return _data(row);
      }
      _revision(row, expectedRevision);
      if (row.profileId == null) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.wrongPerson,
        );
      }
      review.validateForSave();
      final repository = PillRepositoryImpl(
        db: database,
        dao: database.pillsDao,
        profilesDao: database.profilesDao,
        schedulesDao: database.schedulesDao,
        pendingOperations: _pending,
        reconcileProjections: () async {},
      );
      // Medication first: PRN, stock and routines are deliberately separate saves.
      final saved = await repository.create(
        profileId: row.profileId!,
        name: review.name.trim(),
        dosage: review.originalDosage,
        notes: review.notes,
        amount: review.amount,
        packageStrength: review.packageStrength,
        form: review.form,
        shape: review.shape,
        legacyDosageReviewed: review.legacyDosageReviewed,
      );
      if (saved case Err<Pill>(:final error)) throw error;
      final pill = (saved as Ok<Pill>).value;
      return _update(
        row,
        medicationId: pill.id,
        step: SetupStep.routine,
        review: SetupReview(
          personName: prior.personName,
          avatar: prior.avatar,
          audience: prior.audience,
          medication: review,
          routine: prior.routine,
          routineEffectiveFrom: prior.routineEffectiveFrom,
        ),
      );
    });
    return _result(draft, draft.medicationId!);
  }

  Future<MedicationReview> medicationReview(
    String pillId,
  ) => access.withGrant(context, () async {
    final pill = await database.pillsDao.getById(pillId);
    if (pill == null || pill.isDeleted) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    await access.workspaces.requirePerson(context.ownerUserId, pill.profileId);
    final details = await (database.select(
      database.medicationDetails,
    )..where((r) => r.pillId.equals(pillId))).getSingleOrNull();
    return MedicationReview(
      name: pill.name,
      notes: pill.notes,
      originalDosage: pill.dosage,
      packageStrength: details?.packageStrength,
      form: details?.form,
      legacyDosageReviewed: details?.legacyDosageReviewed ?? false,
      amount: details == null
          ? const MedicationAmount.unknown()
          : MedicationAmount.fromJson(
              Map<String, Object?>.from(jsonDecode(details.amountJson) as Map),
            ),
    );
  });

  Future<SetupDraftData> advanceOrSkip(
    String draftId,
    int expectedRevision,
    SetupStep next,
  ) => access.withGrant(context, () async {
    final row = await _read(draftId);
    _revision(row, expectedRevision);
    final current = SetupStep.values.byName(row.step);
    if (current == SetupStep.complete) throw const SetupConflict();
    final backwards = next.index < current.index;
    final sequential = next.index == current.index + 1;
    final deferredReminders =
        current == SetupStep.routine && next == SetupStep.ready;
    final personOnlyCompletion =
        row.purpose == SetupPurpose.person.name &&
        row.profileId != null &&
        next == SetupStep.complete;
    if (!backwards &&
        !sequential &&
        !deferredReminders &&
        !personOnlyCompletion) {
      throw const SetupConflict();
    }
    if (next.index >= SetupStep.medication.index && row.profileId == null) {
      throw const SetupConflict();
    }
    if (next.index >= SetupStep.routine.index &&
        row.medicationId == null &&
        !personOnlyCompletion) {
      throw const SetupConflict();
    }
    return _update(row, step: next);
  });
}
