import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/core/session/session_runtime_coordinator.dart';
import 'package:simpastil/core/startup/optional_capability.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/core/sync/sync_service.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/main.dart';
import 'package:simpastil/shared/app/startup_splash.dart';
import 'package:simpastil/shared/router/app_router.dart';

const _local = WorkspaceContext(
  workspaceId: 'fictional-local',
  ownerUserId: 'fictional-local-owner',
  authorId: 'fictional-author',
  kind: WorkspaceKind.local,
  accessEpoch: 1,
);
const _connected = WorkspaceContext(
  workspaceId: 'fictional-connected',
  ownerUserId: 'fictional-connected-owner',
  authorId: 'fictional-connected-author',
  kind: WorkspaceKind.connected,
  accessEpoch: 3,
  endpoint: 'https://fictional.test',
  sessionGeneration: 2,
  networkEpoch: 2,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Fixture fixture;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'biometric_lock_enabled': false,
      'dynamic_color_enabled': false,
    });
    fixture = _Fixture(await SharedPreferences.getInstance());
  });
  tearDown(() async {
    await fixture.dispose();
  });

  Future<void> mount(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(fixture.widget);
    await tester.pumpAndSettle();
    fixture.contexts.add(_local);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'local startup renders before plugins and then prepares reminders and stock',
    (tester) async {
      final ready = Completer<void>();
      fixture.notificationInitialization = () => ready.future;
      await mount(tester);
      expect(find.text('Care route'), findsOneWidget);
      expect(fixture.events, contains('widget'));
      expect(fixture.events, isNot(contains('reminders')));
      expect(fixture.events, isNot(contains('stock')));

      ready.complete();
      await tester.pumpAndSettle();
      expect(
        fixture.events.where((event) => event == 'reminders'),
        hasLength(1),
      );
      expect(fixture.events.where((event) => event == 'stock'), hasLength(1));
      expect(
        fixture.container
            .read(optionalCapabilityProvider)
            .isReady('notifications'),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local resume refreshes ready projections without creating a network identity',
    (tester) async {
      await mount(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      fixture.events.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fixture.events, containsAll(['reminders', 'stock', 'widget']));
      expect(fixture.runtime.resumes, 1);
      expect(fixture.runtime.pauses, 1);
      expect(fixture.runtime.activeIdentity, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'transient inactive and resume do not refresh care or restart the session',
    (tester) async {
      await mount(tester);
      final updated = <String>{};
      final subscription = fixture.db.tableUpdates().listen((batch) {
        updated.addAll(batch.map((update) => update.table));
      });
      addTearDown(subscription.cancel);
      fixture.events.clear();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(updated, isEmpty);
      expect(fixture.events, isEmpty);
      expect(fixture.runtime.resumes, 0);
      expect(fixture.runtime.pauses, 0);
      expect(find.text('Care route'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'runtime refreshes when startup returns before its lifecycle observer mounts',
    (tester) async {
      fixture.startupLifecycleMonitor.start();
      await tester.pumpWidget(const StartupSplash());
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      final updated = <String>{};
      final subscription = fixture.db.tableUpdates().listen((batch) {
        updated.addAll(batch.map((update) => update.table));
      });
      addTearDown(subscription.cancel);
      fixture.events.clear();

      await tester.pumpWidget(fixture.widget);
      await tester.pumpAndSettle();
      fixture.contexts.add(_local);
      await tester.pumpAndSettle();

      expect(
        updated,
        containsAll([
          fixture.db.medicationOccurrences.actualTableName,
          fixture.db.occurrenceEvents.actualTableName,
          fixture.db.careEventDetails.actualTableName,
          fixture.db.workspaceGrants.actualTableName,
          fixture.db.workspaceDeviceStates.actualTableName,
        ]),
      );
      expect(fixture.events, containsAll(['reminders', 'stock', 'widget']));
      expect(fixture.runtime.resumes, 1);
      expect(fixture.runtime.pauses, 0);
      expect(find.text('Care route'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'resume refreshes care and access reads even when native plugins are unavailable',
    (tester) async {
      fixture.notificationInitialization = () async =>
          throw StateError('fictional notifications unavailable');
      fixture.widgetInitialization = () async =>
          throw StateError('fictional widget unavailable');
      await mount(tester);
      expect(
        fixture.container
            .read(optionalCapabilityProvider)
            .isReady('notifications'),
        isFalse,
      );
      expect(
        fixture.container
            .read(optionalCapabilityProvider)
            .isReady('home_widget'),
        isFalse,
      );
      final updated = <String>{};
      final subscription = fixture.db.tableUpdates().listen((batch) {
        updated.addAll(batch.map((update) => update.table));
      });
      addTearDown(subscription.cancel);
      fixture.events.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(updated, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        updated,
        containsAll([
          fixture.db.medicationOccurrences.actualTableName,
          fixture.db.occurrenceEvents.actualTableName,
          fixture.db.careEventDetails.actualTableName,
          fixture.db.workspaceGrants.actualTableName,
          fixture.db.workspaceDeviceStates.actualTableName,
        ]),
      );
      expect(fixture.events, ['initialize-notifications']);
      expect(fixture.runtime.resumes, 1);
      expect(find.text('Care route'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('local midnight refreshes ready projections', (tester) async {
    await mount(tester);
    fixture.events.clear();
    fixture.now = DateTime(2026, 9, 30, 0, 0, 1);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(fixture.events, containsAll(['reminders', 'stock', 'widget']));
  });

  testWidgets(
    'pausing local care cancels midnight work and pauses network runtime',
    (tester) async {
      await mount(tester);
      fixture.events.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      fixture.now = DateTime(2026, 9, 30, 0, 0, 1);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(fixture.runtime.pauses, 1);
      expect(fixture.events, isEmpty);
    },
  );

  testWidgets(
    'resume respects readiness while a widget remains independently available',
    (tester) async {
      fixture.notificationInitialization = () async =>
          throw StateError('fictional plugin unavailable');
      await mount(tester);
      expect(
        fixture.container
            .read(optionalCapabilityProvider)
            .isReady('notifications'),
        isFalse,
      );
      fixture.events.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fixture.events, ['initialize-notifications', 'widget']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a failed reminder attempt does not suppress stock or widget refresh',
    (tester) async {
      await mount(tester);
      fixture.failReminders = true;
      fixture.events.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fixture.events, containsAll(['reminders', 'stock', 'widget']));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'startup reminder failure still attempts stock and independent widget recovery',
    (tester) async {
      fixture.failReminders = true;
      await mount(tester);
      expect(fixture.events, containsAll(['reminders', 'stock', 'widget']));
      expect(
        fixture.container
            .read(optionalCapabilityProvider)
            .isReady('notifications'),
        isFalse,
      );
      expect(
        fixture.container
            .read(optionalCapabilityProvider)
            .isReady('home_widget'),
        isTrue,
      );
      expect(find.text('Care route'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'startup reminder failure recovers on background return, not focus loss',
    (tester) async {
      fixture.failReminders = true;
      await mount(tester);
      expect(
        fixture.container
            .read(optionalCapabilityProvider)
            .isReady('notifications'),
        isFalse,
      );
      fixture.failReminders = false;
      fixture.events.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fixture.events, isEmpty);
      expect(
        fixture.container
            .read(optionalCapabilityProvider)
            .isReady('notifications'),
        isFalse,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        fixture.events.where((event) => event == 'reminders'),
        hasLength(1),
      );
      expect(
        fixture.container
            .read(optionalCapabilityProvider)
            .isReady('notifications'),
        isTrue,
      );
      expect(fixture.runtime.resumes, 1);
      expect(find.text('Care route'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'protected workspace changes refresh once and errors do not grant effects',
    (tester) async {
      await mount(tester);
      fixture.events.clear();
      // Streams reconstruct contexts; equality must use the captured values,
      // not Dart object identity or Riverpod's identical-value suppression.
      fixture.contexts.add(
        WorkspaceContext(
          workspaceId: _local.workspaceId,
          ownerUserId: _local.ownerUserId,
          authorId: _local.authorId,
          kind: _local.kind,
          accessEpoch: _local.accessEpoch,
        ),
      );
      await tester.pumpAndSettle();
      expect(fixture.events, isEmpty);
      fixture.contexts.addError(StateError('fictional store unavailable'));
      await tester.pumpAndSettle();
      expect(fixture.events, isEmpty);
      fixture.contexts.add(_connected);
      await tester.pumpAndSettle();
      expect(fixture.events, containsAll(['reminders', 'stock', 'widget']));
      expect(fixture.events.where((event) => event == 'widget'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'workspace changes while paused wait for the next foreground resume',
    (tester) async {
      await mount(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      fixture.events.clear();
      fixture.contexts.add(_connected);
      await tester.pumpAndSettle();
      expect(fixture.events, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fixture.events, containsAll(['reminders', 'stock', 'widget']));
    },
  );

  testWidgets(
    'late plugin initialization cannot trigger disposed root effects',
    (tester) async {
      final ready = Completer<void>();
      fixture.notificationInitialization = () => ready.future;
      await mount(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.events.clear();
      ready.complete();
      await tester.pumpAndSettle();
      expect(fixture.events, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Runtime extends SessionRuntimeCoordinator {
  _Runtime(SharedPreferences prefs)
    : super(
        generations: SessionGenerationRepository(prefs),
        startSync: (_, _) {},
        stopSync: () {},
      );
  int resumes = 0;
  int pauses = 0;
  @override
  Future<void> resume() async {
    resumes++;
  }

  @override
  Future<void> pause() async {
    pauses++;
  }
}

class _Fixture {
  _Fixture(SharedPreferences prefs) {
    runtime = _Runtime(prefs);
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        routerProvider.overrideWithValue(router),
        syncServiceProvider.overrideWithValue(
          SyncService(db: db, dio: dio, isOnline: () async => false),
        ),
        sessionRuntimeCoordinatorProvider.overrideWithValue(runtime),
        workspaceContextProvider.overrideWith((ref) => contexts.stream),
        foregroundProjectionOperationsProvider.overrideWithValue(
          ForegroundProjectionOperations(
            initializeNotifications: () async {
              events.add('initialize-notifications');
              await notificationInitialization();
            },
            initializeBackgroundSync: () async {},
            initializeWidget: () => widgetInitialization(),
            reconcileReminders: () async {
              events.add('reminders');
              if (failReminders) throw StateError('fictional reminder failure');
            },
            refreshWidget: () async {
              events.add('widget');
            },
            checkStock: () async {
              events.add('stock');
            },
          ),
        ),
      ],
    );
  }
  final db = AppDatabase.forTesting();
  final dio = Dio();
  final startupLifecycleMonitor = StartupLifecycleMonitor();
  final contexts = StreamController<WorkspaceContext>.broadcast();
  final events = <String>[];
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('Care route')),
      ),
    ],
  );
  late final ProviderContainer container;
  late final _Runtime runtime;
  DateTime now = DateTime(2026, 9, 29, 23, 59, 59);
  bool failReminders = false;
  Future<void> Function() notificationInitialization = () async {};
  Future<void> Function() widgetInitialization = () async {};
  Widget get widget => UncontrolledProviderScope(
    container: container,
    child: SimpastilRuntime(
      clock: () => now,
      startupLifecycleMonitor: startupLifecycleMonitor,
    ),
  );
  Future<void> dispose() async {
    container.dispose();
    router.dispose();
    startupLifecycleMonitor.dispose();
    dio.close(force: true);
    await contexts.close();
    await db.close();
  }
}
