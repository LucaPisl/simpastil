import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/core/session/session_runtime_coordinator.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/projections/projection_identity.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  testWidgets('scheduleStartAfterFrame asks for a frame so an idle UI still '
      'starts the session', (tester) async {
    var started = 0;
    scheduleStartAfterFrame(() => started++);

    expect(started, 0);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump();
    expect(started, 1);
  });

  test(
    'generation advances monotonically and survives identity invalidation',
    () async {
      final repository = SessionGenerationRepository(prefs);

      final first = await repository.advanceTo('user-a');
      final second = await repository.advanceTo('user-a');
      final invalidated = await repository.advanceTo(null);

      expect(first, 1);
      expect(second, 2);
      expect(invalidated, 3);
      expect(await repository.currentIdentity(), isNull);
      expect(await repository.currentGeneration(), 3);
    },
  );

  test(
    'start is idempotent, pause preserves identity, and resume reuses generation',
    () async {
      final repository = SessionGenerationRepository(prefs);
      final generation = await repository.advanceTo('user-a');
      final starts = <(String, int)>[];
      var stops = 0;
      final runtime = SessionRuntimeCoordinator(
        generations: repository,
        startSync: (userId, value) => starts.add((userId, value)),
        stopSync: () => stops++,
      );

      await runtime.start('user-a', generation);
      await runtime.start('user-a', generation);
      await runtime.pause();
      await runtime.resume();

      expect(starts, [('user-a', generation), ('user-a', generation)]);
      expect(stops, 1);
      expect(await repository.currentIdentity(), ('user-a', generation));
    },
  );

  test(
    'logout invalidates generation before stopping, draining, and clearing projections',
    () async {
      final repository = SessionGenerationRepository(prefs);
      final generation = await repository.advanceTo('user-a');
      final events = <String>[];
      final runtime = SessionRuntimeCoordinator(
        generations: repository,
        startSync: (_, _) => events.add('start'),
        stopSync: () =>
            events.add('stop:${prefs.getInt('session_generation')}'),
        drainSync: () async => events.add('drain'),
        clearProjections: () async {
          events.add('projections:${prefs.getInt('session_generation')}');
        },
      );

      await runtime.start('user-a', generation);
      final nextGeneration = await runtime.invalidate();
      final repeatedGeneration = await runtime.invalidate();

      expect(nextGeneration, generation + 1);
      expect(repeatedGeneration, nextGeneration);
      expect(events, ['start', 'stop:2', 'drain', 'projections:2']);
      expect(await repository.currentIdentity(), isNull);
      expect(await repository.currentGeneration(), 2);
    },
  );

  test(
    'session start requests a projection for that exact generation',
    () async {
      final repository = SessionGenerationRepository(prefs);
      final generation = await repository.advanceTo('user-a');
      final reconciled = <(String, int)>[];
      final runtime = SessionRuntimeCoordinator(
        generations: repository,
        startSync: (_, _) {},
        stopSync: () {},
        reconcileProjections: (userId, value) async {
          reconciled.add((userId, value));
        },
      );

      await runtime.start('user-a', generation);
      await Future<void>.delayed(Duration.zero);

      expect(reconciled, [('user-a', generation)]);
    },
  );
  test(
    'new session startup is revalidated after delayed old teardown',
    () async {
      final repository = SessionGenerationRepository(prefs);
      final first = await repository.advanceTo('fictional-a');
      final draining = Completer<void>();
      final release = Completer<void>();
      final starts = <String>[];
      final runtime = SessionRuntimeCoordinator(
        generations: repository,
        startSync: (owner, _) => starts.add(owner),
        stopSync: () {},
        drainSync: () async {
          if (!draining.isCompleted) draining.complete();
          await release.future;
        },
      );
      await runtime.start('fictional-a', first);
      final b = await repository.advanceTo('fictional-b');
      final lateStart = runtime.start('fictional-b', b);
      await draining.future;
      final c = await repository.advanceTo('fictional-c');
      release.complete();
      await lateStart;
      expect(starts, [
        'fictional-a',
      ], reason: 'B became stale while A teardown waited');
      await runtime.start('fictional-c', c);
      expect(starts, ['fictional-a', 'fictional-c']);
    },
  );

  group('protected runtime ownership', () {
    late AppDatabase db;
    late WorkspaceAccessRepository access;
    late SessionGenerationRepository generations;
    Future<WorkspaceContext> authenticate(String slot, int generation) async {
      const endpoint = 'https://fictional.test/care';
      await db
          .into(db.credentialSlots)
          .insert(
            CredentialSlotsCompanion.insert(
              id: slot,
              ownerId: 'fictional-account',
              endpoint: endpoint,
              state: 'staged',
              createdAt: DateTime.now(),
            ),
          );
      await access.authenticate(
        ownerId: 'fictional-account',
        endpoint: endpoint,
        expectedNetworkEpoch:
            (await access.workspaces.deviceState()).networkEpoch,
        sessionGeneration: generation,
        credentialId: slot,
      );
      return (await access.contextForOwner('fictional-account'))!;
    }

    setUp(() async {
      db = AppDatabase.forTesting();
      access = WorkspaceAccessRepository(db);
      await access.configureEndpoint('https://fictional.test/care');
      generations = SessionGenerationRepository(prefs, access: access);
    });
    tearDown(() => db.close());
    test(
      'late captured teardown cannot stop a newer runtime or use global cleanup',
      () async {
        final first = await authenticate('fictional-slot-1', 1);
        final retired = <ProjectionIdentity>[];
        final starts = <int>[];
        final firstStarted = Completer<void>();
        final secondStarted = Completer<void>();
        var stops = 0;
        var global = 0;
        final runtime = SessionRuntimeCoordinator(
          generations: generations,
          access: access,
          startSync: (_, generation) {
            starts.add(generation);
            (generation == 1 ? firstStarted : secondStarted).complete();
          },
          stopSync: () => stops++,
          cancelNotifications: () async {
            global++;
          },
          clearProjections: () async {
            global++;
          },
          retireProjection: (identity) async {
            retired.add(identity);
          },
        );
        await runtime.start(first.ownerUserId, 1);
        await firstStarted.future;
        await access.revokeNetwork();
        final second = await authenticate('fictional-slot-2', 2);
        await runtime.start(second.ownerUserId, 2);
        await secondStarted.future;
        final stopsBefore = stops;
        await runtime.invalidate(
          captureActiveIdentity: false,
          identity: (first.ownerUserId, 1),
          projectionIdentity: ProjectionIdentity.fromContext(first),
        );
        expect(runtime.activeIdentity, (second.ownerUserId, 2));
        expect(stops, stopsBefore);
        expect(global, 0);
        expect(starts, [1, 2]);
        expect(
          retired.every(
            (identity) => identity == ProjectionIdentity.fromContext(first),
          ),
          isTrue,
        );
        expect(await access.currentNetworkCapability(), isNotNull);
      },
    );
    test(
      'queued new runtime starts only after captured old teardown completes',
      () async {
        final first = await authenticate('fictional-slot-1', 1);
        final entered = Completer<void>();
        final release = Completer<void>();
        final retired = <ProjectionIdentity>[];
        final starts = <int>[];
        final firstStarted = Completer<void>();
        final secondStarted = Completer<void>();
        final runtime = SessionRuntimeCoordinator(
          generations: generations,
          access: access,
          startSync: (_, generation) {
            starts.add(generation);
            (generation == 1 ? firstStarted : secondStarted).complete();
          },
          stopSync: () {},
          drainSync: () async {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          },
          retireProjection: (identity) async {
            retired.add(identity);
          },
        );
        await runtime.start(first.ownerUserId, 1);
        await firstStarted.future;
        await access.revokeNetwork();
        final invalidating = runtime.invalidate(
          captureActiveIdentity: false,
          identity: (first.ownerUserId, 1),
          projectionIdentity: ProjectionIdentity.fromContext(first),
        );
        await entered.future;
        final second = await authenticate('fictional-slot-2', 2);
        final starting = runtime.start(second.ownerUserId, 2);
        expect(starts, [1]);
        release.complete();
        await invalidating;
        await starting;
        await secondStarted.future;
        expect(starts, [1, 2]);
        expect(retired, [ProjectionIdentity.fromContext(first)]);
        expect(runtime.activeIdentity, (second.ownerUserId, 2));
      },
    );
    test(
      'deferred callback cannot start work after its grant is revoked',
      () async {
        final current = await authenticate('fictional-slot-1', 1);
        final callbacks = <void Function()>[];
        var starts = 0;
        final runtime = SessionRuntimeCoordinator(
          generations: generations,
          access: access,
          startSync: (_, _) => starts++,
          stopSync: () {},
          scheduleStart: callbacks.add,
        );
        await runtime.start(current.ownerUserId, 1);
        expect(callbacks, hasLength(1));
        await access.revokeNetwork();
        callbacks.single();
        await Future<void>.delayed(Duration.zero);
        expect(starts, 0);
      },
    );
    test(
      'unowned protected invalidation does not clear current workspace or widget',
      () async {
        final current = await authenticate('fictional-slot-1', 1);
        var effects = 0;
        final runtime = SessionRuntimeCoordinator(
          generations: generations,
          access: access,
          startSync: (_, _) {},
          stopSync: () => effects++,
          cancelNotifications: () async {
            effects++;
          },
          clearProjections: () async {
            effects++;
          },
          retireProjection: (_) async {
            effects++;
          },
        );
        await runtime.invalidate(captureActiveIdentity: false);
        expect(effects, 0);
        expect(await access.contextForOwner(current.ownerUserId), isNotNull);
      },
    );
  });
  test(
    'notification teardown failure still attempts captured widget retirement',
    () async {
      var widgetRetired = false;
      await expectLater(
        retireCapturedRuntimeProjections(
          retireReminders: () async =>
              throw StateError('fictional notification failure'),
          retireWidget: () async {
            widgetRetired = true;
          },
        ),
        throwsStateError,
      );
      expect(widgetRetired, isTrue);
    },
  );
  test(
    'optional reconciliation failure does not prevent pause and resume',
    () async {
      final repository = SessionGenerationRepository(prefs);
      final generation = await repository.advanceTo('fictional-account');
      final attempted = Completer<void>();
      var starts = 0;
      var stops = 0;
      final runtime = SessionRuntimeCoordinator(
        generations: repository,
        startSync: (_, _) => starts++,
        stopSync: () => stops++,
        reconcileProjections: (_, _) async {
          if (!attempted.isCompleted) attempted.complete();
          throw StateError('fictional reconciliation failure');
        },
      );
      await runtime.start('fictional-account', generation);
      await attempted.future;
      await Future<void>.delayed(Duration.zero);
      await runtime.pause();
      expect(stops, 1);
      await runtime.resume();
      expect(starts, 2);
      await Future<void>.delayed(Duration.zero);
    },
  );
}
