import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/sync_service.dart';

class MockDio extends Mock implements Dio {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late MockDio dio;
  late SyncService sut;

  const userId = 'user-1';
  const profileId = 'profile-1';
  const pillId = 'pill-1';
  const scheduleId = 'schedule-1';
  final scheduledAt = DateTime.utc(2026, 6, 11, 8, 0);
  final now = DateTime.utc(2026, 6, 11, 7, 0);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting();
    dio = MockDio();
    sut = SyncService(db: db, dio: dio, isOnline: () async => true);

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

    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: userId,
        email: 'user@example.com',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: profileId,
        userId: userId,
        name: 'Test Profile',
        createdAt: now,
        updatedAt: now,
        syncStatus: const Value('synced'),
        serverId: const Value(profileId),
      ),
    );
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: pillId,
        profileId: profileId,
        name: 'Aspirin',
        createdAt: now,
        updatedAt: now,
        syncStatus: const Value('synced'),
        serverId: const Value(pillId),
      ),
    );
    await db.schedulesDao.upsert(
      SchedulesCompanion.insert(
        id: scheduleId,
        pillId: pillId,
        hour: 8,
        minute: 0,
        frequency: 'daily',
        createdAt: now,
        updatedAt: now,
        syncStatus: const Value('synced'),
        serverId: const Value(scheduleId),
      ),
    );
  });

  tearDown(() async => db.close());

  Future<void> insertPendingLog(
    String id, {
    DateTime? takenAt,
    DateTime? scheduledAtOverride,
  }) async {
    await db.doseLogsDao.upsert(
      DoseLogsCompanion.insert(
        id: id,
        scheduleId: scheduleId,
        scheduledAt: scheduledAtOverride ?? scheduledAt,
        status: 'taken',
        createdAt: now,
        updatedAt: now,
        takenAt: Value(takenAt),
      ),
    );
  }

  Future<DoseLog> getLog(String id) =>
      (db.select(db.doseLogs)..where((t) => t.id.equals(id))).getSingle();

  DioException conflict409({Map<String, dynamic>? body}) => DioException(
    requestOptions: RequestOptions(path: '/logs/$scheduleId'),
    response: Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(path: '/logs/$scheduleId'),
      statusCode: 409,
      data: body,
    ),
    type: DioExceptionType.badResponse,
  );

  group('dose-log 409 resolution', () {
    test('PATCHes local status onto existingId and marks synced', () async {
      await insertPendingLog('log-1');
      when(
        () => dio.post<Map<String, dynamic>>(any(), data: any(named: 'data')),
      ).thenThrow(
        conflict409(
          body: {
            'error': 'Dose log already exists for this schedule and time',
            'existingId': 'srv-existing-1',
          },
        ),
      );
      when(() => dio.patch<void>(any(), data: any(named: 'data'))).thenAnswer(
        (_) async => Response<void>(
          requestOptions: RequestOptions(path: '/logs/srv-existing-1'),
          statusCode: 200,
        ),
      );

      await sut.flushPending();

      final captured = verify(
        () => dio.patch<void>(
          '/logs/srv-existing-1',
          data: captureAny(named: 'data'),
        ),
      ).captured;
      expect((captured.single as Map)['status'], 'taken');

      final log = await getLog('log-1');
      expect(log.syncStatus, 'synced');
      expect(log.serverId, 'srv-existing-1');
    });

    test('falls back to conflict status when 409 lacks existingId', () async {
      await insertPendingLog('log-2');
      when(
        () => dio.post<Map<String, dynamic>>(any(), data: any(named: 'data')),
      ).thenThrow(conflict409(body: {'error': 'Dose log already exists'}));

      await sut.flushPending();

      final log = await getLog('log-2');
      expect(log.syncStatus, 'conflict');
      verifyNever(() => dio.patch<void>(any(), data: any(named: 'data')));
    });

    test('leaves log pending when the conflict PATCH itself fails', () async {
      await insertPendingLog('log-3');
      when(
        () => dio.post<Map<String, dynamic>>(any(), data: any(named: 'data')),
      ).thenThrow(conflict409(body: {'existingId': 'srv-existing-3'}));
      when(() => dio.patch<void>(any(), data: any(named: 'data'))).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/logs/srv-existing-3'),
          type: DioExceptionType.connectionTimeout,
        ),
      );

      await sut.flushPending();

      final log = await getLog('log-3');
      expect(log.syncStatus, 'pending');
    });

    test(
      'loop continues and second log synced; first 409 non-Map body falls back',
      () async {
        final takenAtTime = DateTime.utc(2026, 6, 11, 8, 5);
        await insertPendingLog(
          'log-6',
          scheduledAtOverride: DateTime.utc(2026, 6, 11, 8, 0),
        );
        await insertPendingLog(
          'log-7',
          takenAt: takenAtTime,
          scheduledAtOverride: DateTime.utc(2026, 6, 11, 9, 0),
        );

        var calls = 0;
        Map<String, dynamic>? capturedPostData;
        when(
          () => dio.post<Map<String, dynamic>>(any(), data: any(named: 'data')),
        ).thenAnswer((invocation) async {
          calls++;
          if (calls == 1) {
            // Use a dynamic Response so we can pass a non-Map body (String).
            throw DioException(
              requestOptions: RequestOptions(path: '/logs/x'),
              response: Response<dynamic>(
                requestOptions: RequestOptions(path: '/logs/x'),
                statusCode: 409,
                data: 'oops', // non-Map body — exercises fallback
              ),
              type: DioExceptionType.badResponse,
            );
          }
          capturedPostData =
              invocation.namedArguments[const Symbol('data')]
                  as Map<String, dynamic>;
          return Response<Map<String, dynamic>>(
            requestOptions: RequestOptions(path: '/logs/x'),
            statusCode: 201,
            data: {'id': 'srv-new-2'},
          );
        });

        await sut.flushPending();

        final log6 = await getLog('log-6');
        final log7 = await getLog('log-7');
        expect(
          log6.syncStatus,
          'conflict',
          reason: 'non-Map 409 body should fall back to conflict',
        );
        expect(
          log7.syncStatus,
          'synced',
          reason: 'second log should succeed independently',
        );
        expect(capturedPostData, isNotNull);
        expect(
          capturedPostData!.containsKey('takenAt'),
          isTrue,
          reason: 'POST body should include takenAt when non-null',
        );
        verifyNever(() => dio.patch<void>(any(), data: any(named: 'data')));
      },
    );

    test(
      'non-string existingId falls back to conflict without PATCH',
      () async {
        await insertPendingLog(
          'log-8',
          scheduledAtOverride: DateTime.utc(2026, 6, 11, 10, 0),
        );
        when(
          () => dio.post<Map<String, dynamic>>(any(), data: any(named: 'data')),
        ).thenThrow(conflict409(body: {'existingId': 42})); // int, not String

        await sut.flushPending();

        final log = await getLog('log-8');
        expect(
          log.syncStatus,
          'conflict',
          reason: 'non-String existingId should trigger conflict fallback',
        );
        verifyNever(() => dio.patch<void>(any(), data: any(named: 'data')));
      },
    );

    test(
      'removes pull-created ghost row before claiming its serverId',
      () async {
        // A previous cycle's failed conflict PATCH left log-9 pending, and the
        // same cycle's pull inserted the server row as its own local "ghost"
        // (id == serverId). Resolution must delete the ghost so getByServerId
        // stays single-valued.
        await insertPendingLog('log-9');
        await db.doseLogsDao.upsert(
          DoseLogsCompanion.insert(
            id: 'srv-existing-9',
            scheduleId: scheduleId,
            scheduledAt: DateTime.utc(2026, 6, 11, 11, 0),
            status: 'taken',
            createdAt: now,
            updatedAt: now,
            syncStatus: const Value('synced'),
            serverId: const Value('srv-existing-9'),
          ),
        );
        when(
          () => dio.post<Map<String, dynamic>>(any(), data: any(named: 'data')),
        ).thenThrow(conflict409(body: {'existingId': 'srv-existing-9'}));
        when(() => dio.patch<void>(any(), data: any(named: 'data'))).thenAnswer(
          (_) async => Response<void>(
            requestOptions: RequestOptions(path: '/logs/srv-existing-9'),
            statusCode: 200,
          ),
        );

        await sut.flushPending();

        final log = await getLog('log-9');
        expect(log.syncStatus, 'synced');
        expect(log.serverId, 'srv-existing-9');

        final ghost = await (db.select(
          db.doseLogs,
        )..where((t) => t.id.equals('srv-existing-9'))).getSingleOrNull();
        expect(ghost, isNull, reason: 'ghost row should be deleted');

        // Must not throw (getSingleOrNull would StateError on two matches)
        // and must return the original log.
        final byServerId = await db.doseLogsDao.getByServerId('srv-existing-9');
        expect(byServerId?.id, 'log-9');
      },
    );
  });

  group('countPending', () {
    test(
      'counts actionable journal work once and retains review evidence',
      () async {
        await insertPendingLog('pending-log');
        final states = [
          'queued',
          'sending',
          'failedRetryable',
          'blocked',
          'conflict',
          'committed',
        ];
        for (final state in states) {
          await db
              .into(db.pendingOperations)
              .insert(
                PendingOperationsCompanion.insert(
                  id: 'op-$state',
                  userId: userId,
                  mutationId: 'mutation-$state',
                  component: 'medication',
                  operationType: 'legacy.review',
                  contractVersion: 2,
                  payloadJson: '{"entityLocalId":"pending-log"}',
                  state: Value(state),
                  createdAt: now,
                ),
              );
        }
        final before = await db.select(db.pendingOperations).get();
        expect(await sut.countPending(userId: userId), 3);
        expect(await sut.countPending(), 3);
        expect(await db.select(db.pendingOperations).get(), before);
        expect((await getLog('pending-log')).syncStatus, 'pending');
      },
    );
  });

  group('offline guard', () {
    test('flushPending is a no-op when offline', () async {
      final offlineSut = SyncService(
        db: db,
        dio: dio,
        isOnline: () async => false,
      );
      await insertPendingLog('log-5');

      await offlineSut.flushPending();

      verifyZeroInteractions(dio);
      expect((await getLog('log-5')).syncStatus, 'pending');
    });
  });

  // ── CR-3: Pull must not overwrite locally-pending rows ─────────────────────

  Response<Map<String, dynamic>> profilesResponse(
    List<Map<String, dynamic>> profiles,
  ) => Response<Map<String, dynamic>>(
    requestOptions: RequestOptions(path: '/profiles'),
    statusCode: 200,
    data: {'profiles': profiles},
  );

  Response<Map<String, dynamic>> pillsResponse(
    List<Map<String, dynamic>> pills,
  ) => Response<Map<String, dynamic>>(
    requestOptions: RequestOptions(path: '/profiles/p1/pills'),
    statusCode: 200,
    data: {'pills': pills},
  );

  Response<Map<String, dynamic>> schedulesResponse(
    List<Map<String, dynamic>> scheds,
  ) => Response<Map<String, dynamic>>(
    requestOptions: RequestOptions(path: '/pills/pill-1/schedules'),
    statusCode: 200,
    data: {'schedules': scheds},
  );

  Response<Map<String, dynamic>> logsResponse(
    List<Map<String, dynamic>> logs,
  ) => Response<Map<String, dynamic>>(
    requestOptions: RequestOptions(path: '/profiles/p1/logs'),
    statusCode: 200,
    data: {'logs': logs},
  );

  void stubEmptyPullExcept({
    List<Map<String, dynamic>>? profiles,
    List<Map<String, dynamic>>? pills,
    List<Map<String, dynamic>>? schedules,
    List<Map<String, dynamic>>? logs,
  }) {
    when(() => dio.get<Map<String, dynamic>>('/profiles')).thenAnswer(
      (_) async => profilesResponse(
        profiles ??
            [
              {
                'id': profileId,
                'name': 'Test Profile',
                'avatarEmoji': '👤',
                'isActive': true,
                'createdAt': now.toIso8601String(),
                'updatedAt': now.toIso8601String(),
              },
            ],
      ),
    );
    when(
      () => dio.get<Map<String, dynamic>>('/profiles/$profileId/pills'),
    ).thenAnswer(
      (_) async => pillsResponse(
        pills ??
            [
              {
                'id': pillId,
                'name': 'Aspirin',
                'dosage': null,
                'notes': null,
                'color': null,
                'currentStock': null,
                'lowStockThreshold': null,
                'isPrn': false,
                'createdAt': now.toIso8601String(),
                'updatedAt': now.toIso8601String(),
              },
            ],
      ),
    );
    when(
      () => dio.get<Map<String, dynamic>>('/pills/$pillId/schedules'),
    ).thenAnswer(
      (_) async => schedulesResponse(
        schedules ??
            [
              {
                'id': scheduleId,
                'hour': 8,
                'minute': 0,
                'frequency': 'daily',
                'frequencyDays': null,
                'isActive': true,
                'createdAt': now.toIso8601String(),
                'updatedAt': now.toIso8601String(),
              },
            ],
      ),
    );
    when(
      () => dio.get<Map<String, dynamic>>('/profiles/$profileId/logs'),
    ).thenAnswer((_) async => logsResponse(logs ?? []));
  }

  group('CR-3: pull preserves locally-pending rows', () {
    test('pull does not overwrite a pending dose log', () async {
      await db.doseLogsDao.upsert(
        DoseLogsCompanion.insert(
          id: 'log-local',
          scheduleId: scheduleId,
          scheduledAt: scheduledAt,
          status: 'taken',
          createdAt: now,
          updatedAt: now,
          syncStatus: const Value('pending'),
          serverId: const Value('log-local'),
        ),
      );

      stubEmptyPullExcept(
        logs: [
          {
            'id': 'log-local',
            'scheduleId': scheduleId,
            'scheduledAt': scheduledAt.toIso8601String(),
            'takenAt': null,
            'status': 'missed',
            'note': null,
            'createdAt': now.toIso8601String(),
          },
        ],
      );

      await sut.pullFromServer(userId: userId);

      final log = await getLog('log-local');
      expect(
        log.status,
        'taken',
        reason: 'pending local edit must survive pull',
      );
      expect(log.syncStatus, 'pending');
    });

    test('pull does not overwrite a pending profile edit', () async {
      await db.profilesDao.upsert(
        ProfilesCompanion(
          id: const Value(profileId),
          userId: const Value(userId),
          name: const Value('Edited Locally'),
          createdAt: Value(now),
          updatedAt: Value(now),
          serverId: const Value(profileId),
          syncStatus: const Value('pending'),
        ),
      );

      stubEmptyPullExcept();

      await sut.pullFromServer(userId: userId);

      final profile = await db.profilesDao.getById(profileId);
      expect(
        profile!.name,
        'Edited Locally',
        reason: 'pending profile must survive pull',
      );
    });
  });

  // ── CR-5: frequencyDays round-trip ──────────────────────────────────────────

  group('CR-5: frequencyDays serialization', () {
    test('flush sends frequencyDays as int array, not JSON string', () async {
      await db.schedulesDao.upsert(
        SchedulesCompanion(
          id: const Value('sched-weekly'),
          pillId: const Value(pillId),
          hour: const Value(9),
          minute: const Value(0),
          frequency: const Value('weekly'),
          frequencyDays: const Value('[1,3,5]'),
          createdAt: Value(now),
          updatedAt: Value(now),
          syncStatus: const Value('pending'),
          serverId: const Value('sched-weekly'),
        ),
      );

      when(() => dio.patch<void>(any(), data: any(named: 'data'))).thenAnswer(
        (_) async => Response<void>(
          requestOptions: RequestOptions(
            path: '/pills/pill-1/schedules/sched-weekly',
          ),
          statusCode: 200,
        ),
      );

      await sut.flushPending();

      final captured = verify(
        () => dio.patch<void>(
          '/pills/$pillId/schedules/sched-weekly',
          data: captureAny(named: 'data'),
        ),
      ).captured;
      final body = captured.single as Map<String, dynamic>;
      expect(body['frequencyDays'], [
        1,
        3,
        5,
      ], reason: 'must send int array, not JSON string');
    });

    test('pull stores server int array as JSON string', () async {
      stubEmptyPullExcept(
        schedules: [
          {
            'id': scheduleId,
            'hour': 8,
            'minute': 0,
            'frequency': 'weekly',
            'frequencyDays': [2, 4],
            'isActive': true,
            'createdAt': now.toIso8601String(),
            'updatedAt': now.toIso8601String(),
          },
        ],
      );

      await sut.pullFromServer(userId: userId);

      final sched = await db.schedulesDao.getById(scheduleId);
      expect(
        sched!.frequencyDays,
        jsonEncode([2, 4]),
        reason: 'server int array must be stored as JSON string',
      );
    });
  });

  // ── CR-6: un-take must not be resurrected by pull ──────────────────────────

  group('CR-6: soft-deleted dose logs survive pull', () {
    test('pull does not resurrect a locally-deleted dose log', () async {
      await db.doseLogsDao.upsert(
        DoseLogsCompanion.insert(
          id: 'log-deleted',
          scheduleId: scheduleId,
          scheduledAt: scheduledAt,
          status: 'taken',
          createdAt: now,
          updatedAt: now,
          syncStatus: const Value('pending'),
          serverId: const Value('log-deleted'),
          isDeleted: const Value(true),
        ),
      );

      stubEmptyPullExcept(
        logs: [
          {
            'id': 'log-deleted',
            'scheduleId': scheduleId,
            'scheduledAt': scheduledAt.toIso8601String(),
            'takenAt': now.toIso8601String(),
            'status': 'taken',
            'note': null,
            'createdAt': now.toIso8601String(),
          },
        ],
      );

      await sut.pullFromServer(userId: userId);

      final log = await getLog('log-deleted');
      expect(
        log.isDeleted,
        true,
        reason: 'locally-deleted log must not be resurrected',
      );
    });

    test('flush DELETEs soft-deleted log on server', () async {
      await db.doseLogsDao.upsert(
        DoseLogsCompanion.insert(
          id: 'log-untake',
          scheduleId: scheduleId,
          scheduledAt: scheduledAt,
          status: 'taken',
          createdAt: now,
          updatedAt: now,
          syncStatus: const Value('pending'),
          serverId: const Value('srv-untake'),
          isDeleted: const Value(true),
        ),
      );

      when(() => dio.delete<void>(any())).thenAnswer(
        (_) async => Response<void>(
          requestOptions: RequestOptions(path: '/logs/srv-untake'),
          statusCode: 204,
        ),
      );

      await sut.flushPending();

      verify(() => dio.delete<void>('/logs/srv-untake')).called(1);

      final log = await getLog('log-untake');
      expect(log.syncStatus, 'synced');
    });
  });

  // ── H-11: DELETE 404 treated as success ────────────────────────────────────

  group('H-11: DELETE 404 as success', () {
    test('profile DELETE 404 marks synced', () async {
      await db.profilesDao.upsert(
        ProfilesCompanion(
          id: const Value('prof-del'),
          userId: const Value(userId),
          name: const Value('Deleted Profile'),
          createdAt: Value(now),
          updatedAt: Value(now),
          serverId: const Value('prof-del'),
          syncStatus: const Value('pending'),
          isDeleted: const Value(true),
        ),
      );

      when(() => dio.delete<void>(any())).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/profiles/prof-del'),
          response: Response<void>(
            requestOptions: RequestOptions(path: '/profiles/prof-del'),
            statusCode: 404,
          ),
          type: DioExceptionType.badResponse,
        ),
      );

      await sut.flushPending();

      final profile = await db.profilesDao.getById('prof-del');
      expect(
        profile!.syncStatus,
        'synced',
        reason: '404 on DELETE means already gone server-side',
      );
    });
  });

  // ── M-14/M-15: Delta sync with watermarks and tombstones ─────────────────

  Response<Map<String, dynamic>> deltaLogsResponse({
    required List<Map<String, dynamic>> logs,
    required String serverTime,
    String? nextCursor,
  }) => Response<Map<String, dynamic>>(
    requestOptions: RequestOptions(path: '/profiles/$profileId/logs'),
    statusCode: 200,
    data: {'logs': logs, 'serverTime': serverTime, 'nextCursor': nextCursor},
  );

  Map<String, dynamic> serverLog(
    String id, {
    String? deletedAt,
    String? updatedAt,
  }) => {
    'id': id,
    'scheduleId': scheduleId,
    'scheduledAt': scheduledAt.toIso8601String(),
    'takenAt': null,
    'status': 'taken',
    'note': null,
    'createdAt': now.toIso8601String(),
    'updatedAt': updatedAt ?? now.toIso8601String(),
    'deletedAt': ?deletedAt,
  };

  void stubProfilePillSchedulePull() {
    when(() => dio.get<Map<String, dynamic>>('/profiles')).thenAnswer(
      (_) async => profilesResponse([
        {
          'id': profileId,
          'name': 'Test Profile',
          'avatarEmoji': '👤',
          'isActive': true,
          'createdAt': now.toIso8601String(),
          'updatedAt': now.toIso8601String(),
        },
      ]),
    );
    when(
      () => dio.get<Map<String, dynamic>>('/profiles/$profileId/pills'),
    ).thenAnswer(
      (_) async => pillsResponse([
        {
          'id': pillId,
          'name': 'Aspirin',
          'dosage': null,
          'notes': null,
          'color': null,
          'currentStock': null,
          'lowStockThreshold': null,
          'isPrn': false,
          'createdAt': now.toIso8601String(),
          'updatedAt': now.toIso8601String(),
        },
      ]),
    );
    when(
      () => dio.get<Map<String, dynamic>>('/pills/$pillId/schedules'),
    ).thenAnswer(
      (_) async => schedulesResponse([
        {
          'id': scheduleId,
          'hour': 8,
          'minute': 0,
          'frequency': 'daily',
          'frequencyDays': null,
          'isActive': true,
          'createdAt': now.toIso8601String(),
          'updatedAt': now.toIso8601String(),
        },
      ]),
    );
  }

  group('M-14/M-15: delta sync protocol', () {
    test(
      'first sync (no watermark) omits since param and stores watermark',
      () async {
        stubProfilePillSchedulePull();

        final serverTime = DateTime.utc(2026, 6, 15, 12, 0).toIso8601String();
        when(
          () => dio.get<Map<String, dynamic>>(
            '/profiles/$profileId/logs',
            queryParameters: any(named: 'queryParameters'),
          ),
        ).thenAnswer(
          (_) async => deltaLogsResponse(
            logs: [serverLog('srv-log-1')],
            serverTime: serverTime,
          ),
        );

        await sut.pullFromServer(userId: userId);

        final prefs = await SharedPreferences.getInstance();
        final watermark = prefs.getString('sync_watermark_doseLogs_$profileId');
        expect(
          watermark,
          isNotNull,
          reason: 'watermark should be stored after first sync',
        );

        // Verify the call did NOT include 'since' param
        final captured = verify(
          () => dio.get<Map<String, dynamic>>(
            '/profiles/$profileId/logs',
            queryParameters: captureAny(named: 'queryParameters'),
          ),
        ).captured;
        final params = captured.first as Map<String, dynamic>;
        expect(
          params.containsKey('since'),
          isFalse,
          reason: 'first sync should not send since',
        );

        // Verify watermark is server time minus 2 seconds lag
        final wmDate = DateTime.parse(watermark!);
        final expectedWm = DateTime.parse(
          serverTime,
        ).subtract(const Duration(seconds: 2));
        expect(wmDate, expectedWm);
      },
    );

    test('subsequent sync sends since param from stored watermark', () async {
      final storedWatermark = DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 1))
          .toIso8601String();
      SharedPreferences.setMockInitialValues({
        'sync_watermark_doseLogs_$profileId': storedWatermark,
      });

      stubProfilePillSchedulePull();

      final serverTime = DateTime.now().toUtc().toIso8601String();
      when(
        () => dio.get<Map<String, dynamic>>(
          '/profiles/$profileId/logs',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer(
        (_) async => deltaLogsResponse(logs: [], serverTime: serverTime),
      );

      await sut.pullFromServer(userId: userId);

      final captured = verify(
        () => dio.get<Map<String, dynamic>>(
          '/profiles/$profileId/logs',
          queryParameters: captureAny(named: 'queryParameters'),
        ),
      ).captured;
      final params = captured.first as Map<String, dynamic>;
      expect(
        params['since'],
        storedWatermark,
        reason: 'delta sync must include stored watermark as since',
      );
    });

    test('server tombstone soft-deletes synced local row', () async {
      await db.doseLogsDao.upsert(
        DoseLogsCompanion.insert(
          id: 'srv-del-1',
          scheduleId: scheduleId,
          scheduledAt: scheduledAt,
          status: 'taken',
          createdAt: now,
          updatedAt: now,
          syncStatus: const Value('synced'),
          serverId: const Value('srv-del-1'),
        ),
      );

      stubProfilePillSchedulePull();
      when(
        () => dio.get<Map<String, dynamic>>(
          '/profiles/$profileId/logs',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer(
        (_) async => deltaLogsResponse(
          logs: [
            serverLog(
              'srv-del-1',
              deletedAt: DateTime.utc(2026, 6, 15).toIso8601String(),
              updatedAt: DateTime.utc(2026, 6, 15, 1, 0).toIso8601String(),
            ),
          ],
          serverTime: DateTime.utc(2026, 6, 15, 12, 0).toIso8601String(),
        ),
      );

      await sut.pullFromServer(userId: userId);

      final log = await getLog('srv-del-1');
      expect(
        log.isDeleted,
        true,
        reason: 'server tombstone must soft-delete local row',
      );
      expect(log.syncStatus, 'synced');
    });

    test('server tombstone does NOT overwrite locally-pending row', () async {
      await db.doseLogsDao.upsert(
        DoseLogsCompanion.insert(
          id: 'srv-pending-1',
          scheduleId: scheduleId,
          scheduledAt: scheduledAt,
          status: 'taken',
          createdAt: now,
          updatedAt: now,
          syncStatus: const Value('pending'),
          serverId: const Value('srv-pending-1'),
        ),
      );

      stubProfilePillSchedulePull();
      when(
        () => dio.get<Map<String, dynamic>>(
          '/profiles/$profileId/logs',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer(
        (_) async => deltaLogsResponse(
          logs: [
            serverLog(
              'srv-pending-1',
              deletedAt: DateTime.utc(2026, 6, 15).toIso8601String(),
              updatedAt: DateTime.utc(2026, 6, 15, 1, 0).toIso8601String(),
            ),
          ],
          serverTime: DateTime.utc(2026, 6, 15, 12, 0).toIso8601String(),
        ),
      );

      await sut.pullFromServer(userId: userId);

      final log = await getLog('srv-pending-1');
      expect(
        log.isDeleted,
        false,
        reason: 'tombstone must not overwrite pending local edit',
      );
      expect(log.syncStatus, 'pending');
    });

    test('keyset cursor pagination follows nextCursor across pages', () async {
      stubProfilePillSchedulePull();

      final serverTime = DateTime.utc(2026, 6, 15, 12, 0).toIso8601String();
      var callCount = 0;
      when(
        () => dio.get<Map<String, dynamic>>(
          '/profiles/$profileId/logs',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) {
          return deltaLogsResponse(
            logs: [serverLog('srv-p1')],
            serverTime: serverTime,
            nextCursor: '2026-06-15T10:00:00.000Z_srv-p1',
          );
        }
        return deltaLogsResponse(
          logs: [
            serverLog(
              'srv-p2',
              updatedAt: DateTime.utc(2026, 6, 15, 11, 0).toIso8601String(),
            ),
          ],
          serverTime: serverTime,
        );
      });

      await sut.pullFromServer(userId: userId);

      expect(callCount, 2, reason: 'should fetch 2 pages via cursor');

      // Verify second call included cursor param
      final captured = verify(
        () => dio.get<Map<String, dynamic>>(
          '/profiles/$profileId/logs',
          queryParameters: captureAny(named: 'queryParameters'),
        ),
      ).captured;
      final page2Params = captured[1] as Map<String, dynamic>;
      expect(
        page2Params['cursor'],
        '2026-06-15T10:00:00.000Z_srv-p1',
        reason: 'page 2 must send cursor from page 1',
      );

      // Both logs should exist locally
      final log1 = await (db.select(
        db.doseLogs,
      )..where((t) => t.id.equals('srv-p1'))).getSingleOrNull();
      final log2 = await (db.select(
        db.doseLogs,
      )..where((t) => t.id.equals('srv-p2'))).getSingleOrNull();
      expect(log1, isNotNull);
      expect(log2, isNotNull);
    });

    test(
      'watermark not advanced when serverTime is missing (old server)',
      () async {
        stubProfilePillSchedulePull();

        when(
          () => dio.get<Map<String, dynamic>>(
            '/profiles/$profileId/logs',
            queryParameters: any(named: 'queryParameters'),
          ),
        ).thenAnswer(
          (_) async => Response<Map<String, dynamic>>(
            requestOptions: RequestOptions(path: '/profiles/$profileId/logs'),
            statusCode: 200,
            data: {
              'logs': [serverLog('srv-old')],
            },
          ),
        );

        await sut.pullFromServer(userId: userId);

        final prefs = await SharedPreferences.getInstance();
        final watermark = prefs.getString('sync_watermark_doseLogs_$profileId');
        expect(
          watermark,
          isNull,
          reason:
              'watermark must not advance when serverTime is absent (backward compat)',
        );
      },
    );

    test(
      'stale watermark (>88 days) triggers full pull without since',
      () async {
        final staleDate = DateTime.now()
            .subtract(const Duration(days: 89))
            .toUtc()
            .toIso8601String();
        SharedPreferences.setMockInitialValues({
          'sync_watermark_doseLogs_$profileId': staleDate,
        });

        stubProfilePillSchedulePull();

        final serverTime = DateTime.utc(2026, 6, 15, 12, 0).toIso8601String();
        when(
          () => dio.get<Map<String, dynamic>>(
            '/profiles/$profileId/logs',
            queryParameters: any(named: 'queryParameters'),
          ),
        ).thenAnswer(
          (_) async => deltaLogsResponse(logs: [], serverTime: serverTime),
        );

        await sut.pullFromServer(userId: userId);

        final captured = verify(
          () => dio.get<Map<String, dynamic>>(
            '/profiles/$profileId/logs',
            queryParameters: captureAny(named: 'queryParameters'),
          ),
        ).captured;
        final params = captured.first as Map<String, dynamic>;
        expect(
          params.containsKey('since'),
          isFalse,
          reason: 'stale watermark must be cleared, triggering full pull',
        );
      },
    );
  });
}
