import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Builds the file a person saves from the server's account export: the full
/// JSON as the server sent it, plus a `dose-history.csv` that opens in a
/// spreadsheet. Both go into one zip so there is one file to keep.
///
/// The zip is not encrypted. The screens say so before it is saved.
class AccountExportBuilder {
  const AccountExportBuilder();

  static const jsonName = 'simpastil-data.json';
  static const csvName = 'dose-history.csv';

  static const csvHeader = [
    'person',
    'medication',
    'plannedLocalDate',
    'scheduledFor',
    'action',
    'actualAt',
    'actualTimeKnown',
    'amount',
    'recordedBy',
    'recordedAt',
  ];

  /// The zip for [exportJson] (the response body, UTF-8). Throws
  /// [FormatException] when the body is not an account export.
  Uint8List buildZip(Uint8List exportJson) {
    final decoded = jsonDecode(utf8.decode(exportJson));
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'simpastil-account-export' ||
        decoded['tables'] is! Map) {
      throw const FormatException('Not a Simpastil account export');
    }
    final csv = utf8.encode('﻿${buildCsv(decoded)}');
    final archive = Archive()
      ..addFile(ArchiveFile.bytes(jsonName, exportJson))
      ..addFile(ArchiveFile.bytes(csvName, csv));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// One row per recorded event. Care recorded before the ledger (dose logs of
  /// a routine with no occurrences) gets one row per log instead, so no dose
  /// is left out. Cells that a spreadsheet would run as a formula are
  /// prefixed with an apostrophe.
  String buildCsv(Map<String, dynamic> export) {
    final tables = export['tables'] as Map;
    List<Map<String, dynamic>> rows(String key) {
      final value = tables[key];
      if (value is! List) return const [];
      return [
        for (final row in value)
          if (row is Map<String, dynamic>) row,
      ];
    }

    final people = {for (final p in rows('profiles')) p['id']: p['name']};
    final pills = {for (final p in rows('pills')) p['id']: p};
    String person(Object? pillId) {
      final pill = pills[pillId];
      return pill == null ? '' : _text(people[pill['profileId']]);
    }

    String medication(Object? pillId) => _text(pills[pillId]?['name']);

    final occurrences = {
      for (final o in rows('medicationOccurrences')) o['id']: o,
    };
    final out = <List<String>>[];
    final scheduleWithOccurrences = <Object?>{
      for (final o in occurrences.values)
        if (o['scheduleId'] != null) o['scheduleId'],
    };

    for (final event in rows('occurrenceEvents')) {
      final occurrence = occurrences[event['occurrenceId']];
      final pillId = occurrence?['pillId'];
      out.add([
        person(pillId),
        medication(pillId),
        _text(occurrence?['plannedLocalDate']),
        _text(occurrence?['plannedAt']),
        _text(event['action']),
        _text(event['actualAt']),
        event['actualTimeKnown'] == true ? 'true' : 'false',
        _amount(event['administrationAmount']),
        _recordedBy(event['recordedBy']),
        _text(event['recordedAt']),
      ]);
    }

    final schedules = {for (final s in rows('schedules')) s['id']: s};
    for (final log in rows('doseLogs')) {
      if (scheduleWithOccurrences.contains(log['scheduleId'])) continue;
      final pillId = schedules[log['scheduleId']]?['pillId'];
      final scheduled = _text(log['scheduledAt']);
      final taken = _text(log['takenAt']);
      out.add([
        person(pillId),
        medication(pillId),
        scheduled.length >= 10 ? scheduled.substring(0, 10) : scheduled,
        scheduled,
        _text(log['status']),
        taken,
        taken.isEmpty ? 'false' : 'true',
        '',
        '',
        _text(log['updatedAt']),
      ]);
    }

    out.sort((a, b) {
      final byDate = a[2].compareTo(b[2]);
      return byDate != 0 ? byDate : a[9].compareTo(b[9]);
    });
    final buffer = StringBuffer(csvHeader.map(csvCell).join(','))
      ..write('\r\n');
    for (final row in out) {
      buffer
        ..write(row.map(csvCell).join(','))
        ..write('\r\n');
    }
    return buffer.toString();
  }

  static String _text(Object? value) => value == null ? '' : '$value';

  static String _amount(Object? value) {
    if (value is! Map || value['state'] != 'known') return '';
    final unit = value['unit'];
    return '${_text(value['quantity'])}${unit == null ? '' : ' $unit'}'.trim();
  }

  static String _recordedBy(Object? value) =>
      value is Map ? _text(value['name']) : '';

  /// Quotes a cell for CSV and defuses spreadsheet formulas.
  static String csvCell(String value) {
    var cell = value;
    if (cell.isNotEmpty && '=+-@\t\r'.contains(cell[0])) {
      cell = "'$cell";
    }
    if (cell.contains(RegExp('[",\r\n]'))) {
      cell = '"${cell.replaceAll('"', '""')}"';
    }
    return cell;
  }
}
