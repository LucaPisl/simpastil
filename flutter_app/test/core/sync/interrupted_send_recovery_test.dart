import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/sync_service.dart';

class _MockDio extends Mock implements Dio {}

const _userId = 'user-1';
final _now = DateTime.utc(2026, 10, 21, 21);

// A bridge dose command whose body was frozen when it was claimed, so a
// replay under the same command id is idempotent on the server.
const _frozenPayload =
    '{"medicationBridgeRequest":{"commandId":"c1"},'
    '"localProjection":{"pillId":"pill-1"}}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _MockDio dio;
  late SyncService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting();
    addTearDown(db.close);
    dio = _MockDio();
    when(() => dio.get<Map<String, dynamic>>('/capabilities')).thenAnswer(
      (_) async => Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(path: '/capabilities'),
        data: {
          'apiNamespace': 'v1',
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
    );
    service = SyncService(db: db, dio: dio, isOnline: () async => true);
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: _userId,
        email: 'user@example.invalid',
        createdAt: _now,
        updatedAt: _now,
      ),
    );
  });

  Future<void> stranded(
    String id, {
    required String payload,
    required DateTime claimedAt,
  }) => db
      .into(db.pendingOperations)
      .insert(
        PendingOperationsCompanion.insert(
          id: id,
          userId: _userId,
          mutationId: 'm-$id',
          component: 'medication',
          operationType: 'medication.command',
          contractVersion: 2,
          payloadJson: payload,
          state: const Value('sending'),
          attemptCount: const Value(1),
          lastAttemptAt: Value(claimedAt),
          createdAt: _now,
        ),
      );

  DateTime ago(Duration age) => DateTime.now().toUtc().subtract(age);

  test(
    'a send interrupted by a process kill is picked up by the next sync',
    () async {
      // Left in `sending` by a killed process (an app update replacing the
      // running app, or battery optimisation stopping a background sync).
      await stranded(
        'dose',
        payload: _frozenPayload,
        claimedAt: ago(const Duration(hours: 4)),
      );

      await service.flushPending(userId: _userId);

      final row = (await db.pendingOperationsDao.getById('dose'))!;
      expect(
        row.state,
        isNot('sending'),
        reason: 'nothing may stay in sending once no send is in flight',
      );
      // Only the medication stage reports this code, so the requeued row was
      // handed to the sender again (the stub payload cannot really be sent).
      expect(row.safeErrorCode, 'INVALID_MEDICATION_OPERATION');
    },
  );

  for (final entry in {
    'a dose': _frozenPayload,
    'an as-needed dose': '{"phase1PrnRequest":{"commandId":"c3"}}',
  }.entries) {
    test('a stranded frozen request for ${entry.key} is requeued', () async {
      await stranded(
        'frozen',
        payload: entry.value,
        claimedAt: ago(const Duration(hours: 4)),
      );

      final recovered = await db.pendingOperationsDao
          .recoverInterruptedOperations(
            userId: _userId,
            claimedBefore: ago(SyncService.interruptedSendAge),
          );

      expect(recovered, 1);
      final row = (await db.pendingOperationsDao.getById('frozen'))!;
      expect(row.state, 'queued');
      expect(
        row.payloadJson,
        entry.value,
        reason: 'the body is replayed as is',
      );
      expect(row.attemptCount, 1);
    });
  }

  test('a send claimed moments ago is left alone', () async {
    // A schedule repair sends outside the sync lock; a sync starting while it
    // is in flight must not take it for a leftover.
    await stranded(
      'fresh',
      payload: _frozenPayload,
      claimedAt: ago(const Duration(seconds: 5)),
    );

    await service.flushPending(userId: _userId);

    expect((await db.pendingOperationsDao.getById('fresh'))!.state, 'sending');
  });

  test('a claim stamped in the future counts as old', () async {
    // The clock was set back after the kill; waiting for it to catch up would
    // leave the dose in sending for hours.
    await stranded(
      'future',
      payload: _frozenPayload,
      claimedAt: ago(const Duration(hours: -3)),
    );

    final recovered = await db.pendingOperationsDao
        .recoverInterruptedOperations(
          userId: _userId,
          claimedBefore: ago(SyncService.interruptedSendAge),
        );

    expect(recovered, 1);
    expect((await db.pendingOperationsDao.getById('future'))!.state, 'queued');
  });

  test(
    'a stranded send without a frozen request is shown for review',
    () async {
      // No frozen body means nothing proves what the server saw, so it must
      // not be replayed, and it must not hide behind "Nothing needs fixing".
      await stranded(
        'unproven',
        payload: '{"command":{"commandId":"c2"}}',
        claimedAt: ago(const Duration(hours: 4)),
      );

      await service.flushPending(userId: _userId);

      expect(
        (await db.pendingOperationsDao.getById('unproven'))!.state,
        'blocked',
      );
      final counts = await service.countOperations(userId: _userId);
      expect(counts.needsAttention, 1);
    },
  );
}
