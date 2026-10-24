import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';
import '../sync/refill_refusal.dart';
import '../workspace/workspace_provider.dart';
import 'medication_detail_repository.dart';

final medicationDetailRepositoryProvider =
    FutureProvider<MedicationDetailRepository>((ref) async {
      final db = ref.watch(databaseProvider);
      final access = ref.watch(workspaceAccessRepositoryProvider);
      final context = await ref.watch(workspaceContextProvider.future);
      await access.requireCurrent(context);
      return MedicationDetailRepository(
        database: db,
        access: access,
        context: context,
      );
    });

final medicationDetailProvider =
    StreamProvider.family<MedicationCareDetail, String>((ref, pillId) async* {
      final repository = await ref.watch(
        medicationDetailRepositoryProvider.future,
      );
      yield* repository.watch(pillId);
    });

final localRoutineVersionsProvider =
    StreamProvider<Map<String, List<LocalRoutine>>>((ref) async* {
      final repository = await ref.watch(
        medicationDetailRepositoryProvider.future,
      );
      yield* repository.watchRoutineVersions();
    });

final medicationListProvider = StreamProvider<List<MedicationCareDetail>>((
  ref,
) async* {
  final repository = await ref.watch(medicationDetailRepositoryProvider.future);
  yield* repository.watchList();
});

/// Whether a refill of this medication waits, refused by an older server.
///
/// It is read through the medication's own repository, like the rest of the
/// detail, so it starts only once the workspace grant is known.
final refusedRefillProvider = StreamProvider.family<bool, String>((
  ref,
  pillId,
) async* {
  final repository = await ref.watch(medicationDetailRepositoryProvider.future);
  yield* watchRefusedRefill(repository.database, pillId);
});
