import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/sync/adapters/bridge_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/medication_sync_adapter.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

import '../../helpers/care_recording_fixture.dart';

class _Dio extends Mock implements Dio {}

/// The owner's reproduction on a bridge-mode server: take, sync, Undo, take
/// again, sync. Every request goes through the real adapter, in queue order.
class _Harness {
  _Harness(this.f, this.adapter, this.service, this.dio, this.requests);
  final CareRecordingFixture f;
  final BridgeMedicationSyncAdapter adapter;
  final CareRecordingService service;
  final _Dio dio;
  final List<Map<String, dynamic>> requests;

  String get owner => f.workspace.context.ownerUserId;

  Future<void> flush() async {
    for (final operation in await f.db.pendingOperationsDao.getReady(owner)) {
      if (operation.component == 'medication') {
        await adapter.send(operation);
      }
    }
  }

  Future<int> stateVersion() async =>
      (await f.db.medicationLedgerDao.getOccurrenceById(
        f.occurrence.id,
      ))!.stateVersion;

  Future<CareRecordingReceipt> take() async => service.commit(
    await service.prepareTakenNow(
      personId: f.person.id,
      occurrenceId: f.occurrence.id,
      expectedStateVersion: await stateVersion(),
    ),
  );

  Future<List<PendingOperation>> operations() async =>
      (await f.db.pendingOperationsDao.getUnsettledForUser(
        owner,
      )).where((o) => o.component == 'medication').toList();

  Future<PendingOperation> byCommand(String commandId) async =>
      (await f.db.pendingOperationsDao.getByMutationId(owner, commandId))!;
}

Future<_Harness> _harness({bool bridgeUndo = true}) async {
  final f = await CareRecordingFixture.create(connected: true, legacyStock: 4);
  addTearDown(f.db.close);
  await (f.db.update(
    f.db.profiles,
  )..where((r) => r.id.equals(f.person.id))).write(
    ProfilesCompanion(
      serverId: Value(f.person.id),
      syncStatus: const Value('synced'),
    ),
  );
  await (f.db.update(f.db.pills)..where((r) => r.id.equals(f.pill.id))).write(
    PillsCompanion(
      serverId: Value(f.pill.id),
      syncStatus: const Value('synced'),
    ),
  );
  await (f.db.update(
    f.db.schedules,
  )..where((r) => r.id.equals(f.occurrence.scheduleId!))).write(
    SchedulesCompanion(
      serverId: Value(f.occurrence.scheduleId),
      syncStatus: const Value('synced'),
    ),
  );
  await (f.db.update(f.db.medicationOccurrences)
        ..where((r) => r.id.equals(f.occurrence.id)))
      .write(MedicationOccurrencesCompanion(serverId: Value(f.occurrence.id)));
  final context = f.workspace.context;
  final dio = _Dio();
  final requests = <Map<String, dynamic>>[];
  var revision = 1;
  when(
    () => dio.post<dynamic>(
      '/medication/bridge/commands',
      data: any(named: 'data'),
    ),
  ).thenAnswer((invocation) async {
    final request = Map<String, dynamic>.from(
      invocation.namedArguments[#data] as Map,
    );
    requests.add(request);
    revision++;
    return Response<dynamic>(
      requestOptions: RequestOptions(path: '/fictional'),
      data: {
        'commandId': request['commandId'],
        'pillRevision': revision.toString(),
      },
    );
  });
  final adapter = BridgeMedicationSyncAdapter(
    db: f.db,
    dio: dio,
    bridgeUndo: bridgeUndo,
    writeScope: SyncWriteScope(
      access: f.workspace.access,
      capability: NetworkCapability(
        ownerId: context.ownerUserId,
        endpoint: context.endpoint!,
        epoch: context.networkEpoch!,
        generation: context.sessionGeneration!,
      ),
    ),
  );
  final service = CareRecordingService(
    database: f.db,
    access: f.workspace.access,
    context: context,
  );
  return _Harness(f, adapter, service, dio, requests);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(<String, Object?>{}));

  test(
    'take, sync, Undo, take again on a tracked pill commits every operation',
    () async {
      final h = await _harness();
      final take = await h.take();
      await h.flush();
      expect((await h.byCommand(take.event.commandId)).state, 'committed');

      await h.service.commit(await h.service.prepareUndo(take));
      await h.take();
      await h.flush();
      await h.flush();

      expect(h.requests.map((r) => r['status']), ['taken', 'pending', 'taken']);
      expect(await h.operations(), isEmpty);
      final ops = (await h.f.db.pendingOperationsDao.getForUser(
        h.owner,
      )).where((o) => o.component == 'medication');
      expect(ops, hasLength(3));
      expect(ops.map((o) => o.state), everyElement('committed'));
      // The retake is a new dose row for the same slot.
      expect(
        h.requests[2]['legacyDoseId'],
        isNot(h.requests[0]['legacyDoseId']),
      );
      expect(h.requests[1]['legacyDoseId'], h.requests[0]['legacyDoseId']);
      expect(h.requests[1]['allowCreate'], isFalse);
      expect(h.requests[1]['takenAt'], isNull);
    },
  );

  test('bridge commands send a null observed base on a tracked pill', () async {
    final h = await _harness();
    final take = await h.take();
    await h.flush();
    await h.service.commit(await h.service.prepareUndo(take));
    await h.flush();
    expect(h.requests, hasLength(2));
    for (final request in h.requests) {
      expect(request['observedBaseStock'], isNull);
      expect(request['observedBasePillRevision'], isNull);
    }
  });

  test(
    'an ack adopts the returned pill revision when the pill is synced',
    () async {
      final h = await _harness();
      await h.take();
      await h.flush();
      expect((await h.f.db.pillsDao.getById(h.f.pill.id))!.revision, 2);
    },
  );

  test('an ack further ahead leaves a synced pill for the next pull', () async {
    final h = await _harness();
    await h.take();
    // Another device moved the pill to revision 2, so this command's ack (2)
    // is not one past the local base (0 here stands for "behind by one").
    await (h.f.db.update(h.f.db.pills)..where((r) => r.id.equals(h.f.pill.id)))
        .write(const PillsCompanion(revision: Value(0)));
    await h.flush();
    expect((await h.f.db.pillsDao.getById(h.f.pill.id))!.revision, 0);
  });

  test('an ack never overwrites a pill with a pending local edit', () async {
    final h = await _harness();
    await h.take();
    await (h.f.db.update(
      h.f.db.pills,
    )..where((r) => r.id.equals(h.f.pill.id))).write(
      const PillsCompanion(syncStatus: Value('pending'), revision: Value(7)),
    );
    await h.flush();
    final pill = (await h.f.db.pillsDao.getById(h.f.pill.id))!;
    expect(pill.revision, 7);
    expect(pill.syncStatus, 'pending');
  });

  test(
    'a take made before a pending edit still lets the edit keep a current base',
    () async {
      final h = await _harness();
      await h.take();
      await (h.f.db.update(
        h.f.db.pills,
      )..where((r) => r.id.equals(h.f.pill.id))).write(
        const PillsCompanion(
          name: Value('Edited'),
          syncStatus: Value('pending'),
          revision: Value(1),
        ),
      );
      await h.flush();
      final pill = (await h.f.db.pillsDao.getById(h.f.pill.id))!;
      // The ack's one-step bump is this command's own, so the pending PATCH
      // is sent against revision 2 instead of losing a 409.
      expect(pill.revision, 2);
      expect(pill.name, 'Edited');
      expect(pill.syncStatus, 'pending');
    },
  );

  test(
    'a server without bridgeUndo blocks the Undo visibly and strands the retake behind it',
    () async {
      final h = await _harness(bridgeUndo: false);
      final take = await h.take();
      await h.flush();
      final undo = await h.service.commit(await h.service.prepareUndo(take));
      await h.take();
      await h.flush();
      await h.flush();

      expect(h.requests.map((r) => r['status']), ['taken']);
      final blocked = await h.byCommand(undo.event.commandId);
      expect(blocked.state, 'blocked');
      expect(blocked.safeErrorCode, 'BRIDGE_UNDO_UNSUPPORTED');
      final issues = await h.f.db.migrationIssuesDao.getUnresolved(h.owner);
      expect(
        issues.where(
          (i) =>
              i.issueCode == 'bridge_undo_unsupported' &&
              i.entityId == blocked.id,
        ),
        hasLength(1),
      );
      // A second flush must not record a duplicate issue.
      await h.flush();
      expect(
        (await h.f.db.migrationIssuesDao.getUnresolved(
          h.owner,
        )).where((i) => i.issueCode == 'bridge_undo_unsupported'),
        hasLength(1),
      );
      final queued = (await h.operations()).where((o) => o.state == 'queued');
      expect(queued, hasLength(1));
      expect(
        (await h.f.db.pendingOperationsDao.getReady(
          h.owner,
        )).where((o) => o.component == 'medication'),
        isEmpty,
      );
    },
  );

  test(
    'a stale-base 409 drops the observed bases and retries instead of terminal conflict',
    () async {
      final h = await _harness();
      final take = await h.take();
      await h.flush();
      // As after a pull: the dose now carries its server identity, so the
      // undo observes a dose fingerprint.
      final doseId = (await h.f.db.select(h.f.db.doseLogs).get()).single.id;
      await (h.f.db.update(h.f.db.doseLogs)..where((r) => r.id.equals(doseId)))
          .write(DoseLogsCompanion(serverId: Value(doseId)));
      final undo = await h.service.commit(await h.service.prepareUndo(take));

      var calls = 0;
      when(
        () => h.dio.post<dynamic>(
          '/medication/bridge/commands',
          data: any(named: 'data'),
        ),
      ).thenAnswer((invocation) async {
        final request = Map<String, dynamic>.from(
          invocation.namedArguments[#data] as Map,
        );
        h.requests.add(request);
        if (calls++ == 0) {
          throw DioException(
            requestOptions: RequestOptions(path: '/fictional'),
            type: DioExceptionType.badResponse,
            response: Response<dynamic>(
              requestOptions: RequestOptions(path: '/fictional'),
              statusCode: 409,
              data: {
                'error': {
                  'code': 'CONFLICT_STALE_UPDATE',
                  'message': 'Legacy dose changed since the observed base',
                  'retryable': false,
                },
              },
            ),
          );
        }
        return Response<dynamic>(
          requestOptions: RequestOptions(path: '/fictional'),
          data: {'commandId': request['commandId'], 'pillRevision': '3'},
        );
      });

      final first = await h.adapter.send(
        await h.byCommand(undo.event.commandId),
      );
      expect(first.status, MedicationMutationStatus.retryable);
      final retry = await h.byCommand(undo.event.commandId);
      expect(retry.state, 'failedRetryable');
      expect(h.requests.last['observedBaseDoseFingerprint'], isNotNull);

      final second = await h.adapter.send(retry);
      expect(second.status, MedicationMutationStatus.acknowledged);
      expect(h.requests.last['observedBaseDoseFingerprint'], isNull);
      expect(h.requests.last['commandId'], undo.event.commandId);
      expect((await h.byCommand(undo.event.commandId)).state, 'committed');
    },
  );

  test('a non-HTTP cannot-send result persists a transition', () async {
    final h = await _harness();
    final take = await h.take();
    // Corrupt the retained command so the adapter cannot represent it.
    await (h.f.db.update(h.f.db.pendingOperations)
          ..where((r) => r.mutationId.equals(take.event.commandId)))
        .write(const PendingOperationsCompanion(payloadJson: Value('{}')));
    final op = await h.byCommand(take.event.commandId);
    final result = await h.adapter.send(op);
    expect(result.status, MedicationMutationStatus.blocked);
    expect((await h.byCommand(take.event.commandId)).state, 'blocked');
  });

  for (final advertised in [true, null]) {
    test('capabilities parse bridgeUndo ${advertised ?? 'absent'}', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              data: {
                'apiNamespace': 'v1',
                'bridgeUndo': ?advertised,
                'contracts': {
                  'componentSync': 2,
                  'legacySplitReconciliation': 1,
                  'medicationBridgeCommands': 1,
                  'medicationBridgeSync': 1,
                  'medicationCommands': 2,
                },
                'medicationLedgerActive': false,
                'minimumClientBuild': 1,
                'serverRelease': 'release-test',
              },
            ),
          ),
        ),
      );
      final snapshot = await CapabilitiesClient(dio).refresh();
      expect(snapshot.availability, CapabilityAvailability.present);
      expect(snapshot.capabilities!.bridgeUndo, advertised == true);
    });
  }
}
