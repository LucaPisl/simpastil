import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';

void main() {
  test(
    'independent native gates await a live effect before admitting another engine',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'simpastil-effects-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final first = NativeProjectionEffectsGate(directory: directory);
      final second = NativeProjectionEffectsGate(directory: directory);
      final entered = Completer<void>();
      final finishEffect = Completer<void>();
      final events = <String>[];
      final a = first.run(() async {
        events.add('a starts');
        entered.complete();
        await finishEffect.future;
        events.add('a completes');
      });
      await entered.future;
      final b = second.run(() async {
        events.add('b starts');
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(events, ['a starts']);
      finishEffect.complete();
      await Future.wait([a, b]);
      expect(events, ['a starts', 'a completes', 'b starts']);
    },
  );

  test(
    'one native gate instance queues a concurrent in-process effect',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'simpastil-effects-same-instance-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final gate = NativeProjectionEffectsGate(directory: directory);
      final entered = Completer<void>();
      final finishEffect = Completer<void>();
      final events = <String>[];
      final first = gate.run<void>(() async {
        events.add('first starts');
        entered.complete();
        await finishEffect.future;
        events.add('first completes');
      });
      await entered.future;
      final second = gate.run<void>(() async {
        events.add('second starts');
        events.add('second completes');
      });
      try {
        await Future<void>.delayed(const Duration(milliseconds: 3100));
        expect(events, ['first starts']);
      } finally {
        finishEffect.complete();
      }
      await Future.wait([first, second]);
      expect(events, [
        'first starts',
        'first completes',
        'second starts',
        'second completes',
      ]);
    },
  );

  test(
    'a failed queued native effect does not poison the next effect',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'simpastil-effects-queued-failure-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final gate = NativeProjectionEffectsGate(directory: directory);
      final entered = Completer<void>();
      final finishEffect = Completer<void>();
      final first = gate.run<void>(() async {
        entered.complete();
        await finishEffect.future;
        throw StateError('fictional queued effect failure');
      });
      await entered.future;
      final next = gate.run(() async => 'next effect');
      finishEffect.complete();
      await expectLater(first, throwsStateError);
      expect(await next, 'next effect');
    },
  );

  test(
    'a failed effect releases its native lock for the next engine',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'simpastil-effects-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final first = NativeProjectionEffectsGate(directory: directory);
      final second = NativeProjectionEffectsGate(directory: directory);
      await expectLater(
        first.run<void>(() async {
          throw StateError('fictional effect failure');
        }),
        throwsStateError,
      );
      expect(await second.run(() async => 'next engine'), 'next engine');
    },
  );

  test(
    'durable revocation does not wait behind a stuck projection effect',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'simpastil-effects-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final gate = NativeProjectionEffectsGate(directory: directory);
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      final access = WorkspaceAccessRepository(db, effectsGate: gate);
      final local = await access.currentContext();
      final entered = Completer<void>();
      final finishEffect = Completer<void>();
      final running = gate.run(() async {
        entered.complete();
        await finishEffect.future;
      });
      await entered.future;
      try {
        await access.revokeNetwork().timeout(const Duration(seconds: 1));
        expect(await access.currentNetworkCapability(), isNull);
        await access.requireCurrent(local);
      } finally {
        finishEffect.complete();
        await running;
      }
    },
  );

  test(
    'fresh account publication waits for the live projection effect',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'simpastil-effects-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final gate = NativeProjectionEffectsGate(directory: directory);
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      final access = WorkspaceAccessRepository(db, effectsGate: gate);
      const endpoint = 'https://fictional.test/care';
      final transition = await access.configureEndpoint(endpoint);
      await db
          .into(db.credentialSlots)
          .insert(
            CredentialSlotsCompanion.insert(
              id: 'fictional-staged',
              ownerId: 'fictional-owner',
              endpoint: endpoint,
              state: 'staged',
              createdAt: DateTime.now(),
            ),
          );
      final entered = Completer<void>();
      final finishEffect = Completer<void>();
      final running = gate.run(() async {
        entered.complete();
        await finishEffect.future;
      });
      await entered.future;
      final publication = access.authenticate(
        ownerId: 'fictional-owner',
        endpoint: endpoint,
        expectedNetworkEpoch: transition,
        sessionGeneration: 1,
        credentialId: 'fictional-staged',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await access.currentNetworkCapability(), isNull);
      finishEffect.complete();
      await running;
      final published = await publication;
      expect(await access.currentNetworkCapability(), published.network);
    },
  );
}
