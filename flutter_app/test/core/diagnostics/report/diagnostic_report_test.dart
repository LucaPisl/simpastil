import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/diagnostics/diagnostic_event.dart';
import 'package:simpastil/core/diagnostics/report/diagnostic_report.dart';
import 'package:simpastil/core/diagnostics/report/report_values.dart';

const _contractPath = '../contracts/diagnostic-report-v1.json';
const _fixturePath = '../contracts/fixtures/diagnostic-report-v1.txt';

Map<String, Object?> _contract() =>
    jsonDecode(File(_contractPath).readAsStringSync()) as Map<String, Object?>;

DiagnosticReport _sample() => DiagnosticReport(
  createdAt: DateTime.utc(2026, 10, 18, 14, 37, 22),
  app: ReportApp(version: '1.0.0', build: 3, database: 18, language: 'en'),
  device: ReportDevice(
    androidRelease: '14',
    sdk: 34,
    maker: 'samsung',
    model: 'SM-S938B',
    screen: ReportScreen.phone,
  ),
  permissions: const ReportPermissions(
    notifications: ReportPermission.allowed,
    exactAlarms: ReportPermission.denied,
    batteryUnrestricted: ReportPermission.unknown,
  ),
  data: const ReportData(
    profiles: 1,
    medicines: 4,
    schedules: 6,
    doseRecords: 212,
    scheduledReminders: 0,
  ),
  sync: ReportSync(
    connected: true,
    state: 'couldNotSync',
    sinceSuccess: const Duration(hours: 5),
    pending: 3,
    needAttention: 1,
    stages: [
      ReportSyncStage(
        id: 'flush.account',
        status: 'failed',
        code: 'SYNC_STAGE_FAILED',
        httpStatus: 500,
        retries: 1,
        took: const Duration(milliseconds: 1400),
        correlationId: '0f4d4d92-6a6a-4f4e-8d2e-5c9a6a2b7f10',
      ),
      ReportSyncStage(id: 'pull.stable', status: 'succeeded'),
    ],
  ),
  capabilities: [
    ReportCapability(id: 'notifications', phase: 'ready'),
    ReportCapability(
      id: 'widget',
      phase: 'degraded',
      failureType: 'PlatformException',
    ),
  ],
  lastStop: 'EXIT_CRASH',
  events: [
    DiagnosticEvent(
      kind: DiagnosticKind.uncleanEnd,
      at: DateTime.utc(2026, 10, 18, 13, 5),
      code: 'EXIT_CRASH',
    ),
    DiagnosticEvent(
      kind: DiagnosticKind.flutterError,
      at: DateTime.utc(2026, 10, 18, 14, 2),
      component: DiagnosticComponent.ui,
      errorType: 'StateError',
      where: const ['features/today/today_screen.dart:88'],
      library: 'flutter',
    ),
  ],
);

/// Reads the text back the way a maintainer would, and checks every line
/// against the contract. Returns the sections in order.
Map<String, List<(String, String)>> _validate(String text) {
  final contract = _contract();
  final sections = contract['sections']! as Map<String, Object?>;
  final preamble = contract['preamble']! as Map<String, Object?>;
  final lines = text.split('\n');
  expect(lines.last, isEmpty, reason: 'ends with a newline');
  var index = 0;

  expect(lines[index++], preamble['title']);
  final preambleRules = (preamble['lines']! as Map).cast<String, String>();
  for (final key in preambleRules.keys) {
    final line = lines[index++];
    expect(line, startsWith('$key: '), reason: 'preamble order');
    expect(
      RegExp(preambleRules[key]!).hasMatch(line.substring(key.length + 2)),
      isTrue,
      reason: line,
    );
  }

  final found = <String, List<(String, String)>>{};
  String? current;
  for (; index < lines.length - 1; index++) {
    final line = lines[index];
    if (line.isEmpty) continue;
    final header = RegExp(r'^\[([a-z-]+)\]$').firstMatch(line);
    if (header != null) {
      current = header[1]!;
      expect(sections.containsKey(current), isTrue, reason: 'section $line');
      expect(found.containsKey(current), isFalse, reason: 'twice: $line');
      found[current] = [];
      continue;
    }
    expect(current, isNotNull, reason: 'line outside a section: $line');
    final split = line.indexOf(': ');
    expect(split, greaterThan(0), reason: 'not "key: value": $line');
    final key = line.substring(0, split);
    final value = line.substring(split + 2);
    final section = sections[current]! as Map<String, Object?>;
    final keys = (section['keys']! as Map).cast<String, String>();
    final repeatable = ((section['repeatable'] ?? const {}) as Map)
        .cast<String, String>();
    final stateValues = <String>{
      'unavailable',
      ...((section['stateValues'] ?? const []) as List).cast<String>(),
    };
    if (key == 'state') {
      expect(stateValues, contains(value), reason: line);
    } else if (keys.containsKey(key)) {
      expect(RegExp(keys[key]!).hasMatch(value), isTrue, reason: line);
    } else if (repeatable.containsKey(key)) {
      expect(RegExp(repeatable[key]!).hasMatch(value), isTrue, reason: line);
    } else {
      fail('key not in the contract: $line');
    }
    found[current]!.add((key, value));
  }

  // Every contract section is present, and complete unless it says why not.
  for (final name in sections.keys) {
    expect(found.containsKey(name), isTrue, reason: 'missing [$name]');
    final section = sections[name]! as Map<String, Object?>;
    final entries = found[name]!;
    if (entries.any((e) => e.$1 == 'state' && e.$2 == 'unavailable')) {
      expect(entries, hasLength(1), reason: '[$name] unavailable is alone');
      continue;
    }
    final optional = ((section['optionalKeys'] ?? const []) as List)
        .cast<String>()
        .toSet();
    for (final key in (section['keys']! as Map).keys.cast<String>()) {
      if (optional.contains(key)) continue;
      expect(
        entries.where((e) => e.$1 == key),
        hasLength(1),
        reason: '[$name] $key',
      );
    }
  }
  return found;
}

void main() {
  test('the sample report matches the shared contract line by line', () {
    final sections = _validate(_sample().toText());
    expect(sections['sync']!.where((e) => e.$1 == 'stage'), hasLength(2));
  });

  test('the sample report equals the committed fixture', () {
    final text = _sample().toText();
    final fixture = File(_fixturePath);
    if (Platform.environment['UPDATE_REPORT_FIXTURE'] == '1') {
      fixture.writeAsStringSync(text);
    }
    expect(text, fixture.readAsStringSync());
  });

  test('sizes become rough buckets and times lose their minutes', () {
    final text = _sample().toText();
    expect(text, contains('dose-records: 6+'));
    expect(text, contains('medicines: 2-5'));
    expect(text, contains('profiles: 1'));
    expect(text, contains('reminders: 0'));
    expect(text, contains('last-success: 1-6h'));
    expect(text, contains('created: 2026-10-18T14:00Z'));
    expect(text, contains('took=1-5s'));
    expect(text, isNot(contains('212')));
    expect(text, isNot(contains(':37')));
  });

  test('a report with nothing readable still matches the contract', () {
    final text = DiagnosticReport(
      createdAt: DateTime.utc(2026, 1, 2, 3),
    ).toText();
    final sections = _validate(text);
    expect(sections['app'], [('state', 'unavailable')]);
    expect(sections['sync'], [('state', 'unavailable')]);
    expect(sections['last-stop'], [('reason', 'none-recorded')]);
    expect(sections['events'], [('state', 'none-recorded')]);
  });

  test('a device that does not sync says so and lists no stages', () {
    final text = DiagnosticReport(
      createdAt: DateTime.utc(2026, 1, 2, 3),
      sync: ReportSync(connected: false),
    ).toText();
    final sections = _validate(text);
    expect(sections['sync'], [('connected', 'no')]);
  });

  test('the file name carries the date and hour only', () {
    expect(_sample().fileName, 'simpastil-report-20261018-14.txt');
    expect(
      RegExp(
        _contract()['fileNamePattern']! as String,
      ).hasMatch(_sample().fileName),
      isTrue,
    );
  });

  group('canaries', () {
    const canaries = [
      'Aspirin 100mg',
      'luca@example.com',
      'https://sync.example.org/api',
      'eyJhbGciOiJIUzI1NiJ9.payload.signature',
      "Maria's tablet",
      'Insulin',
    ];

    test('hostile text in any field never reaches the report', () {
      final hostile = canaries.join(' ');
      final report = DiagnosticReport(
        createdAt: DateTime.utc(2026, 10, 18, 14),
        app: ReportApp(version: hostile, language: hostile),
        device: ReportDevice(
          androidRelease: hostile,
          maker: canaries[1],
          model: canaries[2],
        ),
        sync: ReportSync(
          connected: true,
          state: hostile,
          stages: [
            ReportSyncStage(
              id: canaries[5],
              status: 'failed',
              code: hostile,
              correlationId: canaries[1],
            ),
          ],
        ),
        capabilities: [
          ReportCapability(
            id: canaries[4],
            phase: 'degraded',
            failureType: hostile,
          ),
        ],
        lastStop: hostile,
        events: [
          DiagnosticEvent(
            kind: DiagnosticKind.flutterError,
            at: DateTime.utc(2026, 10, 18, 14),
            errorType: hostile,
            where: const ['../../etc/passwd:1', 'Aspirin 100mg.dart:3'],
            library: canaries[3],
            code: hostile,
          ),
        ],
      );
      final text = report.toText();
      for (final canary in canaries) {
        expect(text, isNot(contains(canary)), reason: canary);
      }
      _validate(text);
    });

    test('an exception message never enters an event or the report', () {
      final error = StateError(canaries.join(' | '));
      final event = DiagnosticEvent.fromError(
        DiagnosticKind.uncaughtError,
        error,
        StackTrace.fromString(
          '#0 main (package:simpastil/features/today/today_screen.dart:12:3)\n'
          '#1 build (package:flutter/src/widgets/framework.dart:1:1)',
        ),
        at: DateTime.utc(2026, 10, 18, 14),
      );
      final text = DiagnosticReport(
        createdAt: DateTime.utc(2026, 10, 18, 14),
        events: [event],
      ).toText();
      for (final canary in canaries) {
        expect(text, isNot(contains(canary)), reason: canary);
      }
      expect(text, contains('type=StateError'));
      expect(text, contains('at=features/today/today_screen.dart:12'));
      _validate(text);
    });
  });

  group('values', () {
    test('counts', () {
      expect([null, -1, 0, 1, 2, 5, 6, 900].map(ReportValue.count).toList(), [
        'unavailable',
        '0',
        '0',
        '1',
        '2-5',
        '2-5',
        '6+',
        '6+',
      ]);
    });

    test('ages', () {
      expect(
        [
          null,
          const Duration(minutes: 59),
          const Duration(hours: 1),
          const Duration(hours: 6),
          const Duration(hours: 24),
          const Duration(hours: 72),
          const Duration(days: 7),
        ].map(ReportValue.age).toList(),
        ['unavailable', 'under-1h', '1-6h', '6-24h', '1-3d', '3-7d', 'over-7d'],
      );
    });
  });
}
