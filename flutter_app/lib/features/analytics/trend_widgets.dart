import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/pill_colors.dart';
import 'adherence.dart';
import 'trend_stats.dart';

// The pieces the statistics are built from. The phone's stats section stacks
// them in one column; the tablet's Trends view sets them out on a grid.

/// The fill of a [Card] in the current theme: what a bead's ring has to match
/// to disappear into a card.
Color cardColor(BuildContext context) =>
    Theme.of(context).cardTheme.color ??
    Theme.of(context).colorScheme.surfaceContainerLow;

/// The whole-number percent of [ratio], or null when there is no ratio.
String? percentText(double? ratio) =>
    ratio == null ? null : '${(ratio * 100).round()}%';

/// Whether the trend read failed with nothing earlier to show in its place.
///
/// The streak, the as-needed figures and the two charts all come from that one
/// read; when it fails they are not drawn, so the page says so instead of
/// leaving a gap that looks like "no data".
bool trendReadFailed(AsyncValue<TrendStats> trend) =>
    trend.hasError && !trend.hasValue;

/// Where the streak and charts would be, when their read failed: one line and
/// a way to try again, the same as the rest of History offers.
class TrendsLoadError extends StatelessWidget {
  const TrendsLoadError({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      child: Row(
        key: const ValueKey('trends-error'),
        children: [
          Icon(Icons.error_outline, size: 20, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l.tr_trendsCouldNotLoad,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          TextButton(
            key: const ValueKey('trends-retry'),
            onPressed: onRetry,
            child: Text(l.shared_retry),
          ),
        ],
      ),
    );
  }
}

// ── The four figures ──────────────────────────────────────────────────────────

/// A tile for an adherence window: "93%" under [label], or an em dash when no
/// scheduled dose fell due in it.
///
/// With [titled] the tile is headed "Adherence" and [label] (the period) sits
/// under it as its note, as the streak and as-needed tiles carry theirs, so
/// tiles side by side have the same number of lines.
StatTile adherenceTile(
  BuildContext context,
  String label,
  double? ratio, {
  bool dense = false,
  bool inline = false,
  bool titled = false,
}) {
  final l = AppLocalizations.of(context);
  final percent = percentText(ratio);
  return StatTile(
    dense: dense,
    inline: inline,
    value: percent ?? '—',
    label: titled ? l.tf_adherence : label,
    note: titled ? label : null,
    semanticsLabel: percent == null
        ? '$label: ${l.analytics_noData}'
        : '$label: ${l.history_adherence(percent)}',
  );
}

/// The day streak with the best run of the window under it; an em dash when
/// no scheduled dose has fallen due, since there is nothing to count.
StatTile streakTile(BuildContext context, TrendStats trend) {
  final l = AppLocalizations.of(context);
  return StatTile(
    value: trend.hasScheduledDoses ? '${trend.streak.current}' : '—',
    label: l.th_dayStreak,
    note: trend.hasScheduledDoses ? l.th_streakBest(trend.streak.best) : null,
  );
}

/// The as-needed doses taken in the last 30 days.
StatTile asNeededTile(BuildContext context, TrendStats trend) {
  final l = AppLocalizations.of(context);
  return StatTile(
    value: '${trend.prn30Days}',
    label: l.th_tileAsNeededDoses,
    note: l.analytics_last30Days,
  );
}

// ── StatTile ──────────────────────────────────────────────────────────────────

/// One figure with its label and, optionally, a line of context under it.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.value,
    required this.label,
    this.note,
    this.semanticsLabel,
    this.dense = false,
    this.inline = false,
  });

  /// The figure, such as "93%" or "12".
  final String value;
  final String label;

  /// A quieter line under the label, such as "Best in 12 weeks: 19".
  final String? note;

  /// What a screen reader says; defaults to the label, figure and note.
  final String? semanticsLabel;

  /// A smaller tile, for sitting inside another card.
  final bool dense;

  /// The figure beside its label instead of above it, for a tile that has the
  /// whole width of a narrow card to itself.
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final figureStyle =
        (dense ? theme.textTheme.titleLarge : theme.textTheme.headlineSmall)
            ?.copyWith(fontWeight: FontWeight.w700);
    return Semantics(
      container: true,
      label: semanticsLabel ?? ['$label: $value', ?note].join(', '),
      child: ExcludeSemantics(
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: EdgeInsets.all(dense ? 12 : 16),
            child: inline
                ? Row(
                    children: [
                      Text(value, style: figureStyle),
                      const SizedBox(width: 12),
                      Expanded(child: Text(label, style: muted)),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(value, style: figureStyle),
                      const SizedBox(height: 2),
                      Text(label, style: muted),
                      if (note != null) Text(note!, style: muted),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// [tiles] side by side at one height, [gap] apart.
class TileRow extends StatelessWidget {
  const TileRow({super.key, required this.tiles, this.gap = 12});

  final List<Widget> tiles;
  final double gap;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) SizedBox(width: gap),
          Expanded(child: tiles[i]),
        ],
      ],
    ),
  );
}

// ── TrendCard ─────────────────────────────────────────────────────────────────

/// A titled card around one chart or list, with an optional note beside the
/// title (under it when the two do not fit on a line).
class TrendCard extends StatelessWidget {
  const TrendCard({
    super.key,
    required this.title,
    this.note,
    this.fill = false,
    required this.child,
  });

  final String title;
  final String? note;

  /// Gives [child] the height left under the title, for a card set to the
  /// height of its neighbor, instead of leaving that height empty.
  final bool fill;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: fill
              ? CrossAxisAlignment.stretch
              : CrossAxisAlignment.start,
          mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 2,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (note != null)
                  Text(
                    note!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (fill) Expanded(child: child) else child,
          ],
        ),
      ),
    );
  }
}

/// The small muted sentence a chart gives when it has nothing to draw.
class TrendEmptyNote extends StatelessWidget {
  const TrendEmptyNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

// ── WeeklyTrendBars ───────────────────────────────────────────────────────────

/// The share of the bar area [week]'s bar fills: 0 when nothing was due.
double _barFactor(WeekAdherence week) => (week.ratio ?? 0).clamp(0.0, 1.0);

/// Twelve weeks of adherence as bars, the oldest first, with the first week's
/// date under the left end and "This week" under the right.
class WeeklyTrendBars extends StatelessWidget {
  const WeeklyTrendBars({
    super.key,
    required this.weeks,
    this.height = 100,
    this.fill = false,
  });

  final List<WeekAdherence> weeks;

  /// The height of the bar area; its least height when [fill] is set.
  final double height;

  /// Grows the bars to the height the parent gives, for a chart in a card set
  /// to the height of its neighbor. The parent must give it a bounded height.
  final bool fill;

  @override
  Widget build(BuildContext context) {
    if (weeks.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final date = DateFormat('d MMM', locale);

    final bars = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < weeks.length; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: Semantics(
              label: l.th_weekOfSemantics(
                date.format(weeks[i].weekStart),
                percentText(weeks[i].ratio) ?? l.analytics_noData,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // A week with no taken dose has nothing to draw. It gets no
                  // bar rather than a zero-height one: a bar of factor 0 makes
                  // the chart's intrinsic height 0 / 0 (NaN) where a card sets
                  // its height to its neighbor's, and blanks the whole view.
                  if (_barFactor(weeks[i]) > 0)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: _barFactor(weeks[i]),
                        child: ExcludeSemantics(
                          child: Container(
                            key: ValueKey('trend-bar-$i'),
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: cs.primary,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(3),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  // A week with nothing due keeps its place on the axis as a
                  // quiet stub, so the twelve weeks read as twelve even when
                  // only the last few have a bar.
                  if (weeks[i].ratio == null)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: ExcludeSemantics(
                        child: Container(
                          key: ValueKey('trend-slot-$i'),
                          height: 3,
                          decoration: BoxDecoration(
                            color: cs.outlineVariant,
                            borderRadius: BorderRadius.circular(1.5),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );

    return Column(
      children: [
        if (fill)
          Expanded(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: height),
              child: bars,
            ),
          )
        else
          SizedBox(height: height, child: bars),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              date.format(weeks.first.weekStart),
              style: Theme.of(context).textTheme.labelSmall,
            ),
            Text(
              l.analytics_thisWeek,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ],
    );
  }
}

// ── ByMedicationRows ──────────────────────────────────────────────────────────

/// The per-medication adherence rows, worst first as given, with the dot in
/// the medication's color.
class ByMedicationRows extends StatelessWidget {
  const ByMedicationRows({
    super.key,
    required this.pills,
    this.colors = const {},
  });

  final List<PillAdherence> pills;

  /// Medication colors by id, for pills whose own record carries none.
  final Map<String, String?> colors;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (pills.isEmpty) return TrendEmptyNote(l.analytics_noDosesLast30);
    return Column(
      children: [
        for (final pill in pills)
          _PillRow(
            pill: pill,
            color: tryColorFromHex(pill.color ?? colors[pill.pillId]),
          ),
      ],
    );
  }
}

class _PillRow extends StatelessWidget {
  const _PillRow({required this.pill, required this.color});

  final PillAdherence pill;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final percent = percentText(pill.ratio) ?? l.analytics_noData;
    return Semantics(
      label: l.th_pillAdherenceSemantics(
        pill.pillName,
        pill.taken,
        pill.expected,
        percent,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            ExcludeSemantics(
              child: CircleAvatar(
                radius: 6,
                backgroundColor: color ?? cs.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            pill.pillName,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '${pill.taken}/${pill.expected}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: pill.ratio ?? 0,
                        minHeight: 5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── AsNeededByMedication ──────────────────────────────────────────────────────

/// The as-needed doses taken in the last 30 days, one bar per medication,
/// longest first as given, each in the medication's color.
class AsNeededByMedication extends StatelessWidget {
  const AsNeededByMedication({
    super.key,
    required this.counts,
    this.colors = const {},
  });

  final List<PrnPillCount> counts;
  final Map<String, String?> colors;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (counts.isEmpty) return TrendEmptyNote(l.th_asNeededNone);
    final most = counts.map((c) => c.count).reduce(math.max);
    return Column(
      children: [
        for (final count in counts)
          _AsNeededRow(
            key: ValueKey('as-needed-${count.pillId}'),
            name: count.pillName ?? l.th_unknownMedication,
            count: count.count,
            fraction: count.count / most,
            color: tryColorFromHex(colors[count.pillId]),
          ),
      ],
    );
  }
}

class _AsNeededRow extends StatelessWidget {
  const _AsNeededRow({
    super.key,
    required this.name,
    required this.count,
    required this.fraction,
    required this.color,
  });

  final String name;
  final int count;
  final double fraction;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l = AppLocalizations.of(context);
    final nameText = Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium,
    );
    final countText = Text(
      '$count',
      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
    );
    final bar = ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 6,
        child: Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(color: cs.surfaceContainerHighest),
            ),
            // A bare ColoredBox collapses to nothing in a loose Stack unless
            // the box gives it the track's height.
            FractionallySizedBox(
              widthFactor: fraction.clamp(0.0, 1.0),
              heightFactor: 1,
              child: ColoredBox(color: color ?? cs.primary),
            ),
          ],
        ),
      ),
    );
    return Semantics(
      label: l.th_asNeededCountSemantics(name, count),
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          // The name has the line to itself with the count at its end, and
          // the bar goes under it, as in the per-medication rows. Nothing
          // here depends on the width, so it sits inside an IntrinsicHeight.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: nameText),
                  const SizedBox(width: 10),
                  countText,
                ],
              ),
              const SizedBox(height: 4),
              bar,
            ],
          ),
        ),
      ),
    );
  }
}

// ── TimeOfDayChart ────────────────────────────────────────────────────────────

/// When doses were taken: one bar for each hour of the day, the busiest hour
/// in full color, with 00, 06, 12, 18 and 24 under the axis.
class TimeOfDayChart extends StatelessWidget {
  const TimeOfDayChart({super.key, required this.hourly, this.height = 72});

  /// Doses per local hour, 24 entries.
  final List<int> hourly;

  /// The height of the bar area.
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l = AppLocalizations.of(context);
    final peak = hourly.fold<int>(0, math.max);
    if (peak == 0) return TrendEmptyNote(l.th_timeOfDayNone);
    final busiest = hourly.indexOf(peak);
    final axis = theme.textTheme.labelSmall?.copyWith(
      color: cs.onSurfaceVariant,
    );
    return Semantics(
      label: l.th_timeOfDaySemantics(
        '${busiest.toString().padLeft(2, '0')}:00',
        peak,
      ),
      child: ExcludeSemantics(
        child: Column(
          children: [
            SizedBox(
              height: height,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var hour = 0; hour < 24; hour++) ...[
                    if (hour > 0) const SizedBox(width: 3),
                    Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          key: ValueKey('time-of-day-$hour'),
                          height: math
                              .max(3, height * hourly[hour] / peak)
                              .toDouble(),
                          decoration: BoxDecoration(
                            color: hourly[hour] == 0
                                ? cs.primary.withValues(alpha: .18)
                                : hour == busiest
                                ? cs.primary
                                : cs.primary.withValues(alpha: .55),
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                for (final label in const ['00', '06', '12'])
                  Expanded(flex: 6, child: Text(label, style: axis)),
                Expanded(
                  flex: 6,
                  child: Stack(
                    children: [
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text('18', style: axis),
                      ),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: Text('24', style: axis),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
