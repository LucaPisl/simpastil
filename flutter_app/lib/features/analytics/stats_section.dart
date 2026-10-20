import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import 'analytics_providers.dart';
import 'trend_widgets.dart';

// ── StatsSection ──────────────────────────────────────────────────────────────

/// Adherence statistics below the month calendar, in one column: the 7 and 30
/// day figures, the day streak and the as-needed doses of 30 days, when doses
/// were taken through the day, as-needed use per medication, then the 12-week
/// trend and a worst-first per-medication breakdown (30 days).
///
/// The tablet's Trends view sets the same pieces out on a grid instead.
class StatsSection extends ConsumerWidget {
  const StatsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(adherenceStatsProvider);
    // The streak and the two charts come from their own read; until it
    // arrives the section shows what it has, and if it fails it says so.
    final trendAsync = ref.watch(trendStatsProvider);
    final trend = trendAsync.value;
    final colors = ref.watch(pillColorsProvider);
    final l = AppLocalizations.of(context);
    final heading = Theme.of(
      context,
    ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700);

    return statsAsync.when(
      // The provider self-invalidates at midnight and rebuilds on pill-stream
      // emissions; without this the whole section collapses to a spinner on
      // every reload (history_screen.dart uses the same guard).
      skipLoadingOnReload: true,
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text(l.analytics_couldNotLoadStats),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => ref.invalidate(adherenceStatsProvider),
              child: Text(l.shared_retry),
            ),
          ],
        ),
      ),
      data: (stats) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TileRow(
            tiles: [
              adherenceTile(
                context,
                l.analytics_last7Days,
                stats.last7Days,
                titled: true,
              ),
              adherenceTile(
                context,
                l.analytics_last30Days,
                stats.last30Days,
                titled: true,
              ),
            ],
          ),
          if (trendReadFailed(trendAsync)) ...[
            const SizedBox(height: 12),
            TrendsLoadError(onRetry: () => ref.invalidate(trendStatsProvider)),
          ],
          if (trend != null) ...[
            const SizedBox(height: 12),
            TileRow(
              tiles: [streakTile(context, trend), asNeededTile(context, trend)],
            ),
            const SizedBox(height: 16),
            TrendCard(
              title: l.th_timeOfDay,
              note: l.th_timeOfDayNote,
              child: TimeOfDayChart(hourly: trend.hourlyTaken),
            ),
            const SizedBox(height: 12),
            TrendCard(
              title: l.th_asNeededByMedication,
              note: l.analytics_last30Days,
              child: AsNeededByMedication(
                counts: trend.prnByPill,
                colors: colors,
              ),
            ),
          ],
          const SizedBox(height: 24),
          Semantics(
            header: true,
            child: Text(l.analytics_weeklyTrend, style: heading),
          ),
          const SizedBox(height: 8),
          WeeklyTrendBars(weeks: stats.weeklyTrend),
          const SizedBox(height: 24),
          Semantics(
            header: true,
            child: Text(l.analytics_byPill30Days, style: heading),
          ),
          const SizedBox(height: 8),
          ByMedicationRows(pills: stats.perPill, colors: colors),
        ],
      ),
    );
  }
}
