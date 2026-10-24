import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/sync/adapters/v2_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

import '../../helpers/care_recording_fixture.dart';

class _MockDio extends Mock implements Dio {}

const _serverOccurrenceId = '30000000-0000-4000-8000-000000000011';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(<String, Object?>{}));

  group('recordedBy on a dose command', () {
    Future<Map<String, dynamic>> sentTake({
      required bool serverHasRecordedBy,
    }) async {
      final f = await CareRecordingFixture.create(
        connected: true,
        legacyStock: 10,
      );
      addTearDown(f.db.close);
      SharedPreferences.setMockInitialValues({
        LedgerModeHint.recordedByKey: serverHasRecordedBy,
      });
      await (f.db.update(
        f.db.medicationOccurrences,
      )..where((r) => r.id.equals(f.occurrence.id))).write(
        const MedicationOccurrencesCompanion(
          serverId: Value(_serverOccurrenceId),
        ),
      );
      final context = f.workspace.context;
      final scope = SyncWriteScope(
        access: f.workspace.access,
        capability: NetworkCapability(
          ownerId: context.ownerUserId,
          endpoint: context.endpoint!,
          epoch: context.networkEpoch!,
          generation: context.sessionGeneration!,
        ),
      );
      final service = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: context,
      );
      final take = await service.commit(
        await service.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 0,
          amount: const MedicationAmount.unknown(),
        ),
      );
      final queued = (await f.db.pendingOperationsDao.getByMutationId(
        context.ownerUserId,
        take.event.commandId,
      ))!;
      // The name is held with the queued command whatever the server is.
      expect((jsonDecode(queued.payloadJson) as Map)['recordedBy'], isA<Map>());
      final posts = <Map<String, dynamic>>[];
      final dio = _MockDio();
      when(() => dio.post<dynamic>(any(), data: any(named: 'data'))).thenAnswer(
        (invocation) async {
          final data = Map<String, dynamic>.from(
            invocation.namedArguments[#data] as Map,
          );
          posts.add(data);
          return Response(
            data: {'commandId': data['commandId']},
            requestOptions: RequestOptions(path: '/medication/commands'),
          );
        },
      );
      await V2MedicationSyncAdapter(
        db: f.db,
        dio: dio,
        writeScope: scope,
      ).send(queued);
      expect(posts, hasLength(1));
      return posts.single;
    }

    test('is sent to a server that stores it, versioned', () async {
      final body = await sentTake(serverHasRecordedBy: true);
      final recordedBy = body['recordedBy'] as Map;
      expect(recordedBy['version'], 1);
      expect(recordedBy.keys.toSet(), {'version', 'name'});
    });

    test('is never sent to an older server', () async {
      final body = await sentTake(serverHasRecordedBy: false);
      expect(body.containsKey('recordedBy'), isFalse);
    });
  });
}
