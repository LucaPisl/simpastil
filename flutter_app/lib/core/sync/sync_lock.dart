import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import '../utils/app_logger.dart';

/// Process-wide lock that keeps foreground and WorkManager isolates from
/// running sync stages at the same time.
///
/// Both isolates live in the same Android process, where POSIX file locks do
/// not exclude each other, so the lock is a name in [IsolateNameServer]:
/// registering it is atomic and fails while another isolate holds it. The
/// holder answers pings, so a name left behind by an isolate that died while
/// holding the lock (a killed WorkManager engine) is reclaimed instead of
/// blocking sync forever. A live holder answers within milliseconds; the long
/// [livenessTimeout] only keeps a holder stalled in synchronous work or a GC
/// pause from being mistaken for a dead one.
class SyncLock {
  SyncLock({
    this.name = 'simpastil_sync_lock',
    this.livenessTimeout = const Duration(seconds: 10),
  });

  final String name;
  final Duration livenessTimeout;
  ReceivePort? _port;

  /// Acquires the lock without waiting. Returns `true` if it was acquired,
  /// `false` if a live isolate (or this instance) already holds it.
  Future<bool> tryAcquire() async {
    if (_port != null) return false;
    if (_register()) return true;

    final holder = IsolateNameServer.lookupPortByName(name);
    if (holder == null) return _register();
    if (await _isAlive(holder)) return false;
    return _reclaimFrom(holder);
  }

  /// Releases the lock if this instance holds it.
  void release() {
    final port = _port;
    if (port == null) return;
    _port = null;
    if (IsolateNameServer.lookupPortByName(name) == port.sendPort) {
      IsolateNameServer.removePortNameMapping(name);
    }
    port.close();
  }

  /// Replaces a dead [holder]. A second name serializes contenders that found
  /// the same dead holder, so none can remove the name another just took.
  bool _reclaimFrom(SendPort holder) {
    final guard = ReceivePort();
    final guardName = '$name.reclaim';
    if (!IsolateNameServer.registerPortWithName(guard.sendPort, guardName)) {
      guard.close();
      return false;
    }
    try {
      if (IsolateNameServer.lookupPortByName(name) == holder) {
        AppLogger.debug('SyncLock', 'Reclaiming sync lock from a dead isolate');
        IsolateNameServer.removePortNameMapping(name);
      }
      return _register();
    } finally {
      IsolateNameServer.removePortNameMapping(guardName);
      guard.close();
    }
  }

  bool _register() {
    final port = ReceivePort();
    if (!IsolateNameServer.registerPortWithName(port.sendPort, name)) {
      port.close();
      return false;
    }
    port.listen((message) {
      if (message is SendPort) message.send(true);
    });
    _port = port;
    return true;
  }

  Future<bool> _isAlive(SendPort holder) async {
    final reply = ReceivePort();
    try {
      holder.send(reply.sendPort);
      await reply.first.timeout(livenessTimeout);
      return true;
    } on TimeoutException {
      return false;
    } finally {
      reply.close();
    }
  }
}
