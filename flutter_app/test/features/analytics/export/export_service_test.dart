import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/features/analytics/export/export_service.dart';
import 'package:simpastil/features/dashboard/models/history_entry.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

Schedule _schedule({
  String id = 'sched-1',
  String pillId = 'pill-1',
  int hour = 8,
  int minute = 0,
  String frequency = 'daily',
  String? frequencyDays,
  bool isActive = true,
  DateTime? createdAt,
}) => Schedule(
  id: id,
  pillId: pillId,
  hour: hour,
  minute: minute,
  frequency: frequency,
  timeZoneStatus: 'legacy_unknown',
  frequencyDays: frequencyDays,
  isActive: isActive,
  createdAt: createdAt ?? DateTime(2026),
  updatedAt: createdAt ?? DateTime(2026),
  revision: 1,
  syncStatus: 'synced',
  isDeleted: false,
);

Pill _pill({
  String id = 'pill-1',
  String profileId = 'profile-1',
  String name = 'Aspirin',
  String? dosage = '100mg',
  String? color,
  bool isPrn = false,
}) => Pill(
  id: id,
  profileId: profileId,
  name: name,
  dosage: dosage,
  color: color,
  isPrn: isPrn,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  revision: 1,
  syncStatus: 'synced',
  isDeleted: false,
);

DoseLog _log({
  String id = 'log-1',
  String scheduleId = 'sched-1',
  required DateTime scheduledAt,
  String status = 'taken',
  DateTime? takenAt,
  String? note,
}) => DoseLog(
  id: id,
  scheduleId: scheduleId,
  scheduledAt: scheduledAt,
  takenAt: takenAt,
  status: status,
  note: note,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  revision: 1,
  syncStatus: 'synced',
  isDeleted: false,
);

HistoryEntry _entry({
  String doseLogId = 'log-1',
  String pillName = 'Aspirin',
  String? dosage = '100mg',
  required DateTime scheduledAt,
  DateTime? takenAt,
  String status = 'taken',
  String? note,
  String profileName = 'Alex',
  String scheduleId = 'sched-1',
}) => HistoryEntry(
  doseLogId: doseLogId,
  pillName: pillName,
  dosage: dosage,
  scheduledAt: scheduledAt,
  takenAt: takenAt,
  status: status,
  note: note,
  profileName: profileName,
  scheduleId: scheduleId,
);

// ── computeRangeAdherence tests ─────────────────────────────────────────────

void main() {
  late Directory tempDir;
  late AppLocalizations l;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('export_test_');
    l = AppLocalizationsEn();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });
  group('computeRangeAdherence', () {
    test('counts a recorded miss per pill without changing the ratio', () {
      final pillSchedules = [
        (pill: _pill(), schedules: [_schedule(hour: 8)]),
      ];
      RangeAdherence run(List<DoseLog> logs) => computeRangeAdherence(
        pillsWithSchedules: pillSchedules,
        logs: logs,
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 2),
        now: DateTime(2026, 6, 3),
      );
      final taken = _log(id: 'a', scheduledAt: DateTime(2026, 6, 1, 8));
      final missed = _log(
        id: 'b',
        scheduledAt: DateTime(2026, 6, 2, 8),
        status: 'missed',
      );
      final withMiss = run([taken, missed]);
      final unrecorded = run([taken]);
      expect(withMiss.perPill.single.missed, 1);
      expect(unrecorded.perPill.single.missed, 0);
      expect(withMiss.overall, unrecorded.overall);
    });

    test('the PDF summary has a Missed column', () async {
      final paths = await ExportService.generate(
        profileName: 'Alex',
        entries: const [],
        adherence: (
          overall: 0.5,
          perPill: [
            (
              pillName: 'Aspirin',
              dosage: '100mg',
              taken: 1,
              skipped: 0,
              missed: 1,
              expected: 2,
            ),
          ],
        ),
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 2),
        format: ExportFormat.pdf,
        l: l,
        outputDir: tempDir,
      );
      expect(File(paths.single).lengthSync(), greaterThan(0));
    });

    test('returns null overall when no expected slots', () {
      final result = computeRangeAdherence(
        pillsWithSchedules: [],
        logs: [],
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 7),
        now: DateTime(2026, 6, 7, 23, 59),
      );

      expect(result.overall, isNull);
      expect(result.perPill, isEmpty);
    });

    test('computes 100% adherence when all doses taken', () {
      final pill = _pill();
      final sched = _schedule();
      final result = computeRangeAdherence(
        pillsWithSchedules: [
          (pill: pill, schedules: [sched]),
        ],
        logs: [
          _log(
            id: 'log-1',
            scheduledAt: DateTime(2026, 6, 1, 8, 0),
            status: 'taken',
          ),
          _log(
            id: 'log-2',
            scheduledAt: DateTime(2026, 6, 2, 8, 0),
            status: 'taken',
          ),
          _log(
            id: 'log-3',
            scheduledAt: DateTime(2026, 6, 3, 8, 0),
            status: 'taken',
          ),
        ],
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 3),
        now: DateTime(2026, 6, 3, 23, 59),
      );

      expect(result.overall, closeTo(1.0, 0.001));
      expect(result.perPill, hasLength(1));
      expect(result.perPill.first.pillName, 'Aspirin');
      expect(result.perPill.first.dosage, '100mg');
      expect(result.perPill.first.taken, 3);
      expect(result.perPill.first.expected, 3);
    });

    test('skipped doses remain in the denominator', () {
      final pill = _pill();
      final sched = _schedule();
      final result = computeRangeAdherence(
        pillsWithSchedules: [
          (pill: pill, schedules: [sched]),
        ],
        logs: [
          _log(
            id: 'log-1',
            scheduledAt: DateTime(2026, 6, 1, 8, 0),
            status: 'taken',
          ),
          _log(
            id: 'log-2',
            scheduledAt: DateTime(2026, 6, 2, 8, 0),
            status: 'skipped',
          ),
        ],
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 2),
        now: DateTime(2026, 6, 2, 23, 59),
      );

      // 1 taken ÷ 2 due scheduled occurrences = 50%.
      expect(result.overall, closeTo(0.5, 0.001));
    });

    test('missed doses reduce adherence', () {
      final pill = _pill();
      final sched = _schedule();
      final result = computeRangeAdherence(
        pillsWithSchedules: [
          (pill: pill, schedules: [sched]),
        ],
        logs: [
          _log(
            id: 'log-1',
            scheduledAt: DateTime(2026, 6, 1, 8, 0),
            status: 'taken',
          ),
          _log(
            id: 'log-2',
            scheduledAt: DateTime(2026, 6, 2, 8, 0),
            status: 'missed',
          ),
        ],
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 2),
        now: DateTime(2026, 6, 2, 23, 59),
      );

      // 1 taken ÷ (2 expected − 0 skipped) = 50%
      expect(result.overall, closeTo(0.5, 0.001));
    });

    test('multiple pills sorted alphabetically', () {
      final pillA = _pill(id: 'p-a', name: 'Aspirin', dosage: '100mg');
      final pillB = _pill(id: 'p-b', name: 'Vitamin D', dosage: '1000IU');
      final schedA = _schedule(id: 's-a', pillId: 'p-a');
      final schedB = _schedule(id: 's-b', pillId: 'p-b', hour: 20);

      final result = computeRangeAdherence(
        pillsWithSchedules: [
          (pill: pillB, schedules: [schedB]),
          (pill: pillA, schedules: [schedA]),
        ],
        logs: [
          _log(
            id: 'log-1',
            scheduleId: 's-a',
            scheduledAt: DateTime(2026, 6, 1, 8, 0),
            status: 'taken',
          ),
          _log(
            id: 'log-2',
            scheduleId: 's-b',
            scheduledAt: DateTime(2026, 6, 1, 20, 0),
            status: 'missed',
          ),
        ],
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 1),
        now: DateTime(2026, 6, 1, 23, 59),
      );

      expect(result.perPill, hasLength(2));
      expect(result.perPill[0].pillName, 'Aspirin');
      expect(result.perPill[1].pillName, 'Vitamin D');
    });

    test('future slots not counted', () {
      final pill = _pill();
      final sched = _schedule(hour: 20);
      final result = computeRangeAdherence(
        pillsWithSchedules: [
          (pill: pill, schedules: [sched]),
        ],
        logs: [],
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 1),
        now: DateTime(2026, 6, 1, 10, 0), // before the 20:00 slot
      );

      expect(result.overall, isNull);
      expect(result.perPill, isEmpty);
    });
  });

  // ── CSV generation tests ──────────────────────────────────────────────────

  group('ExportService CSV', () {
    test('generates valid CSV with BOM and correct columns', () async {
      final entries = [
        _entry(
          scheduledAt: DateTime(2026, 6, 1, 8, 0),
          takenAt: DateTime(2026, 6, 1, 8, 5),
          status: 'taken',
          note: 'Felt fine',
        ),
        _entry(
          doseLogId: 'log-2',
          pillName: 'Vitamin D',
          dosage: '1000IU',
          scheduledAt: DateTime(2026, 6, 1, 20, 0),
          status: 'missed',
        ),
      ];

      final adherence = computeRangeAdherence(
        pillsWithSchedules: [],
        logs: [],
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 1),
        now: DateTime(2026, 6, 1, 23, 59),
      );

      final paths = await ExportService.generate(
        profileName: 'Alex',
        entries: entries,
        adherence: adherence,
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 1),
        format: ExportFormat.csv,
        l: l,
        outputDir: tempDir,
      );

      expect(paths, hasLength(1));
      expect(paths.first, endsWith('.csv'));

      final file = File(paths.first);
      expect(file.existsSync(), isTrue);

      final bytes = file.readAsBytesSync();
      // Check UTF-8 BOM
      expect(bytes[0], 0xEF);
      expect(bytes[1], 0xBB);
      expect(bytes[2], 0xBF);

      final rawBytes = file.readAsBytesSync();
      // Skip 3-byte UTF-8 BOM, then decode
      final content = utf8.decode(rawBytes.sublist(3));
      final rows = csv.decode(content);

      expect(rows, hasLength(3)); // header + 2 data rows
      expect(rows[0], [
        'Profile',
        'Date',
        'Scheduled Time',
        'Pill Name',
        'Dosage',
        'Status',
        'Time Taken',
        'Notes',
      ]);
      expect(rows[1][0], 'Alex');
      expect(rows[1][1], '2026-06-01');
      expect(rows[1][2], '08:00');
      expect(rows[1][3], 'Aspirin');
      expect(rows[1][4], '100mg');
      expect(rows[1][5], 'Taken');
      expect(rows[1][6], '08:05');
      expect(rows[1][7], 'Felt fine');

      expect(rows[2][5], 'Missed');
      expect(rows[2][6], ''); // no takenAt
      expect(rows[2][7], ''); // no note
    });

    test('a due dose nobody recorded exports as Not recorded, a miss as '
        'Missed', () async {
      final entries = [
        _entry(
          doseLogId: 'log-1',
          scheduledAt: DateTime(2026, 6, 1, 8, 0),
          status: 'unrecorded',
        ),
        _entry(
          doseLogId: 'log-2',
          scheduledAt: DateTime(2026, 6, 1, 20, 0),
          status: 'missed',
        ),
      ];
      final adherence = computeRangeAdherence(
        pillsWithSchedules: [],
        logs: [],
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 1),
        now: DateTime(2026, 6, 1, 23, 59),
      );

      final paths = await ExportService.generate(
        profileName: 'Alex',
        entries: entries,
        adherence: adherence,
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 1),
        format: ExportFormat.csv,
        l: l,
        outputDir: tempDir,
      );

      final content = utf8.decode(
        File(paths.first).readAsBytesSync().sublist(3),
      );
      final rows = csv.decode(content);
      expect(rows[1][5], 'Not recorded');
      expect(rows[2][5], 'Missed');
    });

    test(
      'writes RFC 4180 rows with CRLF and quotes only where needed',
      () async {
        final adherence = computeRangeAdherence(
          pillsWithSchedules: [],
          logs: [],
          from: DateTime(2026, 6, 1),
          to: DateTime(2026, 6, 1),
          now: DateTime(2026, 6, 1, 23, 59),
        );
        final entries = [
          _entry(
            scheduledAt: DateTime(2026, 6, 1, 8, 0),
            takenAt: DateTime(2026, 6, 1, 8, 5),
            pillName: 'Aspirin, buffered',
            dosage: '100mg',
            note: 'said "ok"\nsecond line',
          ),
          _entry(
            scheduledAt: DateTime(2026, 6, 1, 9, 0),
            pillName: '=SUM(A1)',
            dosage: null,
            status: 'missed',
            note: 'caf\u00e9 \u2713',
          ),
        ];

        final paths = await ExportService.generate(
          profileName: 'Alex',
          entries: entries,
          adherence: adherence,
          from: DateTime(2026, 6, 1),
          to: DateTime(2026, 6, 1),
          format: ExportFormat.csv,
          l: l,
          outputDir: tempDir,
        );

        final text = utf8.decode(
          File(paths.first).readAsBytesSync().sublist(3),
        );
        final lines = text.split('\r\n');
        // header, first row (its quoted note holds a bare LF), second row:
        // rows are separated by CRLF, so the LF inside the note does not split.
        expect(lines, hasLength(3));
        expect(
          lines[1],
          'Alex,2026-06-01,08:00,"Aspirin, buffered",100mg,Taken,08:05,'
          '"said ""ok""\nsecond line"',
        );
        // A formula-looking cell stays neutralised and the missing dosage is
        // an empty field, not the word "null".
        expect(
          lines[2],
          startsWith("Alex,2026-06-01,09:00,'=SUM(A1),,Missed,"),
        );
        expect(lines[2], endsWith('caf\u00e9 \u2713'));

        final rows = csv.decode(text);
        expect(rows, hasLength(3));
        expect(rows[1][3], 'Aspirin, buffered');
        expect(rows[1][7], 'said "ok"\nsecond line');
        expect(rows[2][3], "'=SUM(A1)");
        expect(rows[2][4], '');
      },
    );

    test('generates empty CSV with only headers when no entries', () async {
      final adherence = computeRangeAdherence(
        pillsWithSchedules: [],
        logs: [],
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 1),
        now: DateTime(2026, 6, 1, 23, 59),
      );

      final paths = await ExportService.generate(
        profileName: 'Alex',
        entries: [],
        adherence: adherence,
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 1),
        format: ExportFormat.csv,
        l: l,
        outputDir: tempDir,
      );

      expect(paths, hasLength(1));
      final file = File(paths.first);
      final rawBytes = file.readAsBytesSync();
      final content = utf8.decode(rawBytes.sublist(3));
      final rows = csv.decode(content);
      expect(rows, hasLength(1)); // header only
    });
  });

  // ── PDF generation tests ──────────────────────────────────────────────────

  group('ExportService PDF', () {
    test('generates a non-empty PDF file', () async {
      final entries = [
        _entry(
          scheduledAt: DateTime(2026, 6, 1, 8, 0),
          takenAt: DateTime(2026, 6, 1, 8, 5),
          status: 'taken',
        ),
      ];

      final pill = _pill();
      final sched = _schedule();
      final adherence = computeRangeAdherence(
        pillsWithSchedules: [
          (pill: pill, schedules: [sched]),
        ],
        logs: [_log(scheduledAt: DateTime(2026, 6, 1, 8, 0), status: 'taken')],
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 1),
        now: DateTime(2026, 6, 1, 23, 59),
      );

      final paths = await ExportService.generate(
        profileName: 'Alex',
        entries: entries,
        adherence: adherence,
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 1),
        format: ExportFormat.pdf,
        l: l,
        outputDir: tempDir,
      );

      expect(paths, hasLength(1));
      expect(paths.first, endsWith('.pdf'));

      final file = File(paths.first);
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), greaterThan(100));

      // Check PDF magic bytes
      final bytes = file.readAsBytesSync();
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });

    test('generates PDF with empty dose log message when no entries', () async {
      final adherence = computeRangeAdherence(
        pillsWithSchedules: [],
        logs: [],
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 7),
        now: DateTime(2026, 6, 7, 23, 59),
      );

      final paths = await ExportService.generate(
        profileName: 'Alex',
        entries: [],
        adherence: adherence,
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 7),
        format: ExportFormat.pdf,
        l: l,
        outputDir: tempDir,
      );

      expect(paths, hasLength(1));
      final file = File(paths.first);
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), greaterThan(100));
    });
  });

  // ── Both format tests ─────────────────────────────────────────────────────

  group('ExportService both formats', () {
    test('generates both CSV and PDF files', () async {
      final entries = [
        _entry(
          scheduledAt: DateTime(2026, 6, 1, 8, 0),
          status: 'taken',
          takenAt: DateTime(2026, 6, 1, 8, 2),
        ),
      ];

      final adherence = computeRangeAdherence(
        pillsWithSchedules: [],
        logs: [],
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 1),
        now: DateTime(2026, 6, 1, 23, 59),
      );

      final paths = await ExportService.generate(
        profileName: 'Alex',
        entries: entries,
        adherence: adherence,
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 1),
        format: ExportFormat.both,
        l: l,
        outputDir: tempDir,
      );

      expect(paths, hasLength(2));
      expect(paths.any((p) => p.endsWith('.csv')), isTrue);
      expect(paths.any((p) => p.endsWith('.pdf')), isTrue);

      for (final path in paths) {
        final file = File(path);
        expect(file.existsSync(), isTrue);
      }
    });
  });
}
