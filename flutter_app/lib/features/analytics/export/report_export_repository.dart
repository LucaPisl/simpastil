import 'dart:io';

import '../../../core/db/database.dart';
import '../../../core/medication/occurrence_history.dart';
import '../../../core/workspace/workspace_access_repository.dart';
import '../../../core/workspace/workspace_context.dart';
import '../../../l10n/app_localizations.dart';
import '../../dashboard/history_entry_mapper.dart';
import 'export_service.dart';

enum ReportExportFailureCode { unavailable, staleAccess, shareFailed }

class ReportExportFailure implements Exception {
  const ReportExportFailure(this.code);
  final ReportExportFailureCode code;
  @override
  String toString() => 'ReportExportFailure(${code.name})';
}

/// Report working files are private, transient clear files, not restorable
/// backups. An explicit share is dispatched only with current care access.
class ReportExportRepository {
  const ReportExportRepository({
    required this.database,
    required this.access,
    required this.context,
    this.outputDirectory,
  });
  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final WorkspaceContext context;
  final Directory? outputDirectory;

  Future<void> exportAndShare({
    required String? personId,
    required String profileName,
    required DateTime from,
    required DateTime to,
    required ExportFormat format,
    required AppLocalizations l,
    required Future<void> Function(List<String>) share,
    Future<void> Function()? beforeDisclosure,
  }) async {
    final paths = <String>[];
    try {
      final captured = await access.withGrant(context, () async {
        final all = await database.medicationLedgerDao.getForUserLocalDateRange(
          context.ownerUserId,
          _localDateKey(from),
          _localDateKey(to),
        );
        final records = personId == null
            ? all
            : all
                  .where(
                    (record) =>
                        decodeOccurrenceSnapshot(
                          record.occurrence.scheduleSnapshotJson,
                        )?['profileId'] ==
                        personId,
                  )
                  .toList();
        final now = DateTime.now();
        final entries =
            records
                .map(
                  (record) =>
                      historyEntryFromOccurrenceRecord(record, now: now),
                )
                .where((entry) => entry.status != 'pending')
                .toList()
              ..sort((a, b) {
                final aTime = a.scheduledAt ?? a.takenAt,
                    bTime = b.scheduledAt ?? b.takenAt;
                if (aTime == null) return bTime == null ? 0 : 1;
                if (bTime == null) return -1;
                return aTime.compareTo(bTime);
              });
        return (
          entries: entries,
          adherence: computeRangeAdherenceFromOccurrences(
            records: records,
            from: from,
            to: to,
            now: now,
          ),
        );
      }, profileId: personId);
      paths.addAll(
        await ExportService.generate(
          profileName: profileName,
          entries: captured.entries,
          adherence: captured.adherence,
          from: from,
          to: to,
          format: format,
          l: l,
          outputDir: outputDirectory,
        ),
      );
      await beforeDisclosure?.call();
      await access.withGrant(context, () async {}, profileId: personId);
      try {
        await share(List.unmodifiable(paths));
      } catch (_) {
        throw const ReportExportFailure(ReportExportFailureCode.shareFailed);
      }
    } on WorkspaceAccessFailure {
      throw const ReportExportFailure(ReportExportFailureCode.staleAccess);
    } on ReportExportFailure {
      rethrow;
    } catch (_) {
      throw const ReportExportFailure(ReportExportFailureCode.unavailable);
    } finally {
      await ExportService.cleanupFiles(paths);
    }
  }

  static String _localDateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
