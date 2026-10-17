import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/sync/sync_lock.dart';

const _name = 'simpastil_sync_lock_test';

/// Holds the lock in another isolate until told to release it.
Future<void> _holdLock(SendPort reply) async {
  final lock = SyncLock(name: _name);
  final acquired = await lock.tryAcquire();
  final control = ReceivePort();
  reply.send([acquired, control.sendPort]);
  await control.first;
  lock.release();
  control.close();
  reply.send('released');
}

/// Holds the lock, then blocks its event loop for [_busyFor] before releasing.
Future<void> _holdLockBusy(SendPort reply) async {
  final lock = SyncLock(name: _name);
  reply.send(await lock.tryAcquire());
  await Future<void>.delayed(const Duration(milliseconds: 50));
  final until = DateTime.now().add(_busyFor);
  while (DateTime.now().isBefore(until)) {}
  // Back on the event loop, the queued ping is answered before release.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  lock.release();
}

const _busyFor = Duration(milliseconds: 600);

/// Acquires the lock and exits without releasing it, as a killed worker would.
Future<void> _acquireAndDie(SendPort reply) async {
  reply.send(await SyncLock(name: _name).tryAcquire());
  Isolate.exit();
}

void main() {
  tearDown(() => IsolateNameServer.removePortNameMapping(_name));

  test('refuses promptly while another isolate holds the lock', () async {
    final replies = ReceivePort();
    final events = StreamIterator(replies);
    await Isolate.spawn(_holdLock, replies.sendPort);
    expect(await events.moveNext(), isTrue);
    final [held as bool, control as SendPort] = events.current as List<Object?>;
    expect(held, isTrue);

    final lock = SyncLock(name: _name);
    final watch = Stopwatch()..start();
    final acquired = await lock.tryAcquire();
    watch.stop();

    control.send('release');
    expect(await events.moveNext(), isTrue);
    expect(events.current, 'released');
    replies.close();

    expect(acquired, isFalse, reason: 'second holder must be refused');
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(await lock.tryAcquire(), isTrue, reason: 'free after release');
    lock.release();
  });

  test(
    'refuses a second holder in the same isolate and reacquires after release',
    () async {
      final first = SyncLock(name: _name);
      final second = SyncLock(name: _name);
      expect(await first.tryAcquire(), isTrue);
      expect(await first.tryAcquire(), isFalse);
      expect(await second.tryAcquire(), isFalse);
      second.release(); // not the holder: must not free the lock
      expect(await SyncLock(name: _name).tryAcquire(), isFalse);
      first.release();
      expect(await second.tryAcquire(), isTrue);
      second.release();
    },
  );

  test(
    'reclaims a lock left behind by an isolate that died holding it',
    () async {
      final replies = ReceivePort();
      await Isolate.spawn(_acquireAndDie, replies.sendPort);
      expect(await replies.first, isTrue);
      expect(IsolateNameServer.lookupPortByName(_name), isNotNull);

      final lock = SyncLock(
        name: _name,
        livenessTimeout: const Duration(milliseconds: 200),
      );
      expect(await lock.tryAcquire(), isTrue);
      lock.release();
      expect(IsolateNameServer.lookupPortByName(_name), isNull);
    },
  );

  test('a holder stalled in synchronous work is not taken over', () async {
    final replies = ReceivePort();
    await Isolate.spawn(_holdLockBusy, replies.sendPort);
    expect(await replies.first, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final lock = SyncLock(name: _name, livenessTimeout: _busyFor * 3);
    expect(await lock.tryAcquire(), isFalse);
  });

  test(
    'contenders that find the same dead holder never both acquire',
    () async {
      final replies = ReceivePort();
      await Isolate.spawn(_acquireAndDie, replies.sendPort);
      expect(await replies.first, isTrue);

      final locks = List.generate(
        4,
        (_) => SyncLock(
          name: _name,
          livenessTimeout: const Duration(milliseconds: 200),
        ),
      );
      final results = await Future.wait(locks.map((l) => l.tryAcquire()));
      expect(results.where((acquired) => acquired), hasLength(1));
      for (final lock in locks) {
        lock.release();
      }
      expect(IsolateNameServer.lookupPortByName(_name), isNull);
      expect(IsolateNameServer.lookupPortByName('$_name.reclaim'), isNull);
    },
  );
}
