import 'dart:convert';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/features/pills/schedule_repository.dart';
import 'package:simpastil/features/pills/legacy_routine_review_repository.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import '../../helpers/protected_workspace_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  late ProtectedWorkspaceFixture f;
  late _Schedules schedules;
  late LegacyRoutineReviewRepository repo;
  final boundary = DateTime(2026, 10, 5);
  setUp(() async {
    f = await ProtectedWorkspaceFixture.create(ownerId: 'fictional-owner');
    final now = DateTime.utc(2026, 10, 4);
    await f.db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: 'person',
        userId: f.context.ownerUserId,
        name: 'Fictional person',
        createdAt: now,
        updatedAt: now,
        syncStatus: const Value('synced'),
      ),
    );
    await f.db.pillsDao.upsert(
      PillsCompanion.insert(
        id: 'pill',
        profileId: 'person',
        name: 'Fictional medication',
        createdAt: now,
        updatedAt: now,
        syncStatus: const Value('synced'),
      ),
    );
    schedules = _Schedules();
    repo = LegacyRoutineReviewRepository(
      database: f.db,
      access: f.access,
      context: f.context,
      schedules: schedules,
      clock: () => DateTime.utc(2026, 10, 4),
    );
  });
  tearDown(() async => f.db.close());
  Future<void> add(
    String id, {
    String? days,
    String frequency = 'daily',
    String status = 'synced',
    String issueEntityType = 'schedule',
    bool invalid = false,
  }) async {
    final now = DateTime.utc(2026, 10, 4);
    await f.db.schedulesDao.upsert(
      SchedulesCompanion.insert(
        id: id,
        pillId: 'pill',
        hour: 8,
        minute: 30,
        frequency: frequency,
        frequencyDays: Value(days),
        createdAt: now,
        updatedAt: now,
        serverId: Value('server-$id'),
        syncStatus: Value(status),
      ),
    );
    await f.db.migrationIssuesDao.record(
      MigrationIssuesCompanion.insert(
        id: 'issue-$id',
        userId: f.context.ownerUserId,
        entityType: issueEntityType,
        entityId: 'server-$id',
        issueCode: 'schedule_timezone_review_required',
        snapshotJson: '{}',
        serverId: Value('issue-$id'),
        createdAt: now,
        updatedAt: now,
      ),
    );
    if (invalid) {
      await f.db.migrationIssuesDao.record(
        MigrationIssuesCompanion.insert(
          id: 'invalid-$id',
          userId: f.context.ownerUserId,
          entityType: 'schedule',
          entityId: id,
          issueCode: 'invalid_schedule_frequency_days',
          snapshotJson: '{}',
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
  }

  /// A server review for a routine this device holds no row for at all.
  Future<void> addUnreachable(String id) async {
    final now = DateTime.utc(2026, 10, 4);
    expect(await f.db.schedulesDao.getByMappedOrLocalId('server-$id'), isNull);
    await f.db.migrationIssuesDao.record(
      MigrationIssuesCompanion.insert(
        id: 'issue-$id',
        userId: f.context.ownerUserId,
        entityType: 'schedules',
        entityId: 'server-$id',
        issueCode: 'schedule_timezone_review_required',
        snapshotJson: '{}',
        serverId: Value('issue-$id'),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<LegacyRoutineReviewPreview> preview() => repo.preview(
    timeZone: 'Europe/Bucharest',
    effectiveFromLocalDate: boundary,
  );

  for (final committed in [false, true]) {
    test(
      'existing preview resumes its exact frozen repair (committed=$committed)',
      () async {
        const issueId = '10000000-0000-4000-8000-000000000020';
        const scheduleId = '10000000-0000-4000-8000-000000000021';
        const pillId = '10000000-0000-4000-8000-000000000022';
        const mutation = '10000000-0000-4000-8000-000000000023';
        await add('frozen');
        await f.db.pillsDao.markSynced('pill', pillId);
        await f.db.schedulesDao.markSynced('frozen', scheduleId);
        await (f.db.update(
          f.db.migrationIssues,
        )..where((r) => r.id.equals('issue-frozen'))).write(
          const MigrationIssuesCompanion(
            id: Value(issueId),
            serverId: Value(issueId),
            entityId: Value(scheduleId),
          ),
        );
        final review = await preview();
        expect(review.items, hasLength(1));
        await f.db.pendingOperationsDao.enqueue(
          PendingOperationsCompanion.insert(
            id: 'frozen-repair',
            userId: f.context.ownerUserId,
            mutationId: mutation,
            component: 'stable',
            operationType: 'schedule.repair',
            contractVersion: 2,
            state: Value(committed ? 'committed' : 'failedRetryable'),
            createdAt: DateTime.utc(2026, 10, 5),
            payloadJson: jsonEncode({
              'entityType': 'schedule',
              'entityLocalId': 'frozen',
              'parentEntityType': 'pill',
              'parentEntityLocalId': 'pill',
              'action': 'repair',
              'reviewedRepair': {
                'version': 1,
                'issueId': issueId,
                'issueRevision': 1,
                'pillServerId': pillId,
                'scheduleServerId': scheduleId,
                'request': {
                  'mutationId': mutation,
                  'baseRevision': '1',
                  'effectiveFromLocalDate': '2026-10-05',
                  'schedule': {
                    'hour': 8,
                    'minute': 30,
                    'frequency': 'daily',
                    'frequencyDays': null,
                    'isActive': true,
                    'timeZone': 'Europe/Bucharest',
                  },
                },
              },
            }),
          ),
        );
        if (committed) {
          await f.db.schedulesDao.markSynced('frozen', scheduleId, revision: 2);
        }
        final result = await repo.apply(review);
        expect(result.isComplete, isTrue);
        expect(result.acceptedCount, 1);
        expect(
          schedules.calls,
          committed ? isEmpty : [('frozen', 'Europe/Bucharest')],
        );
      },
    );
  }

  test(
    'a definitively rejected edit appears in preview; new intent invalidates it',
    () async {
      await add('rejected', status: 'pending', issueEntityType: 'schedules');
      await f.db.pendingOperationsDao.enqueue(
        PendingOperationsCompanion.insert(
          id: 'rejected-operation',
          userId: f.context.ownerUserId,
          mutationId: 'rejected-mutation',
          component: 'stable',
          operationType: 'schedule.update',
          contractVersion: 2,
          state: const Value('conflict'),
          safeErrorCode: const Value('SCHEDULE_TIMEZONE_REVIEW_REQUIRED'),
          payloadJson: jsonEncode({
            'entityType': 'schedule',
            'entityLocalId': 'rejected',
            'parentEntityType': 'pill',
            'parentEntityLocalId': 'pill',
            'action': 'update',
            'data': {
              'hour': 8,
              'minute': 30,
              'frequency': 'daily',
              'frequencyDays': null,
              'isActive': true,
              'timeZone': 'Europe/Bucharest',
            },
          }),
          createdAt: DateTime.utc(2026, 10, 4),
        ),
      );
      final review = await preview();
      expect(review.items.single.schedule.id, 'rejected');
      expect(review.items.single.schedule.hour, 8);
      expect(review.items.single.schedule.minute, 30);
      expect(review.unavailableCount, 0);
      await (f.db.update(
        f.db.pendingOperations,
      )..where((row) => row.id.equals('rejected-operation'))).write(
        const PendingOperationsCompanion(
          safeErrorCode: Value('CONFLICT_REVISION'),
        ),
      );
      expect((await repo.apply(review)).error, isA<ConflictError>());
      expect(schedules.calls, isEmpty);
    },
  );

  test(
    'server-shaped routine issues can be reviewed without admitting pending work',
    () async {
      await add('server-shaped', issueEntityType: 'schedules');
      await add(
        'server-pending',
        issueEntityType: 'schedules',
        status: 'pending',
      );
      final before = await f.db.select(f.db.schedules).get();

      final review = await preview();
      expect(review.items.map((item) => item.schedule.id), ['server-shaped']);
      expect(review.invalidCount, 0);
      expect(review.unavailableCount, 1);
      expect(review.items.single.schedule.hour, 8);
      expect(review.items.single.schedule.minute, 30);
      expect(review.items.single.nextDoseAt, DateTime.utc(2026, 10, 5, 5, 30));
      expect(schedules.calls, isEmpty);

      expect((await repo.apply(review)).isComplete, isTrue);
      expect(schedules.calls, [('server-shaped', 'Europe/Bucharest')]);
      expect(await f.db.select(f.db.schedules).get(), before);
      expect(await f.db.select(f.db.occurrenceEvents).get(), isEmpty);
      expect(
        await f.db.migrationIssuesDao.getUnresolved(f.context.ownerUserId),
        hasLength(2),
      );
    },
  );

  test(
    'a routine this device never received is not offered or counted as skipped',
    () async {
      await add('reachable', issueEntityType: 'schedules');
      await addUnreachable('absent');

      final review = await preview();
      expect(review.items.map((item) => item.schedule.id), ['reachable']);
      expect(review.invalidCount, 0);
      // Counting it would send a person to an individual review that has
      // nothing to open.
      expect(review.unavailableCount, 0);

      // Until queued routine work lands, absence proves nothing and the review
      // has to stay answerable.
      await f.db.pendingOperationsDao.enqueue(
        PendingOperationsCompanion.insert(
          id: 'absent-routine-create',
          userId: f.context.ownerUserId,
          mutationId: '10000000-0000-4000-8000-000000000078',
          component: 'stable',
          operationType: 'schedule.create',
          contractVersion: 2,
          createdAt: DateTime.utc(2026, 10, 5),
          payloadJson: jsonEncode({
            'entityType': 'schedule',
            'entityLocalId': 'server-absent',
            'action': 'create',
          }),
        ),
      );
      expect((await preview()).unavailableCount, 1);
      expect(schedules.calls, isEmpty);
    },
  );

  test(
    'one review retains valid times and excludes invalid or pending work',
    () async {
      await add('daily');
      await add('weekly', frequency: 'weekly', days: '[1]');
      await add('invalid', frequency: 'weekly', days: '[0]', invalid: true);
      await add('pending', status: 'pending');
      final before = await f.db.select(f.db.schedules).get();
      final review = await preview();
      expect(review.items.map((item) => item.schedule.id).toSet(), {
        'daily',
        'weekly',
      });
      expect(review.invalidCount, 1);
      expect(review.unavailableCount, 1);
      expect(review.items.first.nextDoseAt, DateTime.utc(2026, 10, 5, 5, 30));
      expect(schedules.calls, isEmpty);
      final result = await repo.apply(review);
      expect(result.isComplete, isTrue);
      expect(result.acceptedCount, 2);
      expect(
        schedules.calls.map((call) => call.$2),
        everyElement('Europe/Bucharest'),
      );
      expect(await f.db.select(f.db.schedules).get(), before);
      expect(await f.db.select(f.db.occurrenceEvents).get(), isEmpty);
      expect(
        await f.db.migrationIssuesDao.getUnresolved(f.context.ownerUserId),
        hasLength(5),
      );
    },
  );
  test('a changed preview sends nothing', () async {
    await add('daily');
    final review = await preview();
    await (f.db.update(f.db.schedules)..where((row) => row.id.equals('daily')))
        .write(const SchedulesCompanion(hour: Value(9)));
    expect((await repo.apply(review)).error, isA<ConflictError>());
    expect(schedules.calls, isEmpty);
  });
  test(
    'partial retry skips accepted items even after their issue syncs',
    () async {
      await add('first');
      await add('second');
      final review = await preview();
      schedules.failSecond = true;
      expect((await repo.apply(review)).acceptedCount, 1);
      await (f.db.update(
        f.db.migrationIssues,
      )..where((row) => row.id.equals('issue-first'))).write(
        MigrationIssuesCompanion(
          resolutionState: const Value('resolved'),
          revision: const Value(2),
          resolvedAt: Value(DateTime.utc(2026, 10, 4)),
        ),
      );
      schedules.failSecond = false;
      final retried = await repo.apply(review);
      expect(retried.isComplete, isTrue);
      expect(retried.acceptedCount, 2);
      expect(schedules.calls.map((call) => call.$1).toList(), [
        'first',
        'second',
        'second',
      ]);
    },
  );
  test('revoked access cannot submit a retained review', () async {
    await add('daily');
    final review = await preview();
    await f.access.revokeNetwork();
    await expectLater(repo.apply(review), throwsA(isA<Exception>()));
    expect(schedules.calls, isEmpty);
  });
}

class _Schedules implements ScheduleRepository {
  final calls = <(String, String)>[];
  bool failSecond = false;
  @override
  Future<Result<Schedule>> repair({
    required String localId,
    required String issueId,
    required int expectedIssueRevision,
    required int hour,
    required int minute,
    required String frequency,
    required List<int>? frequencyDays,
    required bool isActive,
    required DateTime effectiveFromLocalDate,
    required String timeZone,
  }) async {
    calls.add((localId, timeZone));
    if (failSecond && calls.length == 2) {
      return const Err(NetworkError('fictional'));
    }
    return Ok(
      Schedule(
        id: localId,
        pillId: 'pill',
        hour: hour,
        minute: minute,
        frequency: frequency,
        timeZoneStatus: 'legacy_unknown',
        frequencyDays: null,
        isActive: isActive,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        serverId: null,
        revision: 1,
        syncStatus: 'synced',
        lastSyncAt: null,
        isDeleted: false,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
