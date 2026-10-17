import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/adapters/medication_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/sync_retry_policy.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

import '../../helpers/care_recording_fixture.dart';

class _MockDio extends Mock implements Dio {}

const _serverPillId = '30000000-0000-4000-8000-000000000022';
const _serverProfileId = '30000000-0000-4000-8000-000000000033';
const _commandId = '30000000-0000-4000-8000-0000000000c1';

// A stock correction held in bridge mode is saved as the count the person
// made (10 -> 8). Weeks later three doses were taken (phone 8 -> 5, server
// 10 -> 7). Sent as the absolute 8 it would wipe the doses out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(<String, Object?>{}));

  late CareRecordingFixture f;
  late V2MedicationSyncAdapter adapter;
  late _MockDio dio;
  late int serverStock;
  final posts = <Map<String, dynamic>>[];
  var serverGets = 0;
  Object? Function() getBehaviour = () => null;

  setUp(() async {
    posts.clear();
    serverGets = 0;
    getBehaviour = () => null;
    serverStock = 7;
    f = await CareRecordingFixture.create(connected: true, legacyStock: 5);
    addTearDown(f.db.close);
    final userId = f.workspace.context.ownerUserId;
    await (f.db.update(f.db.profiles)..where((p) => p.id.equals(f.person.id)))
        .write(const ProfilesCompanion(serverId: Value(_serverProfileId)));
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      const PillsCompanion(
        serverId: Value(_serverPillId),
        revision: Value(6),
        syncStatus: Value('synced'),
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
    final t0 = DateTime.utc(2026, 9, 1);
    await f.db.pendingOperationsDao.enqueue(
      PendingOperationsCompanion.insert(
        id: 'op-correct',
        userId: userId,
        mutationId: _commandId,
        component: 'medication',
        operationType: 'inventory.correct',
        contractVersion: 2,
        payloadJson: jsonEncode({
          'inventoryCommand': {
            'commandId': _commandId,
            'action': 'correct',
            'pillId': f.pill.id,
            'targetStock': 8,
            'note': null,
          },
        }),
        createdAt: t0,
      ),
    );
    Future<void> event(
      String id,
      String command,
      String kind,
      int delta,
      int d,
    ) => f.db.medicationLedgerDao.appendInventoryEvent(
      InventoryEventsCompanion.insert(
        id: id,
        userId: userId,
        pillId: f.pill.id,
        commandId: command,
        kind: kind,
        delta: delta,
        origin: 'native',
        recordedAt: t0.add(Duration(days: d)),
      ),
    );
    await event('ev-correct', _commandId, 'correction', -2, 0);
    for (var i = 1; i <= 3; i++) {
      // Doses already acknowledged: their commands are not unsent work.
      await event('ev-dose-$i', 'acked-dose-$i', 'dose', -1, i);
    }
    dio = _MockDio();
    when(() => dio.get<dynamic>(any())).thenAnswer((_) async {
      serverGets++;
      final custom = getBehaviour();
      if (custom is DioException) throw custom;
      if (custom != null) {
        return Response(
          data: custom,
          requestOptions: RequestOptions(path: '/profiles/x/pills'),
        );
      }
      return Response(
        data: {
          'pills': [
            {'id': _serverPillId, 'currentStock': serverStock, 'revision': '9'},
          ],
        },
        requestOptions: RequestOptions(path: '/profiles/x/pills'),
      );
    });
    when(() => dio.post<dynamic>(any(), data: any(named: 'data'))).thenAnswer((
      invocation,
    ) async {
      final data = Map<String, dynamic>.from(
        invocation.namedArguments[#data] as Map,
      );
      posts.add(data);
      return Response(
        data: {'commandId': data['commandId'], 'revision': '10'},
        requestOptions: RequestOptions(path: '/medication/inventory/commands'),
      );
    });
    adapter = V2MedicationSyncAdapter(db: f.db, dio: dio, writeScope: scope);
  });

  Future<PendingOperation> op() async =>
      (await f.db.pendingOperationsDao.getById('op-correct'))!;

  test('a held correction is sent as a delta on the server count', () async {
    final result = await adapter.send(await op());
    expect(result.status, MedicationMutationStatus.acknowledged);
    // 7 on the server + (8 - 10) = 5: the three doses stay counted.
    expect(posts.single['targetStock'], 5);
    expect(posts.single['baseRevision'], '9');
    expect(serverGets, 1);
    // The phone keeps showing its own, equal count.
    expect((await f.db.pillsDao.getById(f.pill.id))!.currentStock, 5);
    // Frozen at first send: a replay carries the same body.
    final frozen = jsonDecode((await op()).payloadJson) as Map;
    expect((frozen['resolvedInventoryRequest'] as Map)['targetStock'], 5);
  });

  test('a server count moved by something unseen goes to review', () async {
    serverStock = 9; // another device refilled
    final result = await adapter.send(await op());
    expect(result.status, MedicationMutationStatus.conflict);
    expect(posts, isEmpty);
    expect((await op()).state, 'conflict');
    expect((await f.db.pillsDao.getById(f.pill.id))!.currentStock, 5);
  });

  test('doses still unsent are not mistaken for an unseen move', () async {
    // A fourth dose is queued but not on the server yet: the phone shows 4
    // while the server still holds 7.
    final userId = f.workspace.context.ownerUserId;
    await f.db.pendingOperationsDao.enqueue(
      PendingOperationsCompanion.insert(
        id: 'op-dose-4',
        userId: userId,
        mutationId: 'unsent-dose-4',
        component: 'medication',
        operationType: 'medication.command',
        contractVersion: 2,
        payloadJson: '{}',
        createdAt: DateTime.utc(2026, 9, 5),
      ),
    );
    await f.db.medicationLedgerDao.appendInventoryEvent(
      InventoryEventsCompanion.insert(
        id: 'ev-dose-4',
        userId: userId,
        pillId: f.pill.id,
        commandId: 'unsent-dose-4',
        kind: 'dose',
        delta: -1,
        origin: 'native',
        recordedAt: DateTime.utc(2026, 9, 5),
      ),
    );
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      const PillsCompanion(currentStock: Value(4)),
    );
    final result = await adapter.send(await op());
    expect(result.status, MedicationMutationStatus.acknowledged);
    expect(posts.single['targetStock'], 5);
  });

  group('without any later local event', () {
    setUp(() async {
      // Only the correction exists locally: phone 8, server 10 -> after
      // another device took five, server 5.
      await f.db.customStatement(
        "DELETE FROM inventory_events WHERE id LIKE 'ev-dose-%'",
      );
      await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id)))
          .write(const PillsCompanion(currentStock: Value(8)));
    });

    test('a server count that equals the expected one is sent', () async {
      serverStock = 10;
      final result = await adapter.send(await op());
      expect(result.status, MedicationMutationStatus.acknowledged);
      expect(serverGets, 1);
      expect(posts.single['targetStock'], 8);
      expect(posts.single['baseRevision'], '9');
    });

    test("another device's doses are not wiped: review", () async {
      serverStock = 5;
      final result = await adapter.send(await op());
      expect(serverGets, 1);
      expect(result.status, MedicationMutationStatus.conflict);
      expect(posts, isEmpty);
      expect((await op()).state, 'conflict');
    });
  });

  group('server count unreadable', () {
    DioException failure(int? status) => DioException(
      requestOptions: RequestOptions(path: '/profiles/x/pills'),
      type: status == null
          ? DioExceptionType.receiveTimeout
          : DioExceptionType.badResponse,
      response: status == null
          ? null
          : Response(
              requestOptions: RequestOptions(path: '/profiles/x/pills'),
              statusCode: status,
            ),
    );

    Future<void> elapseBackoff() => (f.db.update(f.db.pendingOperations)).write(
      PendingOperationsCompanion(
        lastAttemptAt: Value(
          DateTime.now().toUtc().subtract(const Duration(days: 1)),
        ),
      ),
    );

    test('a transient GET failure counts the attempt and backs off', () async {
      getBehaviour = () => failure(503);
      final result = await adapter.send(await op());
      expect(result.status, MedicationMutationStatus.retryable);
      final saved = await op();
      expect(saved.state, 'failedRetryable');
      expect(saved.attemptCount, 1);
      expect(saved.safeErrorCode, 'INVENTORY_SERVER_STOCK_UNAVAILABLE');
      expect(posts, isEmpty);
      // The backoff keeps it out of the ready list right away.
      final ready = await f.db.pendingOperationsDao.getReady(
        f.workspace.context.ownerUserId,
        honorBackoff: true,
      );
      expect(ready.where((o) => o.id == 'op-correct'), isEmpty);
    });

    test('repeated failures end blocked with a review issue', () async {
      getBehaviour = () => failure(null);
      MedicationMutationResult? last;
      for (var i = 0; i < SyncRetryPolicy.maxAttempts + 2; i++) {
        final current = await op();
        if (current.state == 'blocked') break;
        await elapseBackoff();
        last = await adapter.send(await op());
      }
      final saved = await op();
      expect(saved.state, 'blocked');
      expect(saved.safeErrorCode, SyncRetryPolicy.retryExhaustedCode);
      expect(last!.status, MedicationMutationStatus.blocked);
      expect(posts, isEmpty);
    });

    test('an unreadable 200 body is retryable, not a conflict', () async {
      getBehaviour = () => '<html>captive portal</html>';
      final result = await adapter.send(await op());
      expect(result.status, MedicationMutationStatus.retryable);
      final saved = await op();
      expect(saved.state, 'failedRetryable');
      expect(saved.attemptCount, 1);
      expect(posts, isEmpty);
    });

    test('a pill missing from a readable list is retried, bounded', () async {
      getBehaviour = () => {'pills': <Object>[]};
      final result = await adapter.send(await op());
      expect(result.status, MedicationMutationStatus.retryable);
      expect((await op()).state, 'failedRetryable');
    });

    test('a 404 goes to review', () async {
      getBehaviour = () => failure(404);
      var result = await adapter.send(await op());
      expect(result.status, MedicationMutationStatus.conflict);
      expect((await op()).state, 'conflict');
    });

    test('a tombstoned pill goes to review without asking', () async {
      await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id)))
          .write(const PillsCompanion(isDeleted: Value(true)));
      final result = await adapter.send(await op());
      expect(result.status, MedicationMutationStatus.conflict);
      expect(serverGets, 0);
    });
  });
}
