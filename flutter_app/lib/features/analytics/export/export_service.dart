import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:simpastil_storage/simpastil_storage.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/database.dart';
import '../../../core/db/daos/medication_ledger_dao.dart';
import '../../../core/doses/slot_engine.dart';
import '../../../core/medication/occurrence_history.dart';
import '../../../l10n/app_localizations.dart';
import '../../dashboard/models/history_entry.dart';
import '../../pills/pill_provider.dart' show PillWithSchedules;
import '../adherence.dart';

// ── Types ────────────────────────────────────────────────────────────────────

enum ExportFormat { csv, pdf, both }

typedef ExportPillAdherence = ({
  String pillName,
  String? dosage,
  int taken,
  int skipped,
  int missed,
  int expected,
});

typedef RangeAdherence = ({double? overall, List<ExportPillAdherence> perPill});

// ── Range adherence ─────────────────────────────────────────────────────────

RangeAdherence computeRangeAdherence({
  required List<PillWithSchedules> pillsWithSchedules,
  required List<DoseLog> logs,
  required DateTime from,
  required DateTime to,
  required DateTime now,
}) {
  final logByKey = {
    for (final l in logs) slotKey(l.scheduleId, l.scheduledAt): l,
  };

  var totalTaken = 0, totalSkipped = 0, totalExpected = 0;
  final pillAccumulators = <String, _PillAcc>{};

  final logsByDay = <DateTime, List<DoseLog>>{};
  for (final l in logs) {
    (logsByDay[dateOnly(l.scheduledAt)] ??= []).add(l);
  }

  for (
    var day = dateOnly(from);
    !day.isAfter(dateOnly(to));
    day = DateTime(day.year, day.month, day.day + 1)
  ) {
    for (final pws in pillsWithSchedules) {
      for (final slot in expectedSlotsFor(
        pws.schedules,
        day,
        existingLogs: logsByDay[day],
      )) {
        if (slot.scheduledAt.isAfter(now)) continue;
        final log = logByKey[slotKey(slot.schedule.id, slot.scheduledAt)];
        final isTaken = log?.status == 'taken';
        final isSkipped = log?.status == 'skipped';
        final isMissed = log?.status == 'missed';

        totalExpected++;
        if (isTaken) totalTaken++;
        if (isSkipped) totalSkipped++;

        final acc = pillAccumulators.putIfAbsent(
          pws.pill.id,
          () => _PillAcc(pws.pill.name, pws.pill.dosage),
        );
        acc.expected++;
        if (isTaken) acc.taken++;
        if (isSkipped) acc.skipped++;
        if (isMissed) acc.missed++;
      }
    }
  }

  final perPill = <ExportPillAdherence>[
    for (final e in pillAccumulators.entries)
      if (adherenceRatio(e.value.taken, e.value.skipped, e.value.expected) !=
          null)
        (
          pillName: e.value.pillName,
          dosage: e.value.dosage,
          taken: e.value.taken,
          skipped: e.value.skipped,
          missed: e.value.missed,
          expected: e.value.expected,
        ),
  ]..sort((a, b) => a.pillName.compareTo(b.pillName));

  return (
    overall: adherenceRatio(totalTaken, totalSkipped, totalExpected),
    perPill: perPill,
  );
}

RangeAdherence computeRangeAdherenceFromOccurrences({
  required List<MedicationOccurrenceRecord> records,
  required DateTime from,
  required DateTime to,
  required DateTime now,
}) {
  final summary = calculateOccurrenceAdherence(records: records, now: now);
  var totalTaken = 0;
  var totalSkipped = 0;
  var totalExpected = 0;
  final accumulators = <String, _PillAcc>{};
  for (final item in summary.history) {
    if (!item.isDueScheduled || item.plannedLocalDate == null) continue;
    final parts = item.plannedLocalDate!.split('-').map(int.parse).toList();
    final date = DateTime(parts[0], parts[1], parts[2]);
    if (dateOnly(date).isBefore(dateOnly(from)) ||
        dateOnly(date).isAfter(dateOnly(to))) {
      continue;
    }
    final isTaken = item.status == 'taken';
    final isSkipped = item.status == 'skipped';
    final isMissed = item.status == 'missed';
    totalExpected++;
    if (isTaken) totalTaken++;
    if (isSkipped) totalSkipped++;
    final id = item.pillId ?? 'unknown:${item.pillName ?? ''}';
    final accumulator = accumulators.putIfAbsent(
      id,
      () => _PillAcc(item.pillName ?? 'Unknown', item.dosage),
    );
    accumulator.expected++;
    if (isTaken) accumulator.taken++;
    if (isSkipped) accumulator.skipped++;
    if (isMissed) accumulator.missed++;
  }

  final perPill = <ExportPillAdherence>[
    for (final entry in accumulators.entries)
      (
        pillName: entry.value.pillName,
        dosage: entry.value.dosage,
        taken: entry.value.taken,
        skipped: entry.value.skipped,
        missed: entry.value.missed,
        expected: entry.value.expected,
      ),
  ]..sort((a, b) => a.pillName.compareTo(b.pillName));
  return (
    overall: adherenceRatio(totalTaken, totalSkipped, totalExpected),
    perPill: perPill,
  );
}

class _PillAcc {
  _PillAcc(this.pillName, this.dosage);
  final String pillName;
  final String? dosage;
  int taken = 0, skipped = 0, missed = 0, expected = 0;
}

// ── ExportService ────────────────────────────────────────────────────────────

class ExportService {
  static final _dateFmt = DateFormat('yyyy-MM-dd');
  static final _timeFmt = DateFormat('HH:mm');

  static final _formulaPrefix = RegExp(r'^[=+\-@\t\r]');

  static String _sanitizeCsvCell(String value) {
    if (value.isNotEmpty && _formulaPrefix.hasMatch(value)) {
      return "'$value";
    }
    return value;
  }

  static String _localizedStatus(AppLocalizations l, String status) {
    return switch (status) {
      'taken' => l.export_statusTaken,
      'missed' => l.export_statusMissed,
      'skipped' => l.export_statusSkipped,
      'pending' => l.export_statusPending,
      'unrecorded' => l.export_statusNotRecorded,
      _ => status,
    };
  }

  static String _entryStatus(AppLocalizations l, HistoryEntry entry) {
    final status = _localizedStatus(l, entry.status);
    return entry.provenance == 'legacy_estimated'
        ? '$status (estimated history)'
        : status;
  }

  static String _entryDate(HistoryEntry entry) {
    if (entry.plannedLocalDate != null) return entry.plannedLocalDate!;
    final scheduledAt = entry.scheduledAt;
    return scheduledAt == null ? 'Date unknown' : _dateFmt.format(scheduledAt);
  }

  static String _entryScheduledTime(HistoryEntry entry) {
    if (entry.plannedLocalTime != null) {
      return entry.plannedLocalTime!.substring(0, 5);
    }
    final scheduledAt = entry.scheduledAt;
    return scheduledAt == null ? 'Time unknown' : _timeFmt.format(scheduledAt);
  }

  /// Generates export file(s) and returns their paths.
  ///
  /// Android previews stay in private no-backup storage until explicit sharing.
  /// [outputDir] is a trusted fixture override, never a user-provided path.
  static Future<List<String>> generate({
    required String profileName,
    required List<HistoryEntry> entries,
    required RangeAdherence adherence,
    required DateTime from,
    required DateTime to,
    required ExportFormat format,
    required AppLocalizations l,
    Directory? outputDir,
  }) async {
    final dir = outputDir ?? await _privatePreviewDirectory();
    final now = DateTime.now();
    final dateStamp = _dateFmt.format(now);
    final timeStamp =
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final identity = const Uuid().v4();
    final paths = <String>[];

    try {
      if (format == ExportFormat.csv || format == ExportFormat.both) {
        final csvPath = p.join(
          dir.path,
          'simpastil_export_${dateStamp}_${timeStamp}_$identity.csv',
        );
        paths.add(csvPath);
        await _writeCsv(csvPath, entries, l, profileName);
      }

      if (format == ExportFormat.pdf || format == ExportFormat.both) {
        final pdfPath = p.join(
          dir.path,
          'simpastil_report_${dateStamp}_${timeStamp}_$identity.pdf',
        );
        paths.add(pdfPath);
        await _writePdf(
          pdfPath,
          profileName: profileName,
          entries: entries,
          adherence: adherence,
          from: from,
          to: to,
          l: l,
        );
      }

      return paths;
    } catch (_) {
      await cleanupFiles(paths);
      rethrow;
    }
  }

  static Future<Directory> _privatePreviewDirectory() async {
    if (!Platform.isAndroid) return getTemporaryDirectory();
    final directory = Directory(
      p.join(await const SimpastilStorage().noBackupPath(), 'report-previews'),
    );
    await directory.create(recursive: true);
    return directory;
  }

  static Future<void> cleanupFiles(List<String> paths) async {
    for (final path in paths) {
      try {
        await File(path).delete();
      } catch (_) {
        // Best effort cleanup of temporary export files.
      }
    }
  }

  // ── CSV ──────────────────────────────────────────────────────────────────

  static Future<void> _writeCsv(
    String path,
    List<HistoryEntry> entries,
    AppLocalizations l,
    String profileName,
  ) async {
    final header = [
      l.export_headerProfile,
      l.export_headerDate,
      l.export_headerScheduledTime,
      l.export_headerPillName,
      l.export_headerDosage,
      l.export_headerStatus,
      l.export_headerTimeTaken,
      l.export_headerNotes,
    ];

    final rows = <List<String>>[
      header,
      for (final e in entries)
        [
          _sanitizeCsvCell(profileName),
          _entryDate(e),
          _entryScheduledTime(e),
          _sanitizeCsvCell(e.pillName),
          _sanitizeCsvCell(e.dosage ?? ''),
          _entryStatus(l, e),
          e.actualTimeKnown && e.takenAt != null
              ? _timeFmt.format(e.takenAt!)
              : '',
          _sanitizeCsvCell(e.note ?? ''),
        ],
    ];

    final csvString = const ListToCsvConverter().convert(rows);
    final bom = Uint8List.fromList([0xEF, 0xBB, 0xBF]);
    final file = File(path);
    await file.writeAsBytes([...bom, ...utf8.encode(csvString)]);
  }

  // ── PDF ──────────────────────────────────────────────────────────────────

  static Future<void> _writePdf(
    String path, {
    required String profileName,
    required List<HistoryEntry> entries,
    required RangeAdherence adherence,
    required DateTime from,
    required DateTime to,
    required AppLocalizations l,
  }) async {
    final pdf = pw.Document();
    final rangeFmt = '${_dateFmt.format(from)} - ${_dateFmt.format(to)}';
    final generatedFmt = DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now());

    final bold = pw.TextStyle(fontWeight: pw.FontWeight.bold);
    const smallStyle = pw.TextStyle(fontSize: 9);

    final logRows = <List<String>>[];
    String? lastDate;
    for (final e in entries) {
      final date = _entryDate(e);
      logRows.add([
        date == lastDate ? '' : date,
        _entryScheduledTime(e),
        e.pillName,
        e.dosage ?? '',
        _entryStatus(l, e),
        e.actualTimeKnown && e.takenAt != null
            ? _timeFmt.format(e.takenAt!)
            : '',
        e.note ?? '',
      ]);
      lastDate = date;
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(20 * PdfPageFormat.mm),
        header: (context) => _pdfHeader(
          profileName: profileName,
          rangeFmt: rangeFmt,
          generatedFmt: generatedFmt,
          bold: bold,
          l: l,
        ),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            l.export_pdfPageNumber(context.pageNumber, context.pagesCount),
            style: smallStyle,
          ),
        ),
        build: (context) => [
          _pdfAdherenceSummary(adherence, bold, smallStyle, l),
          pw.SizedBox(height: 16),
          if (logRows.isNotEmpty) ...[
            pw.Text(l.export_pdfDoseLog, style: bold.copyWith(fontSize: 13)),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              border: pw.TableBorder.all(color: PdfColors.grey400),
              headerStyle: bold.copyWith(fontSize: 9),
              cellStyle: smallStyle,
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.grey200,
              ),
              cellAlignments: {
                0: pw.Alignment.centerLeft,
                1: pw.Alignment.center,
                2: pw.Alignment.centerLeft,
                3: pw.Alignment.centerLeft,
                4: pw.Alignment.center,
                5: pw.Alignment.center,
                6: pw.Alignment.centerLeft,
              },
              headers: [
                l.export_headerDate,
                l.export_headerScheduledTime,
                l.export_headerPill,
                l.export_headerDosage,
                l.export_headerStatus,
                l.export_headerTimeTaken,
                l.export_headerNotes,
              ],
              data: logRows,
            ),
          ] else
            pw.Text(l.export_pdfNoEntries, style: smallStyle),
        ],
      ),
    );

    final file = File(path);
    await file.writeAsBytes(await pdf.save());
  }

  static pw.Widget _pdfHeader({
    required String profileName,
    required String rangeFmt,
    required String generatedFmt,
    required pw.TextStyle bold,
    required AppLocalizations l,
  }) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(l.export_pdfTitle, style: bold.copyWith(fontSize: 16)),
        pw.SizedBox(height: 4),
        pw.Text(l.export_pdfProfile(profileName)),
        pw.Text(l.export_pdfDateRange(rangeFmt)),
        pw.Text(
          l.export_pdfGenerated(generatedFmt),
          style: const pw.TextStyle(fontSize: 9),
        ),
        pw.Divider(),
        pw.SizedBox(height: 8),
      ],
    );
  }

  static pw.Widget _pdfAdherenceSummary(
    RangeAdherence adherence,
    pw.TextStyle bold,
    pw.TextStyle smallStyle,
    AppLocalizations l,
  ) {
    final overallPct = adherence.overall != null
        ? '${(adherence.overall! * 100).round()}%'
        : 'N/A';

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          l.export_pdfAdherenceSummary,
          style: bold.copyWith(fontSize: 13),
        ),
        pw.SizedBox(height: 6),
        pw.Text(
          l.export_pdfOverallAdherence(overallPct),
          style: bold.copyWith(fontSize: 11),
        ),
        pw.SizedBox(height: 8),
        if (adherence.perPill.isNotEmpty)
          pw.TableHelper.fromTextArray(
            border: pw.TableBorder.all(color: PdfColors.grey400),
            headerStyle: bold.copyWith(fontSize: 9),
            cellStyle: smallStyle,
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
            cellAlignments: {
              0: pw.Alignment.centerLeft,
              1: pw.Alignment.centerLeft,
              2: pw.Alignment.center,
              3: pw.Alignment.center,
              4: pw.Alignment.center,
            },
            headers: [
              l.export_headerPill,
              l.export_headerDosage,
              l.export_headerTakenExpected,
              l.export_headerMissed,
              l.export_headerAdherence,
            ],
            data: [
              for (final pill in adherence.perPill)
                [
                  pill.pillName,
                  pill.dosage ?? '',
                  '${pill.taken} / ${pill.expected}',
                  '${pill.missed}',
                  adherenceRatio(pill.taken, pill.skipped, pill.expected) !=
                          null
                      ? '${(adherenceRatio(pill.taken, pill.skipped, pill.expected)! * 100).round()}%'
                      : 'N/A',
                ],
            ],
          ),
      ],
    );
  }
}
