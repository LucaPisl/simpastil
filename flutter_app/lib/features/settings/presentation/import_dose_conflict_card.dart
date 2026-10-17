import 'package:flutter/material.dart';

import '../../../core/backup/import_plan.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/format/clock.dart';

String _state(ImportDoseState state, AppLocalizations l) => switch (state) {
  ImportDoseState.pending => l.t15_notRecorded,
  ImportDoseState.taken => l.t15_taken,
  ImportDoseState.skipped => l.t15_skipped,
  ImportDoseState.missed => l.dashboard_statusMissed,
};
String _planned(BuildContext context, ImportDoseContext dose) {
  final time = dose.localTime;
  return '${dose.medicationName} · ${dose.localDate} · '
      '${time == null ? AppLocalizations.of(context).t15_timeUnknown : clockText(context, time)}';
}

/// Factual review only: this component accepts no IDs or care-mutation API.
class ImportDoseConflictCard extends StatelessWidget {
  const ImportDoseConflictCard({
    super.key,
    required this.conflict,
    required this.onReview,
  });
  final ImportDoseConflict conflict;
  final VoidCallback onReview;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ColoredBox(
            color: theme.colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.description_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l.t15_differentDoseRecords,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conflict.local.personName,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(_planned(context, conflict.local)),
                const Divider(height: 24),
                _FactRow(
                  label: l.t15_onThisDevice,
                  value: _state(conflict.local.state, l),
                ),
                const Divider(height: 24),
                _FactRow(
                  label: l.t15_inBackup,
                  value: _state(conflict.imported.state, l),
                ),
                const Divider(height: 24),
                if (_planned(context, conflict.local) !=
                    _planned(context, conflict.imported))
                  Text(_planned(context, conflict.imported)),
                Text(l.t15_differenceBody),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: onReview,
                  child: Text(l.t15_reviewDifference),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 20,
    runSpacing: 8,
    children: [
      Text(label),
      Text(
        value,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
    ],
  );
}

class ImportDoseDifferenceDialog extends StatelessWidget {
  const ImportDoseDifferenceDialog({super.key, required this.conflict});
  final ImportDoseConflict conflict;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.t15_reviewDifference),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.t15_onThisDevice,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(conflict.local.personName),
          Text(_planned(context, conflict.local)),
          Text(_state(conflict.local.state, l)),
          const SizedBox(height: 24),
          Text(l.t15_inBackup, style: Theme.of(context).textTheme.titleMedium),
          Text(conflict.imported.personName),
          Text(_planned(context, conflict.imported)),
          Text(_state(conflict.imported.state, l)),
          const SizedBox(height: 24),
          Text(l.t15_differenceBody),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.shared_close),
        ),
      ],
    );
  }
}
