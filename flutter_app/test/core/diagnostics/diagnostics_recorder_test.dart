import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/diagnostics/diagnostic_event.dart';
import 'package:simpastil/core/diagnostics/diagnostics_recorder.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('simpastil-diag-');
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  DiagnosticEvent event(int minute, [DiagnosticKind? kind]) => DiagnosticEvent(
    kind: kind ?? DiagnosticKind.uncaughtError,
    at: DateTime.utc(2026, 10, 18, 9, minute),
    errorType: 'StateError',
  );

  test('reads back what was recorded, oldest first', () async {
    final recorder = DiagnosticsRecorder(directory: () async => dir);
    await recorder.record(event(1));
    await recorder.record(event(2));
    final events = await recorder.recent();
    expect(events.map((e) => e.at.minute), [1, 2]);
  });

  test('keeps only the newest events when asked for fewer', () async {
    final recorder = DiagnosticsRecorder(directory: () async => dir);
    for (var i = 0; i < 10; i++) {
      await recorder.record(event(i));
    }
    expect((await recorder.recent(limit: 3)).map((e) => e.at.minute), [
      7,
      8,
      9,
    ]);
  });

  test('rotates so it never grows past about twice the cap', () async {
    final recorder = DiagnosticsRecorder(
      directory: () async => dir,
      maxFileBytes: 400,
    );
    for (var i = 0; i < 50; i++) {
      await recorder.record(event(i % 60));
    }
    final sizes = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.lengthSync())
        .toList();
    expect(sizes.length, lessThanOrEqualTo(2));
    expect(sizes.every((size) => size < 400 + 300), isTrue);
    // The newest event always survives a rotation.
    expect((await recorder.recent()).last.at.minute, 49 % 60);
  });

  test('skips damaged and foreign lines instead of failing', () async {
    final recorder = DiagnosticsRecorder(directory: () async => dir);
    await recorder.record(event(1));
    File('${dir.path}/events.foreground.jsonl').writeAsStringSync(
      'not json\n{"v":2,"kind":"sync_failed"}\n\n[1,2]\n',
      mode: FileMode.append,
    );
    await recorder.record(event(2));
    expect((await recorder.recent()).map((e) => e.at.minute), [1, 2]);
  });

  test('concurrent writers never leave a half line', () async {
    final recorder = DiagnosticsRecorder(directory: () async => dir);
    await Future.wait([for (var i = 0; i < 40; i++) recorder.record(event(i))]);
    final lines = File('${dir.path}/events.foreground.jsonl').readAsLinesSync();
    expect(lines, hasLength(40));
    expect(await recorder.recent(limit: 100), hasLength(40));
  });

  test('never throws when the directory is unavailable', () async {
    final recorder = DiagnosticsRecorder(
      directory: () async => throw const FileSystemException('no support dir'),
    );
    await recorder.record(event(1));
    expect(await recorder.recent(), isEmpty);
    await recorder.clear();
  });

  test('clear forgets everything', () async {
    final recorder = DiagnosticsRecorder(directory: () async => dir);
    await recorder.record(event(1));
    await recorder.clear();
    expect(await recorder.recent(), isEmpty);
  });
}
