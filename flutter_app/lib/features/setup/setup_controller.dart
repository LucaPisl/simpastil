import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/workspace/workspace_context.dart';
import '../../core/workspace/workspace_provider.dart';
import 'setup_repository.dart';
import 'setup_state.dart';

final setupRepositoryProvider = FutureProvider<SetupRepository>((ref) async {
  final contextFuture = ref.watch(workspaceContextProvider.future);
  final database = ref.watch(databaseProvider);
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final context = await contextFuture;
  await access.requireCurrent(context);
  return SetupRepository(database: database, access: access, context: context);
});

class SetupRequest {
  const SetupRequest({
    this.purpose = SetupPurpose.onboarding,
    this.fixedPersonId,
  });
  final SetupPurpose purpose;
  final String? fixedPersonId;
  @override
  bool operator ==(Object other) =>
      other is SetupRequest &&
      other.purpose == purpose &&
      other.fixedPersonId == fixedPersonId;
  @override
  int get hashCode => Object.hash(purpose, fixedPersonId);
}

final setupControllerProvider = AsyncNotifierProvider.autoDispose
    .family<SetupController, SetupDraftData, SetupRequest>(SetupController.new);

final unfinishedSetupDraftProvider = FutureProvider<SetupDraftData?>((
  ref,
) async {
  final repository = await ref.watch(setupRepositoryProvider.future);
  return repository.findUnfinishedDraft();
});

/// Setup availability is explicit; failed optional work leaves durable care ready.
class SetupController extends AsyncNotifier<SetupDraftData> {
  SetupController(this._request);

  final SetupRequest _request;
  int _commandEpoch = 0;
  @override
  Future<SetupDraftData> build() async {
    final request = _request;
    final repository = await ref.watch(setupRepositoryProvider.future);
    return repository.resumeOrCreateDraft(
      purpose: request.purpose,
      fixedPersonId: request.fixedPersonId,
    );
  }

  Future<T> _invoke<T>(
    Future<T> Function(SetupRepository, SetupDraftData) command,
    SetupDraftData Function(T) updatedDraft,
  ) async {
    final container = ref.container;
    final epoch = ++_commandEpoch;
    final repositoryState = ref.read(setupRepositoryProvider);
    if (repositoryState.hasError ||
        repositoryState.isLoading ||
        repositoryState.asData == null ||
        state.hasError ||
        state.isLoading ||
        state.asData == null) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.unavailable,
      );
    }
    final repository = repositoryState.asData!.value;
    final prior = state.asData!.value;
    final result = await command(repository, prior);
    try {
      final available = container.read(setupRepositoryProvider);
      if (epoch == _commandEpoch &&
          identical(
            container.read(setupControllerProvider(_request).notifier),
            this,
          ) &&
          !available.hasError &&
          !available.isLoading &&
          identical(available.asData?.value, repository)) {
        state = AsyncData(updatedDraft(result));
      }
    } on StateError {
      // Durable save may complete after this view is disposed. The next view
      // resumes protected state; it cannot publish into the old controller.
    }
    return result;
  }

  Future<SetupDraftData> saveDraft(SetupReview review) => _invoke(
    (repo, draft) => repo.saveDraft(draft.id, draft.revision, review),
    (value) => value,
  );
  Future<SetupSave> savePerson({
    required String name,
    required String avatar,
  }) => _invoke(
    (repo, draft) =>
        repo.savePerson(draft.id, draft.revision, name: name, avatar: avatar),
    (value) => value.draft,
  );
  Future<SetupSave> saveMedication(MedicationReview review) => _invoke(
    (repo, draft) => repo.saveMedication(draft.id, draft.revision, review),
    (value) => value.draft,
  );
  Future<SetupDraftData> advanceOrSkip(SetupStep next) => _invoke(
    (repo, draft) => repo.advanceOrSkip(draft.id, draft.revision, next),
    (value) => value,
  );
  void reload() => ref.invalidateSelf();
}
