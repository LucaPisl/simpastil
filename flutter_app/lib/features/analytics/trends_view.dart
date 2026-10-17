import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import 'analytics_providers.dart';
import 'trend_widgets.dart';

/// The Trends view of a wide window: the four figures in a row, the 12-week
/// trend beside the per-medication breakdown and as-needed use, and when doses
/// were taken across the bottom. The same numbers the phone's stats section
/// stacks in one column.
class TrendsView extends ConsumerWidget {
  const TrendsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final statsAsync = ref.watch(adherenceStatsProvider);
    final trendAsync = ref.watch(trendStatsProvider);
    final trend = trendAsync.valueOrNull;
    final colors = ref.watch(pillColorsProvider);

    return statsAsync.when(
      skipLoadingOnReload: true,
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 32),
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
              if (trend != null) ...[
                streakTile(context, trend),
                asNeededTile(context, trend),
              ],
            ],
          ),
          if (trendReadFailed(trendAsync)) ...[
            const SizedBox(height: 12),
            TrendsLoadError(onRetry: () => ref.invalidate(trendStatsProvider)),
          ],
          const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 3,
                  child: TrendCard(
                    title: l.analytics_weeklyTrend,
                    fill: true,
                    child: WeeklyTrendBars(
                      weeks: stats.weeklyTrend,
                      height: 180,
                      fill: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: TrendCard(
                    title: l.th_byMedication,
                    note: l.th_scheduledLast30,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ByMedicationRows(pills: stats.perPill, colors: colors),
                        if (trend != null) ...[
                          const SizedBox(height: 16),
                          Semantics(
                            header: true,
                            child: Text(
                              l.th_asNeededByMedication,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(height: 6),
                          AsNeededByMedication(
                            counts: trend.prnByPill,
                            colors: colors,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (trend != null) ...[
            const SizedBox(height: 12),
            TrendCard(
              title: l.th_timeOfDay,
              note: l.th_timeOfDayNote,
              child: TimeOfDayChart(hourly: trend.hourlyTaken, height: 88),
            ),
          ],
        ],
      ),
    );
  }
}
