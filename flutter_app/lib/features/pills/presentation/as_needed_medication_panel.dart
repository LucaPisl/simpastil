import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/medication/care_provider.dart';
import '../../../core/medication/medication_detail_repository.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/format/clock.dart';
import '../../dashboard/as_needed/as_needed_controller.dart';
import '../../dashboard/as_needed/as_needed_details_sheet.dart';
import '../../dashboard/as_needed/as_needed_dose_editor.dart';
import '../../dashboard/as_needed/as_needed_option.dart';
import '../../dashboard/as_needed/as_needed_ring_card.dart' show asNeededAgo;
import '../../dashboard/as_needed/as_needed_summary.dart';
import 'medication_detail_sections.dart'
    show MedicationHistoryLink, MedicationSectionHead;

/// What a person sees for an as-needed medicine where a routine would be: how
/// often it was taken, the recent doses and a Record button. An as-needed
/// medicine never shows a routine or schedule.
class AsNeededMedicationPanel extends ConsumerStatefulWidget {
  const AsNeededMedicationPanel({super.key, required this.detail});
  final MedicationCareDetail detail;

  @override
  ConsumerState<AsNeededMedicationPanel> createState() =>
      _AsNeededMedicationPanelState();
}

class _AsNeededMedicationPanelState
    extends ConsumerState<AsNeededMedicationPanel> {
  late final AsNeededController _controller = AsNeededController(
    ref: ref,
    localDate: () => routineDateKey(DateTime.now()),
    canFeel: () => mounted,
    onUndoStockUnchanged: () {},
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final pillId = widget.detail.pill.id;
    final options = ref
        .watch(
          asNeededOptionsProvider(
            CareDayRequest(
              localDate: routineDateKey(DateTime.now()),
              personId: widget.detail.person.id,
            ),
          ),
        )
        .asData
        ?.value;
    AsNeededOption? option;
    for (final o in options ?? const <AsNeededOption>[]) {
      if (o.pillId == pillId) option = o;
    }
    final summary =
        ref.watch(asNeededSummariesProvider).value?[pillId] ??
        AsNeededSummary.empty(pillId);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final last = summary.lastTakenAt;
    final lastText = last == null
        ? '–'
        : (DateTime(last.year, last.month, last.day) == today
              ? clockAt(context, last)
              : asNeededAgo(l, last, now));
    final recent = summary.doses.take(5).toList();
    final target = option;

    return Column(
      key: const ValueKey('as-needed-panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.t08_asNeeded, style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(l.asn_detailIntro, style: theme.textTheme.bodyLarge),
        const SizedBox(height: 16),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: AsNeededStat(
                  value: '${summary.todayCount}',
                  label: l.asn_statToday,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AsNeededStat(
                  value: '${summary.weekCount}',
                  label: l.asn_stat7Days,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AsNeededStat(value: lastText, label: l.asn_statLastDose),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        MedicationSectionHead(
          title: l.asn_recentDoses,
          trailing: const MedicationHistoryLink(),
        ),
        const SizedBox(height: 4),
        if (recent.isEmpty)
          Text(
            l.asn_noRecentDoses,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          )
        else
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: colors.outlineVariant.withValues(alpha: .6),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: Column(
                children: [
                  for (var i = 0; i < recent.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        color: colors.outlineVariant.withValues(alpha: .6),
                      ),
                    AsNeededDoseRow(dose: recent[i]),
                  ],
                ],
              ),
            ),
          ),
        if (target != null && !target.needsReview) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('as-needed-record-dose'),
            onPressed: () => openAsNeededDoseEditor(
              context,
              option: target,
              controller: _controller,
            ),
            icon: const Icon(Icons.check_rounded, size: 20),
            label: Text(l.asn_recordDose),
          ),
        ],
      ],
    );
  }
}
