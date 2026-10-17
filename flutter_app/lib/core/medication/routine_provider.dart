import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../db/database.dart';
import '../workspace/workspace_provider.dart';
import 'routine_repository.dart';

final routineRepositoryProvider = FutureProvider<RoutineRepository>((
  ref,
) async {
  final db = ref.watch(databaseProvider);
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final context = await ref.watch(workspaceContextProvider.future);
  await access.requireCurrent(context);
  return RoutineRepository(database: db, access: access, context: context);
});
