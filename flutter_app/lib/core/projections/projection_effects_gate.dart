import 'dart:async';
import 'dart:io';

import 'package:simpastil_storage/simpastil_storage.dart';
import 'package:sqlite3/sqlite3.dart';

abstract interface class ProjectionEffectsGate {
  Future<T> run<T>(Future<T> Function() action);
}

class ProjectionEffectsBusy implements Exception {
  const ProjectionEffectsBusy();
}

/// The lock is in a separate private database. No care transaction is held
/// across a platform call. A live platform future always keeps the lock until
/// completion; timing out a caller must never admit competing effects.
class NativeProjectionEffectsGate implements ProjectionEffectsGate {
  NativeProjectionEffectsGate({required this.directory});
  final Directory directory;
  final SerialProjectionEffectsGate _localQueue = SerialProjectionEffectsGate();

  @override
  Future<T> run<T>(Future<T> Function() action) =>
      _localQueue.run(() => _runWithFileLock(action));

  Future<T> _runWithFileLock<T>(Future<T> Function() action) async {
    await directory.create(recursive: true);
    final lock = sqlite3.open('${directory.path}/effects-gate.sqlite');
    var held = false;
    try {
      lock.execute('PRAGMA busy_timeout=0');
      final waiting = Stopwatch()..start();
      while (!held) {
        try {
          lock.execute('BEGIN EXCLUSIVE');
          held = true;
        } on SqliteException catch (error) {
          if (!const {5, 6}.contains(error.resultCode)) rethrow;
          if (waiting.elapsed >= const Duration(seconds: 3)) {
            throw const ProjectionEffectsBusy();
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      }
      return await action();
    } finally {
      try {
        if (held) lock.execute('ROLLBACK');
      } finally {
        lock.close();
      }
    }
  }
}

/// Private path lookup is lazy, including in headless Flutter engines. Each
/// [subdirectory] under the no-backup path is an independent lock domain
/// (projections, app lock, portable preferences).
class PrivateProjectionEffectsGate implements ProjectionEffectsGate {
  PrivateProjectionEffectsGate({this.subdirectory = 'projections'});

  final String subdirectory;
  Future<NativeProjectionEffectsGate>? _gate;

  Future<NativeProjectionEffectsGate> _open() async {
    const storage = SimpastilStorage();
    return NativeProjectionEffectsGate(
      directory: Directory('${await storage.noBackupPath()}/$subdirectory'),
    );
  }

  @override
  Future<T> run<T>(Future<T> Function() action) async =>
      (await (_gate ??= _open())).run(action);
}

/// Deterministic injected gate for tests; production uses the native file lock.
class SerialProjectionEffectsGate implements ProjectionEffectsGate {
  Future<void> _tail = Future<void>.value();
  @override
  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

final ProjectionEffectsGate privateProjectionEffectsGate =
    PrivateProjectionEffectsGate();
