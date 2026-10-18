import 'package:dio/dio.dart';
import 'package:drift/isolate.dart' show DriftRemoteException;
import 'package:flutter/services.dart' show PlatformException;
import 'package:sqlite3/sqlite3.dart';

import '../utils/safe_diagnostics.dart';

/// The closed list of things the diagnostics recorder writes down. A new kind
/// is a deliberate change here, in `contracts/diagnostic-report-v1.json` and
/// in the report builder, never a free-form string.
enum DiagnosticKind {
  appStarted('app_started'),
  flutterError('flutter_error'),
  uncaughtError('uncaught_error'),
  startupFailed('startup_failed'),
  uncleanEnd('unclean_end'),
  backgroundFailed('background_failed'),
  syncFailed('sync_failed'),
  reminderFailed('reminder_failed');

  const DiagnosticKind(this.wireName);
  final String wireName;

  static DiagnosticKind? fromWire(Object? value) {
    for (final kind in values) {
      if (kind.wireName == value) return kind;
    }
    return null;
  }
}

/// Where the code that failed was running.
enum DiagnosticSource {
  foreground('foreground'),
  background('background');

  const DiagnosticSource(this.wireName);
  final String wireName;

  static DiagnosticSource? fromWire(Object? value) {
    for (final source in values) {
      if (source.wireName == value) return source;
    }
    return null;
  }
}

/// The part of the app an event belongs to. Fixed names only.
enum DiagnosticComponent {
  startup('startup'),
  sync('sync'),
  reminders('reminders'),
  notifications('notifications'),
  widget('widget'),
  storage('storage'),
  ui('ui'),
  other('other');

  const DiagnosticComponent(this.wireName);
  final String wireName;

  static DiagnosticComponent? fromWire(Object? value) {
    for (final component in values) {
      if (component.wireName == value) return component;
    }
    return null;
  }
}

/// One line of the diagnostics log.
///
/// Every field is either a fixed name or a value that passed a pattern check;
/// nothing the app shows a person (names, doses, times of care), no server
/// address, no account and no exception message can enter an event. An event
/// that was written by an older or damaged file is re-checked on the way in
/// ([fromJson]) and on the way out ([toJson]).
class DiagnosticEvent {
  DiagnosticEvent({
    required this.kind,
    required this.at,
    this.source = DiagnosticSource.foreground,
    this.component,
    String? errorType,
    List<String> where = const [],
    String? library,
    String? code,
  }) : errorType = _validName(errorType),
       where = List.unmodifiable(where.where(_frame.hasMatch).take(maxFrames)),
       library = _validLibrary(library),
       code = _validCode(code);

  /// Describes [error] and [stack] without keeping either of them.
  ///
  /// Only the error's runtime type, a short code (SQLite result code, server
  /// error code), the first frames inside this app (`path/file.dart:line`) and
  /// the name of the first library outside it are taken. The message, the
  /// object's own text and every argument stay out.
  factory DiagnosticEvent.fromError(
    DiagnosticKind kind,
    Object error,
    StackTrace? stack, {
    DateTime? at,
    DiagnosticSource source = DiagnosticSource.foreground,
    DiagnosticComponent? component,
  }) {
    // A background database isolate wraps the real error; describe that.
    final cause = error is DriftRemoteException ? error.remoteCause : error;
    final frames = _readStack(stack);
    return DiagnosticEvent(
      kind: kind,
      at: at ?? DateTime.now().toUtc(),
      source: source,
      component: component,
      errorType: cause.runtimeType.toString(),
      where: frames.own,
      library: frames.library,
      code: _codeFor(cause),
    );
  }

  factory DiagnosticEvent.fromJson(Map<String, Object?> json) {
    final kind = DiagnosticKind.fromWire(json['kind']);
    final at = json['at'] is String
        ? DateTime.tryParse(json['at']! as String)
        : null;
    if (kind == null || at == null) {
      throw const FormatException('not a diagnostic event');
    }
    final where = json['where'];
    return DiagnosticEvent(
      kind: kind,
      at: at.toUtc(),
      source:
          DiagnosticSource.fromWire(json['source']) ??
          DiagnosticSource.foreground,
      component: DiagnosticComponent.fromWire(json['component']),
      errorType: json['errorType'] is String
          ? json['errorType']! as String
          : null,
      where: where is List ? where.whereType<String>().toList() : const [],
      library: json['library'] is String ? json['library']! as String : null,
      code: json['code'] is String ? json['code']! as String : null,
    );
  }

  /// How many own frames an event keeps.
  static const maxFrames = 3;

  final DiagnosticKind kind;
  final DateTime at;
  final DiagnosticSource source;
  final DiagnosticComponent? component;

  /// The error's runtime type, such as `StateError` or `SqliteException`.
  final String? errorType;

  /// `path/inside/lib/file.dart:line`, nearest call first.
  final List<String> where;

  /// The first library outside the app on the stack: `drift`, `dart:async`.
  final String? library;

  /// A short upper-case code: `SQLITE_13`, a server error code.
  final String? code;

  Map<String, Object?> toJson() => {
    'v': 1,
    'at': at.toUtc().toIso8601String(),
    'kind': kind.wireName,
    'source': source.wireName,
    if (component != null) 'component': component!.wireName,
    if (errorType != null) 'errorType': errorType,
    if (where.isNotEmpty) 'where': where,
    if (library != null) 'library': library,
    if (code != null) 'code': code,
  };

  static final _name = RegExp(r'^[A-Za-z_][A-Za-z0-9_$]{0,63}$');
  static final _frame = RegExp(r'^[a-z0-9_]+(?:/[a-z0-9_]+)*\.dart:\d{1,6}$');
  static final _libraryName = RegExp(
    r'^(?:[a-z][a-z0-9_]{0,40}|dart:[a-z_]{1,20})$',
  );
  static final _codePattern = RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,63}$');

  static String? _validName(String? value) =>
      value != null && _name.hasMatch(value) ? value : null;
  static String? _validLibrary(String? value) =>
      value != null && _libraryName.hasMatch(value) ? value : null;
  static String? _validCode(String? value) =>
      value != null && _codePattern.hasMatch(value) ? value : null;

  static String? _codeFor(Object error) => switch (error) {
    SqliteException() => 'SQLITE_${error.resultCode}',
    DioException() => SafeDiagnostics.errorCodeFrom(error),
    PlatformException() => error.code,
    _ => null,
  };

  static final _ownFrame = RegExp(
    r'package:simpastil/([a-z0-9_/]+\.dart):(\d{1,6})',
  );
  static final _foreignFrame = RegExp(
    r'(?:package:([a-z][a-z0-9_]{0,40})/|dart:([a-z_]{1,20}))',
  );

  static ({List<String> own, String? library}) _readStack(StackTrace? stack) {
    if (stack == null) return (own: const [], library: null);
    final own = <String>[];
    String? library;
    // Split first so one hostile-looking line cannot affect its neighbours.
    for (final line in stack.toString().split('\n')) {
      final mine = _ownFrame.firstMatch(line);
      if (mine != null) {
        if (own.length < maxFrames) own.add('${mine[1]}:${mine[2]}');
        continue;
      }
      if (library == null) {
        final other = _foreignFrame.firstMatch(line);
        if (other != null) {
          library = other[1] ?? 'dart:${other[2]}';
        }
      }
    }
    return (own: own, library: library);
  }
}
