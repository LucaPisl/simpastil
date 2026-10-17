import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart' show Share, XFile;

import '../../../core/db/database.dart';
import '../../../core/protection/app_lock_controller.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/drag_handle.dart';
import '../../profiles/profile_provider.dart';
import 'export_service.dart';
import 'report_export_repository.dart';

class ExportBottomSheet extends ConsumerStatefulWidget {
  const ExportBottomSheet({super.key, this.now});

  final DateTime Function()? now;

  @override
  ConsumerState<ExportBottomSheet> createState() => _ExportBottomSheetState();
}

enum _DatePreset { last7, last30, last3Months, custom }

class _ExportBottomSheetState extends ConsumerState<ExportBottomSheet> {
  _DatePreset _preset = _DatePreset.last7;
  ExportFormat _format = ExportFormat.pdf;
  DateTimeRange? _customRange;
  bool _exporting = false;

  DateTime get _from {
    final now = (widget.now ?? DateTime.now)();
    final today = DateTime(now.year, now.month, now.day);
    return switch (_preset) {
      _DatePreset.last7 => today.subtract(const Duration(days: 6)),
      _DatePreset.last30 => today.subtract(const Duration(days: 29)),
      _DatePreset.last3Months => DateTime(
        today.year,
        today.month - 3,
        today.day,
      ),
      _DatePreset.custom =>
        _customRange?.start ?? today.subtract(const Duration(days: 6)),
    };
  }

  DateTime get _to {
    final now = (widget.now ?? DateTime.now)();
    final today = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
    return switch (_preset) {
      _DatePreset.custom =>
        _customRange != null
            ? DateTime(
                _customRange!.end.year,
                _customRange!.end.month,
                _customRange!.end.day,
                23,
                59,
                59,
                999,
              )
            : today,
      _ => today,
    };
  }

  Future<void> _pickCustomRange() async {
    final now = (widget.now ?? DateTime.now)();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: now,
      initialDateRange:
          _customRange ??
          DateTimeRange(
            start: now.subtract(const Duration(days: 29)),
            end: now,
          ),
    );
    if (picked != null && mounted) {
      setState(() {
        _customRange = picked;
        _preset = _DatePreset.custom;
      });
    }
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);

    try {
      final lockLease = ref
          .read(appLockControllerProvider.notifier)
          .captureAccess();
      final db = ref.read(databaseProvider);
      final access = ref.read(workspaceAccessRepositoryProvider);
      final available = ref.read(workspaceContextProvider);
      if (available.isLoading ||
          available.hasError ||
          available.asData == null) {
        throw const ReportExportFailure(ReportExportFailureCode.unavailable);
      }
      final capturedContext = available.asData!.value;
      final primary = ref.read(primaryProfileIdProvider.future);
      final l = AppLocalizations.of(context);
      final from = _from, to = _to, format = _format;
      final personId = await primary;
      if (!mounted) return;
      final profileName = await access.withGrant(
        capturedContext,
        () async => personId == null
            ? l.t08_everyone
            : (await db.profilesDao.getById(personId))!.name,
        profileId: personId,
      );
      if (!mounted) return;
      await ReportExportRepository(
        database: db,
        access: access,
        context: capturedContext,
      ).exportAndShare(
        personId: personId,
        profileName: profileName,
        from: from,
        to: to,
        format: format,
        l: l,
        share: (paths) async {
          if (!mounted) {
            throw const ReportExportFailure(
              ReportExportFailureCode.unavailable,
            );
          }
          lockLease.requireCurrent();
          await Share.shareXFiles(paths.map((p) => XFile(p)).toList());
        },
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        final l = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.export_failed(l.shared_somethingWentWrong))),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final profileName =
        ref.watch(primaryProfileNameProvider) ?? l.shared_unknown;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        16,
        24,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const DragHandle(),
          Text(
            l.export_title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            l.export_profile(profileName),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 20),

          // ── Date range ──────────────────────────────────────────────
          Text(
            l.export_dateRange,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _PresetChip(
                label: l.export_last7Days,
                selected: _preset == _DatePreset.last7,
                onTap: () => setState(() => _preset = _DatePreset.last7),
              ),
              _PresetChip(
                label: l.export_last30Days,
                selected: _preset == _DatePreset.last30,
                onTap: () => setState(() => _preset = _DatePreset.last30),
              ),
              _PresetChip(
                label: l.export_last3Months,
                selected: _preset == _DatePreset.last3Months,
                onTap: () => setState(() => _preset = _DatePreset.last3Months),
              ),
              _PresetChip(
                label: _customRange != null && _preset == _DatePreset.custom
                    ? '${_customRange!.start.day}/${_customRange!.start.month} — ${_customRange!.end.day}/${_customRange!.end.month}'
                    : l.export_custom,
                selected: _preset == _DatePreset.custom,
                onTap: _pickCustomRange,
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ── Format ──────────────────────────────────────────────────
          Text(
            l.export_format,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          SegmentedButton<ExportFormat>(
            segments: [
              const ButtonSegment(
                value: ExportFormat.csv,
                label: Text('CSV'),
                icon: Icon(Icons.table_chart_outlined),
              ),
              const ButtonSegment(
                value: ExportFormat.pdf,
                label: Text('PDF'),
                icon: Icon(Icons.picture_as_pdf_outlined),
              ),
              ButtonSegment(
                value: ExportFormat.both,
                label: Text(l.export_both),
                icon: const Icon(Icons.file_copy_outlined),
              ),
            ],
            selected: {_format},
            onSelectionChanged: (s) => setState(() => _format = s.first),
          ),
          const SizedBox(height: 24),

          // ── Export button ────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _exporting ? null : _export,
              icon: _exporting
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        semanticsLabel: l.semantics_loading,
                      ),
                    )
                  : const Icon(Icons.share_outlined),
              label: Text(
                _exporting ? l.export_generating : l.export_exportAndShare,
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
    );
  }
}
