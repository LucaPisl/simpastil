import 'dart:async';
import 'dart:ui';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/projections/projection_identity.dart';
import 'package:simpastil/core/projections/projection_reconciler.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/core/sync/auto_sync_service.dart';
import 'package:simpastil/core/sync/sync_error_classifier.dart';
import 'package:simpastil/core/sync/sync_service.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/sync_status_notifier.dart';

class MockSyncService extends Mock implements SyncService {}

class _HungReconciler extends Mock implements ProjectionReconciler {
  int calls = 0;

  @override
  Future<ProjectionReconciliationReport?> reconcile({
    SessionIdentity? identity,
    Locale? locale,
    ProjectionIdentity? projectionIdentity,
  }) {
    calls++;
    return Completer<ProjectionReconciliationReport?>().future;
  }

  @override
  Future<ReconcileAllResult> reconcileAll({
    Locale? locale,
    bool refreshActiveActions = false,
    String? buildKey,
  }) {
    calls++;
    return Completer<ReconcileAllResult>().future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSyncService syncService;
  late StreamController<List<ConnectivityResult>> connectivity;
  late ProviderContainer container;
  late Provider<AutoSyncService> testAutoSyncProvider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    syncService = MockSyncService();
    connectivity = StreamController<List<ConnectivityResult>>.broadcast();
    testAutoSyncProvider = Provider<AutoSyncService>(
      (ref) =>
          AutoSyncService(ref: ref, connectivityStream: connectivity.stream),
    );
    container = ProviderContainer(
      overrides: [syncServiceProvider.overrideWithValue(syncService)],
    );
    addTearDown(container.dispose);
    addTearDown(connectivity.close);

    when(() => syncService.countPending()).thenAnswer((_) async => 0);
    when(
      () => syncService.countOperations(userId: any(named: 'userId')),
    ).thenAnswer((_) async => SyncOperationCounts.none);
    when(
      () => syncService.earliestRetryAt(userId: any(named: 'userId')),
    ).thenAnswer((_) async => null);
  });

  void stubSuccess() {
    when(
      () => syncService.flushPending(userId: any(named: 'userId')),
    ).thenAnswer((_) async {});
    when(
      () => syncService.pullFromServer(userId: any(named: 'userId')),
    ).thenAnswer((_) async => true);
  }

  void stubFailure() {
    when(
      () => syncService.flushPending(userId: any(named: 'userId')),
    ).thenAnswer((_) async {});
    when(
      () => syncService.pullFromServer(userId: any(named: 'userId')),
    ).thenAnswer((_) async => false);
  }

  test('successful sync reports success and keeps 5-minute cadence', () {
    fakeAsync((async) {
      stubSuccess();
      final sut = container.read(testAutoSyncProvider);
      sut.start('u1');
      async.flushMicrotasks();

      expect(container.read(syncStatusProvider).phase, SyncPhase.idle);
      expect(container.read(syncStatusProvider).lastSuccessAt, isNotNull);
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);

      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);

      sut.stop();
    });
  });

  test(
    'a sync already running in the background is not reported as failure',
    () {
      fakeAsync((async) {
        stubSuccess();
        var busy = true;
        when(
          () => syncService.pullFromServer(userId: any(named: 'userId')),
        ).thenAnswer((_) async {
          if (busy) throw const SyncBusyException();
          return true;
        });
        final sut = container.read(testAutoSyncProvider);
        sut.start('u1');
        async.flushMicrotasks();

        final status = container.read(syncStatusProvider);
        expect(status.phase, isNot(SyncPhase.failure));
        expect(status.lastSuccessAt, isNull);
        verify(() => syncService.pullFromServer(userId: 'u1')).called(1);

        busy = false;
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        verify(() => syncService.pullFromServer(userId: 'u1')).called(1);
        expect(container.read(syncStatusProvider).phase, SyncPhase.idle);
        expect(container.read(syncStatusProvider).lastSuccessAt, isNotNull);

        sut.stop();
      });
    },
  );

  test('completion from an earlier session generation is not published', () {
    fakeAsync((async) {
      stubSuccess();
      final oldPull = Completer<bool>();
      when(
        () => syncService.pullFromServer(userId: 'old-user'),
      ).thenAnswer((_) => oldPull.future);
      final sut = container.read(testAutoSyncProvider);

      sut.start('old-user', generation: 4);
      async.flushMicrotasks();
      verify(() => syncService.pullFromServer(userId: 'old-user')).called(1);

      sut.start('new-user', generation: 5);
      oldPull.complete(true);
      async.flushMicrotasks();

      verify(() => syncService.pullFromServer(userId: 'new-user')).called(1);
      expect(container.read(syncStatusProvider).phase, SyncPhase.idle);
      sut.stop();
    });
  });

  test('the sync waits for the connection scope to settle first', () {
    fakeAsync((async) {
      stubSuccess();
      final settled = Completer<void>();
      var settleCalls = 0;
      final gated = Provider<AutoSyncService>(
        (ref) => AutoSyncService(
          ref: ref,
          connectivityStream: connectivity.stream,
          settleScope: () {
            settleCalls++;
            return settled.future;
          },
        ),
      );
      final sut = container.read(gated);
      sut.start('u1');
      async.flushMicrotasks();

      expect(settleCalls, 1);
      verifyNever(
        () => syncService.pullFromServer(userId: any(named: 'userId')),
      );
      expect(container.read(syncStatusProvider).phase, SyncPhase.idle);

      settled.complete();
      async.flushMicrotasks();
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);
      expect(container.read(syncStatusProvider).lastSuccessAt, isNotNull);
      sut.stop();
    });
  });

  test('a successful sync clears a failure left over from before', () {
    fakeAsync((async) {
      SharedPreferences.setMockInitialValues({
        'sync_status_owner': 'u1',
        'last_sync_at': '2026-01-01T10:00:00.000',
        'sync_failing_since': '2026-01-02T10:00:00.000',
        'last_sync_error': 'SYNC_FAILED',
      });
      stubSuccess();
      final sut = container.read(testAutoSyncProvider);
      sut.start('u1');
      async.flushMicrotasks();

      final status = container.read(syncStatusProvider);
      expect(status.phase, SyncPhase.idle);
      expect(status.failingSince, isNull);
      expect(status.lastError, isNull);
      expect(
        status.lastSuccessAt!.isAfter(DateTime.parse('2026-01-01T10:00:00')),
        isTrue,
      );
      String? storedFailure = 'unread';
      SharedPreferences.getInstance().then((prefs) {
        storedFailure = prefs.getString('sync_failing_since');
      });
      async.flushMicrotasks();
      expect(storedFailure, isNull);
      sut.stop();
    });
  });

  test('signing in as another account starts from a clean sync status', () {
    fakeAsync((async) {
      SharedPreferences.setMockInitialValues({
        'sync_status_owner': 'old-user',
        'last_sync_at': '2026-01-01T10:00:00.000',
        'sync_failing_since': '2026-01-02T10:00:00.000',
        'last_sync_error': 'SYNC_FAILED',
      });
      final hung = Completer<bool>();
      when(
        () => syncService.flushPending(userId: any(named: 'userId')),
      ).thenAnswer((_) async {});
      when(
        () => syncService.pullFromServer(userId: any(named: 'userId')),
      ).thenAnswer((_) => hung.future);
      // The previous account's failure is on screen before the new sign-in.
      container.read(syncStatusProvider);
      async.flushMicrotasks();
      expect(container.read(syncStatusProvider).failingSince, isNotNull);

      final sut = container.read(testAutoSyncProvider);
      sut.start('new-user');
      async.flushMicrotasks();

      final status = container.read(syncStatusProvider);
      expect(status.phase, SyncPhase.syncing);
      expect(status.failingSince, isNull);
      expect(status.lastSuccessAt, isNull);
      sut.stop();
    });
  });

  // Timeline:
  //  t=0s    start → immediate sync fails (call #1), retry armed at t=30s, failureCount=1
  //  t=30s   retry fires, fails (call #2), retry armed at t=1m30s,  failureCount=2
  //  t=1m30s retry fires, fails (call #3), retry armed at t=3m30s,  failureCount=3
  //  t=3m30s retry fires, fails (call #4), retry armed at t=8m30s (cap),  failureCount=4
  //  --- elapse 90s to t=5m ---
  //  t=5m    periodic tick fires, fails (call #5); replaces cap retry → new retry at t=10m
  //  --- elapse 5m to t=10m ---
  //  t=10m   cap retry fires, fails (call #6)
  test('failure schedules backoff retries at 30s, 1m, 2m, then 5m cap', () {
    fakeAsync((async) {
      stubFailure();
      final sut = container.read(testAutoSyncProvider);
      sut.start('u1');
      async.flushMicrotasks();
      // t=0: initial sync failed
      expect(container.read(syncStatusProvider).phase, SyncPhase.failure);
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);

      // t=30s: first backoff rung
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);

      // t=1m30s: second backoff rung (1m later)
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);

      // t=3m30s: third backoff rung (2m later)
      async.elapse(const Duration(minutes: 2));
      async.flushMicrotasks();
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);

      // t=5m: advance 90s — periodic tick fires (not the cap retry which is at
      // t=8m30s). The periodic-tick failure replaces the cap retry, re-arming
      // it at t=10m (5m from now). Exactly 1 call in this window.
      async.elapse(const Duration(seconds: 90));
      async.flushMicrotasks();
      verify(
        () => syncService.pullFromServer(userId: 'u1'),
      ).called(1); // periodic tick

      // t=10m: advance 5m — the re-armed cap retry fires. Exactly 1 call.
      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();
      verify(
        () => syncService.pullFromServer(userId: 'u1'),
      ).called(1); // cap retry

      sut.stop();
    });
  });

  test('failed pull retains component diagnostics on the first sync', () {
    fakeAsync((async) {
      stubFailure();
      const pull = SyncRunResult([
        SyncStageResult(
          stageId: 'stable',
          outcome: SyncComponentOutcome.failed(
            safeErrorCode: 'SYNC_STAGE_FAILED',
            httpStatusCode: 500,
          ),
        ),
      ]);
      when(() => syncService.lastPullOutcome).thenReturn(pull);
      final sut = container.read(testAutoSyncProvider);
      sut.start('u1');
      async.flushMicrotasks();

      final status = container.read(syncStatusProvider);
      expect(status.phase, SyncPhase.failure);
      expect(status.lastSuccessAt, isNull);
      expect(status.lastRun?.stages.single.stageId, 'pull.stable');
      expect(
        status.lastRun?.stages.single.outcome.safeErrorCode,
        'SYNC_STAGE_FAILED',
      );
      sut.stop();
    });
  });

  test('success after failure resets backoff and reports idle', () {
    fakeAsync((async) {
      stubFailure();
      final sut = container.read(testAutoSyncProvider);
      sut.start('u1');
      async.flushMicrotasks();

      stubSuccess();
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();

      expect(container.read(syncStatusProvider).phase, SyncPhase.idle);
      sut.stop();
    });
  });

  test('connectivity restoration triggers immediate retry while failing', () {
    fakeAsync((async) {
      stubFailure();
      final sut = container.read(testAutoSyncProvider);
      sut.start('u1');
      async.flushMicrotasks();
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);

      stubSuccess();
      connectivity.add([ConnectivityResult.wifi]);
      async.flushMicrotasks();

      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);
      expect(container.read(syncStatusProvider).phase, SyncPhase.idle);
      sut.stop();
    });
  });

  test('connectivity events are ignored when not failing', () {
    fakeAsync((async) {
      stubSuccess();
      final sut = container.read(testAutoSyncProvider);
      sut.start('u1');
      async.flushMicrotasks();
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);

      connectivity.add([ConnectivityResult.wifi]);
      async.flushMicrotasks();
      verifyNever(() => syncService.pullFromServer(userId: 'u1'));
      sut.stop();
    });
  });

  test('syncNow resets backoff ladder to 30s rung', () {
    // Timeline:
    //  t=0   start → immediate sync fails (call #1), retry armed at t=30s, failureCount=1
    //  t≈0   syncNow: resets failureCount=0, cancels retry, syncs → fails (call #2)
    //        _scheduleRetry uses backoffSteps[0]=30s, failureCount→1, retry at t≈30s
    //  t≈30s retry fires → fails (call #3) — proves ladder reset to 30s, not 1m
    fakeAsync((async) {
      stubFailure();
      final sut = container.read(testAutoSyncProvider);
      sut.start('u1');
      async.flushMicrotasks();
      // call #1 consumed
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);

      // syncNow resets failureCount to 0 before running; after failure it
      // re-arms at the 30s rung (not the 1m rung that start's failure would
      // have advanced to).
      unawaited(sut.syncNow('u1'));
      async.flushMicrotasks();
      // call #2 consumed
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);

      // Advance 30s — the reset ladder fires at the first rung.
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      // call #3: confirms 30s rung, not 1m
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);

      sut.stop();
    });
  });

  test('syncNow with success path reports idle immediately', () {
    fakeAsync((async) {
      stubFailure();
      final sut = container.read(testAutoSyncProvider);
      sut.start('u1');
      async.flushMicrotasks();

      stubSuccess();
      unawaited(sut.syncNow('u1'));
      async.flushMicrotasks();

      expect(container.read(syncStatusProvider).phase, SyncPhase.idle);
      sut.stop();
    });
  });

  test('explicit sync waits for one fresh pass after an in-flight pull', () {
    fakeAsync((async) {
      final first = Completer<bool>();
      final second = Completer<bool>();
      var pulls = 0;
      when(
        () => syncService.flushPending(userId: any(named: 'userId')),
      ).thenAnswer((_) async {});
      when(
        () => syncService.pullFromServer(userId: any(named: 'userId')),
      ).thenAnswer((_) => ++pulls == 1 ? first.future : second.future);
      final sut = container.read(testAutoSyncProvider);
      sut.start('u1');
      async.flushMicrotasks();
      var completed = false;
      unawaited(sut.syncNow('u1').then((_) => completed = true));
      unawaited(sut.syncNow('u1'));
      async.flushMicrotasks();
      expect(pulls, 1);
      expect(completed, isFalse);
      first.complete(true);
      async.flushMicrotasks();
      expect(pulls, 2);
      expect(completed, isFalse);
      second.complete(true);
      async.flushMicrotasks();
      expect(completed, isTrue);
      expect(pulls, 2);
      expect(container.read(syncStatusProvider).phase, SyncPhase.idle);
      sut.stop();
    });
  });

  for (final switchSession in [false, true]) {
    test(
      'queued explicit sync cancels on ${switchSession ? 'session change' : 'stop'}',
      () {
        fakeAsync((async) {
          final first = Completer<bool>();
          final users = <String>[];
          when(
            () => syncService.flushPending(userId: any(named: 'userId')),
          ).thenAnswer((_) async {});
          when(
            () => syncService.pullFromServer(userId: any(named: 'userId')),
          ).thenAnswer((invocation) {
            users.add(invocation.namedArguments[#userId] as String);
            return users.length == 1 ? first.future : Future.value(true);
          });
          final sut = container.read(testAutoSyncProvider);
          sut.start('u1', generation: 1);
          async.flushMicrotasks();
          unawaited(sut.syncNow('u1', generation: 1));
          async.flushMicrotasks();
          if (switchSession) {
            sut.start('u2', generation: 2);
          } else {
            sut.stop();
          }
          first.complete(true);
          async.flushMicrotasks();
          expect(users, switchSession ? ['u1', 'u2'] : ['u1']);
          sut.stop();
        });
      },
    );
  }

  test('401 auth failure records no sync failure and arms no retry', () {
    // Auth failures belong to the AuthInterceptor logout gate — they must
    // not surface as a sync failure (which would persist a false
    // sync_failing_since marker) and must not start the backoff ladder.
    fakeAsync((async) {
      when(
        () => syncService.flushPending(userId: any(named: 'userId')),
      ).thenAnswer((_) async {});
      when(
        () => syncService.pullFromServer(userId: any(named: 'userId')),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/profiles'),
          response: Response<void>(
            requestOptions: RequestOptions(path: '/profiles'),
            statusCode: 401,
          ),
          type: DioExceptionType.badResponse,
        ),
      );
      final sut = container.read(testAutoSyncProvider);
      sut.start('u1');
      async.flushMicrotasks();

      // Consume the initial attempt.
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);
      // Status rolled back to idle — not failure.
      expect(container.read(syncStatusProvider).phase, SyncPhase.idle);
      expect(container.read(syncStatusProvider).failingSince, isNull);

      // No backoff retry armed: elapse past the 30s rung (still under the
      // 5-minute periodic tick) and verify silence.
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      verifyNever(() => syncService.pullFromServer(userId: 'u1'));

      // No false failure marker persisted.
      SharedPreferences? prefs;
      unawaited(SharedPreferences.getInstance().then((p) => prefs = p));
      async.flushMicrotasks();
      expect(prefs!.containsKey('sync_failing_since'), isFalse);

      sut.stop();
    });
  });

  test('stop prevents retry re-arm after in-flight failure completes', () {
    // A failure that completes after stop() must not re-arm a retry timer
    // for a logged-out user.
    fakeAsync((async) {
      final completer = Completer<bool>();
      when(
        () => syncService.flushPending(userId: any(named: 'userId')),
      ).thenAnswer((_) async {});
      when(
        () => syncService.pullFromServer(userId: any(named: 'userId')),
      ).thenAnswer((_) => completer.future);
      final sut = container.read(testAutoSyncProvider);
      sut.start('u1');
      async.flushMicrotasks();
      // sync is now in-flight; stop() clears _userId
      sut.stop();
      // in-flight failure resolves → _scheduleRetry sees _userId==null and returns
      completer.complete(false);
      async.flushMicrotasks();

      // No retry should fire — advance past every backoff step and verify silence.
      async.elapse(const Duration(minutes: 6));
      async.flushMicrotasks();
      // Only the 1 call from before stop() should ever have happened.
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);
    });
  });

  test('a reconcile that never completes does not hold the sync', () {
    fakeAsync((async) {
      stubSuccess();
      final hung = _HungReconciler();
      final local = ProviderContainer(
        overrides: [
          syncServiceProvider.overrideWithValue(syncService),
          projectionReconcilerProvider.overrideWithValue(hung),
        ],
      );
      addTearDown(local.dispose);
      final sut = local.read(
        Provider<AutoSyncService>(
          (ref) => AutoSyncService(
            ref: ref,
            connectivityStream: connectivity.stream,
            effectsTimeout: const Duration(seconds: 10),
          ),
        ),
      );
      var done = false;
      sut.syncNow('u1', generation: 1).then((_) => done = true);
      async.flushMicrotasks();
      expect(done, isFalse);
      async.elapse(const Duration(seconds: 11));
      async.flushMicrotasks();
      expect(hung.calls, 1);
      expect(done, isTrue);
      expect(local.read(syncStatusProvider).phase, SyncPhase.idle);
      expect(local.read(syncStatusProvider).lastSuccessAt, isNotNull);
      sut.stop();
    });
  });

  test('a hung pull times out without freeing the slot early', () {
    fakeAsync((async) {
      stubSuccess();
      final pull = Completer<bool>();
      when(
        () => syncService.pullFromServer(userId: any(named: 'userId')),
      ).thenAnswer((_) => pull.future);
      final sut = container.read(
        Provider<AutoSyncService>(
          (ref) => AutoSyncService(
            ref: ref,
            connectivityStream: connectivity.stream,
            pullTimeout: const Duration(seconds: 20),
          ),
        ),
      );
      sut.start('u1');
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 21));
      async.flushMicrotasks();
      // Still syncing in the background, not a failure.
      expect(
        container.read(syncStatusProvider).phase,
        isNot(SyncPhase.failure),
      );
      // The hung pull still runs, so the 30s retry must not start a second.
      async.elapse(const Duration(seconds: 31));
      async.flushMicrotasks();
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);
      pull.complete(true);
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);
      sut.stop();
    });
  });

  test('silent busy retries never flip the banner and back off', () {
    fakeAsync((async) {
      stubSuccess();
      var busy = true;
      when(
        () => syncService.pullFromServer(userId: any(named: 'userId')),
      ).thenAnswer((_) async {
        if (busy) throw const SyncBusyException();
        return true;
      });
      final phases = <SyncPhase>[];
      container.listen(syncStatusProvider, (_, next) => phases.add(next.phase));
      final sut = container.read(testAutoSyncProvider);
      sut.start('u1');
      async.flushMicrotasks();
      phases.clear();
      clearInteractions(syncService);
      // Busy again at 30s, 1m, 2m: invisible, and spaced on the ladder.
      for (final wait in const [30, 60, 120]) {
        async.elapse(Duration(seconds: wait - 1));
        async.flushMicrotasks();
        verifyNever(() => syncService.pullFromServer(userId: 'u1'));
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        verify(() => syncService.pullFromServer(userId: 'u1')).called(1);
        clearInteractions(syncService);
      }
      expect(phases, isEmpty);
      busy = false;
      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();
      expect(container.read(syncStatusProvider).phase, SyncPhase.idle);
      sut.stop();
    });
  });

  test('a partial result backs off instead of waiting for the next tick', () {
    fakeAsync((async) {
      stubSuccess();
      when(
        () => syncService.countOperations(userId: any(named: 'userId')),
      ).thenAnswer((_) async => const SyncOperationCounts(queued: 1));
      when(() => syncService.lastPullOutcome).thenReturn(
        const SyncRunResult([
          SyncStageResult(
            stageId: 'medication',
            outcome: SyncComponentOutcome.partiallySynced(
              safeErrorCode: 'SYNC_RETRY_SCHEDULED',
            ),
          ),
        ]),
      );
      final sut = container.read(testAutoSyncProvider);
      sut.start('u1');
      async.flushMicrotasks();
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);
      async.elapse(const Duration(seconds: 31));
      async.flushMicrotasks();
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);
      async.elapse(const Duration(seconds: 61));
      async.flushMicrotasks();
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);
      sut.stop();
    });
  });

  const partialRun = SyncRunResult([
    SyncStageResult(
      stageId: 'medication',
      outcome: SyncComponentOutcome.partiallySynced(
        safeErrorCode: 'SYNC_RETRY_SCHEDULED',
      ),
    ),
  ]);

  test('a stuck change alone does not re-arm a visible retry', () {
    fakeAsync((async) {
      stubSuccess();
      when(() => syncService.lastPullOutcome).thenReturn(partialRun);
      when(
        () => syncService.countOperations(userId: any(named: 'userId')),
      ).thenAnswer(
        (_) async => const SyncOperationCounts(blocked: 1, conflict: 1),
      );
      final phases = <SyncPhase>[];
      container.listen(syncStatusProvider, (_, next) => phases.add(next.phase));
      final sut = container.read(testAutoSyncProvider);
      sut.start('u1');
      async.flushMicrotasks();
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);
      phases.clear();
      // Nothing but the 5-minute tick: no 30s/1m ladder retries.
      async.elapse(const Duration(minutes: 4));
      async.flushMicrotasks();
      verifyNever(() => syncService.pullFromServer(userId: 'u1'));
      expect(phases, isEmpty);
      sut.stop();
    });
  });

  test('a retrying change is looked at when due, silently', () {
    fakeAsync((async) {
      stubSuccess();
      when(() => syncService.lastPullOutcome).thenReturn(partialRun);
      when(
        () => syncService.countOperations(userId: any(named: 'userId')),
      ).thenAnswer((_) async => const SyncOperationCounts(retrying: 1));
      when(
        () => syncService.earliestRetryAt(userId: any(named: 'userId')),
      ).thenAnswer(
        (_) async => DateTime.now().toUtc().add(const Duration(seconds: 90)),
      );
      final phases = <SyncPhase>[];
      container.listen(syncStatusProvider, (_, next) => phases.add(next.phase));
      final sut = container.read(testAutoSyncProvider);
      sut.start('u1');
      async.flushMicrotasks();
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);
      phases.clear();
      async.elapse(const Duration(seconds: 80));
      async.flushMicrotasks();
      verifyNever(() => syncService.pullFromServer(userId: 'u1'));
      async.elapse(const Duration(seconds: 15));
      async.flushMicrotasks();
      verify(() => syncService.pullFromServer(userId: 'u1')).called(1);
      expect(phases, isNot(contains(SyncPhase.syncing)));
      sut.stop();
    });
  });

  test('syncNow and drain wait for a timed-out stage and keep the bypass', () {
    fakeAsync((async) {
      stubSuccess();
      final pull = Completer<bool>();
      when(
        () => syncService.pullFromServer(userId: any(named: 'userId')),
      ).thenAnswer((_) => pull.future);
      when(
        () => syncService.makeRetriesEligibleNow(userId: any(named: 'userId')),
      ).thenAnswer((_) async {});
      final sut = container.read(
        Provider<AutoSyncService>(
          (ref) => AutoSyncService(
            ref: ref,
            connectivityStream: connectivity.stream,
            pullTimeout: const Duration(seconds: 20),
          ),
        ),
      );
      sut.start('u1');
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 21));
      async.flushMicrotasks();
      var drained = false;
      var synced = false;
      sut.drain().then((_) => drained = true);
      sut.syncNow('u1').then((_) => synced = true);
      async.flushMicrotasks();
      // The straggler is still writing: both wait, and nothing was consumed.
      expect(drained, isFalse);
      expect(synced, isFalse);
      verifyNever(
        () => syncService.makeRetriesEligibleNow(userId: any(named: 'userId')),
      );
      pull.complete(true);
      async.flushMicrotasks();
      expect(drained, isTrue);
      expect(synced, isTrue);
      sut.stop();
    });
  });

  test('a straggler that ends after a timeout publishes quietly and arms '
      'no visible retry', () {
    fakeAsync((async) {
      stubSuccess();
      final pull = Completer<bool>();
      var pulls = 0;
      when(
        () => syncService.pullFromServer(userId: any(named: 'userId')),
      ).thenAnswer((_) => ++pulls == 1 ? pull.future : Future.value(true));
      final sut = container.read(
        Provider<AutoSyncService>(
          (ref) => AutoSyncService(
            ref: ref,
            connectivityStream: connectivity.stream,
            pullTimeout: const Duration(seconds: 20),
          ),
        ),
      );
      final phases = <SyncPhase>[];
      container.listen(syncStatusProvider, (_, next) => phases.add(next.phase));
      sut.start('u1');
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 21));
      async.flushMicrotasks();
      // A timeout of a bounded stage is not a failure: the stage still runs.
      expect(
        container.read(syncStatusProvider).phase,
        isNot(SyncPhase.failure),
      );
      expect(container.read(syncStatusProvider).failingSince, isNull);
      expect(container.read(syncStatusProvider).lastError, isNull);

      // No ladder retry fires while the straggler holds the slot.
      phases.clear();
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(pulls, 1);
      expect(phases, isEmpty);

      // The straggler ends: only a silent run follows (no syncing flip), and
      // it publishes the real outcome.
      pull.complete(true);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 6));
      async.flushMicrotasks();
      expect(pulls, 2);
      expect(phases, isNot(contains(SyncPhase.syncing)));
      expect(container.read(syncStatusProvider).phase, SyncPhase.idle);
      sut.stop();
    });
  });

  group('a stage that never finishes', () {
    AutoSyncService build() => container.read(
      Provider<AutoSyncService>(
        (ref) => AutoSyncService(
          ref: ref,
          connectivityStream: connectivity.stream,
          pullTimeout: const Duration(seconds: 20),
        ),
      ),
    );

    test('is reported as a failure after three stage limits, keeps the slot '
        'and never blocks a later sync request', () {
      fakeAsync((async) {
        stubSuccess();
        final pull = Completer<bool>();
        var pulls = 0;
        when(
          () => syncService.pullFromServer(userId: any(named: 'userId')),
        ).thenAnswer((_) => ++pulls == 1 ? pull.future : Future.value(true));
        when(
          () =>
              syncService.makeRetriesEligibleNow(userId: any(named: 'userId')),
        ).thenAnswer((_) async {});
        final sut = build();
        sut.start('u1');
        async.flushMicrotasks();

        // One limit: still just syncing, nothing reported yet.
        async.elapse(const Duration(seconds: 21));
        async.flushMicrotasks();
        expect(container.read(syncStatusProvider).lastError, isNull);

        // Three limits: the failure is published.
        async.elapse(const Duration(seconds: 40));
        async.flushMicrotasks();
        var status = container.read(syncStatusProvider);
        expect(status.phase, SyncPhase.failure);
        expect(status.lastError, isNotNull);
        expect(status.failingSince, isNotNull);

        // The slot is still taken: retries never start a second pull.
        async.elapse(const Duration(minutes: 3));
        async.flushMicrotasks();
        expect(pulls, 1);
        expect(container.read(syncStatusProvider).phase, SyncPhase.failure);

        // Neither an explicit request nor teardown waits for the straggler.
        var synced = false;
        var drained = false;
        sut.syncNow('u1').then((_) => synced = true);
        sut.drain().then((_) => drained = true);
        async.flushMicrotasks();
        expect(synced, isTrue);
        expect(drained, isTrue);
        expect(pulls, 1);

        // If it ends after all, a quiet run replaces the failure.
        pull.complete(true);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();
        expect(pulls, 2);
        status = container.read(syncStatusProvider);
        expect(status.phase, SyncPhase.idle);
        expect(status.failingSince, isNull);
        sut.stop();
      });
    });

    test('a straggler that ends before the watchdog reports nothing', () {
      fakeAsync((async) {
        stubSuccess();
        final pull = Completer<bool>();
        var pulls = 0;
        when(
          () => syncService.pullFromServer(userId: any(named: 'userId')),
        ).thenAnswer((_) => ++pulls == 1 ? pull.future : Future.value(true));
        final sut = build();
        sut.start('u1');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        pull.complete(true);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 2));
        async.flushMicrotasks();
        expect(container.read(syncStatusProvider).lastError, isNull);
        expect(container.read(syncStatusProvider).phase, SyncPhase.idle);
        sut.stop();
      });
    });
  });
}
