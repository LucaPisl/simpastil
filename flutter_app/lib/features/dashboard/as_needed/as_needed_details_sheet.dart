import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/medication/unit_names.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/format/clock.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/widgets/stock_state_label.dart';
import '../../pills/presentation/medication_identity.dart';
import '../care_record_form.dart' show careAmountLabel;
import '../dose_detail_screen.dart';
import 'as_needed_option.dart';
import 'as_needed_ring_card.dart';
import 'as_needed_summary.dart';

/// The details of one as-needed medication: how often it was taken, what is
/// left, the recent doses, and the two ways to record one now.
Future<void> showAsNeededDetailsSheet(
  BuildContext context, {
  required AsNeededOption option,
  required VoidCallback onRecordNow,
  required VoidCallback onOpenEditor,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  clipBehavior: Clip.antiAlias,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
  ),
  builder: (sheetContext) => _DetailsSheet(
    option: option,
    onRecordNow: () {
      Navigator.of(sheetContext).pop();
      onRecordNow();
    },
    onOpenEditor: () {
      Navigator.of(sheetContext).pop();
      onOpenEditor();
    },
  ),
);

class _DetailsSheet extends ConsumerWidget {
  const _DetailsSheet({
    required this.option,
    required this.onRecordNow,
    required this.onOpenEditor,
  });
  final AsNeededOption option;
  final VoidCallback onRecordNow;
  final VoidCallback onOpenEditor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final summary =
        ref.watch(asNeededSummariesProvider).value?[option.pillId] ??
        AsNeededSummary.empty(option.pillId);
    final tint = medicationTint(id: option.pill.id, color: option.pill.color);
    final locale = Localizations.localeOf(context).toString();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final last = summary.lastTakenAt;
    final lastText = last == null
        ? '–'
        : (DateTime(last.year, last.month, last.day) == today
              ? clockAt(context, last)
              : asNeededAgo(l, last, now));
    final largeText = MediaQuery.textScalerOf(context).scale(10) > 12;

    final groups = <DateTime, List<AsNeededDose>>{};
    for (final dose in summary.doses) {
      groups.putIfAbsent(dose.day, () => []).add(dose);
    }
    String dayLabel(DateTime day) {
      if (day == today) return l.asn_statToday;
      if (day == DateTime(today.year, today.month, today.day - 1)) {
        return l.asn_yesterday;
      }
      return DateFormat.MMMEd(locale).format(day);
    }

    final stock = summary.stock;
    final buttons = [
      FilledButton.icon(
        key: const ValueKey('as-needed-record-now'),
        onPressed: onRecordNow,
        icon: const Icon(Icons.check_rounded, size: 20),
        label: Text(l.asn_recordNow),
      ),
      OutlinedButton(
        key: const ValueKey('as-needed-open-editor'),
        onPressed: onOpenEditor,
        child: Text(l.asn_openEditor),
      ),
    ];

    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      label: l.asn_detailsFor(option.pill.name),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 58,
                  height: 58,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tint.withValues(alpha: .16),
                  ),
                  child: PillMark(
                    pillId: option.pill.id,
                    name: option.pill.name,
                    color: tint,
                    fallbackShape: option.shape,
                    size: 32,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.t08_forPerson(option.person.name),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        option.pill.name,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _Chip(
                  label: l.asn_onlyWhenNeeded,
                  background: colors.primaryContainer,
                  foreground: colors.onPrimaryContainer,
                ),
                if ((option.form ?? '').trim().isNotEmpty)
                  _Chip(
                    label: medicationFormName(l, option.form!),
                    background: colors.surfaceContainerHighest,
                    foreground: colors.onSurfaceVariant,
                  ),
              ],
            ),
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
                    child: AsNeededStat(
                      value: lastText,
                      label: l.asn_statLastDose,
                    ),
                  ),
                ],
              ),
            ),
            if (stock != null) ...[
              const SizedBox(height: 12),
              AsNeededStockBox(
                stock: stock,
                daysAtPace: summary.daysAtRecentPace,
              ),
            ],
            const SizedBox(height: 20),
            Text(
              l.asn_recentDoses,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            if (groups.isEmpty)
              Text(
                l.asn_noRecentDoses,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              )
            else
              for (final entry in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 6),
                  child: Text(
                    l.asn_groupHeader(
                      dayLabel(entry.key),
                      l.asn_doseCount(entry.value.length),
                    ),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
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
                        for (var i = 0; i < entry.value.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: 1,
                              color: colors.outlineVariant.withValues(
                                alpha: .6,
                              ),
                            ),
                          AsNeededDoseRow(dose: entry.value[i]),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            const SizedBox(height: 20),
            Text(
              l.asn_usualDose(careAmountLabel(l, option.usualAmount)),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            if (largeText)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [buttons[0], const SizedBox(height: 8), buttons[1]],
              )
            else
              Row(
                children: [
                  Expanded(child: buttons[0]),
                  const SizedBox(width: 10),
                  Expanded(child: buttons[1]),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.background,
    required this.foreground,
  });
  final String label;
  final Color background;
  final Color foreground;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: foreground,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class AsNeededStat extends StatelessWidget {
  const AsNeededStat({super.key, required this.value, required this.label});
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class AsNeededStockBox extends StatelessWidget {
  const AsNeededStockBox({super.key, required this.stock, this.daysAtPace});
  final AsNeededStock stock;

  /// Whole days the stock lasts at the recent pace; the line is left out
  /// when null.
  final int? daysAtPace;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // The unit is typed free text with no plural form ("15 tablet"), so
    // stock reads as a bare count, as it does for scheduled medication.
    final amount = stock.left;
    final fill = stock.low ? colors.error : asNeededTakenColor(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.inventory_2_outlined,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.asn_stockLeft(amount),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (stock.low)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      stock.value <= 0
                          ? stockStateIcon(StockState.out)
                          : stockStateIcon(StockState.low),
                      size: 16,
                      color: colors.error,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      stock.value <= 0 ? l.stock_out : l.asn_stockLow,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colors.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          if (stock.fraction != null) ...[
            const SizedBox(height: 10),
            _StockBar(fraction: stock.fraction!, fill: fill),
          ],
          if (daysAtPace != null) ...[
            const SizedBox(height: 8),
            Text(
              l.asn_stockPace(daysAtPace!),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StockBar extends StatelessWidget {
  const _StockBar({required this.fraction, required this.fill});
  final double fraction;
  final Color fill;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final quiet = AppMotion.quiet(context);
    return ExcludeSemantics(
      child: SizedBox(
        height: 8,
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              TweenAnimationBuilder<double>(
                tween: Tween(end: fraction),
                duration: quiet ? Duration.zero : AppMotion.emphasis,
                curve: AppMotion.curve,
                builder: (context, value, _) => Container(
                  width: box.maxWidth * value,
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              // The low-stock level sits a quarter of the way along.
              Positioned(
                left: box.maxWidth * .25 - 1,
                top: -2,
                bottom: -2,
                width: 2,
                child: ColoredBox(color: colors.onSurface),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AsNeededDoseRow extends StatelessWidget {
  const AsNeededDoseRow({super.key, required this.dose});
  final AsNeededDose dose;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final at = dose.takenAt;
    final time = at == null ? l.t08_unknownTime : clockAt(context, at);
    final note = dose.note?.trim();
    return InkWell(
      key: ValueKey('as-needed-dose-${dose.occurrenceId}'),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DoseDetailScreen(occurrenceId: dose.occurrenceId),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Text(
              time,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                [
                  careAmountLabel(l, dose.amount),
                  if (note != null && note.isNotEmpty) note,
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            Icon(Icons.edit_outlined, size: 18, color: colors.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
