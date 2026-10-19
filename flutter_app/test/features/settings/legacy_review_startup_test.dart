import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/core/projections/projection_reconciler.dart';
import 'package:simpastil/features/settings/presentation/legacy_routine_review_screen.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/protected_workspace_fixture.dart';

class _ApiClient extends Mock implements ApiClient {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'review and reminder providers can load before native initialization',
    () async {
      tzdata.initializeTimeZones();
      final fixture = await ProtectedWorkspaceFixture.create(
        ownerId: 'example-owner',
      );
      final client = _ApiClient();
      final dio = Dio();
      var requests = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests++;
            handler.reject(DioException(requestOptions: request));
          },
        ),
      );
      when(() => client.dio).thenReturn(dio);
      final container = await fixture.createContainer(
        extraOverrides: [apiClientProvider.overrideWithValue(client)],
      );
      addTearDown(() async {
        container.dispose();
        dio.close();
        await fixture.db.close();
      });

      // Session startup can request this before optional native notification
      // initialization. Do not assign a fake global plugin: that hid the race.
      final reconciler = container.read(projectionReconcilerProvider);
      final repository = await container.read(
        legacyRoutineReviewRepositoryProvider.future,
      );
      final preview = await repository.preview(
        timeZone: 'Europe/Bucharest',
        effectiveFromLocalDate: DateTime(2026, 10, 8),
      );
      expect(preview.items, isEmpty);
      expect(
        identical(container.read(projectionReconcilerProvider), reconciler),
        isTrue,
      );
      expect(requests, 0);
    },
  );
}
