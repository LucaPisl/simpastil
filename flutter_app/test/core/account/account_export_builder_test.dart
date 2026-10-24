import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/account/account_export_builder.dart';

Map<String, dynamic> _export({
  List<Map<String, dynamic>> events = const [],
  List<Map<String, dynamic>> logs = const [],
  List<Map<String, dynamic>> occurrences = const [],
  String pillName = 'Vitamin D',
}) => {
  'format': 'simpastil-account-export',
  'version': 1,
  'tables': {
    'profiles': [
      {'id': 'p1', 'name': 'Alex'},
    ],
    'pills': [
      {'id': 'm1', 'name': pillName, 'profileId': 'p1'},
    ],
    'schedules': [
      {'id': 's1', 'pillId': 'm1'},
      {'id': 's2', 'pillId': 'm1'},
    ],
    'doseLogs': logs,
    'medicationOccurrences': occurrences,
    'occurrenceEvents': events,
  },
};

Uint8List _bytes(Map<String, dynamic> m) =>
    Uint8List.fromList(utf8.encode(jsonEncode(m)));

void main() {
  const builder = AccountExportBuilder();

  test('the zip holds the json untouched and a BOM-prefixed csv', () {
    final src = _bytes(_export());
    final archive = ZipDecoder().decodeBytes(builder.buildZip(src));
    final names = archive.files.map((f) => f.name).toList();
    expect(names, ['simpastil-data.json', 'dose-history.csv']);
    expect(archive.files[0].content, src);
    final raw = archive.files[1].content as List<int>;
    expect(raw.take(3), [0xEF, 0xBB, 0xBF]);
    expect(utf8.decode(raw), startsWith('person,medication,'));
  });

  test('a body that is not an export is refused', () {
    expect(
      () => builder.buildZip(_bytes({'format': 'other', 'tables': {}})),
      throwsFormatException,
    );
  });

  test('events become rows with person, medication and amount', () {
    final csv = builder.buildCsv(
      _export(
        occurrences: [
          {
            'id': 'o1',
            'pillId': 'm1',
            'scheduleId': 's1',
            'plannedLocalDate': '2026-09-30',
            'plannedAt': '2026-09-30T09:00:00Z',
          },
        ],
        events: [
          {
            'occurrenceId': 'o1',
            'action': 'take',
            'actualAt': '2026-09-30T09:05:00Z',
            'actualTimeKnown': true,
            'administrationAmount': {
              'state': 'known',
              'quantity': '1',
              'unit': 'tablet',
            },
            'recordedBy': {'name': 'Sam'},
            'recordedAt': '2026-09-30T09:06:00Z',
          },
        ],
      ),
    );
    final lines = csv.trim().split('\r\n');
    expect(lines, hasLength(2));
    expect(lines[1], contains('Alex,Vitamin D,2026-09-30'));
    expect(lines[1], contains(',take,'));
    expect(lines[1], contains('1 tablet'));
    expect(lines[1], contains(',Sam,'));
  });

  test('dose logs of a routine with no occurrences are not left out', () {
    final csv = builder.buildCsv(
      _export(
        occurrences: [
          {'id': 'o1', 'pillId': 'm1', 'scheduleId': 's1'},
        ],
        logs: [
          {
            'scheduleId': 's1',
            'scheduledAt': '2026-01-01T08:00:00Z',
            'status': 'taken',
          },
          {
            'scheduleId': 's2',
            'scheduledAt': '2026-01-02T08:00:00Z',
            'takenAt': '2026-01-02T08:10:00Z',
            'status': 'taken',
          },
        ],
      ),
    );
    final lines = csv.trim().split('\r\n');
    expect(lines, hasLength(2));
    expect(lines[1], contains('2026-01-02'));
  });

  test('cells that a spreadsheet would run are neutralised and quoted', () {
    for (final risky in ['=SUM(A1)', '+1', '-1', '@x']) {
      expect(AccountExportBuilder.csvCell(risky), "'$risky");
    }
    expect(AccountExportBuilder.csvCell('say "hi", ok'), '"say ""hi"", ok"');
    final csv = builder.buildCsv(
      _export(
        pillName: '=HYPERLINK("x")',
        occurrences: [
          {'id': 'o1', 'pillId': 'm1'},
        ],
        events: [
          {'occurrenceId': 'o1', 'action': 'take'},
        ],
      ),
    );
    expect(csv, contains('"\'=HYPERLINK(""x"")"'));
  });
}
