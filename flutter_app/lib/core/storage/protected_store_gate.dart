import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'protected_database.dart';

/// Shares the startup preparation gate; normal care transactions are untouched.
Future<T> withProtectedStoreGate<T>(
  Directory root,
  Future<T> Function() action,
) async {
  final path = File('${root.path}/preparation.sqlite');
  if (!await path.exists()) {
    throw const ProtectedStoreFailure(
      ProtectedStoreFailureCode.activeStoreMissing,
    );
  }
  final gate = sqlite3.open(path.path, mode: OpenMode.readWrite);
  var held = false;
  try {
    gate.execute('PRAGMA busy_timeout=0');
    final elapsed = Stopwatch()..start();
    while (!held) {
      try {
        gate.execute('BEGIN EXCLUSIVE');
        held = true;
      } on SqliteException catch (error) {
        if (!const {5, 6}.contains(error.resultCode)) rethrow;
        if (elapsed.elapsed >= const Duration(seconds: 3)) {
          throw const ProtectedStoreFailure(ProtectedStoreFailureCode.busy);
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }
    return await action();
  } finally {
    try {
      if (held) gate.execute('ROLLBACK');
    } finally {
      gate.close();
    }
  }
}
