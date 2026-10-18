import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'diagnostic_event.dart';

/// A small on-device log of what went wrong, written so a problem report can
/// say more than "it crashed".
///
/// It is deliberately independent of everything it reports on: no database, no
/// providers, no protected storage. A crash in any of those still leaves a
/// line here. The files are append-only JSON lines in the app's private
/// support directory, capped at about [maxFileBytes] each with one older file
/// kept, so the log never grows past a few hundred kilobytes. It never leaves
/// the device by itself.
///
/// The app's foreground and its background workers run in separate isolates
/// that cannot share a lock, and Dart's append mode seeks to the end instead of
/// appending atomically. So each side writes its own pair of files and reading
/// merges them by time; within one isolate writes are queued one after another.
///
/// No call throws: recording must never be the thing that breaks the app.
class DiagnosticsRecorder {
  DiagnosticsRecorder({
    Future<Directory> Function()? directory,
    this.maxFileBytes = defaultMaxFileBytes,
  }) : _directory = directory ?? _defaultDirectory;

  /// The recorder the app uses.
  static final DiagnosticsRecorder shared = DiagnosticsRecorder();

  static const defaultMaxFileBytes = 64 * 1024;

  final Future<Directory> Function() _directory;
  final int maxFileBytes;
  Future<Directory?>? _ready;
  Future<void> _queue = Future<void>.value();

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}diagnostics');
  }

  Future<Directory?> _resolve() => _ready ??= () async {
    try {
      final dir = await _directory();
      await dir.create(recursive: true);
      return dir;
    } on Object {
      return null;
    }
  }();

  /// The directory the log lives in; null when the platform will not give one.
  Future<Directory?> get directory => _resolve();

  static String _name(DiagnosticSource source, {required bool previous}) =>
      'events.${source.wireName}${previous ? '.1' : ''}.jsonl';

  /// Appends [event]. Never throws and never waits on anything but the disk.
  Future<void> record(DiagnosticEvent event) {
    final done = _queue.then((_) => _append(event));
    // The queue only orders writes; a failure was already swallowed in _append.
    _queue = done;
    return done;
  }

  Future<void> _append(DiagnosticEvent event) async {
    try {
      final dir = await _resolve();
      if (dir == null) return;
      final base = dir.path + Platform.pathSeparator;
      final current = File(base + _name(event.source, previous: false));
      if (current.existsSync() && current.lengthSync() >= maxFileBytes) {
        await current.rename(base + _name(event.source, previous: true));
      }
      await current.writeAsString(
        '${jsonEncode(event.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
    } on Object {
      // Recording is best effort by design.
    }
  }

  /// Records an error without keeping its message. See
  /// [DiagnosticEvent.fromError] for what is taken from it.
  Future<void> recordError(
    DiagnosticKind kind,
    Object error,
    StackTrace? stack, {
    DiagnosticSource source = DiagnosticSource.foreground,
    DiagnosticComponent? component,
  }) => record(
    DiagnosticEvent.fromError(
      kind,
      error,
      stack,
      source: source,
      component: component,
    ),
  );

  /// The newest events, oldest first. Lines that are damaged, from a newer
  /// format or no longer valid are skipped, never shown.
  Future<List<DiagnosticEvent>> recent({int limit = 40}) async {
    try {
      final dir = await _resolve();
      if (dir == null) return const [];
      final events = <DiagnosticEvent>[];
      for (final source in DiagnosticSource.values) {
        for (final previous in [true, false]) {
          final file = File(
            '${dir.path}${Platform.pathSeparator}${_name(source, previous: previous)}',
          );
          if (!file.existsSync()) continue;
          for (final line in await file.readAsLines()) {
            final event = _parse(line);
            if (event != null) events.add(event);
          }
        }
      }
      // Stable by time; equal times keep their file order.
      events.sort((a, b) => a.at.compareTo(b.at));
      return events.length <= limit
          ? events
          : events.sublist(events.length - limit);
    } on Object {
      return const [];
    }
  }

  /// Forgets everything recorded. Used by tests and by "clear" in the report.
  Future<void> clear() async {
    try {
      final dir = await _resolve();
      if (dir == null) return;
      for (final source in DiagnosticSource.values) {
        for (final previous in [true, false]) {
          final file = File(
            '${dir.path}${Platform.pathSeparator}${_name(source, previous: previous)}',
          );
          if (file.existsSync()) await file.delete();
        }
      }
    } on Object {
      // Nothing to do.
    }
  }

  static DiagnosticEvent? _parse(String line) {
    if (line.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, Object?>) return null;
      if (decoded['v'] != 1) return null;
      return DiagnosticEvent.fromJson(decoded);
    } on Object {
      return null;
    }
  }
}
