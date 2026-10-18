import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/diagnostics/diagnostic_event.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  final at = DateTime.utc(2026, 10, 18, 9, 30);

  group('DiagnosticEvent.fromError', () {
    test('keeps the type, own frames and first outside library only', () {
      final stack = StackTrace.fromString('''
#0      _SyncRunner._merge (package:simpastil/core/sync/sync_runner.dart:210:7)
#1      Zone.run (dart:async/zone.dart:1546:19)
#2      SyncRunner.run (package:simpastil/core/sync/sync_runner.dart:90:5)
#3      Database.run (package:drift/src/runtime/api/db_base.dart:55:3)
''');
      final event = DiagnosticEvent.fromError(
        DiagnosticKind.syncFailed,
        StateError('Paracetamol 500mg for Anna at 08:00 canary'),
        stack,
        at: at,
        component: DiagnosticComponent.sync,
      );
      expect(event.errorType, 'StateError');
      expect(event.where, [
        'core/sync/sync_runner.dart:210',
        'core/sync/sync_runner.dart:90',
      ]);
      expect(event.library, 'dart:async');
      expect(event.component, DiagnosticComponent.sync);
      final text = jsonEncode(event.toJson());
      expect(text, isNot(contains('canary')));
      expect(text, isNot(contains('Paracetamol')));
    });

    test('keeps at most three own frames', () {
      final lines = [
        for (var i = 1; i <= 6; i++) '#$i  f (package:simpastil/a/b.dart:$i:1)',
      ].join('\n');
      final event = DiagnosticEvent.fromError(
        DiagnosticKind.uncaughtError,
        Exception('x'),
        StackTrace.fromString(lines),
        at: at,
      );
      expect(event.where, ['a/b.dart:1', 'a/b.dart:2', 'a/b.dart:3']);
    });

    test('reads the SQLite result code and never the SQL', () {
      final event = DiagnosticEvent.fromError(
        DiagnosticKind.syncFailed,
        SqliteException(
          extendedResultCode: 13,
          message: 'database or disk is full',
          causingStatement: 'INSERT INTO pills (name) VALUES (?) canary',
          parametersToStatement: ['canary'],
        ),
        null,
        at: at,
      );
      expect(event.errorType, 'SqliteException');
      expect(event.code, 'SQLITE_13');
      expect(jsonEncode(event.toJson()), isNot(contains('canary')));
    });

    test('has no frames when there is no stack', () {
      final event = DiagnosticEvent.fromError(
        DiagnosticKind.flutterError,
        ArgumentError('x'),
        null,
        at: at,
      );
      expect(event.where, isEmpty);
      expect(event.library, isNull);
    });
  });

  group('field rules', () {
    test('drop every value that does not match its pattern', () {
      final event = DiagnosticEvent(
        kind: DiagnosticKind.uncaughtError,
        at: at,
        errorType: 'Bad Name; canary',
        where: const [
          '/home/luca/secret/file.dart:3',
          'core/ok.dart:9',
          'core/ok.dart:line',
          '../escape.dart:1',
        ],
        library: 'package:evil/canary',
        code: 'has space canary',
      );
      expect(event.errorType, isNull);
      expect(event.where, ['core/ok.dart:9']);
      expect(event.library, isNull);
      expect(event.code, isNull);
    });
  });

  group('JSON', () {
    test('round-trips an event', () {
      final event = DiagnosticEvent(
        kind: DiagnosticKind.backgroundFailed,
        at: at,
        source: DiagnosticSource.background,
        component: DiagnosticComponent.reminders,
        errorType: 'TimeoutException',
        where: const ['core/projections/runner.dart:44'],
        library: 'dart:async',
        code: 'EXIT_ANR',
      );
      final back = DiagnosticEvent.fromJson(
        jsonDecode(jsonEncode(event.toJson())) as Map<String, Object?>,
      );
      expect(back.toJson(), event.toJson());
    });

    test('re-checks values read from a file written by something else', () {
      final back = DiagnosticEvent.fromJson({
        'v': 1,
        'at': at.toIso8601String(),
        'kind': 'sync_failed',
        'errorType': 'oops; canary',
        'message': 'Paracetamol canary',
        'where': ['x y.dart:1', 'core/ok.dart:2'],
      });
      final text = jsonEncode(back.toJson());
      expect(text, isNot(contains('canary')));
      expect(back.where, ['core/ok.dart:2']);
    });

    test('rejects an unknown kind or a missing time', () {
      expect(
        () => DiagnosticEvent.fromJson({'kind': 'nope', 'at': at.toString()}),
        throwsFormatException,
      );
      expect(
        () => DiagnosticEvent.fromJson({'kind': 'sync_failed'}),
        throwsFormatException,
      );
    });
  });
}
