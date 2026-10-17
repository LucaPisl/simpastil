import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';
import '../workspace/workspace_provider.dart';
import 'occurrence_detail_repository.dart';

final occurrenceDetailRepositoryProvider =
    FutureProvider<OccurrenceDetailRepository>((ref) async {
      final database = ref.watch(databaseProvider);
      final access = ref.watch(workspaceAccessRepositoryProvider);
      final context = await ref.watch(workspaceContextProvider.future);
      await access.requireCurrent(context);
      return OccurrenceDetailRepository(
        database: database,
        access: access,
        context: context,
      );
    });

final occurrenceDetailProvider = StreamProvider.autoDispose
    .family<OccurrenceCareDetail, String>((ref, occurrenceId) async* {
      final repository = await ref.watch(
        occurrenceDetailRepositoryProvider.future,
      );
      yield* repository.watch(occurrenceId);
    });
