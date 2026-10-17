import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/scene/dose_bead.dart';
import 'analytics_providers.dart';
import 'calendar_month_view.dart';
import 'trend_stats.dart';
import 'trend_widgets.dart';

/// What the beads under the calendar's days mean: taken, skipped, not
/// recorded, missed and as needed, each drawn as it is on the days.
class CalendarLegend extends StatelessWidget {
  const CalendarLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Wrap(
      spacing: 16,
      runSpacing: 6,
      children: [
        _LegendItem(DoseBead.taken, l.t08_taken),
        _LegendItem(DoseBead.skipped, l.t08_skipped),
        _LegendItem(DoseBead.unrecorded, l.t08_unrecorded),
        _LegendItem(DoseBead.missed, l.dashboard_statusMissed),
        _LegendItem(DoseBead.asNeeded, l.t08_asNeeded),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem(this.bead, this.label);

  final DoseBead bead;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: CustomPaint(
            size: const Size(14, 14),
            painter: MonthDayPainter(
              beads: [(bead: bead, color: bead.colorIn(theme))],
              cut: cardColor(context),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// The month on show in the calendar, in three figures: scheduled doses
/// recorded of those due, as-needed doses taken, and the last 30 days.
///
/// Reads the same month data as the calendar's days, so the two always agree.
/// The title says "so far" only for the month that is still going.
class MonthSoFar extends ConsumerWidget {
  const MonthSoFar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final month = ref.watch(calendarMonthProvider);
    final now = DateTime.now();
    final current = month.year == now.year && month.month == now.month;
    final name = DateFormat.MMMM(
      Localizations.localeOf(context).toString(),
    ).format(month);
    final days = ref.watch(monthAdherenceProvider(month)).valueOrNull;
    final prn = ref.watch(monthPrnCountsProvider(month)).valueOrNull;
    final last30 = ref.watch(adherenceStatsProvider).valueOrNull?.last30Days;
    final summary = summarizeMonth(days ?? const {}, prn ?? const {});

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            current ? l.th_monthSoFar(name) : name,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, box) {
            // Three tiles side by side need room for their labels at the
            // reader's text size; in a narrow card or at a large size they
            // stack, each figure beside its label, rather than wrap.
            final scale = MediaQuery.textScalerOf(context).scale(1);
            final stacked = (box.maxWidth - 16) / 3 < 96 * scale + 28;
            final tiles = [
              StatTile(
                dense: true,
                inline: stacked,
                value: l.th_tileOfTotal(summary.recorded, summary.expected),
                label: l.th_tilePlannedRecorded,
              ),
              StatTile(
                dense: true,
                inline: stacked,
                value: '${summary.prnTaken}',
                label: l.th_tileAsNeededDoses,
              ),
              adherenceTile(
                context,
                l.analytics_last30Days,
                last30,
                dense: true,
                inline: stacked,
              ),
            ];
            if (!stacked) return TileRow(gap: 8, tiles: tiles);
            return Column(
              children: [
                for (var i = 0; i < tiles.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  tiles[i],
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}
