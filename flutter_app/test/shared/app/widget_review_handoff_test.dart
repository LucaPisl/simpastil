import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/notifications/notification_action_handler.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
import 'package:simpastil/core/protection/app_lock_controller.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/core/session/session_runtime_coordinator.dart';
import 'package:simpastil/core/sync/sync_service.dart';
import 'package:simpastil/main.dart';
import 'package:simpastil/core/widget/widget_action_handler.dart';
import 'package:simpastil/shared/app/widget_review_handoff.dart';
import 'package:simpastil/shared/router/app_router.dart';

import '../../helpers/care_recording_fixture.dart';

const _widgetChannel = MethodChannel('home_widget');
const _widgetUpdates = MethodChannel('home_widget/updates');

class _NotificationInbox extends ValueNotifier<NotificationReviewRequest?> {
  _NotificationInbox(super.value);
  bool get isSubscribed => hasListeners;
}

class _Authentication implements DeviceAuthenticator {
  bool accepted = true;
  @override
  void Function(String)? onCredentialPromptPaused;
  @override
  void Function(String)? onCredentialPromptResumed;
  @override
  Future<bool> isSupported() async => true;
  @override
  Future<DeviceAuthenticationContext> context() async =>
      const DeviceAuthenticationContext(leaveGeneration: 0, foreground: true);
  @override
  Future<bool> authenticate(
    String reason, {
    required String attemptId,
    String? fallbackLabel,
  }) async => accepted;
}

class _Harness {
  _Harness(this.care, this.controller, this.router, this.container, this.dio);
  final CareRecordingFixture care;
  final AppLockController controller;
  final GoRouter router;
  final ProviderContainer container;
  final Dio dio;
  static Future<_Harness> create() async {
    SharedPreferences.setMockInitialValues({legacyAppLockKey: true});
    final preferences = await SharedPreferences.getInstance();
    final care = await CareRecordingFixture.create(preferences: preferences);
    await care.db
        .into(care.db.devicePersonReminders)
        .insertOnConflictUpdate(
          DevicePersonRemindersCompanion.insert(
            profileId: care.person.id,
            enabled: const Value(true),
          ),
        );
    final controller = AppLockController(
      AppLockPolicyStore(
        SharedAppLockPolicyStorage(preferences),
        gate: SerialProjectionEffectsGate(),
      ),
      _Authentication(),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('Existing care route')),
        ),
        GoRoute(
          path: '/doses/:id',
          builder: (_, state) =>
              Scaffold(body: Text('Review ${state.pathParameters['id']}')),
        ),
      ],
    );
    final dio = Dio();
    final container = await care.workspace.createContainer(
      extraOverrides: [
        appLockControllerProvider.overrideWith((_) => controller),
        routerProvider.overrideWithValue(router),
        syncServiceProvider.overrideWithValue(
          SyncService(db: care.db, dio: dio, isOnline: () async => false),
        ),
        sessionRuntimeCoordinatorProvider.overrideWithValue(
          SessionRuntimeCoordinator(
            generations: SessionGenerationRepository(preferences),
            startSync: (_, _) {},
            stopSync: () {},
          ),
        ),
        foregroundProjectionOperationsProvider.overrideWithValue(
          ForegroundProjectionOperations(
            initializeNotifications: () async {},
            initializeBackgroundSync: () async {},
            initializeWidget: () async {},
            reconcileReminders: () async {},
            refreshWidget: () async {},
            checkStock: () async {},
          ),
        ),
      ],
    );
    return _Harness(care, controller, router, container, dio);
  }

  Uri get uri {
    final c = care.workspace.context;
    final o = care.occurrence;
    return Uri(
      scheme: 'simpastil',
      host: 'take',
      queryParameters: {
        'version': '2',
        'active_user_id': c.ownerUserId,
        'session_generation': '${c.accessEpoch}',
        'workspaceId': c.workspaceId,
        'grantEpoch': '${c.accessEpoch}',
        'occurrenceId': o.id,
        'stateVersion': '${o.stateVersion}',
        'projectionId': widgetProjectionId(
          userId: c.ownerUserId,
          sessionGeneration: c.accessEpoch,
          occurrenceId: o.id,
          workspaceId: c.workspaceId,
          grantEpoch: c.accessEpoch,
          stateVersion: o.stateVersion,
        ),
      },
    );
  }

  Widget get app => UncontrolledProviderScope(
    container: container,
    child: const SimpastilRuntime(),
  );
  Widget withValidator(Future<String?> Function(Uri) validate) =>
      UncontrolledProviderScope(
        container: container,
        child: WidgetReviewHandoff(
          validate: validate,
          child: const SimpastilApp(),
        ),
      );
  NotificationResponse notification(String action) {
    final c = care.workspace.context;
    final o = care.occurrence;
    final projectionId = reminderProjectionId(
      userId: c.ownerUserId,
      sessionGeneration: c.accessEpoch,
      occurrenceId: o.id,
      kind: 'reminder',
      workspaceId: c.workspaceId,
      grantEpoch: c.accessEpoch,
      stateVersion: o.stateVersion,
    );
    return NotificationResponse(
      id: notificationIdForProjection(projectionId),
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      actionId: action,
      input: 'original delivered input',
      payload: jsonEncode({
        'version': 2,
        'workspaceId': c.workspaceId,
        'grantEpoch': c.accessEpoch,
        'userId': c.ownerUserId,
        'sessionGeneration': c.accessEpoch,
        'occurrenceId': o.id,
        'stateVersion': o.stateVersion,
        'projectionId': projectionId,
      }),
    );
  }

  Widget withNotifications(
    ValueNotifier<NotificationReviewRequest?> inbox, {
    required Future<String?> Function(NotificationResponse) validate,
    required Future<void> Function(NotificationResponse, void Function(String))
    dispatch,
  }) => UncontrolledProviderScope(
    container: container,
    child: WidgetReviewHandoff(
      validate: this.validate,
      notifications: inbox,
      validateNotification: validate,
      dispatchNotification: dispatch,
      child: const SimpastilApp(),
    ),
  );

  Future<String?> validate(Uri uri) => validateWidgetActionForReview(
    uri,
    db: care.db,
    access: care.workspace.access,
  );
  Future<void> dispose() async {
    container.dispose();
    router.dispose();
    dio.close(force: true);
    await care.db.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Harness h;
  var listening = false;
  Future<String?> Function()? initial;

  setUp(() async {
    tz_data.initializeTimeZones();
    h = await _Harness.create();
    listening = false;
    initial = () async => h.uri.toString();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_widgetUpdates, (call) async {
      listening = call.method == 'listen';
      return null;
    });
    messenger.setMockMethodCallHandler(_widgetChannel, (call) async {
      if (call.method == 'initiallyLaunchedFromHomeWidget') {
        expect(
          listening,
          isTrue,
          reason: 'Warm subscription precedes cold read',
        );
        return initial?.call();
      }
      return null;
    });
  });
  tearDown(() async {
    await h.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_widgetChannel, null);
    messenger.setMockMethodCallHandler(_widgetUpdates, null);
  });

  Future<void> mount(WidgetTester tester, {Widget? app}) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(app ?? h.app);
    await tester.pumpAndSettle();
  }

  Future<void> click(WidgetTester tester, Uri uri) async {
    tester.binding.channelBuffers.push(
      'home_widget/updates',
      const StandardMethodCodec().encodeSuccessEnvelope(uri.toString()),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  Future<void> unlock(WidgetTester tester) async {
    await tester.tap(find.text('Unlock'));
    await _flushUntil(tester, () => !h.controller.current.isAuthenticating);
  }

  Finder getReview() => find.text('Review ${h.care.occurrence.id}');

  testWidgets(
    'cold widget entry waits for unlock then reviews exact pending dose without recording',
    (tester) async {
      expect(
        await validateWidgetActionForReview(
          h.uri,
          db: h.care.db,
          access: h.care.workspace.access,
        ),
        h.care.occurrence.id,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(h.app);
      await tester.pumpAndSettle();
      expect(find.text('Unlock'), findsOneWidget);
      expect(h.router.canPop(), isFalse);
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      await _flushUntil(
        tester,
        () => find.text('Review ${h.care.occurrence.id}').evaluate().isNotEmpty,
      );
      expect(find.text('Review ${h.care.occurrence.id}'), findsOneWidget);
      expect(h.router.canPop(), isTrue);
      expect(
        (await h.care.db.medicationLedgerDao.getOccurrenceById(
          h.care.occurrence.id,
        ))!.state,
        'pending',
      );
      expect(await h.care.db.select(h.care.db.occurrenceEvents).get(), isEmpty);
      expect(
        await h.care.db.select(h.care.db.pendingOperations).get(),
        isEmpty,
      );
    },
  );

  testWidgets(
    'warm click reviews after cancelled unlock is retried, without recording',
    (tester) async {
      initial = () async => null;
      await mount(tester);
      await click(tester, h.uri);
      (h.controller.authenticator as _Authentication).accepted = false;
      await unlock(tester);
      expect(find.text('Unlock'), findsOneWidget);
      expect(h.router.canPop(), isFalse);
      expect(await h.care.db.select(h.care.db.occurrenceEvents).get(), isEmpty);
      (h.controller.authenticator as _Authentication).accepted = true;
      await unlock(tester);
      await _flushUntil(tester, () => getReview().evaluate().isNotEmpty);
      expect(getReview(), findsOneWidget);
      expect(await h.care.db.select(h.care.db.occurrenceEvents).get(), isEmpty);
      h.router.pop();
      await tester.pumpAndSettle();
      expect(find.text('Existing care route'), findsOneWidget);
    },
  );

  testWidgets('a warm request wins over a late cold-launch response', (
    tester,
  ) async {
    final cold = Completer<String?>();
    initial = () => cold.future;
    await mount(tester);
    await click(tester, h.uri);
    cold.complete('simpastil://take?invalid=cold');
    await tester.pumpAndSettle();
    await unlock(tester);
    await _flushUntil(tester, () => getReview().evaluate().isNotEmpty);
    expect(getReview(), findsOneWidget);
    h.router.pop();
    await tester.pumpAndSettle();
    expect(h.router.canPop(), isFalse);
  });

  testWidgets(
    'full payload is validated again after unlock and refuses a changed occurrence',
    (tester) async {
      var validated = false;
      await mount(
        tester,
        app: h.withValidator((uri) async {
          final result = await h.validate(uri);
          validated = true;
          return result;
        }),
      );
      expect(validated, isFalse);
      await (h.care.db.update(h.care.db.medicationOccurrences)
            ..where((row) => row.id.equals(h.care.occurrence.id)))
          .write(const MedicationOccurrencesCompanion(stateVersion: Value(2)));
      expect(await h.validate(h.uri), isNull);
      await unlock(tester);
      await _flushUntil(tester, () => validated);
      expect(validated, isTrue);
      expect(getReview(), findsNothing);
      expect(find.text('Existing care route'), findsOneWidget);
      expect(h.router.canPop(), isFalse);
      expect(await h.care.db.select(h.care.db.occurrenceEvents).get(), isEmpty);
    },
  );

  testWidgets(
    'latest tap supersedes an in-flight validation before any navigation',
    (tester) async {
      initial = () async => null;
      final held = Completer<String?>();
      final calls = <Uri>[];
      await mount(
        tester,
        app: h.withValidator((uri) {
          calls.add(uri);
          return calls.length == 1 ? held.future : h.validate(uri);
        }),
      );
      await unlock(tester);
      await click(tester, h.uri);
      expect(calls, [h.uri]);
      final latest = h.uri.replace(host: 'skip');
      await click(tester, latest);
      held.complete('superseded-target');
      await _flushUntil(tester, () => getReview().evaluate().isNotEmpty);
      expect(calls, [h.uri, latest]);
      expect(find.text('Review superseded-target'), findsNothing);
      expect(getReview(), findsOneWidget);
      h.router.pop();
      await tester.pumpAndSettle();
      expect(h.router.canPop(), isFalse);
      expect(await h.care.db.select(h.care.db.occurrenceEvents).get(), isEmpty);
    },
  );

  testWidgets(
    'background during validation requires a fresh unlock and validation',
    (tester) async {
      initial = () async => null;
      final held = Completer<String?>();
      var calls = 0;
      await mount(
        tester,
        app: h.withValidator((uri) {
          calls++;
          return calls == 1 ? held.future : h.validate(uri);
        }),
      );
      await unlock(tester);
      await click(tester, h.uri);
      expect(calls, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      held.complete(h.care.occurrence.id);
      await tester.pumpAndSettle();
      expect(h.router.canPop(), isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Unlock'), findsOneWidget);
      expect(calls, 1);
      await unlock(tester);
      await _flushUntil(tester, () => getReview().evaluate().isNotEmpty);
      expect(calls, 2);
      expect(getReview(), findsOneWidget);
    },
  );

  for (final action in ['taken', 'skip', 'snooze']) {
    testWidgets(
      'locked $action notification keeps full response and only reviews after unlock',
      (tester) async {
        initial = () async => null;
        final response = h.notification(action);
        final inbox = _NotificationInbox(
          NotificationReviewRequest(response, isInitial: true),
        );
        addTearDown(inbox.dispose);
        final validated = <NotificationResponse>[];
        var dispatched = 0;
        await mount(
          tester,
          app: h.withNotifications(
            inbox,
            validate: (received) async {
              validated.add(received);
              return validateNotificationActionForReview(
                received,
                db: h.care.db,
                access: h.care.workspace.access,
              );
            },
            dispatch: (_, _) async {
              dispatched++;
            },
          ),
        );
        expect(validated, isEmpty);
        expect(dispatched, 0);
        (h.controller.authenticator as _Authentication).accepted = false;
        await unlock(tester);
        expect(find.text('Unlock'), findsOneWidget);
        expect(validated, isEmpty);
        expect(h.router.canPop(), isFalse);
        (h.controller.authenticator as _Authentication).accepted = true;
        await unlock(tester);
        await _flushUntil(tester, () => getReview().evaluate().isNotEmpty);
        expect(getReview(), findsOneWidget);
        expect(validated.single, same(response));
        expect(dispatched, 0);
        expect(
          await h.care.db.select(h.care.db.occurrenceEvents).get(),
          isEmpty,
        );
        expect(
          await h.care.db.select(h.care.db.pendingOperations).get(),
          isEmpty,
        );
      },
    );
  }

  for (final action in ['taken', 'skip', 'snooze']) {
    testWidgets(
      'off-policy warm $action delegates original complete response once',
      (tester) async {
        initial = () async => null;
        await tester.runAsync(
          () => h.controller.setEnabled(false, 'Test credential'),
        );
        final inbox = _NotificationInbox(null);
        addTearDown(inbox.dispose);
        final dispatched = <NotificationResponse>[];
        var validated = 0;
        await mount(
          tester,
          app: h.withNotifications(
            inbox,
            validate: (_) async {
              validated++;
              return h.care.occurrence.id;
            },
            dispatch: (response, _) async {
              dispatched.add(response);
            },
          ),
        );
        final response = h.notification(action);
        inbox.value = NotificationReviewRequest(response);
        await tester.pumpAndSettle();
        expect(dispatched, [same(response)]);
        expect(validated, 0);
        expect(
          inbox.value,
          isNull,
          reason: 'Consumed actions must not replay on remount.',
        );
        await tester.pumpWidget(const SizedBox());
        expect(inbox.isSubscribed, isFalse);
        await mount(
          tester,
          app: h.withNotifications(
            inbox,
            validate: (_) async {
              validated++;
              return null;
            },
            dispatch: (response, _) async {
              dispatched.add(response);
            },
          ),
        );
        expect(dispatched, hasLength(1));
      },
    );
  }

  testWidgets(
    'warm notification retains stale full identity and refuses review after unlock',
    (tester) async {
      initial = () async => null;
      final inbox = _NotificationInbox(null);
      addTearDown(inbox.dispose);
      var validated = false;
      var dispatched = false;
      await mount(
        tester,
        app: h.withNotifications(
          inbox,
          validate: (response) async {
            final id = await validateNotificationActionForReview(
              response,
              db: h.care.db,
              access: h.care.workspace.access,
            );
            validated = true;
            return id;
          },
          dispatch: (_, _) async {
            dispatched = true;
          },
        ),
      );
      inbox.value = NotificationReviewRequest(h.notification('taken'));
      await (h.care.db.update(h.care.db.medicationOccurrences)
            ..where((row) => row.id.equals(h.care.occurrence.id)))
          .write(const MedicationOccurrencesCompanion(stateVersion: Value(2)));
      await unlock(tester);
      await _flushUntil(tester, () => validated);
      expect(validated, isTrue);
      expect(dispatched, isFalse);
      expect(h.router.canPop(), isFalse);
      expect(await h.care.db.select(h.care.db.occurrenceEvents).get(), isEmpty);
    },
  );

  testWidgets(
    'latest notification supersedes in-flight review and ignores late cold launch',
    (tester) async {
      initial = () async => null;
      final inbox = _NotificationInbox(null);
      addTearDown(inbox.dispose);
      final held = Completer<String?>();
      final calls = <NotificationResponse>[];
      await mount(
        tester,
        app: h.withNotifications(
          inbox,
          validate: (response) {
            calls.add(response);
            return calls.length == 1
                ? held.future
                : Future.value(h.care.occurrence.id);
          },
          dispatch: (_, _) async {
            fail('Locked actions must never dispatch');
          },
        ),
      );
      await unlock(tester);
      final first = h.notification('taken');
      final latest = h.notification('skip');
      inbox.value = NotificationReviewRequest(first);
      await tester.pumpAndSettle();
      expect(calls, [same(first)]);
      inbox.value = NotificationReviewRequest(latest);
      inbox.value = NotificationReviewRequest(
        h.notification('snooze'),
        isInitial: true,
      );
      held.complete('superseded-dose');
      await _flushUntil(tester, () => getReview().evaluate().isNotEmpty);
      expect(calls, [same(first), same(latest)]);
      expect(find.text('Review superseded-dose'), findsNothing);
      expect(getReview(), findsOneWidget);
      h.router.pop();
      await tester.pumpAndSettle();
      expect(h.router.canPop(), isFalse);
    },
  );

  testWidgets(
    'notification received while locked remains review-only after policy is disabled',
    (tester) async {
      initial = () async => null;
      final inbox = _NotificationInbox(null);
      addTearDown(inbox.dispose);
      var validated = false;
      await mount(
        tester,
        app: h.withNotifications(
          inbox,
          validate: (_) async {
            validated = true;
            return h.care.occurrence.id;
          },
          dispatch: (_, _) async {
            fail('A formerly locked request cannot become a delayed Take');
          },
        ),
      );
      inbox.value = NotificationReviewRequest(h.notification('taken'));
      await tester.runAsync(
        () => h.controller.setEnabled(false, 'Test credential'),
      );
      await _flushUntil(tester, () => getReview().evaluate().isNotEmpty);
      expect(validated, isTrue);
      expect(getReview(), findsOneWidget);
      expect(await h.care.db.select(h.care.db.occurrenceEvents).get(), isEmpty);
    },
  );

  testWidgets('disposal cancels clicks and drops a late validation', (
    tester,
  ) async {
    initial = () async => null;
    final held = Completer<String?>();
    var calls = 0;
    await mount(
      tester,
      app: h.withValidator((_) {
        calls++;
        return held.future;
      }),
    );
    await unlock(tester);
    await click(tester, h.uri);
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(listening, isFalse);
    held.complete(h.care.occurrence.id);
    await tester.pumpAndSettle();
    expect(h.router.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _flushUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}
