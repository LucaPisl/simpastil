import 'package:flutter/material.dart';

import '../../../core/medication/prn_limits.dart';
import '../../../l10n/app_localizations.dart';
import '../../pills/presentation/medication_extras_fields.dart';
import '../../../shared/format/clock.dart';
import 'as_needed_option.dart';

/// Asks before an as-needed dose that would go past a limit the person set.
/// Resolves true only for "Record anyway"; a dismissed dialog and "Don't
/// record" both mean no dose is written. The safe answer is the filled one.
Future<bool> showAsNeededLimitDialog(
  BuildContext context, {
  required AsNeededOption option,
  required PrnLimitState state,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (_) =>
        AsNeededLimitDialog(medicationName: option.pill.name, state: state),
  );
  return answer == true;
}

class AsNeededLimitDialog extends StatelessWidget {
  const AsNeededLimitDialog({
    super.key,
    required this.medicationName,
    required this.state,
  });
  final String medicationName;
  final PrnLimitState state;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final name = medicationName;
    final lines = <String>[
      if (state.breach == PrnLimitBreach.daily ||
          state.breach == PrnLimitBreach.both)
        l.mx_overDaily(name, state.countIn24h, state.maxPer24h!),
      if (state.breach == PrnLimitBreach.gap ||
          state.breach == PrnLimitBreach.both)
        l.mx_overGap(
          name,
          gapHoursText(state.minGapMinutes!, l.localeName),
          MedicationExtrasEditor.gapHoursCount(state.minGapMinutes!),
        ),
      if (state.nextAllowedAt != null)
        l.mx_overNext(clockAt(context, state.nextAllowedAt!)),
    ];
    return AlertDialog(
      key: const ValueKey('as-needed-limit-dialog'),
      title: Text(l.mx_overTitle),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < lines.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            Text(lines[i], style: theme.textTheme.bodyMedium),
          ],
        ],
      ),
      actionsOverflowDirection: VerticalDirection.down,
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(
          key: const ValueKey('as-needed-limit-record-anyway'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l.mx_recordAnyway),
        ),
        FilledButton(
          key: const ValueKey('as-needed-limit-dont-record'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l.mx_dontRecord),
        ),
      ],
    );
  }
}

/// The gap in hours as it reads in a sentence: `4`, `1.5` (`1,5` in Romanian).
String gapHoursText(int minutes, String locale) =>
    MedicationExtrasEditor.formatGapHours(minutes, locale: locale);
