import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';
import '../workspace/workspace_provider.dart';
import 'care_sharing_status.dart';

final careSharingStatusProvider = StreamProvider.autoDispose<CareSharingStatus>(
  (ref) async* {
    final database = ref.watch(databaseProvider);
    final access = ref.watch(workspaceAccessRepositoryProvider);
    final context = await ref.watch(workspaceContextProvider.future);
    yield* CareSharingStatusRepository(
      database: database,
      access: access,
      context: context,
    ).watch();
  },
);
