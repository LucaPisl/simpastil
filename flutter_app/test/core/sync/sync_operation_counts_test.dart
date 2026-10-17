import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/sync_service.dart';
import 'package:simpastil/core/sync/sync_status_notifier.dart';
import 'package:simpastil/features/settings/presentation/sync_diagnostics_sheet.dart';

class _MockDio extends Mock implements Dio {}

const _userId = 'user-1';
final _now = DateTime.utc(2026, 10, 14, 8);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late SyncService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting();
    addTearDown(db.close);
    final dio = _MockDio();
    when(() => dio.get<Map<String, dynamic>>('/capabilities')).thenThrow(
      DioException(
        requestOptions: RequestOptions(path: '/capabilities'),
        response: Response<Map<String, dynamic>>(
          requestOptions: RequestOptions(path: '/capabilities'),
          statusCode: 404,
        ),
        type: DioExceptionType.badResponse,
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

  var sequence = 0;
  Future<void> op(
    String id,
    String state, {
    String? dependsOn,
    String component = 'stable',
    String operationType = 'profile.update',
    String? payload,
  }) => db
      .into(db.pendingOperations)
      .insert(
        PendingOperationsCompanion.insert(
          id: id,
          userId: _userId,
          mutationId: 'm-$id',
          component: component,
          operationType: operationType,
          contractVersion: 2,
          payloadJson:
              payload ?? '{"entityType":"profile","entityLocalId":"p-$id"}',
          state: Value(state),
          dependsOnOperationId: Value(dependsOn),
          createdAt: _now.add(Duration(seconds: sequence++)),
        ),
      );

  test('every state is counted once, separately', () async {
    await op('q', 'queued');
    await op('s', 'sending');
    await op('r', 'failedRetryable');
    await op('b', 'blocked');
    await op('c', 'conflict');
    await op('done', 'committed');

    final counts = await service.countOperations(userId: _userId);

    expect(counts.queued, 2, reason: 'queued and sending');
    expect(counts.retrying, 1);
    expect(counts.blocked, 1);
    expect(counts.conflict, 1);
    expect(counts.stranded, 0);
    expect(counts.needsAttention, 2);
    expect(counts.isSettled, isFalse);
  });

  test('dependents of a blocked or conflicting op are stranded', () async {
    await op('root', 'blocked');
    await op('child', 'queued', dependsOn: 'root');
    await op('grandchild', 'failedRetryable', dependsOn: 'child');
    await op('cRoot', 'conflict');
    await op('cChild', 'queued', dependsOn: 'cRoot');
    await op('free', 'queued');
    await op('afterDone', 'queued', dependsOn: 'gone');

    final counts = await service.countOperations(userId: _userId);

    expect(counts.blocked, 1);
    expect(counts.conflict, 1);
    expect(counts.stranded, 3);
    expect(counts.queued, 2, reason: 'free and afterDone are not stranded');
    expect(counts.retrying, 0, reason: 'a stranded retry is stranded');
  });

  test(
    'dose operations behind a stuck pill or schedule create are stranded',
    () async {
      await op(
        'pillCreate',
        'blocked',
        operationType: 'pill.create',
        payload: '{"entityType":"pill","entityLocalId":"pill-1"}',
      );
      await op(
        'scheduleCreate',
        'conflict',
        operationType: 'schedule.create',
        payload:
            '{"entityType":"schedule","entityLocalId":"s-2","parentEntityType":"pill","parentEntityLocalId":"pill-2"}',
      );
      await op(
        'dose1',
        'queued',
        component: 'medication',
        operationType: 'medication.command',
        payload: '{"localProjection":{"pillId":"pill-1"}}',
      );
      await op(
        'dose2',
        'failedRetryable',
        component: 'medication',
        operationType: 'medication.command',
        payload: '{"localProjection":{"pillId":"pill-2"}}',
      );
      await op(
        'dose3',
        'queued',
        component: 'medication',
        operationType: 'medication.command',
        payload: '{"localProjection":{"pillId":"pill-3"}}',
      );

      final counts = await service.countOperations(userId: _userId);

      expect(counts.stranded, 2);
      expect(counts.queued, 1, reason: 'the dose of a healthy pill');
      expect(counts.retrying, 0);
      expect(counts.needsAttention, 4, reason: 'two stuck creates + two doses');
    },
  );

  test('a dependency cycle cannot hang the tally', () async {
    await op('a', 'queued', dependsOn: 'b');
    await op('b', 'queued', dependsOn: 'a');

    final counts = await service.countOperations(userId: _userId);

    expect(counts.queued, 2);
  });

  test('a refused medication op is persisted, never left queued', () async {
    // No split checkpoint exists, so the legacy adapter refuses to send it.
    await op('refused', 'queued', component: 'medication');

    await service.flushPending(userId: _userId);

    final row = await db.pendingOperationsDao.getById('refused');
    expect(row!.state, 'blocked');
    expect(row.safeErrorCode, 'MISSING_SPLIT_CHECKPOINT');
    final counts = await service.countOperations(userId: _userId);
    expect(counts.blocked, 1);
    expect(counts.queued, 0);
  });

  test('countPending keeps its waiting-work meaning', () async {
    await op('b', 'blocked');
    await op('c', 'queued', dependsOn: 'b');
    await op('r', 'failedRetryable');

    expect(await service.countPending(userId: _userId), 2);
  });

  group('status', () {
    test('markSuccess keeps the counts it is given', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const counts = SyncOperationCounts(blocked: 1, stranded: 2);

      await container
          .read(syncStatusProvider.notifier)
          .markSuccess(pendingCount: 2, counts: counts);

      expect(container.read(syncStatusProvider).counts, counts);
    });

    test('never reads synced while blocked, conflict or stranded remain', () {
      for (final counts in const [
        SyncOperationCounts(blocked: 1),
        SyncOperationCounts(conflict: 1),
        SyncOperationCounts(stranded: 1),
      ]) {
        final state = syncHeadlineState(
          SyncStatus(
            lastSuccessAt: DateTime.utc(2026, 10, 14),
            lastRun: const SyncRunResult([]),
            counts: counts,
          ),
        );
        expect(state, isNot(SyncHeadlineState.synced), reason: '$counts');
        expect(state, SyncHeadlineState.needsReview, reason: '$counts');
      }
    });

    test('retrying work is not synced either', () {
      final state = syncHeadlineState(
        SyncStatus(
          lastSuccessAt: DateTime.utc(2026, 10, 14),
          pendingCount: 1,
          counts: const SyncOperationCounts(retrying: 1),
        ),
      );
      expect(state, SyncHeadlineState.partiallySynced);
    });

    test('settled counts are synced', () {
      expect(
        syncHeadlineState(
          SyncStatus(lastSuccessAt: DateTime.utc(2026, 10, 14)),
        ),
        SyncHeadlineState.synced,
      );
    });
  });
}
