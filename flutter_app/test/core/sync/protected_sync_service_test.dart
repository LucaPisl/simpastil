import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/core/auth/protected_credentials_repository.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/core/sync/sync_service.dart';
import 'package:simpastil/core/sync/component_sync_pull_adapter.dart';
import 'package:simpastil/core/sync/component_sync_merger.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/sync/adapters/profiles_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_stable_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import '../../helpers/held_provider_read.dart';

class _Secrets implements CredentialSlotStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _Transport implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == '/capabilities') {
      return ResponseBody.fromString(
        '{}',
        404,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'profiles': [
          {
            'id': 'fictional-person',
            'name': 'Fictional person',
            'avatarEmoji': '🙂',
            'createdAt': '2026-09-30T00:00:00Z',
            'updatedAt': '2026-09-30T00:00:00Z',
            'isActive': true,
          },
        ],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tz_data.initializeTimeZones);
  test(
    'bridge v4 publishes reviewed routines to Today without replacing recorded care',
    () async {
      final fixture = await _fixture();
      final db = fixture.db;
      await _seedReviewedRoutine(db);
      await db.syncStateDao.saveState(
        SyncComponentStatesCompanion.insert(
          userId: 'a',
          component: 'medicationBridge',
          contractVersion: 3,
          lastCompletedCursor: const Value('1'),
          lastFullSuccessAt: Value(DateTime.now().toUtc()),
          currentState: const Value('idle'),
        ),
      );
      final now = DateTime.utc(2026, 10, 5, 12);
      await db.medicationLedgerDao.upsertOccurrence(
        MedicationOccurrencesCompanion.insert(
          id: 'retained-recording',
          userId: 'a',
          pillId: const Value('review-local-pill'),
          scheduleId: const Value('review-local-schedule'),
          occurrenceKey: 'retained-recording-key',
          source: 'scheduled',
          plannedLocalDate: '2026-10-04',
          timeZone: 'Europe/Bucharest',
          scheduleSnapshotJson: '{}',
          provenance: 'exact',
          state: const Value('taken'),
          stateVersion: const Value(1),
          createdAt: now,
          updatedAt: now,
        ),
      );
      final recorded = await db.medicationLedgerDao.getOccurrenceById(
        'retained-recording',
      );
      final transport = _historicalBridgeTransport(
        _reviewedRoutineOccurrence(),
        supportsAncestors: true,
        supportsOccurrences: true,
        change: _reviewedRoutineChange(),
      );
      addTearDown(() => transport.dio.close(force: true));
      final service = SyncService(
        db: db,
        dio: transport.dio,
        isOnline: () async => true,
        writeScope: fixture.scope,
      );
      expect(await service.pullFromServer(userId: 'a'), isTrue);
      expect(transport.contracts, [4]);
      expect(transport.checkpoints, ['0']);
      final day = await CareDayRepository(
        database: db,
        access: fixture.access,
        context: await fixture.scope.captureContext(),
        clock: () => now,
      ).load(localDate: '2026-10-05');
      expect(day.remainingCount, 1);
      final entry = day.entries.single;
      expect(entry.pill.id, 'review-local-pill');
      expect(entry.person.id, 'review-local-person');
      expect(entry.snapshot.profileId, 'review-local-person');
      expect(entry.occurrence.scheduleId, 'review-local-schedule');
      expect(entry.occurrence.scheduleRevision, 2);
      expect(entry.occurrence.timeZone, 'Europe/Bucharest');
      expect(
        entry.occurrence.plannedAt?.toUtc(),
        DateTime.utc(2026, 10, 5, 5, 30),
      );
      final occurrences = await db.select(db.medicationOccurrences).get();
      expect(await service.pullFromServer(userId: 'a'), isTrue);
      expect(transport.checkpoints, ['0', '1']);
      expect(await db.select(db.medicationOccurrences).get(), occurrences);
      expect(
        await db.medicationLedgerDao.getOccurrenceById('retained-recording'),
        recorded,
      );
      expect(await db.select(db.occurrenceEvents).get(), isEmpty);
      // Fictional care already recorded on this phone is not server plan state.
      await (db.update(
        db.medicationOccurrences,
      )..where((row) => row.id.equals(entry.occurrence.id))).write(
        const MedicationOccurrencesCompanion(
          state: Value('taken'),
          stateVersion: Value(1),
        ),
      );
      await db.medicationLedgerDao.appendOccurrenceEvent(
        OccurrenceEventsCompanion.insert(
          id: 'fictional-recorded-head',
          userId: 'a',
          occurrenceId: entry.occurrence.id,
          commandId: 'fictional-take',
          action: 'take',
          fromState: 'pending',
          toState: 'taken',
          origin: 'native',
          baseVersion: 0,
          resultVersion: 1,
          recordedAt: now,
        ),
      );
      final taken = await db.medicationLedgerDao.getOccurrenceById(
        entry.occurrence.id,
      );
      final events = await db.select(db.occurrenceEvents).get();
      final retired = _reviewedRoutineChange();
      (retired['payload'] as Map<String, dynamic>)['supersededAt'] =
          '2026-10-05T13:00:00Z';
      await fixture.scope.write(
        () => ComponentSyncMerger(db, writeScope: fixture.scope).merge(
          'a',
          SyncComponent.medicationBridge,
          [retired],
          contractVersion: 4,
        ),
      );
      expect(
        await db.medicationLedgerDao.getOccurrenceById(entry.occurrence.id),
        taken,
      );
      expect(await db.select(db.occurrenceEvents).get(), events);
    },
  );
  for (final invalidParent in ['missing', 'wrong owner']) {
    test(
      'bridge v4 rejects $invalidParent parents without advancing care',
      () async {
        final fixture = await _fixture();
        final db = fixture.db;
        if (invalidParent != 'missing') {
          await _seedReviewedRoutine(db, owner: 'b');
        }
        final transport = _historicalBridgeTransport(
          _reviewedRoutineOccurrence(),
          supportsAncestors: true,
          supportsOccurrences: true,
          change: _reviewedRoutineChange(),
        );
        addTearDown(() => transport.dio.close(force: true));
        final service = SyncService(
          db: db,
          dio: transport.dio,
          isOnline: () async => true,
          writeScope: fixture.scope,
        );
        await expectLater(
          service.pullFromServer(userId: 'a'),
          throwsA(isA<WorkspaceAccessFailure>()),
        );
        expect(transport.contracts, [4]);
        expect(await db.select(db.medicationOccurrences).get(), isEmpty);
        expect(
          (await db.syncStateDao.getState(
            'a',
            'medicationBridge',
          ))?.lastCompletedCursor,
          isNull,
        );
        expect(
          await (db.select(
            db.workspaceSyncCheckpoints,
          )..where((row) => row.channel.equals('carePull'))).get(),
          isEmpty,
        );
      },
    );
  }
  test('bridge v3 rejects occurrence payloads without negotiated v4', () async {
    final fixture = await _fixture();
    await _seedReviewedRoutine(fixture.db);
    final transport = _historicalBridgeTransport(
      _reviewedRoutineOccurrence(),
      supportsAncestors: true,
      change: _reviewedRoutineChange(),
    );
    addTearDown(() => transport.dio.close(force: true));
    final service = SyncService(
      db: fixture.db,
      dio: transport.dio,
      isOnline: () async => true,
      writeScope: fixture.scope,
    );
    await service.pullFromServer(userId: 'a');
    expect(service.lastPullOutcome?.status, SyncRunStatus.partiallySynced);
    expect(
      service.lastPullOutcome?.forStage('medicationBridge')?.status,
      SyncComponentStatus.failed,
    );
    expect(transport.contracts, [3]);
    expect(
      await fixture.db.select(fixture.db.medicationOccurrences).get(),
      isEmpty,
    );
    expect(
      (await fixture.db.syncStateDao.getState(
        'a',
        'medicationBridge',
      ))?.lastCompletedCursor,
      isNull,
    );
    expect(
      await (fixture.db.select(
        fixture.db.workspaceSyncCheckpoints,
      )..where((row) => row.channel.equals('carePull'))).get(),
      isEmpty,
    );
  });
  test('bridge v4 retains verified historical ancestor recovery', () async {
    final fixture = await _fixture();
    final payload = _historicalBridgeDose();
    _addHistoricalAncestors(payload);
    final transport = _historicalBridgeTransport(
      payload,
      supportsAncestors: true,
      supportsOccurrences: true,
    );
    addTearDown(() => transport.dio.close(force: true));
    expect(
      await SyncService(
        db: fixture.db,
        dio: transport.dio,
        isOnline: () async => true,
        writeScope: fixture.scope,
      ).pullFromServer(userId: 'a'),
      isTrue,
    );
    expect(transport.contracts, [4]);
    final schedule = await fixture.db.schedulesDao.getByServerId(
      payload['scheduleId'] as String,
    );
    expect(schedule?.isActive, isFalse);
    expect(await fixture.db.select(fixture.db.doseLogs).get(), hasLength(1));
  });
  test(
    'only a complete protected care pull publishes workspace freshness',
    () async {
      final fixture = await _fixture();
      SharedPreferences.setMockInitialValues({});
      final db = fixture.db;
      final now = DateTime.now().toUtc();
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: 'fictional-pull-person',
          userId: 'a',
          name: 'Fictional pull person',
          createdAt: now,
          updatedAt: now,
          syncStatus: const Value('synced'),
        ),
      );
      var failMedication = false;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/capabilities') {
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  data: {
                    'apiNamespace': 'v1',
                    'contracts': {
                      'componentSync': 2,
                      'legacySplitReconciliation': 1,
                      'medicationBridgeCommands': 1,
                      'medicationBridgeSync': 1,
                      'medicationCommands': 2,
                    },
                    'medicationLedgerActive': true,
                    'minimumClientBuild': 1,
                    'serverRelease': 'fictional',
                  },
                ),
              );
              return;
            }
            final component = options.path.split('/').last;
            if (failMedication && component == 'medication') {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                ),
              );
              return;
            }
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                data: {
                  'component': component,
                  'contractVersion': 2,
                  'afterSequence':
                      options.queryParameters['afterSequence'] ?? '0',
                  'throughSequence': '0',
                  'hasMore': false,
                  'nextCursor': null,
                  'items': <Object>[],
                },
              ),
            );
          },
        ),
      );
      final service = SyncService(
        db: db,
        dio: dio,
        isOnline: () async => true,
        writeScope: fixture.scope,
      );
      expect(await service.pullFromServer(userId: 'a'), isTrue);
      final first = await (db.select(
        db.workspaceSyncCheckpoints,
      )..where((c) => c.channel.equals('carePull'))).get();
      expect(first, hasLength(1));
      expect(first.single.workspaceId, await fixture.scope.workspaceId);
      expect(first.single.profileId, 'fictional-pull-person');
      // A fresh sign-in has nobody selected; the first completed pull selects
      // the pulled person so their medications are not hidden.
      final workspace = await fixture.access.workspaces.byId(
        await fixture.scope.workspaceId,
      );
      expect(workspace!.selectedProfileId, 'fictional-pull-person');
      expect(workspace.viewEveryone, isFalse);
      await service.flushPending(userId: 'a');
      expect(
        await (db.select(
          db.workspaceSyncCheckpoints,
        )..where((c) => c.channel.equals('carePull'))).get(),
        first,
        reason: 'Push success is not a new care pull',
      );
      failMedication = true;
      await service.pullFromServer(userId: 'a');
      expect(
        await (db.select(
          db.workspaceSyncCheckpoints,
        )..where((c) => c.channel.equals('carePull'))).get(),
        first,
        reason: 'Partial pulls retain the last completed care update',
      );
    },
  );
  test(
    'revocation after response validation refuses the later care write',
    () async {
      const endpoint = 'https://fictional.test/care';
      SharedPreferences.setMockInitialValues({'server_url': endpoint});
      final db = AppDatabase.forTesting();
      final access = WorkspaceAccessRepository(db);
      await access.configureEndpoint(endpoint);
      final credentials = ProtectedCredentialsRepository(
        access: access,
        store: _Secrets(),
      );
      final slot = await credentials.stage(
        CredentialBundle(
          ownerId: 'a',
          endpoint: endpoint,
          accessToken: 'fictional-access',
          refreshToken: 'fictional-refresh',
          expiresAtMillis: DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        ),
      );
      await credentials.activate(
        credentialId: slot,
        expectedTransition: await access.revokeNetwork(),
        sessionGeneration: 1,
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          protectedCredentialsRepositoryProvider.overrideWithValue(credentials),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      await container.readHeld(connectionDeviceStateProvider);
      final client = container.read(apiClientProvider);
      client.dio.httpClientAdapter = _Transport();
      var boundaryReached = false;
      SyncComponentState? beforeRevoke;
      client.dio.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) async {
            if (response.requestOptions.path == '/profiles') {
              boundaryReached = true;
              beforeRevoke = await db.syncStateDao.getState('a', 'stable');
              await access.revokeNetwork();
            }
            handler.next(response);
          },
        ),
      );
      final service = SyncService(
        db: db,
        dio: client.dio,
        isOnline: () async => true,
        writeScope: SyncWriteScope(
          access: access,
          capability: client.networkCapability,
        ),
      );
      await expectLater(
        service.pullFromServer(userId: 'a'),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(boundaryReached, isTrue);
      expect(await access.contextForOwner('a'), isNull);
      expect(await db.profilesDao.getById('fictional-person'), isNull);
      expect(await db.syncStateDao.getState('a', 'stable'), beforeRevoke);
    },
  );

  test(
    'revocation during traversal preserves staging and its old checkpoint',
    () async {
      final fixture = await _fixture();
      final db = fixture.db;
      await db.syncStateDao.saveState(
        SyncComponentStatesCompanion.insert(
          userId: 'a',
          component: 'stable',
          contractVersion: 2,
          lastCompletedCursor: const Value('5'),
          lastFullSuccessAt: Value(DateTime.now().toUtc()),
        ),
      );
      final dio = Dio();
      var calls = 0;
      var mergeCalls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            calls++;
            if (calls == 2) await fixture.access.revokeNetwork();
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                data: {
                  'component': 'stable',
                  'contractVersion': 2,
                  'afterSequence': calls == 1 ? '5' : '6',
                  'throughSequence': '7',
                  'hasMore': calls == 1,
                  'nextCursor': calls == 1 ? 'page-2' : null,
                  'items': [
                    {
                      'serverSequence': calls == 1 ? '6' : '7',
                      'change': {
                        'entityType': 'profile',
                        'entityId': 'fictional-person',
                        'payload': <String, dynamic>{},
                      },
                    },
                  ],
                },
              ),
            );
          },
        ),
      );
      await expectLater(
        ComponentSyncPullAdapter(
          db: db,
          dio: dio,
          writeScope: fixture.scope,
        ).pull(
          userId: 'a',
          component: SyncComponent.stable,
          contractVersion: 2,
          merge: (_, _) async {
            mergeCalls++;
          },
        ),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(calls, 2);
      expect(mergeCalls, 0);
      expect(
        (await db.syncStateDao.getState('a', 'stable'))!.lastCompletedCursor,
        '5',
      );
      final retained = await db.select(db.syncStagingRuns).get();
      expect(retained, hasLength(1));
      expect(retained.single.pageCount, 1);
      expect(
        await db.syncStateDao.getStagedItems(retained.single.id),
        hasLength(1),
      );
    },
  );

  test('medication reply after revoke cannot publish its receipt', () async {
    final fixture = await _fixture();
    final db = fixture.db;
    final now = DateTime.now().toUtc();
    await db.medicationLedgerDao.upsertOccurrence(
      MedicationOccurrencesCompanion.insert(
        id: 'fictional-occurrence',
        userId: 'a',
        serverId: const Value('fictional-server-occurrence'),
        occurrenceKey: 'fictional-key',
        source: 'prn',
        plannedLocalDate: '2026-09-30',
        timeZone: 'Europe/Bucharest',
        scheduleSnapshotJson: '{}',
        provenance: 'exact',
        createdAt: now,
        updatedAt: now,
      ),
    );
    final recorded = await PendingOperationRepository(db).record(
      operation: const PendingOperationDraft(
        userId: 'a',
        mutationId: 'fictional-command',
        component: 'medication',
        operationType: 'medication.command',
        entityType: 'occurrence',
        entityLocalId: 'fictional-occurrence',
        payload: {
          'command': {
            'commandId': 'fictional-command',
            'occurrenceId': 'fictional-occurrence',
            'occurrenceKey': 'fictional-key',
          },
        },
      ),
      applyProjection: () async {},
    );
    final operation = (await db.pendingOperationsDao.getById(
      recorded.operationId,
    ))!;
    final dio = Dio();
    var sent = false;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          sent = true;
          expect(
            (await db.pendingOperationsDao.getById(operation.id))!.state,
            'sending',
          );
          await fixture.access.revokeNetwork();
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              data: {'commandId': 'fictional-command'},
            ),
          );
        },
      ),
    );
    await expectLater(
      V2MedicationSyncAdapter(
        db: db,
        dio: dio,
        writeScope: fixture.scope,
      ).send(operation),
      throwsA(isA<WorkspaceAccessFailure>()),
    );
    expect(sent, isTrue);
    expect(
      (await db.pendingOperationsDao.getById(operation.id))!.state,
      'sending',
    );
    expect(
      (await db.medicationLedgerDao.getOccurrenceById(
        'fictional-occurrence',
      ))!.state,
      'pending',
    );
  });

  test(
    'stable reply after revoke leaves both mapping and queue uncommitted',
    () async {
      final fixture = await _fixture();
      final db = fixture.db;
      final operationId = await _profileOperation(db);
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            await fixture.access.revokeNetwork();
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                data: {'id': 'fictional-person', 'revision': 1},
              ),
            );
          },
        ),
      );
      await expectLater(
        ProfilesSyncAdapter(db).flush(
          'a',
          V2StableAdapter(db: db, dio: dio, writeScope: fixture.scope),
        ),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(
        (await db.profilesDao.getById('fictional-person'))!.serverId,
        isNull,
      );
      expect(
        (await db.pendingOperationsDao.getById(operationId))!.state,
        'sending',
      );
    },
  );

  test(
    'projection failure rolls back an otherwise matching stable receipt',
    () async {
      final fixture = await _fixture();
      final db = fixture.db;
      final operationId = await _profileOperation(db);
      await db.customStatement(
        "CREATE TRIGGER refuse_mapping BEFORE UPDATE OF server_id ON profiles WHEN NEW.server_id IS NOT NULL BEGIN SELECT RAISE(ABORT, 'fictional mapping failure'); END",
      );
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                data: {'id': 'fictional-person', 'revision': 1},
              ),
            );
          },
        ),
      );
      await expectLater(
        ProfilesSyncAdapter(db).flush(
          'a',
          V2StableAdapter(db: db, dio: dio, writeScope: fixture.scope),
        ),
        throwsA(anything),
      );
      expect(
        (await db.profilesDao.getById('fictional-person'))!.serverId,
        isNull,
      );
      expect(
        (await db.pendingOperationsDao.getById(operationId))!.state,
        'sending',
      );
    },
  );

  test(
    'foreign owner identity collision rolls back component publication',
    () async {
      final fixture = await _fixture();
      final db = fixture.db;
      final now = DateTime.now().toUtc();
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: 'b',
          email: 'fictional-b@example.invalid',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: 'foreign-person',
          userId: 'b',
          name: 'Retained B',
          createdAt: now,
          updatedAt: now,
          serverId: const Value('collision'),
          syncStatus: const Value('synced'),
        ),
      );
      await expectLater(
        fixture.scope.write(
          () => ComponentSyncMerger(db, writeScope: fixture.scope).merge(
            'a',
            SyncComponent.stable,
            [
              {
                'component': 'stable',
                'payload': {
                  'kind': 'profile',
                  'id': 'collision',
                  'revision': '2',
                  'name': 'Incoming A',
                  'avatarEmoji': '🙂',
                  'isActive': true,
                  'createdAt': now.toIso8601String(),
                  'updatedAt': now.toIso8601String(),
                },
              },
            ],
          ),
        ),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect((await db.profilesDao.getById('foreign-person'))!.userId, 'b');
      expect(
        (await db.profilesDao.getById('foreign-person'))!.name,
        'Retained B',
      );
    },
  );
  test(
    'medication history resolves protected legacy parents by server mapping',
    () async {
      final fixture = await _fixture();
      final db = fixture.db;
      final now = DateTime.utc(2026, 10, 4);
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: 'local-person',
          userId: 'a',
          name: 'Fictional person',
          createdAt: now,
          updatedAt: now,
          serverId: const Value('server-person'),
          syncStatus: const Value('synced'),
        ),
      );
      await db.pillsDao.upsert(
        PillsCompanion.insert(
          id: 'local-pill',
          profileId: 'local-person',
          name: 'Fictional medication',
          createdAt: now,
          updatedAt: now,
          serverId: const Value('server-pill'),
          syncStatus: const Value('pending'),
        ),
      );
      await db.schedulesDao.upsert(
        SchedulesCompanion.insert(
          id: 'local-schedule',
          pillId: 'local-pill',
          hour: 8,
          minute: 30,
          frequency: 'daily',
          createdAt: now,
          updatedAt: now,
          serverId: const Value('server-schedule'),
          syncStatus: const Value('synced'),
        ),
      );

      await fixture.scope.write(
        () => ComponentSyncMerger(db, writeScope: fixture.scope).merge(
          'a',
          SyncComponent.medication,
          [
            {
              'component': 'medication',
              'payload': {
                'kind': 'medicationOccurrence',
                'id': 'server-occurrence',
                'pillId': 'server-pill',
                'scheduleId': 'server-schedule',
                'occurrenceKey': 'server-schedule:2026-10-05',
                'source': 'scheduled',
                'scheduleRevision': '1',
                'plannedLocalDate': '2026-10-05',
                'plannedLocalTime': '08:30',
                'timeZone': 'Europe/Bucharest',
                'plannedAt': '2026-10-05T05:30:00Z',
                'expected': true,
                'snapshotVersion': 1,
                'scheduleSnapshot': <String, dynamic>{'version': 1},
                'provenance': 'exact',
                'supersededAt': null,
                'supersededByOccurrenceId': null,
                'stateVersion': '0',
              },
            },
          ],
        ),
      );

      final occurrence = await db.medicationLedgerDao.getOccurrenceByServerId(
        'server-occurrence',
      );
      expect(occurrence?.userId, 'a');
      expect(occurrence?.pillId, 'local-pill');
      expect(occurrence?.scheduleId, 'local-schedule');
    },
  );
  for (final disposition in ['quarantined', 'deleted']) {
    test(
      'bridge v2 preserves history with an absent $disposition parent',
      () async {
        final fixture = await _fixture();
        final db = fixture.db;
        await _seedHistoricalPill(db);
        final payload = _historicalBridgeDose(disposition: disposition);
        await db
            .into(db.migrationIssues)
            .insert(
              MigrationIssuesCompanion.insert(
                id: 'fictional-frequency-review',
                userId: 'a',
                entityType: 'schedule',
                entityId: payload['scheduleId'] as String,
                issueCode: 'invalid_schedule_frequency_days',
                snapshotJson: '{}',
                createdAt: DateTime.utc(2026, 10, 4),
                updatedAt: DateTime.utc(2026, 10, 4),
              ),
            );
        final transport = _historicalBridgeTransport(payload);
        final service = SyncService(
          db: db,
          dio: transport.dio,
          isOnline: () async => true,
          writeScope: fixture.scope,
        );
        expect(await service.pullFromServer(userId: 'a'), isTrue);
        expect(transport.contracts, [2]);
        final schedule = (await db.schedulesDao.getByServerId(
          payload['scheduleId'] as String,
        ))!;
        expect(schedule.pillId, 'local-historical-pill');
        expect(schedule.hour, 8);
        expect(schedule.minute, 30);
        expect(
          schedule.frequencyDays,
          disposition == 'quarantined' ? '[8,null,8]' : null,
        );
        expect(schedule.isActive, isFalse);
        expect(schedule.isDeleted, disposition == 'deleted');
        expect(schedule.syncStatus, 'synced');
        final dose = (await db.doseLogsDao.getByServerId(
          payload['id'] as String,
        ))!;
        expect(dose.scheduleId, schedule.id);
        expect(dose.status, 'taken');
        expect(dose.scheduledAt.toUtc(), DateTime.utc(2026, 9, 30, 5, 30));
        expect(dose.takenAt?.toUtc(), DateTime.utc(2026, 9, 30, 5, 34));
        expect(
          (await db.syncStateDao.getState(
            'a',
            'medicationBridge',
          ))?.lastCompletedCursor,
          '1',
        );
        expect(
          (await db.migrationIssuesDao.getById(
            'fictional-frequency-review',
          ))?.resolutionState,
          'unresolved',
        );
        expect(await db.select(db.workspaceSyncCheckpoints).get(), isNotEmpty);
      },
    );
  }

  test('bridge stock updates only the existing synced medication', () async {
    final fixture = await _fixture();
    final db = fixture.db;
    await _seedHistoricalPill(db);
    final before = (await db.pillsDao.getById('local-historical-pill'))!;
    final merger = ComponentSyncMerger(db, writeScope: fixture.scope);
    final updatedAt = DateTime.utc(2026, 10, 5, 10);
    Future<void> pullStock(int? stock) => fixture.scope.write(
      () => merger.merge('a', SyncComponent.medicationBridge, [
        {
          'component': 'medicationBridge',
          'payload': {
            'kind': 'bridgeStock',
            'pillId': before.serverId,
            'currentStock': stock,
            'updatedAt': updatedAt.toIso8601String(),
          },
        },
      ], contractVersion: 3),
    );

    await pullStock(-3);
    expect(
      await db.pillsDao.getById(before.id),
      before.copyWith(
        currentStock: const Value(-3),
        updatedAt: updatedAt.toLocal(),
      ),
    );
    await pullStock(null);
    expect(
      await db.pillsDao.getById(before.id),
      before.copyWith(
        currentStock: const Value(null),
        updatedAt: updatedAt.toLocal(),
      ),
    );
    await (db.update(db.pills)..where((row) => row.id.equals(before.id))).write(
      const PillsCompanion(
        currentStock: Value(11),
        syncStatus: Value('pending'),
      ),
    );
    final pending = await db.pillsDao.getById(before.id);
    await pullStock(7);
    expect(await db.pillsDao.getById(before.id), pending);
    expect(await db.select(db.doseLogs).get(), isEmpty);
    expect(await db.select(db.pendingOperations).get(), isEmpty);
  });

  test(
    'bridge stock refuses a medication belonging to another owner',
    () async {
      final fixture = await _fixture();
      final db = fixture.db;
      await _seedHistoricalPill(db, owner: 'b');
      final before = await db.pillsDao.getById('local-historical-pill');
      await expectLater(
        fixture.scope.write(
          () => ComponentSyncMerger(db, writeScope: fixture.scope).merge(
            'a',
            SyncComponent.medicationBridge,
            [
              {
                'component': 'medicationBridge',
                'payload': {
                  'kind': 'bridgeStock',
                  'pillId': before!.serverId,
                  'currentStock': 7,
                  'updatedAt': '2026-10-05T10:00:00Z',
                },
              },
            ],
            contractVersion: 3,
          ),
        ),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(await db.pillsDao.getById('local-historical-pill'), before);
    },
  );

  for (final deleted in [false, true]) {
    test(
      'bridge v3 restores a missing ancestor chain with deleted=$deleted',
      () async {
        final fixture = await _fixture();
        final db = fixture.db;
        final payload = _historicalBridgeDose(disposition: 'deleted');
        _addHistoricalAncestors(payload, deleted: deleted);
        await _seedSyncedOrphan(db, payload);
        final transport = _historicalBridgeTransport(
          payload,
          supportsAncestors: true,
        );
        final service = SyncService(
          db: db,
          dio: transport.dio,
          isOnline: () async => true,
          writeScope: fixture.scope,
        );
        expect(await service.pullFromServer(userId: 'a'), isTrue);
        expect(transport.contracts, [3]);
        final pill = (await db.pillsDao.getById(
          '11111111-1111-4111-8111-111111111111',
        ))!;
        final profile = (await db.profilesDao.getById(pill.profileId))!;
        final dose = (await db.doseLogsDao.getById('fictional-orphan-dose'))!;
        expect(profile.userId, 'a');
        expect(profile.isDeleted, deleted);
        expect(profile.name, 'Fictional canonical person');
        expect(pill.isDeleted, deleted);
        expect(pill.dosage, 'Old dosage text');
        expect(pill.currentStock, -1);
        expect(dose.scheduleId, payload['scheduleId']);
        expect(dose.note, 'Fictional private note');
        await service.purgeSyncedTombstones();
        await fixture.scope.requireEntity('doseLog', dose.id);
        expect(await db.pillsDao.getById(pill.id), pill);
        expect(await db.profilesDao.getById(profile.id), profile);
        expect(
          (await db.syncStateDao.getState(
            'a',
            'medicationBridge',
          ))?.lastCompletedCursor,
          '1',
        );
        expect(service.lastPullOutcome?.status, SyncRunStatus.succeeded);
        expect(
          await db.select(db.workspaceSyncCheckpoints).get(),
          deleted ? isEmpty : isNotEmpty,
        );
        await db.schedulesDao.purgeSyncedTombstones(DateTime.now());
        await db.pillsDao.purgeSyncedTombstones(DateTime.now());
        await db.profilesDao.purgeSyncedTombstones(DateTime.now());
        await fixture.scope.requireEntity('doseLog', dose.id);
      },
    );
  }

  for (final failure in [
    'foreign owner',
    'wrong profile',
    'missing profile',
    'missing pill',
    'missing schedule',
    'old contract',
  ]) {
    test('bridge ancestry rejects $failure atomically', () async {
      final fixture = await _fixture();
      final db = fixture.db;
      final payload = _historicalBridgeDose(disposition: 'deleted');
      _addHistoricalAncestors(payload);
      switch (failure) {
        case 'foreign owner':
          (payload['parentProfile'] as Map<String, dynamic>)['userId'] = 'b';
        case 'wrong profile':
          (payload['parentPill'] as Map<String, dynamic>)['profileId'] =
              '55555555-5555-4555-8555-555555555555';
        case 'missing profile':
          payload.remove('parentProfile');
        case 'missing pill':
          payload.remove('parentPill');
        case 'missing schedule':
          payload.remove('parentSchedule');
        case 'old contract':
          break;
      }
      await _seedSyncedOrphan(db, payload);
      final before = await db.select(db.doseLogs).get();
      final service = SyncService(
        db: db,
        dio: _historicalBridgeTransport(
          payload,
          supportsAncestors: failure != 'old contract',
        ).dio,
        isOnline: () async => true,
        writeScope: fixture.scope,
      );
      if (failure == 'foreign owner') {
        await expectLater(
          service.pullFromServer(userId: 'a'),
          throwsA(isA<WorkspaceAccessFailure>()),
        );
      } else {
        await service.pullFromServer(userId: 'a');
        expect(service.lastPullOutcome?.status, SyncRunStatus.partiallySynced);
        expect(
          service.lastPullOutcome?.forStage('medicationBridge')?.status,
          SyncComponentStatus.failed,
        );
      }
      expect(await db.select(db.doseLogs).get(), before);
      expect(await db.select(db.schedules).get(), isEmpty);
      expect(await db.select(db.pills).get(), isEmpty);
      expect(await db.select(db.profiles).get(), isEmpty);
      expect(
        (await db.syncStateDao.getState(
          'a',
          'medicationBridge',
        ))?.lastCompletedCursor,
        isNull,
      );
      expect(await db.select(db.workspaceSyncCheckpoints).get(), isEmpty);
    });
  }

  test(
    'bridge v3 reuses verified ancestor aliases without overwriting them',
    () async {
      final fixture = await _fixture();
      final db = fixture.db;
      final payload = _historicalBridgeDose(disposition: 'deleted');
      _addHistoricalAncestors(payload);
      await _seedAncestorRows(
        db,
        payload,
        profileAlias: 'retained-person',
        pillAlias: 'retained-pill',
      );
      await _seedSyncedOrphan(db, payload);
      final beforePeople = await db.select(db.profiles).get();
      final beforePills = await db.select(db.pills).get();
      final service = SyncService(
        db: db,
        dio: _historicalBridgeTransport(payload, supportsAncestors: true).dio,
        isOnline: () async => true,
        writeScope: fixture.scope,
      );
      await service.pullFromServer(userId: 'a');
      expect(service.lastPullOutcome?.status, SyncRunStatus.succeeded);
      expect(await db.select(db.profiles).get(), beforePeople);
      expect(await db.select(db.pills).get(), beforePills);
      expect(
        (await db.schedulesDao.getById(
          payload['scheduleId'] as String,
        ))?.pillId,
        'retained-pill',
      );
      expect(
        (await db.doseLogsDao.getById('fictional-orphan-dose'))?.note,
        'Fictional private note',
      );
    },
  );

  for (final (doseState, ancestorState) in [
    ('synced', 'synced'),
    ('synced', 'pending'),
    ('synced', 'conflict'),
    ('pending', 'pending'),
    ('conflict', 'conflict'),
  ]) {
    test(
      'historical dose pull respects a reviewed $ancestorState routine and $doseState care',
      () async {
        final fixture = await _fixture();
        final db = fixture.db;
        final payload = _historicalBridgeDose();
        _addHistoricalAncestors(payload);
        await _seedAncestorRows(db, payload);
        await _seedHistoricalSchedule(db, payload);
        await _seedSyncedOrphan(db, payload);
        await (db.update(db.schedules)
              ..where((row) => row.id.equals(payload['scheduleId'] as String)))
            .write(
              SchedulesCompanion(
                isActive: const Value(true),
                syncStatus: Value(ancestorState),
                revision: const Value(2),
                hour: const Value(9),
                frequencyDays: const Value(null),
                timeZone: const Value('Europe/Bucharest'),
                timeZoneStatus: const Value('known'),
                updatedAt: Value(DateTime.utc(2026, 10, 5)),
              ),
            );
        await db.customStatement(
          'UPDATE pills SET sync_status=?, current_stock=7',
          [ancestorState],
        );
        await db.customStatement('UPDATE profiles SET sync_status=?', [
          ancestorState,
        ]);
        await (db.update(db.doseLogs)
              ..where((row) => row.id.equals('fictional-orphan-dose')))
            .write(DoseLogsCompanion(syncStatus: Value(doseState)));
        final before = await db.doseLogsDao.getById('fictional-orphan-dose');
        final schedules = await db.select(db.schedules).get();
        final people = await db.select(db.profiles).get();
        final pills = await db.select(db.pills).get();
        final service = SyncService(
          db: db,
          dio: _historicalBridgeTransport(payload, supportsAncestors: true).dio,
          isOnline: () async => true,
          writeScope: fixture.scope,
        );
        expect(await service.pullFromServer(userId: 'a'), isTrue);
        expect(service.lastPullOutcome?.status, SyncRunStatus.succeeded);
        expect(await db.select(db.schedules).get(), schedules);
        expect(await db.select(db.profiles).get(), people);
        expect(await db.select(db.pills).get(), pills);
        final dose = (await db.doseLogsDao.getById('fictional-orphan-dose'))!;
        expect(dose.scheduleId, payload['scheduleId']);
        expect(dose.note, 'Fictional private note');
        if (doseState == 'synced') {
          expect(dose.takenAt?.toUtc(), DateTime.utc(2026, 9, 30, 5, 34));
        } else {
          expect(dose, before);
        }
        expect(
          (await db.syncStateDao.getState(
            'a',
            'medicationBridge',
          ))?.lastCompletedCursor,
          '1',
        );
      },
    );
  }

  for (final retained in ['none', 'pill', 'mapped profile']) {
    test(
      'bridge v3 restores ancestors of an existing schedule with $retained retained',
      () async {
        final fixture = await _fixture();
        final db = fixture.db;
        final payload = _historicalBridgeDose(disposition: 'deleted');
        _addHistoricalAncestors(payload);
        if (retained == 'pill') {
          await _seedAncestorRows(db, payload, includeProfile: false);
        }
        if (retained == 'mapped profile') {
          await _seedAncestorRows(
            db,
            payload,
            profileAlias: 'retained-person',
            includePill: false,
          );
        }
        await _seedHistoricalSchedule(db, payload);
        await _seedSyncedOrphan(db, payload);
        payload['takenAt'] = '2026-09-30T05:32:00Z';
        final beforeSchedule = await db.select(db.schedules).get();
        final beforeDose = await db.select(db.doseLogs).get();
        final service = SyncService(
          db: db,
          dio: _historicalBridgeTransport(payload, supportsAncestors: true).dio,
          isOnline: () async => true,
          writeScope: fixture.scope,
        );
        await service.pullFromServer(userId: 'a');
        expect(service.lastPullOutcome?.status, SyncRunStatus.succeeded);
        expect(await db.select(db.schedules).get(), beforeSchedule);
        expect(await db.select(db.doseLogs).get(), beforeDose);
        await fixture.scope.requireEntity('doseLog', 'fictional-orphan-dose');
      },
    );
  }

  for (final failure in [
    'pending profile',
    'newer pill',
    'foreign profile',
    'profile collision',
    'unmapped pending schedule',
    'schedule field mismatch',
    'schedule pill mismatch',
    'reviewed foreign profile',
    'reviewed profile collision',
    'reviewed profile link mismatch',
  ]) {
    test('bridge v3 preserves all rows and refuses $failure', () async {
      final fixture = await _fixture();
      final db = fixture.db;
      final payload = _historicalBridgeDose(disposition: 'deleted');
      _addHistoricalAncestors(payload);
      await _seedAncestorRows(db, payload);
      await _seedSyncedOrphan(db, payload);
      final profileId =
          (payload['parentProfile'] as Map<String, dynamic>)['id'] as String;
      final pillId =
          (payload['parentPill'] as Map<String, dynamic>)['id'] as String;
      switch (failure) {
        case 'pending profile':
          await db.customStatement("UPDATE profiles SET sync_status='pending'");
        case 'newer pill':
          await db.customStatement('UPDATE pills SET revision=2');
        case 'foreign profile':
          await db.usersDao.upsert(
            UsersCompanion.insert(
              id: 'b',
              email: 'fictional-b@example.invalid',
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
            ),
          );
          await db.customStatement("UPDATE profiles SET user_id='b'");
        case 'profile collision':
          await db.customStatement("UPDATE profiles SET id='aliased-person'");
          await db.customStatement(
            "UPDATE pills SET profile_id='aliased-person'",
          );
          await db.profilesDao.upsert(
            ProfilesCompanion.insert(
              id: profileId,
              userId: 'a',
              name: 'Colliding retained person',
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
              syncStatus: const Value('synced'),
            ),
          );
        default:
          await _seedHistoricalSchedule(db, payload);
          if (failure == 'unmapped pending schedule') {
            await db.customStatement(
              "UPDATE schedules SET sync_status='pending', server_id=NULL",
            );
          }
          if (failure == 'schedule field mismatch') {
            await db.customStatement('UPDATE schedules SET hour=9');
          }
          if (failure == 'schedule field mismatch') {
            // This case tests repair of missing ancestry, not ordinary
            // history reads through a complete current ownership chain.
            await db.customStatement('DELETE FROM profiles');
          }
          if (failure == 'schedule pill mismatch') {
            await db.customStatement(
              "UPDATE schedules SET pill_id='different-pill'",
            );
          }
      }
      if (const {
        'reviewed foreign profile',
        'reviewed profile collision',
        'reviewed profile link mismatch',
      }.contains(failure)) {
        await db.customStatement(
          "UPDATE schedules SET is_active=1, revision=2, time_zone='Europe/Bucharest', time_zone_status='known'",
        );
        switch (failure) {
          case 'reviewed foreign profile':
            await db.usersDao.upsert(
              UsersCompanion.insert(
                id: 'b',
                email: 'fictional-b@example.invalid',
                createdAt: DateTime.utc(2026),
                updatedAt: DateTime.utc(2026),
              ),
            );
            await db.customStatement("UPDATE profiles SET user_id='b'");
          case 'reviewed profile collision':
          case 'reviewed profile link mismatch':
            if (failure == 'reviewed profile collision') {
              await db.customStatement(
                'UPDATE profiles SET server_id=NULL WHERE id=?',
                [profileId],
              );
            }
            await db.profilesDao.upsert(
              ProfilesCompanion.insert(
                id: 'other-local-person',
                userId: 'a',
                name: 'Fictional different person',
                serverId: Value(
                  failure == 'reviewed profile collision'
                      ? profileId
                      : 'other-server-person',
                ),
                syncStatus: const Value('synced'),
                createdAt: DateTime.utc(2026),
                updatedAt: DateTime.utc(2026),
              ),
            );
            if (failure == 'reviewed profile link mismatch') {
              await db.customStatement(
                "UPDATE pills SET profile_id='other-local-person'",
              );
            }
          default:
            break;
        }
      }
      final before = (
        await db.select(db.profiles).get(),
        await db.select(db.pills).get(),
        await db.select(db.schedules).get(),
        await db.select(db.doseLogs).get(),
      );
      final service = SyncService(
        db: db,
        dio: _historicalBridgeTransport(payload, supportsAncestors: true).dio,
        isOnline: () async => true,
        writeScope: fixture.scope,
      );
      await expectLater(
        service.pullFromServer(userId: 'a'),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(await db.select(db.profiles).get(), before.$1);
      expect(await db.select(db.pills).get(), before.$2);
      expect(await db.select(db.schedules).get(), before.$3);
      expect(await db.select(db.doseLogs).get(), before.$4);
      expect(
        (await db.syncStateDao.getState(
          'a',
          'medicationBridge',
        ))?.lastCompletedCursor,
        isNull,
      );
      expect(await db.select(db.workspaceSyncCheckpoints).get(), isEmpty);
      expect(await db.pillsDao.getById(pillId), isNotNull);
    });
  }

  test(
    'existing historical schedule ancestor recovery requires protected authority',
    () async {
      final fixture = await _fixture();
      final db = fixture.db;
      final payload = _historicalBridgeDose(disposition: 'deleted');
      _addHistoricalAncestors(payload);
      await _seedHistoricalSchedule(db, payload);
      await _seedSyncedOrphan(db, payload);
      final beforeSchedules = await db.select(db.schedules).get();
      final beforeDoses = await db.select(db.doseLogs).get();
      await expectLater(
        db.transaction(
          () => ComponentSyncMerger(db).merge(
            'a',
            SyncComponent.medicationBridge,
            [_historicalBridgeChange(payload)],
            contractVersion: 3,
          ),
        ),
        throwsA(
          isA<WorkspaceAccessFailure>().having(
            (e) => e.code,
            'code',
            WorkspaceAccessFailureCode.staleGrant,
          ),
        ),
      );
      expect(await db.select(db.schedules).get(), beforeSchedules);
      expect(await db.select(db.doseLogs).get(), beforeDoses);
      expect(await db.select(db.profiles).get(), isEmpty);
      expect(await db.select(db.pills).get(), isEmpty);
      expect(await db.syncStateDao.getState('a', 'medicationBridge'), isNull);
      expect(await db.select(db.workspaceSyncCheckpoints).get(), isEmpty);
    },
  );

  test('historical parent recovery requires protected authority', () async {
    final fixture = await _fixture();
    await _seedHistoricalPill(fixture.db);
    final transport = _historicalBridgeTransport(_historicalBridgeDose());
    final service = SyncService(
      db: fixture.db,
      dio: transport.dio,
      isOnline: () async => true,
    );
    await expectLater(
      service.pullFromServer(userId: 'a'),
      throwsA(isA<WorkspaceAccessFailure>()),
    );
    expect(await fixture.db.select(fixture.db.schedules).get(), isEmpty);
    expect(await fixture.db.select(fixture.db.doseLogs).get(), isEmpty);
    expect(
      (await fixture.db.syncStateDao.getState(
        'a',
        'medicationBridge',
      ))?.lastCompletedCursor,
      isNull,
    );
  });

  test(
    'bridge v2 without a verified parent retains the access refusal',
    () async {
      final diagnostics = _captureDiagnostics();
      final fixture = await _fixture();
      await _seedHistoricalPill(fixture.db);
      final transport = _historicalBridgeTransport(
        _historicalBridgeDose()..remove('parentSchedule'),
      );
      final service = SyncService(
        db: fixture.db,
        dio: transport.dio,
        isOnline: () async => true,
        writeScope: fixture.scope,
      );
      await expectLater(
        service.pullFromServer(userId: 'a'),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(await fixture.db.select(fixture.db.schedules).get(), isEmpty);
      expect(await fixture.db.select(fixture.db.doseLogs).get(), isEmpty);
      expect(
        (await fixture.db.syncStateDao.getState(
          'a',
          'medicationBridge',
        ))?.lastCompletedCursor,
        isNull,
      );
      expect(
        await fixture.db.select(fixture.db.workspaceSyncCheckpoints).get(),
        isEmpty,
      );
      expect(
        diagnostics.any(
          (line) => line.contains('"phase":"bridge_incoming_without_parent"'),
        ),
        isTrue,
      );
    },
  );

  test(
    'bridge refusal identifies an existing orphan without changing it',
    () async {
      final diagnostics = _captureDiagnostics();
      final fixture = await _fixture();
      final db = fixture.db;
      await _seedHistoricalPill(db);
      final payload = _historicalBridgeDose();
      await db.doseLogsDao.upsert(
        DoseLogsCompanion.insert(
          id: 'fictional-orphan-dose',
          scheduleId: payload['scheduleId'] as String,
          scheduledAt: DateTime.utc(2026, 9, 30, 5, 30),
          takenAt: Value(DateTime.utc(2026, 9, 30, 5, 34)),
          status: 'taken',
          note: const Value('Fictional private note'),
          createdAt: DateTime.utc(2026, 9, 30),
          updatedAt: DateTime.utc(2026, 9, 30),
          serverId: Value(payload['id'] as String),
          syncStatus: const Value('synced'),
        ),
      );
      final before = await db.doseLogsDao.getById('fictional-orphan-dose');
      final service = SyncService(
        db: db,
        dio: _historicalBridgeTransport(
          payload,
          change: _historicalBridgeChange(payload)..remove('sourceIdentity'),
        ).dio,
        isOnline: () async => true,
        writeScope: fixture.scope,
      );
      await expectLater(
        service.pullFromServer(userId: 'a'),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(await db.doseLogsDao.getById('fictional-orphan-dose'), before);
      expect(await db.select(db.schedules).get(), isEmpty);
      expect(
        (await db.syncStateDao.getState(
          'a',
          'medicationBridge',
        ))?.lastCompletedCursor,
        isNull,
      );
      expect(await db.select(db.workspaceSyncCheckpoints).get(), isEmpty);
      expect(
        diagnostics.any(
          (line) => line.contains('"phase":"bridge_existing_dose"'),
        ),
        isTrue,
      );
      expect(
        diagnostics.any(
          (line) =>
              line.contains('"parentIdentity":"same_local_id"') &&
              line.contains('"legacyOwnerEvidence":"none"'),
        ),
        isTrue,
      );
      expect(diagnostics.join(), isNot(contains('fictional-orphan-dose')));
      expect(diagnostics.join(), isNot(contains('Fictional private note')));
      expect(
        diagnostics.join(),
        isNot(contains(payload['scheduleId'] as String)),
      );
    },
  );

  for (final disposition in ['quarantined', 'deleted']) {
    test(
      'exact synced orphan restores its $disposition parent without rebinding',
      () async {
        final fixture = await _fixture();
        final db = fixture.db;
        await _seedHistoricalPill(db);
        final payload = _historicalBridgeDose(disposition: disposition);
        payload['sourceRevision'] = '2';
        if (disposition == 'deleted') {
          final parent = payload['parentSchedule'] as Map<String, dynamic>;
          parent['createdAt'] = '2025-01-01T00:00:00Z';
          parent['updatedAt'] = '2026-01-01T00:00:00Z';
          parent['deletedAt'] = '2026-01-01T00:00:00Z';
        }
        await _seedSyncedOrphan(db, payload);
        final service = SyncService(
          db: db,
          dio: _historicalBridgeTransport(payload).dio,
          isOnline: () async => true,
          writeScope: fixture.scope,
        );
        expect(await service.pullFromServer(userId: 'a'), isTrue);
        expect(service.lastPullOutcome?.status, SyncRunStatus.succeeded);
        final dose = (await db.doseLogsDao.getById('fictional-orphan-dose'))!;
        expect(dose.scheduleId, payload['scheduleId']);
        expect(dose.note, 'Fictional private note');
        expect(dose.status, 'taken');
        expect(dose.takenAt?.toUtc(), DateTime.utc(2026, 9, 30, 5, 34));
        expect(dose.revision, 2);
        expect(dose.serverId, payload['id']);
        final parent = (await db.schedulesDao.getById(dose.scheduleId))!;
        expect(parent.isActive, isFalse);
        expect(parent.isDeleted, disposition == 'deleted');
        expect(parent.pillId, 'local-historical-pill');
        expect(
          (await db.syncStateDao.getState(
            'a',
            'medicationBridge',
          ))?.lastCompletedCursor,
          '1',
        );
        expect(await db.select(db.workspaceSyncCheckpoints).get(), isNotEmpty);
        await service.purgeSyncedTombstones();
        expect(await db.schedulesDao.getById(dose.scheduleId), parent);
        await fixture.scope.requireEntity('doseLog', dose.id);
        expect(
          await db.doseLogsDao.getHistoryEntriesForDateRange(
            DateTime.utc(2026, 9, 30),
            DateTime.utc(2026, 10, 1),
          ),
          hasLength(1),
        );
      },
    );
  }

  for (final failure in [
    'pending',
    'conflict',
    'outer identity',
    'source kind',
    'source identity',
    'source revision',
    'schedule identity',
    'scheduled time',
    'newer revision',
    'local identity collision',
    'foreign existing parent',
    'foreign pill',
    'missing pill',
    'retained foreign owner',
    'retained different pill',
  ]) {
    test(
      'orphan repair refuses $failure and leaves its history checkpoint untouched',
      () async {
        final fixture = await _fixture();
        final db = fixture.db;
        await _seedHistoricalPill(
          db,
          owner: failure == 'foreign pill' ? 'b' : 'a',
        );
        final payload = _historicalBridgeDose();
        final change = _historicalBridgeChange(payload);
        await _seedSyncedOrphan(db, payload);
        switch (failure) {
          case 'pending':
          case 'conflict':
            await (db.update(db.doseLogs)
                  ..where((row) => row.id.equals('fictional-orphan-dose')))
                .write(DoseLogsCompanion(syncStatus: Value(failure)));
          case 'outer identity':
            change['entityId'] = '55555555-5555-4555-8555-555555555555';
          case 'source kind':
            (change['sourceIdentity'] as Map<String, dynamic>)['sourceKind'] =
                'schedule';
          case 'source identity':
            (change['sourceIdentity'] as Map<String, dynamic>)['sourceId'] =
                '55555555-5555-4555-8555-555555555555';
          case 'source revision':
            (change['sourceIdentity']
                    as Map<String, dynamic>)['sourceRevision'] =
                '2';
          case 'schedule identity':
            await (db.update(
              db.doseLogs,
            )..where((row) => row.id.equals('fictional-orphan-dose'))).write(
              const DoseLogsCompanion(
                scheduleId: Value('different-local-parent'),
              ),
            );
          case 'scheduled time':
            payload['scheduledAt'] = '2026-09-30T05:31:00Z';
          case 'newer revision':
            await (db.update(db.doseLogs)
                  ..where((row) => row.id.equals('fictional-orphan-dose')))
                .write(const DoseLogsCompanion(revision: Value(2)));
          case 'local identity collision':
            await db.doseLogsDao.upsert(
              DoseLogsCompanion.insert(
                id: payload['id'] as String,
                scheduleId: 'other-retained-parent',
                scheduledAt: DateTime.utc(2026, 9, 29),
                status: 'skipped',
                createdAt: DateTime.utc(2026, 9, 29),
                updatedAt: DateTime.utc(2026, 9, 29),
              ),
            );
          case 'foreign existing parent':
            await _seedHistoricalPill(db, owner: 'b');
            await db.schedulesDao.upsert(
              SchedulesCompanion.insert(
                id: payload['scheduleId'] as String,
                pillId: 'local-historical-pill',
                hour: 9,
                minute: 0,
                frequency: 'daily',
                createdAt: DateTime.utc(2026, 9, 1),
                updatedAt: DateTime.utc(2026, 9, 1),
                syncStatus: const Value('synced'),
              ),
            );
          case 'missing pill':
            (payload['parentSchedule'] as Map<String, dynamic>)['pillId'] =
                '55555555-5555-4555-8555-555555555555';
          case 'foreign pill':
            break;
          case 'retained foreign owner':
          case 'retained different pill':
            await db.medicationLedgerDao.upsertOccurrence(
              MedicationOccurrencesCompanion.insert(
                id: 'contradictory-fictional-history',
                userId: failure == 'retained foreign owner' ? 'b' : 'a',
                pillId: Value(
                  failure == 'retained different pill'
                      ? 'different-retained-pill'
                      : 'local-historical-pill',
                ),
                scheduleId: Value(payload['scheduleId'] as String),
                occurrenceKey: 'legacy:fictional-orphan-dose',
                source: 'legacy',
                plannedLocalDate: '2026-09-30',
                timeZone: 'Europe/Bucharest',
                scheduleSnapshotJson: '{}',
                provenance: 'legacy_estimated',
                createdAt: DateTime.utc(2026, 9, 30),
                updatedAt: DateTime.utc(2026, 9, 30),
              ),
            );
        }
        final dosesBefore = await db.select(db.doseLogs).get();
        final schedulesBefore = await db.select(db.schedules).get();
        final occurrencesBefore = await db
            .select(db.medicationOccurrences)
            .get();
        final service = SyncService(
          db: db,
          dio: _historicalBridgeTransport(payload, change: change).dio,
          isOnline: () async => true,
          writeScope: fixture.scope,
        );
        await expectLater(
          service.pullFromServer(userId: 'a'),
          throwsA(isA<WorkspaceAccessFailure>()),
        );
        expect(await db.select(db.doseLogs).get(), dosesBefore);
        expect(await db.select(db.schedules).get(), schedulesBefore);
        expect(
          await db.select(db.medicationOccurrences).get(),
          occurrencesBefore,
        );
        expect(
          (await db.syncStateDao.getState(
            'a',
            'medicationBridge',
          ))?.lastCompletedCursor,
          isNull,
        );
        expect(await db.select(db.workspaceSyncCheckpoints).get(), isEmpty);
      },
    );
  }

  for (final protected in [false, true]) {
    test(
      'schedule cleanup retains an occurrence parent with protected scope $protected',
      () async {
        final fixture = await _fixture();
        final db = fixture.db;
        await _seedHistoricalPill(db);
        final old = DateTime.utc(2025, 1, 1);
        for (final id in [
          'retained-occurrence-parent',
          'unreferenced-old-parent',
        ]) {
          await db.schedulesDao.upsert(
            SchedulesCompanion.insert(
              id: id,
              pillId: 'local-historical-pill',
              hour: 8,
              minute: 30,
              frequency: 'daily',
              createdAt: old,
              updatedAt: old,
              isDeleted: const Value(true),
              syncStatus: const Value('synced'),
            ),
          );
        }
        await db.medicationLedgerDao.upsertOccurrence(
          MedicationOccurrencesCompanion.insert(
            id: 'retained-fictional-occurrence',
            userId: 'a',
            pillId: const Value('local-historical-pill'),
            scheduleId: const Value('retained-occurrence-parent'),
            occurrenceKey: 'fictional-history',
            source: 'legacy',
            plannedLocalDate: '2025-01-01',
            timeZone: 'Europe/Bucharest',
            scheduleSnapshotJson: '{}',
            provenance: 'legacy_estimated',
            createdAt: old,
            updatedAt: old,
          ),
        );
        await db.customStatement(
          "UPDATE pills SET is_deleted=1, updated_at=?",
          [old.millisecondsSinceEpoch ~/ 1000],
        );
        await db.customStatement(
          "UPDATE profiles SET is_deleted=1, updated_at=?",
          [old.millisecondsSinceEpoch ~/ 1000],
        );
        for (final id in ['retained-prn-pill', 'unreferenced-pill']) {
          await db.pillsDao.upsert(
            PillsCompanion.insert(
              id: id,
              profileId: 'historical-person',
              name: 'Fictional history medication',
              isDeleted: const Value(true),
              syncStatus: const Value('synced'),
              createdAt: old,
              updatedAt: old,
            ),
          );
        }
        await db.medicationLedgerDao.upsertOccurrence(
          MedicationOccurrencesCompanion.insert(
            id: 'fictional-prn-occurrence',
            userId: 'a',
            pillId: const Value('retained-prn-pill'),
            occurrenceKey: 'fictional-prn-history',
            source: 'prn',
            plannedLocalDate: '2025-01-01',
            timeZone: 'Europe/Bucharest',
            scheduleSnapshotJson: '{}',
            provenance: 'legacy_estimated',
            createdAt: old,
            updatedAt: old,
          ),
        );
        await SyncService(
          db: db,
          dio: Dio(),
          writeScope: protected ? fixture.scope : null,
        ).purgeSyncedTombstones();
        expect(
          await db.schedulesDao.getById('retained-occurrence-parent'),
          isNotNull,
        );
        expect(
          await db.schedulesDao.getById('unreferenced-old-parent'),
          isNull,
        );
        expect(await db.pillsDao.getById('local-historical-pill'), isNotNull);
        expect(await db.pillsDao.getById('retained-prn-pill'), isNotNull);
        expect(await db.pillsDao.getById('unreferenced-pill'), isNull);
        expect(await db.profilesDao.getById('historical-person'), isNotNull);
      },
    );
  }

  test('valid frequency cannot be imported as quarantined metadata', () async {
    final fixture = await _fixture();
    await _seedHistoricalPill(fixture.db);
    final payload = _historicalBridgeDose();
    (payload['parentSchedule'] as Map<String, dynamic>)['frequencyDays'] = null;
    final transport = _historicalBridgeTransport(payload);
    final service = SyncService(
      db: fixture.db,
      dio: transport.dio,
      isOnline: () async => true,
      writeScope: fixture.scope,
    );
    await service.pullFromServer(userId: 'a');
    expect(
      service.lastPullOutcome?.forStage('medicationBridge')?.status,
      SyncComponentStatus.failed,
    );
    expect(await fixture.db.select(fixture.db.schedules).get(), isEmpty);
    expect(await fixture.db.select(fixture.db.doseLogs).get(), isEmpty);
    expect(
      (await fixture.db.syncStateDao.getState(
        'a',
        'medicationBridge',
      ))?.lastCompletedCursor,
      isNull,
    );
    expect(
      await fixture.db.select(fixture.db.workspaceSyncCheckpoints).get(),
      isEmpty,
    );
  });

  test(
    'historical bridge parent cannot import another owner\'s pill',
    () async {
      final diagnostics = _captureDiagnostics();
      final fixture = await _fixture();
      final db = fixture.db;
      await _seedHistoricalPill(db, owner: 'b');
      final transport = _historicalBridgeTransport(_historicalBridgeDose());
      final service = SyncService(
        db: db,
        dio: transport.dio,
        isOnline: () async => true,
        writeScope: fixture.scope,
      );
      await expectLater(
        service.pullFromServer(userId: 'a'),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(await db.select(db.schedules).get(), isEmpty);
      expect(await db.select(db.doseLogs).get(), isEmpty);
      expect(
        (await db.syncStateDao.getState(
          'a',
          'medicationBridge',
        ))?.lastCompletedCursor,
        isNull,
      );
      expect(await db.select(db.workspaceSyncCheckpoints).get(), isEmpty);
      expect(
        diagnostics.any(
          (line) => line.contains('"phase":"bridge_parent_import"'),
        ),
        isTrue,
      );
    },
  );

  test('mismatched historical parent rolls back bridge publication', () async {
    final fixture = await _fixture();
    final db = fixture.db;
    await _seedHistoricalPill(db);
    final payload = _historicalBridgeDose();
    (payload['parentSchedule'] as Map<String, dynamic>)['id'] =
        '33333333-3333-4333-8333-333333333333';
    final transport = _historicalBridgeTransport(payload);
    final service = SyncService(
      db: db,
      dio: transport.dio,
      isOnline: () async => true,
      writeScope: fixture.scope,
    );
    await service.pullFromServer(userId: 'a');
    expect(
      service.lastPullOutcome?.forStage('medicationBridge')?.status,
      SyncComponentStatus.failed,
    );
    expect(service.lastPullOutcome?.status, SyncRunStatus.partiallySynced);
    expect(await db.select(db.schedules).get(), isEmpty);
    expect(await db.select(db.doseLogs).get(), isEmpty);
    expect(
      (await db.syncStateDao.getState(
        'a',
        'medicationBridge',
      ))?.lastCompletedCursor,
      isNull,
    );
    expect(await db.select(db.workspaceSyncCheckpoints).get(), isEmpty);
  });

  for (final supported in [false, true]) {
    test(
      'historical bridge preserves pending routine with parent capability $supported',
      () async {
        final fixture = await _fixture();
        final db = fixture.db;
        await _seedHistoricalPill(db);
        final payload = _historicalBridgeDose();
        if (!supported) payload.remove('parentSchedule');
        await db.schedulesDao.upsert(
          SchedulesCompanion.insert(
            id: 'pending-local-schedule',
            pillId: 'local-historical-pill',
            hour: 11,
            minute: 45,
            frequency: 'daily',
            createdAt: DateTime.utc(2026, 10, 4),
            updatedAt: DateTime.utc(2026, 10, 4),
            serverId: Value(payload['scheduleId'] as String),
          ),
        );
        final transport = _historicalBridgeTransport(
          payload,
          supportsParents: supported,
        );
        final service = SyncService(
          db: db,
          dio: transport.dio,
          isOnline: () async => true,
          writeScope: fixture.scope,
        );
        expect(await service.pullFromServer(userId: 'a'), isTrue);
        expect(transport.contracts, [supported ? 2 : 1]);
        final schedule = (await db.schedulesDao.getById(
          'pending-local-schedule',
        ))!;
        expect(schedule.hour, 11);
        expect(schedule.minute, 45);
        expect(schedule.syncStatus, 'pending');
        expect(schedule.isActive, isTrue);
        expect(
          (await db.doseLogsDao.getByServerId(
            payload['id'] as String,
          ))?.scheduleId,
          schedule.id,
        );
      },
    );
  }

  test('an earlier stable receipt preserves a newer queued local edit', () async {
    final fixture = await _fixture();
    final db = fixture.db;
    final firstId = await _profileOperation(db);
    final dio = Dio();
    var replies = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          replies++;
          await PendingOperationRepository(db).record(
            operation: const PendingOperationDraft(
              userId: 'a',
              mutationId: 'fictional-later-edit',
              component: 'stable',
              operationType: 'profile.update',
              entityType: 'profile',
              entityLocalId: 'fictional-person',
              payload: {
                'action': 'update',
                'data': {'name': 'Newer local choice', 'avatarEmoji': '🙂'},
              },
            ),
            applyProjection: () async {
              await db.customUpdate(
                "UPDATE profiles SET name='Newer local choice', sync_status='pending', updated_at=updated_at+1 WHERE id='fictional-person'",
                updates: {db.profiles},
              );
            },
          );
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              data: {'id': 'fictional-person', 'revision': 1},
            ),
          );
        },
      ),
    );
    await ProfilesSyncAdapter(
      db,
    ).flush('a', V2StableAdapter(db: db, dio: dio, writeScope: fixture.scope));
    expect(replies, 1);
    expect(
      (await db.pendingOperationsDao.getById(firstId))!.state,
      'committed',
    );
    final row = (await db.profilesDao.getById('fictional-person'))!;
    expect(row.name, 'Newer local choice');
    expect(row.serverId, 'fictional-person');
    expect(row.syncStatus, 'pending');
    expect(
      (await db.pendingOperationsDao.getByMutationId(
        'a',
        'fictional-later-edit',
      ))!.state,
      'queued',
    );
  });

  test('an older legacy row response preserves a newer queued edit', () async {
    final fixture = await _fixture();
    final db = fixture.db;
    final now = DateTime.now();
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: 'fictional-person',
        userId: 'a',
        name: 'Earlier choice',
        createdAt: now,
        updatedAt: now,
        serverId: const Value('fictional-server-person'),
      ),
    );
    final dio = Dio();
    var edits = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.path == '/capabilities') {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(requestOptions: options, statusCode: 404),
                type: DioExceptionType.badResponse,
              ),
            );
            return;
          }
          if (options.path == '/profiles/fictional-server-person') {
            edits++;
            await PendingOperationRepository(db).record(
              operation: const PendingOperationDraft(
                userId: 'a',
                mutationId: 'fictional-newer-legacy-edit',
                component: 'stable',
                operationType: 'profile.update',
                entityType: 'profile',
                entityLocalId: 'fictional-person',
                payload: {
                  'action': 'update',
                  'data': {'name': 'Newer choice'},
                },
              ),
              applyProjection: () async {
                await db.customUpdate(
                  "UPDATE profiles SET name='Newer choice', sync_status='pending', updated_at=updated_at+1 WHERE id='fictional-person'",
                  updates: {db.profiles},
                );
              },
            );
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{},
            ),
          );
        },
      ),
    );
    await SyncService(
      db: db,
      dio: dio,
      isOnline: () async => true,
      writeScope: fixture.scope,
    ).flushPending(userId: 'a');
    expect(edits, 1);
    final person = (await db.profilesDao.getById('fictional-person'))!;
    expect(person.name, 'Newer choice');
    expect(person.syncStatus, 'pending');
    expect(
      (await db.pendingOperationsDao.getByMutationId(
        'a',
        'fictional-newer-legacy-edit',
      ))!.state,
      'queued',
    );
  });

  test(
    'count and tombstone retirement are confined to the captured owner',
    () async {
      final fixture = await _fixture();
      final db = fixture.db;
      await _profileOperation(db);
      final old = DateTime.utc(2025, 1, 1);
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: 'b',
          email: 'fictional-b@example.invalid',
          createdAt: old,
          updatedAt: old,
        ),
      );
      for (final owner in ['a', 'b']) {
        await db.profilesDao.upsert(
          ProfilesCompanion.insert(
            id: 'retired-$owner',
            userId: owner,
            name: 'Retired $owner',
            createdAt: old,
            updatedAt: old,
            isDeleted: const Value(true),
            syncStatus: const Value('synced'),
          ),
        );
      }
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: 'pending-b',
          userId: 'b',
          name: 'Pending B',
          createdAt: old,
          updatedAt: old,
        ),
      );
      final service = SyncService(
        db: db,
        dio: Dio(),
        writeScope: fixture.scope,
      );
      expect(await service.countPending(), 1);
      await expectLater(
        service.countPending(userId: 'b'),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      await service.purgeSyncedTombstones();
      expect(await db.profilesDao.getById('retired-a'), isNull);
      expect(await db.profilesDao.getById('retired-b'), isNotNull);
      expect(await db.profilesDao.getById('pending-b'), isNotNull);
    },
  );
  test(
    'a retained foreground intent repository cannot write after sign-out',
    () async {
      final fixture = await _fixture();
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(fixture.db),
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.readHeld(workspaceContextProvider);
      final retained = container.read(pendingOperationRepositoryProvider);
      await fixture.access.revokeNetwork();
      await expectLater(
        retained.record(
          operation: const PendingOperationDraft(
            userId: 'a',
            mutationId: 'fictional-late-intent',
            operationType: 'profile.create',
            entityType: 'profile',
            entityLocalId: 'late-person',
            payload: {
              'action': 'create',
              'data': {'name': 'Late person'},
            },
          ),
          applyProjection: () => fixture.db.profilesDao.upsert(
            ProfilesCompanion.insert(
              id: 'late-person',
              userId: 'a',
              name: 'Late person',
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          ),
        ),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(await fixture.db.profilesDao.getById('late-person'), isNull);
      expect(
        await fixture.db.pendingOperationsDao.getByMutationId(
          'a',
          'fictional-late-intent',
        ),
        isNull,
      );
    },
  );
  test(
    'interrupted recovery leaves another retained account untouched',
    () async {
      final fixture = await _fixture();
      final db = fixture.db;
      final a = await _profileOperation(db);
      final now = DateTime.now();
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: 'b',
          email: 'fictional-b@example.invalid',
          createdAt: now,
          updatedAt: now,
        ),
      );
      final b = await PendingOperationRepository(db).record(
        operation: const PendingOperationDraft(
          userId: 'b',
          mutationId: 'fictional-b-work',
          operationType: 'profile.create',
          entityType: 'profile',
          entityLocalId: 'fictional-b-person',
          payload: {
            'action': 'create',
            'data': {'name': 'B'},
          },
        ),
        applyProjection: () async {},
      );
      for (final id in [a, b.operationId]) {
        expect(
          await db.pendingOperationsDao.transitionState(
            operationId: id,
            from: 'queued',
            to: 'sending',
          ),
          isTrue,
        );
      }
      final context = (await fixture.access.contextForOwner('a'))!;
      await PendingOperationRepository(
        db,
        access: fixture.access,
        context: context,
      ).recoverInterruptedWork();
      expect((await db.pendingOperationsDao.getById(a))!.state, 'blocked');
      expect(
        (await db.pendingOperationsDao.getById(b.operationId))!.state,
        'sending',
      );
      expect(await db.migrationIssuesDao.getUnresolved('b'), isEmpty);
    },
  );
}

List<String> _captureDiagnostics() {
  final messages = <String>[];
  final previous = debugPrint;
  debugPrint = (message, {wrapWidth}) {
    if (message != null && message.contains('[SyncDiag]')) {
      messages.add(message);
    }
  };
  addTearDown(() => debugPrint = previous);
  return messages;
}

Future<
  ({AppDatabase db, WorkspaceAccessRepository access, SyncWriteScope scope})
>
_fixture() async {
  const endpoint = 'https://fictional.test/care';
  final db = AppDatabase.forTesting();
  addTearDown(db.close);
  final access = WorkspaceAccessRepository(db);
  await access.configureEndpoint(endpoint);
  final credentials = ProtectedCredentialsRepository(
    access: access,
    store: _Secrets(),
  );
  final slot = await credentials.stage(
    CredentialBundle(
      ownerId: 'a',
      endpoint: endpoint,
      accessToken: 'fictional-access',
      refreshToken: 'fictional-refresh',
      expiresAtMillis: DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    ),
  );
  final capability = await credentials.activate(
    credentialId: slot,
    expectedTransition: await access.revokeNetwork(),
    sessionGeneration: 1,
  );
  return (
    db: db,
    access: access,
    scope: SyncWriteScope(access: access, capability: capability.network),
  );
}

Future<String> _profileOperation(AppDatabase db) async {
  final now = DateTime.now().toUtc();
  final recorded = await PendingOperationRepository(db).record(
    operation: const PendingOperationDraft(
      userId: 'a',
      mutationId: 'fictional-profile-command',
      component: 'stable',
      operationType: 'profile.create',
      entityType: 'profile',
      entityLocalId: 'fictional-person',
      payload: {
        'action': 'create',
        'data': {'name': 'Fictional person', 'avatarEmoji': '🙂'},
      },
    ),
    applyProjection: () => db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: 'fictional-person',
        userId: 'a',
        name: 'Fictional person',
        createdAt: now,
        updatedAt: now,
      ),
    ),
  );
  return recorded.operationId;
}

Future<void> _seedHistoricalPill(AppDatabase db, {String owner = 'a'}) async {
  final now = DateTime.utc(2026, 10, 4);
  if (owner != 'a') {
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: owner,
        email: 'fictional-b@example.invalid',
        createdAt: now,
        updatedAt: now,
      ),
    );
  }
  await db.profilesDao.upsert(
    ProfilesCompanion.insert(
      id: 'historical-person',
      userId: owner,
      name: 'Fictional historical person',
      createdAt: now,
      updatedAt: now,
      syncStatus: const Value('synced'),
    ),
  );
  await db.pillsDao.upsert(
    PillsCompanion.insert(
      id: 'local-historical-pill',
      profileId: 'historical-person',
      name: 'Fictional historical medication',
      createdAt: now,
      updatedAt: now,
      serverId: const Value('11111111-1111-4111-8111-111111111111'),
      syncStatus: const Value('synced'),
    ),
  );
}

Map<String, dynamic> _historicalBridgeDose({
  String disposition = 'quarantined',
}) => {
  'kind': 'bridgeDose',
  'id': '44444444-4444-4444-8444-444444444444',
  'scheduleId': '22222222-2222-4222-8222-222222222222',
  'scheduledAt': '2026-09-30T05:30:00Z',
  'takenAt': '2026-09-30T05:34:00Z',
  'status': 'taken',
  'deletedAt': null,
  'sourceRevision': '1',
  'parentSchedule': {
    'id': '22222222-2222-4222-8222-222222222222',
    'pillId': '11111111-1111-4111-8111-111111111111',
    'hour': 8,
    'minute': 30,
    'frequency': 'daily',
    'frequencyDays': disposition == 'quarantined' ? [8, null, 8] : null,
    'revision': '1',
    'createdAt': '2026-09-01T00:00:00Z',
    'updatedAt': '2026-09-29T00:00:00Z',
    'deletedAt': disposition == 'deleted' ? '2026-10-01T00:00:00Z' : null,
    'disposition': disposition,
  },
};

({Dio dio, List<int> contracts, List<String> checkpoints})
_historicalBridgeTransport(
  Map<String, dynamic> payload, {
  bool supportsParents = true,
  bool supportsAncestors = false,
  bool supportsOccurrences = false,
  Map<String, dynamic>? change,
}) {
  final dio = Dio();
  final contracts = <int>[];
  final checkpoints = <String>[];
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path == '/capabilities') {
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              data: {
                'apiNamespace': 'v1',
                'contracts': {
                  'componentSync': 2,
                  'legacySplitReconciliation': 1,
                  'medicationBridgeCommands': 1,
                  'medicationBridgeSync': 1,
                  if (supportsParents) 'medicationBridgeParentSync': 2,
                  if (supportsAncestors) 'medicationBridgeAncestorSync': 3,
                  if (supportsOccurrences) 'medicationBridgeOccurrenceSync': 4,
                  'medicationCommands': 2,
                },
                'medicationLedgerActive': false,
                'minimumClientBuild': 1,
                'serverRelease': 'fictional',
              },
            ),
          );
          return;
        }
        final bridge = options.path.endsWith('medication-bridge');
        if (bridge) {
          contracts.add(options.queryParameters['contractVersion'] as int);
          checkpoints.add(
            options.queryParameters['afterSequence'] as String? ?? '0',
          );
        }
        final component = bridge
            ? 'medicationBridge'
            : options.path.split('/').last;
        handler.resolve(
          Response<Map<String, dynamic>>(
            requestOptions: options,
            data: {
              'component': component,
              'contractVersion': options.queryParameters['contractVersion'],
              'afterSequence': options.queryParameters['afterSequence'] ?? '0',
              'throughSequence': bridge ? '1' : '0',
              'hasMore': false,
              'nextCursor': null,
              'items':
                  bridge &&
                      !(supportsOccurrences &&
                          options.queryParameters['afterSequence'] == '1')
                  ? [
                      {
                        'serverSequence': '1',
                        'change': change ?? _historicalBridgeChange(payload),
                      },
                    ]
                  : <Object>[],
            },
          ),
        );
      },
    ),
  );
  return (dio: dio, contracts: contracts, checkpoints: checkpoints);
}

Future<void> _seedReviewedRoutine(AppDatabase db, {String owner = 'a'}) async {
  final now = DateTime.utc(2026, 10, 5);
  if (owner != 'a') {
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: owner,
        email: 'fictional@example.invalid',
        createdAt: now,
        updatedAt: now,
      ),
    );
  }
  await db.profilesDao.upsert(
    ProfilesCompanion.insert(
      id: 'review-local-person',
      userId: owner,
      name: 'Fictional reviewed person',
      serverId: const Value('review-server-person'),
      syncStatus: const Value('synced'),
      createdAt: now,
      updatedAt: now,
    ),
  );
  await db.pillsDao.upsert(
    PillsCompanion.insert(
      id: 'review-local-pill',
      profileId: 'review-local-person',
      name: 'Fictional reviewed medicine',
      serverId: const Value('review-server-pill'),
      syncStatus: const Value('synced'),
      createdAt: now,
      updatedAt: now,
    ),
  );
  await db.schedulesDao.upsert(
    SchedulesCompanion.insert(
      id: 'review-local-schedule',
      pillId: 'review-local-pill',
      hour: 8,
      minute: 30,
      frequency: 'daily',
      serverId: const Value('review-server-schedule'),
      revision: const Value(2),
      syncStatus: const Value('synced'),
      createdAt: now,
      updatedAt: now,
    ),
  );
}

Map<String, dynamic> _reviewedRoutineOccurrence() => {
  'kind': 'medicationOccurrence',
  'id': 'review-server-occurrence',
  'pillId': 'review-server-pill',
  'scheduleId': 'review-server-schedule',
  'occurrenceKey': 'scheduled:review-server-schedule:2:2026-10-05',
  'source': 'scheduled',
  'scheduleRevision': '2',
  'plannedLocalDate': '2026-10-05',
  'plannedLocalTime': '08:30',
  'timeZone': 'Europe/Bucharest',
  'plannedAt': '2026-10-05T05:30:00Z',
  'expected': true,
  'snapshotVersion': 1,
  'scheduleSnapshot': {
    'version': 1,
    'pillName': 'Fictional reviewed medicine',
    'dosage': null,
    'frequency': 'daily',
    'frequencyDays': null,
    'hour': 8,
    'minute': 30,
    'timeZone': 'Europe/Bucharest',
    'profileId': 'review-server-person',
    'profileName': 'Fictional reviewed person',
  },
  'provenance': 'exact',
  'stateVersion': '0',
  'supersededAt': null,
  'supersededByOccurrenceId': null,
};

Map<String, dynamic> _reviewedRoutineChange() => {
  'schemaVersion': 2,
  'component': 'medicationBridge',
  'entityType': 'medication_occurrence',
  'entityId': 'review-server-occurrence',
  'operation': 'upsert',
  'sourceIdentity': {
    'sourceKind': 'occurrence',
    'sourceId': 'review-server-occurrence',
    'sourceRevision': '1',
  },
  'payload': _reviewedRoutineOccurrence(),
};

Map<String, dynamic> _historicalBridgeChange(Map<String, dynamic> payload) => {
  'schemaVersion': 2,
  'component': 'medicationBridge',
  'entityType': 'bridge_dose',
  'entityId': payload['id'],
  'operation': 'upsert',
  'sourceIdentity': {
    'sourceKind': 'legacy_dose_log',
    'sourceId': payload['id'],
    'sourceRevision': payload['sourceRevision'],
  },
  'payload': payload,
};

void _addHistoricalAncestors(
  Map<String, dynamic> payload, {
  bool deleted = false,
}) {
  const profileId = '33333333-3333-4333-8333-333333333333';
  final deletedAt = deleted ? '2026-01-01T00:00:00Z' : null;
  payload['parentProfile'] = {
    'kind': 'profile',
    'id': profileId,
    'userId': 'a',
    'name': 'Fictional canonical person',
    'avatarEmoji': '🙂',
    'isActive': false,
    'revision': '1',
    'deletedAt': deletedAt,
    'createdAt': '2025-01-01T00:00:00Z',
    'updatedAt': '2026-01-01T00:00:00Z',
  };
  payload['parentPill'] = {
    'kind': 'pill',
    'id': '11111111-1111-4111-8111-111111111111',
    'profileId': profileId,
    'name': 'Fictional canonical medicine',
    'dosage': 'Old dosage text',
    'notes': null,
    'color': null,
    'currentStock': -1,
    'lowStockThreshold': 0,
    'isPrn': false,
    'revision': '1',
    'deletedAt': deletedAt,
    'createdAt': '2025-01-01T00:00:00Z',
    'updatedAt': '2026-01-01T00:00:00Z',
  };
}

Future<void> _seedSyncedOrphan(AppDatabase db, Map<String, dynamic> payload) =>
    db.doseLogsDao.upsert(
      DoseLogsCompanion.insert(
        id: 'fictional-orphan-dose',
        scheduleId: payload['scheduleId'] as String,
        scheduledAt: DateTime.utc(2026, 9, 30, 5, 30),
        takenAt: Value(DateTime.utc(2026, 9, 30, 5, 32)),
        status: 'taken',
        note: const Value('Fictional private note'),
        createdAt: DateTime.utc(2026, 9, 30),
        updatedAt: DateTime.utc(2026, 9, 30),
        serverId: Value(payload['id'] as String),
        syncStatus: const Value('synced'),
      ),
    );

Future<void> _seedAncestorRows(
  AppDatabase db,
  Map<String, dynamic> payload, {
  String? profileAlias,
  String? pillAlias,
  bool includeProfile = true,
  bool includePill = true,
}) async {
  final profile = payload['parentProfile'] as Map<String, dynamic>;
  final pill = payload['parentPill'] as Map<String, dynamic>;
  final localProfileId = profileAlias ?? profile['id'] as String;
  if (includeProfile) {
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: localProfileId,
        userId: 'a',
        name: 'Retained local person text',
        createdAt: DateTime.parse(profile['createdAt'] as String),
        updatedAt: DateTime.parse(profile['updatedAt'] as String),
        serverId: Value(profile['id'] as String),
        syncStatus: const Value('synced'),
      ),
    );
  }
  if (includePill) {
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: pillAlias ?? pill['id'] as String,
        profileId: localProfileId,
        name: 'Retained local medication text',
        notes: const Value('Retained private medication note'),
        createdAt: DateTime.parse(pill['createdAt'] as String),
        updatedAt: DateTime.parse(pill['updatedAt'] as String),
        serverId: Value(pill['id'] as String),
        syncStatus: const Value('synced'),
      ),
    );
  }
}

Future<void> _seedHistoricalSchedule(
  AppDatabase db,
  Map<String, dynamic> payload,
) async {
  final parent = payload['parentSchedule'] as Map<String, dynamic>;
  await db.schedulesDao.upsert(
    SchedulesCompanion.insert(
      id: parent['id'] as String,
      pillId: parent['pillId'] as String,
      hour: parent['hour'] as int,
      minute: parent['minute'] as int,
      frequency: parent['frequency'] as String,
      frequencyDays: Value(
        parent['frequencyDays'] == null
            ? null
            : jsonEncode(parent['frequencyDays']),
      ),
      isActive: const Value(false),
      isDeleted: Value(parent['deletedAt'] != null),
      createdAt: DateTime.parse(parent['createdAt'] as String),
      updatedAt: DateTime.parse(parent['updatedAt'] as String),
      serverId: Value(parent['id'] as String),
      syncStatus: const Value('synced'),
    ),
  );
}
