import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/storage/portable_preference_writer.dart';
import 'package:simpastil/core/sync/auto_sync_service.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/sync_service.dart';
import 'package:simpastil/core/sync/sync_status_notifier.dart';

class _MockSyncService extends Mock implements SyncService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockSyncService syncService;
  late StreamController<List<ConnectivityResult>> connectivity;
  late StreamController<int> unsent;
  late ProviderContainer container;
  late Provider<AutoSyncService> provider;
  late List<String> calls;
  var pullSucceeds = true;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    syncService = _MockSyncService();
    connectivity = StreamController<List<ConnectivityResult>>.broadcast();
    unsent = StreamController<int>.broadcast();
    calls = [];
    pullSucceeds = true;
    provider = Provider<AutoSyncService>(
      (ref) => AutoSyncService(
        ref: ref,
        connectivityStream: connectivity.stream,
        unsentChanges: (_) => unsent.stream,
      ),
    );
    container = ProviderContainer(
      overrides: [syncServiceProvider.overrideWithValue(syncService)],
    );
    addTearDown(container.dispose);
    addTearDown(connectivity.close);
    addTearDown(unsent.close);

    when(
      () => syncService.countOperations(userId: any(named: 'userId')),
    ).thenAnswer((_) async => SyncOperationCounts.none);
    when(
      () => syncService.earliestRetryAt(userId: any(named: 'userId')),
    ).thenAnswer((_) async => null);
    when(
      () => syncService.flushPending(userId: any(named: 'userId')),
    ).thenAnswer((_) async => calls.add('flush'));
    when(
      () => syncService.pullFromServer(userId: any(named: 'userId')),
    ).thenAnswer((_) async {
      calls.add('pull');
      return pullSucceeds;
    });
  });

  test('a new local change is sent a few seconds later, flush first', () {
    fakeAsync((async) {
      final sut = container.read(provider)..start('u1');
      unsent.add(0);
      async.flushMicrotasks();
      calls.clear();

      unsent.add(1);
      async.elapse(const Duration(seconds: 2));
      expect(calls, isEmpty);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(calls, ['flush', 'pull']);
      sut.stop();
    });
  });

  test('a burst of changes goes out in one run', () {
    fakeAsync((async) {
      final sut = container.read(provider)..start('u1');
      unsent.add(0);
      async.flushMicrotasks();
      calls.clear();

      for (var n = 1; n <= 4; n++) {
        unsent.add(n);
        async.elapse(const Duration(seconds: 1));
      }
      async.elapse(AutoSyncService.sendSoonDelay);
      async.flushMicrotasks();
      expect(calls, ['flush', 'pull']);
      sut.stop();
    });
  });

  test('changes going out do not start another run', () {
    fakeAsync((async) {
      final sut = container.read(provider)..start('u1');
      unsent.add(3);
      async.flushMicrotasks();
      calls.clear();

      unsent.add(0);
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      expect(calls, isEmpty);
      sut.stop();
    });
  });

  test('while the server is failing the backoff decides, not the change', () {
    fakeAsync((async) {
      pullSucceeds = false;
      final sut = container.read(provider)..start('u1');
      unsent.add(0);
      async.flushMicrotasks();
      expect(container.read(syncStatusProvider).phase, SyncPhase.failure);
      calls.clear();

      unsent.add(1);
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      expect(calls, isEmpty);
      sut.stop();
    });
  });

  test('a change made while a run is going waits for it, then goes out', () {
    fakeAsync((async) {
      final sut = container.read(provider)..start('u1');
      unsent.add(0);
      async.flushMicrotasks();
      calls.clear();

      final gate = Completer<void>();
      when(
        () => syncService.flushPending(userId: any(named: 'userId')),
      ).thenAnswer((_) async {
        calls.add('flush');
        await gate.future;
      });
      sut.syncNow('u1');
      async.flushMicrotasks();
      unsent.add(1);
      async.elapse(AutoSyncService.sendSoonDelay);
      async.flushMicrotasks();
      expect(calls, ['flush']);

      when(
        () => syncService.flushPending(userId: any(named: 'userId')),
      ).thenAnswer((_) async => calls.add('flush'));
      gate.complete();
      async.flushMicrotasks();
      async.elapse(AutoSyncService.sendSoonDelay);
      async.flushMicrotasks();
      expect(calls, ['flush', 'pull', 'flush', 'pull']);
      sut.stop();
    });
  });

  test('signing out cancels a pending send', () {
    fakeAsync((async) {
      final sut = container.read(provider)..start('u1');
      unsent.add(0);
      async.flushMicrotasks();
      calls.clear();

      unsent.add(1);
      sut.stop();
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      expect(calls, isEmpty);
    });
  });

  test('the watch counts queued changes for the user only', () async {
    final db = AppDatabase.forTesting();
    addTearDown(db.close);
    final at = DateTime.utc(2026, 10, 23, 8);
    for (final id in ['u1', 'u2']) {
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: id,
          email: '$id@example.test',
          createdAt: at,
          updatedAt: at,
        ),
      );
    }
    Future<void> op(String id, String user, String state) => db
        .into(db.pendingOperations)
        .insert(
          PendingOperationsCompanion.insert(
            id: id,
            userId: user,
            mutationId: 'm-$id',
            component: 'medication',
            operationType: 'medication.command',
            contractVersion: 2,
            payloadJson: '{}',
            state: Value(state),
            createdAt: at,
          ),
        );
    final seen = <int>[];
    final sub = watchUnsentChanges(db, 'u1').listen(seen.add);
    addTearDown(sub.cancel);
    await pumpEventQueue();
    await op('a', 'u1', 'queued');
    await pumpEventQueue();
    await op('b', 'u2', 'queued');
    await op('c', 'u1', 'committed');
    await pumpEventQueue();
    expect(seen.first, 0);
    expect(seen.last, 1);
    expect(seen, contains(1));
  });

  test('a queued account settings edit counts as an unsent change', () async {
    final db = AppDatabase.forTesting();
    addTearDown(db.close);
    final seen = <int>[];
    final sub = watchUnsentChanges(db, 'u1').listen(seen.add);
    addTearDown(sub.cancel);
    await pumpEventQueue();
    await db
        .into(db.pendingAccountSettings)
        .insert(
          PendingAccountSettingsCompanion.insert(
            userId: 'u1',
            settingKey: 'reminders.snoozeMinutes',
            baseRevision: 0,
            queuedAt: DateTime.utc(2026, 10, 22),
          ),
        );
    await db
        .into(db.pendingAccountSettings)
        .insert(
          PendingAccountSettingsCompanion.insert(
            userId: 'u2',
            settingKey: 'reminders.snoozeMinutes',
            baseRevision: 0,
            queuedAt: DateTime.utc(2026, 10, 22),
          ),
        );
    await pumpEventQueue();
    expect(seen.first, 0);
    expect(seen.last, 1, reason: 'only this user\'s edit counts, and it rises');
  });

  test('a settings edit is sent a few seconds later, flush first', () {
    final writes = StreamController<String>.broadcast();
    addTearDown(writes.close);
    final withSettings = Provider<AutoSyncService>(
      (ref) => AutoSyncService(
        ref: ref,
        connectivityStream: connectivity.stream,
        unsentChanges: (_) => unsent.stream,
        settingWrites: writes.stream,
      ),
    );
    fakeAsync((async) {
      final sut = container.read(withSettings)..start('u1');
      async.flushMicrotasks();
      calls.clear();

      writes.add('snooze_duration_minutes_u1');
      async.elapse(const Duration(seconds: 2));
      expect(calls, isEmpty);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(calls, ['flush', 'pull']);

      sut.stop();
      calls.clear();
      writes.add('snooze_duration_minutes_u1');
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(calls, isEmpty, reason: 'nothing is sent after sign-out');
    });
  });

  test('a settings edit schedules exactly one run', () {
    final writes = StreamController<String>.broadcast();
    addTearDown(writes.close);
    final withSettings = Provider<AutoSyncService>(
      (ref) => AutoSyncService(
        ref: ref,
        connectivityStream: connectivity.stream,
        unsentChanges: (_) => unsent.stream,
        settingWrites: writes.stream,
      ),
    );
    fakeAsync((async) {
      final sut = container.read(withSettings)..start('u1');
      unsent.add(0);
      async.flushMicrotasks();
      // The flush queues the edit (the count rises), the send empties it.
      when(
        () => syncService.flushPending(userId: any(named: 'userId')),
      ).thenAnswer((_) async {
        calls.add('flush');
        unsent.add(1);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        unsent.add(0);
      });
      calls.clear();

      writes.add('recorded_by_mode_u1');
      async.elapse(AutoSyncService.sendSoonDelay);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 20));
      async.flushMicrotasks();
      expect(calls, ['flush', 'pull'], reason: 'no extra silent run');
      sut.stop();
    });
  });

  test(
    'the preference writer announces a recorded-by or Later edit once',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final seen = <String>[];
      final sub = portablePreferenceWrites.listen(seen.add);
      addTearDown(sub.cancel);
      final gate = _OpenGate();
      await PortablePreferenceWriter(
        prefs,
        gate: gate,
        announce: false,
      ).write('recorded_by_name_u1', 'Mum');
      await PortablePreferenceWriter(
        prefs,
        gate: gate,
      ).write('recorded_by_mode_u1', 'custom');
      await PortablePreferenceWriter(
        prefs,
        gate: gate,
      ).write('today_low_stock_dismissed', ['p|2026-10-24']);
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['recorded_by_mode_u1', 'today_low_stock_dismissed']);
      expect(
        () => PortablePreferenceWriter(
          prefs,
          gate: gate,
        ).write('some_other_key_u1', 'x'),
        throwsFormatException,
      );
    },
  );

  test(
    'the preference writer announces a person\'s edit, not the account\'s',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final seen = <String>[];
      final sub = portablePreferenceWrites.listen(seen.add);
      addTearDown(sub.cancel);
      final gate = _OpenGate();
      await PortablePreferenceWriter(
        prefs,
        gate: gate,
      ).write('app_locale', 'ro');
      await PortablePreferenceWriter(
        prefs,
        gate: gate,
        announce: false,
      ).write('app_locale', 'en');
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['app_locale']);
    },
  );
}

class _OpenGate implements ProjectionEffectsGate {
  @override
  Future<T> run<T>(Future<T> Function() action) => action();
}
