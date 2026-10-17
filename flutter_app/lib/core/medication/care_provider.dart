import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';
import '../workspace/workspace_provider.dart';
import 'care_day.dart';
import 'care_recording.dart';

final careRecordingServiceProvider = FutureProvider<CareRecordingService>((
  ref,
) async {
  final contextFuture = ref.watch(workspaceContextProvider.future);
  final database = ref.watch(databaseProvider);
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final context = await contextFuture;
  await access.requireCurrent(context);
  return CareRecordingService(
    database: database,
    access: access,
    context: context,
  );
});

class CareDayRequest {
  const CareDayRequest({required this.localDate, this.personId});
  final String localDate;
  final String? personId;
  @override
  bool operator ==(Object other) =>
      other is CareDayRequest &&
      other.localDate == localDate &&
      other.personId == personId;
  @override
  int get hashCode => Object.hash(localDate, personId);
}

final careDayProvider = StreamProvider.autoDispose
    .family<CareDay, CareDayRequest>((ref, request) async* {
      final contextFuture = ref.watch(workspaceContextProvider.future);
      final database = ref.watch(databaseProvider);
      final access = ref.watch(workspaceAccessRepositoryProvider);
      final context = await contextFuture;
      yield* CareDayRepository(
        database: database,
        access: access,
        context: context,
      ).watch(localDate: request.localDate, personId: request.personId);
    });
