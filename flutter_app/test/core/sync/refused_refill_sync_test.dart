import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/held_stock.dart';
import 'package:simpastil/core/sync/refill_refusal.dart';
import 'package:simpastil/core/sync/sync_recovery_service.dart';
import 'package:simpastil/core/sync/sync_service.dart';

const _user = 'user-refill';
const _profile = 'profile-refill';
const _pill = 'pill-refill';
final _at = DateTime.utc(2026, 10, 23, 8);

/// A refill queued while the server was unknown meets an older server. The
/// whole sync pass must settle it in one visible place: blocked with its own
/// reason, never sent or retried, its count left to the server, and an edit
/// queued behind it free to go.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Dio dio;
  late List<RequestOptions> requests;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting();
    requests = [];
    dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          if (request.path == '/capabilities') {
            handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.badResponse,
                response: Response(requestOptions: request, statusCode: 404),
              ),
            );
            return;
          }
          requests.add(request);
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              data: {'id': _pill, 'name': 'Edited', 'currentStock': 10},
            ),
          );
        },
      ),
    );
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: _user,
        email: 'fictional@example.invalid',
        createdAt: _at,
        updatedAt: _at,
      ),
    );
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _profile,
        userId: _user,
        name: 'Fictional person',
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_profile),
        syncStatus: const Value('synced'),
      ),
    );
    // The refill already moved the phone's count from 10 to 15.
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: _pill,
        profileId: _profile,
        name: 'Fictional medication',
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_pill),
        currentStock: const Value(15),
        syncStatus: const Value('synced'),
      ),
    );
    await db.pendingOperationsDao.enqueue(
      PendingOperationsCompanion.insert(
        id: 'refill',
        userId: _user,
        mutationId: 'm-refill',
        component: 'medication',
        operationType: 'inventory.refill',
        contractVersion: 2,
        payloadJson: jsonEncode({
          'entityType': 'pill',
          'entityLocalId': _pill,
          'inventoryCommand': {
            'commandId': 'm-refill',
            'action': 'refill',
            'pillId': _pill,
            'amount': 5,
          },
        }),
        createdAt: _at,
      ),
    );
  });
  tearDown(() async {
    dio.close(force: true);
    await db.close();
  });

  Future<void> behind(String id, Map<String, Object?> body) =>
      db.pendingOperationsDao.enqueue(
        PendingOperationsCompanion.insert(
          id: id,
          userId: _user,
          mutationId: 'm-$id',
          component: 'stable',
          operationType: 'pill.${body['action']}',
          contractVersion: 2,
          dependsOnOperationId: const Value('refill'),
          payloadJson: jsonEncode({
            'entityType': 'pill',
            'entityLocalId': _pill,
            'parentEntityType': 'profile',
            'parentEntityLocalId': _profile,
            ...body,
          }),
          createdAt: _at.add(const Duration(minutes: 1)),
        ),
      );

  SyncService service() =>
      SyncService(db: db, dio: dio, isOnline: () async => true);

  Future<PendingOperation> op(String id) async =>
      (await db.pendingOperationsDao.getById(id))!;

  test('the refill ends blocked with its reason and is never sent or '
      'retried', () async {
    await service().flushPending(userId: _user);
    var refill = await op('refill');
    expect(refill.state, 'blocked');
    expect(refill.safeErrorCode, refillNeedsLedgerCode);
    final attempts = refill.attemptCount;

    await service().flushPending(userId: _user);
    await service().flushPending(userId: _user);
    refill = await op('refill');
    expect(refill.state, 'blocked');
    expect(refill.attemptCount, attempts);
    expect(requests.where((r) => r.path.contains('inventory')), isEmpty);
    expect(requests.where((r) => r.path.contains('refill')), isEmpty);
  });

  test('the server keeps its count: the refusal no longer holds the phone '
      'count, and the medication says why', () async {
    expect(await unsettledInventoryPillIds(db, _user), contains(_pill));
    await service().flushPending(userId: _user);

    // The pull may now put the server's count back.
    expect(await unsettledInventoryPillIds(db, _user), isEmpty);
    expect(await watchRefusedRefill(db, _pill).first, isTrue);
    expect(await watchRefusedRefill(db, 'another-pill').first, isFalse);
  });

  test(
    'an edit queued behind the refill is sent; a delete still waits',
    () async {
      await behind('edit', {
        'action': 'update',
        'data': {'name': 'Edited'},
      });
      await behind('delete', {'action': 'delete', 'data': {}});

      await service().flushPending(userId: _user);
      await service().flushPending(userId: _user);

      // An older server accepts the edit; the pull then reconciles it.
      expect(
        (await op('edit')).safeErrorCode,
        'LEGACY_STABLE_AWAITING_RECONCILIATION',
      );
      expect(
        requests.where((r) => r.method == 'PATCH').single.path,
        contains(_pill),
      );
      expect((await op('delete')).state, 'queued');
      expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
    },
  );

  test(
    'an edit that carries stock keeps its order behind the refill',
    () async {
      await behind('stock-edit', {
        'action': 'update',
        'data': {'name': 'Edited', 'currentStock': 20},
      });
      await service().flushPending(userId: _user);
      await service().flushPending(userId: _user);
      expect((await op('stock-edit')).state, 'queued');
      expect(requests.where((r) => r.method == 'PATCH'), isEmpty);
    },
  );

  group('in Fix sync problems', () {
    SyncRecoveryService recovery(RecoveryFlush flush) => SyncRecoveryService(
      db: db,
      flush: flush,
      pull: (_) async => true,
      write: <T>(_, action) => db.transaction(action),
    );

    Future<String> refillKey(SyncRecoveryService service) async =>
        (await service.diagnose(_user)).items
            .firstWhere((item) => item.operations.any((o) => o.id == 'refill'))
            .key;

    test('retried after the server gains the ledger, the refill is sent '
        'and the notice clears', () async {
      await service().flushPending(userId: _user);
      expect(await watchRefusedRefill(db, _pill).first, isTrue);

      // The updated server takes the refill: the flush after Try again
      // commits it, as a ledger answer would.
      final sent = <String>[];
      final updated = recovery((userId) async {
        for (final op in await db.pendingOperationsDao.getUnsettledForUser(
          userId,
        )) {
          if (op.state != 'queued') continue;
          sent.add(op.id);
          await db.pendingOperationsDao.transitionState(
            operationId: op.id,
            from: 'queued',
            to: 'committed',
          );
        }
      });
      final outcome = await updated.tryAgain(_user, await refillKey(updated));

      expect(outcome.refusal, isNull);
      expect(sent, contains('refill'));
      expect((await op('refill')).state, 'committed');
      expect(await watchRefusedRefill(db, _pill).first, isFalse);
    });

    test('retried while the server is still older, the notice comes '
        'back', () async {
      await service().flushPending(userId: _user);
      final older = recovery(
        (userId) => service().flushPending(userId: userId),
      );
      await older.tryAgain(_user, await refillKey(older));

      expect((await op('refill')).safeErrorCode, refillNeedsLedgerCode);
      expect(await watchRefusedRefill(db, _pill).first, isTrue);
    });

    test('discarded, the refill is dropped and the notice clears', () async {
      await service().flushPending(userId: _user);
      final stream = watchRefusedRefill(db, _pill);
      expect(await stream.first, isTrue);

      final discard = recovery((_) async {});
      final outcome = await discard.discardItem(
        _user,
        await refillKey(discard),
      );

      expect(outcome.refusal, isNull);
      expect((await op('refill')).state, 'discarded');
      expect(await watchRefusedRefill(db, _pill).first, isFalse);
    });
  });
}
