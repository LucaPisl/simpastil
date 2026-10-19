import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/inventory/supply_forecast.dart';
import '../../../core/medication/medication_activity.dart';
import '../../../core/medication/medication_detail_repository.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/format/clock.dart';
import '../../../shared/router/app_router.dart' show AppPaths;
import '../../../shared/theme/app_theme.dart';
import '../medication_activity_provider.dart';
import 'add_edit_pill_sheet.dart';
import 'medication_edit.dart';
import 'stock_capsule.dart';
import 'supply_runway.dart';

/// Opens the stock editor of [detail]: the medication's own edit sheet with
/// the stock count in view, or the connected medication sheet where the
/// workspace keeps its stock. Returns what the edit sheet saved, if it did.
Future<MedicationDetailSave?> showMedicationStockEditor(
  BuildContext context,
  MedicationCareDetail detail,
  MedicationDetailRepository repository,
) async {
  if (repository.context.isLocal) {
    return showMedicationReview(context, detail, repository, focusStock: true);
  }
  await showAddEditPillSheet(context: context, pill: detail.pill);
  return null;
}

/// A section title with an action or figure at the end of its line when
/// both fit, and under the title when a narrow window, a large text size or
/// a longer translation leaves no room for both.
class MedicationSectionHead extends StatelessWidget {
  const MedicationSectionHead({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// A titled block of the medication page: a soft card on a phone page, or
/// flat inside a pane that is already a card.
class MedicationSection extends StatelessWidget {
  const MedicationSection({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
    this.flat = false,
  });

  final String title;
  final Widget? trailing;
  final List<Widget> children;

  /// No surface of its own.
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final head = MedicationSectionHead(title: title, trailing: trailing);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [head, const SizedBox(height: 12), ...children],
    );
    if (flat) return body;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: .5)),
      ),
      child: body,
    );
  }
}

/// How many are left, when it runs out and where the refill reminder sits,
/// with the days ahead as a blister strip, and the button that adds stock.
class MedicationStockSection extends StatelessWidget {
  const MedicationStockSection({
    super.key,
    required this.detail,
    required this.forecast,
    required this.tint,
    required this.onAddStock,
    this.flat = false,
    this.showSummary = true,
  });

  final MedicationCareDetail detail;
  final SupplyForecast? forecast;
  final Color tint;
  final VoidCallback onAddStock;
  final bool flat;

  /// Whether the count and when it runs out lead the section; a pane that
  /// already shows them in its header leaves them out.
  final bool showSummary;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final stock = detail.pill.currentStock;
    final threshold = detail.pill.lowStockThreshold;
    final forecast = this.forecast;
    return MedicationSection(
      key: const ValueKey('medication-stock-section'),
      flat: flat,
      title: l.tm_stockTitle,
      trailing: FilledButton.tonalIcon(
        key: const ValueKey('add-stock'),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        onPressed: onAddStock,
        icon: const Icon(Icons.add_rounded, size: 20),
        label: Text(l.tm_addStock),
      ),
      children: [
        if (stock == null)
          Text(
            l.tm_stockNone,
            style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          )
        else ...[
          // A pane that shows the count and the run-out date in its header
          // still draws the capsule when it has no runway to show, so the
          // section is never just a title.
          if (showSummary || forecast == null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: StockCapsule(
                stock: stock,
                threshold: threshold,
                color: tint,
              ),
            ),
          if (showSummary && forecast != null) ...[
            const SizedBox(height: 10),
            Text(
              stockRunsOutLine(context, forecast),
              key: const ValueKey('stock-runs-out'),
              style: text.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: stockRunsShort(forecast) ? semantic.statusMissed : null,
              ),
            ),
          ],
          if (threshold != null) ...[
            SizedBox(height: showSummary || forecast == null ? 8 : 4),
            Text(
              l.tm_refillAt(threshold),
              key: const ValueKey('stock-threshold'),
              style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          if (forecast != null) ...[
            const SizedBox(height: 14),
            SupplyRunway(
              key: const ValueKey('supply-runway'),
              forecast: forecast,
              tint: tint,
              showTitle: false,
              showHeadline: false,
            ),
          ],
        ],
      ],
    );
  }
}

/// The last 14 days of a medication: a day mark for each (taken, skipped,
/// not recorded) when it is scheduled, or the doses taken each day when it
/// is as needed.
class MedicationLast14Section extends ConsumerWidget {
  const MedicationLast14Section({
    super.key,
    required this.detail,
    required this.tint,
    this.flat = false,
  });

  final MedicationCareDetail detail;
  final Color tint;
  final bool flat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final asNeeded = detail.pill.isPrn;
    final activity =
        ref.watch(medicationActivityProvider(detail.pill.id)).valueOrNull ??
        // Until the ledger answers, the days are there and empty.
        medicationActivityFrom(
          items: const [],
          pillId: detail.pill.id,
          now: DateTime.now(),
        );
    final String? summary;
    final String? spoken;
    if (asNeeded) {
      summary = l.tm_asNeededTotal(activity.asNeededTotal);
      spoken = null;
    } else if (activity.dueDays > 0) {
      summary = l.tm_daysTaken(activity.takenDays, activity.dueDays);
      spoken = l.tm_daysTakenSpoken(activity.takenDays, activity.dueDays);
    } else {
      summary = null;
      spoken = null;
    }
    final note = asNeeded
        ? l.tm_last14AsNeededNote
        : (!activity.hasAnyRecord ? l.tm_last14Empty : '');
    return MedicationSection(
      key: const ValueKey('medication-last-14'),
      flat: flat,
      title: l.tm_last14Title,
      trailing: summary == null
          ? null
          : Semantics(
              label: spoken,
              child: ExcludeSemantics(
                excluding: spoken != null,
                child: Text(
                  summary,
                  key: const ValueKey('last-14-summary'),
                  style: text.labelLarge?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ),
      children: [
        _DayGrid(days: activity.days, asNeeded: asNeeded, tint: tint),
        // A note only when there is one: an empty line would leave a gap
        // under the grid.
        if (note.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            note,
            style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _DayGrid extends StatelessWidget {
  const _DayGrid({
    required this.days,
    required this.asNeeded,
    required this.tint,
  });

  final List<ActivityDay> days;
  final bool asNeeded;
  final Color tint;

  static const _perRow = 7;
  static const _gap = 6.0;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toString();
    final date = DateFormat.MMMEd(locale);
    String label(ActivityDay d) {
      if (asNeeded) {
        return l.tm_dayCellAsNeeded(date.format(d.date), d.asNeeded);
      }
      return l.tm_dayCell(date.format(d.date), switch (d.state) {
        ActivityDayState.taken => l.t08_taken,
        ActivityDayState.skipped => l.t08_skipped,
        ActivityDayState.missed => l.dashboard_statusMissed,
        ActivityDayState.notRecorded => l.t08_unrecorded,
        ActivityDayState.partial => l.tm_dayPartial,
        ActivityDayState.upcoming => l.tm_dayUpcoming,
        ActivityDayState.none => l.tm_dayNone,
      });
    }

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: Column(
        key: const ValueKey('day-grid'),
        children: [
          for (var start = 0; start < days.length; start += _perRow) ...[
            if (start > 0) const SizedBox(height: _gap),
            Row(
              children: [
                for (var i = start; i < start + _perRow; i++) ...[
                  if (i > start) const SizedBox(width: _gap),
                  Expanded(
                    child: i < days.length
                        ? _DayCell(
                            key: ValueKey('day-cell-$i'),
                            day: days[i],
                            asNeeded: asNeeded,
                            tint: tint,
                            label: label(days[i]),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    super.key,
    required this.day,
    required this.asNeeded,
    required this.tint,
    required this.label,
  });

  final ActivityDay day;
  final bool asNeeded;
  final Color tint;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final semantic = theme.extension<AppSemanticColors>()!;
    final muted = cs.onSurfaceVariant;
    Color? fill;
    Color? ink;
    Color? line;
    var dashed = false;
    Widget? mark;
    if (asNeeded) {
      if (day.asNeeded > 0) {
        fill = tint.withValues(alpha: .24);
        ink = cs.onSurface;
        mark = Text(
          '${day.asNeeded}',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
            color: ink,
          ),
        );
      } else {
        line = cs.outlineVariant.withValues(alpha: .6);
      }
    } else {
      switch (day.state) {
        case ActivityDayState.taken:
          ink = semantic.statusTaken;
          fill = ink.withValues(alpha: .16);
          mark = Icon(Icons.check_rounded, size: 18, color: ink);
        case ActivityDayState.partial:
          ink = semantic.statusTaken;
          fill = ink.withValues(alpha: .07);
          line = ink.withValues(alpha: .55);
          mark = Icon(Icons.contrast_rounded, size: 17, color: ink);
        case ActivityDayState.skipped:
          ink = semantic.statusSkipped;
          fill = ink.withValues(alpha: .16);
          mark = Icon(Icons.skip_next_rounded, size: 18, color: ink);
        case ActivityDayState.missed:
          ink = semantic.statusMissed;
          fill = ink.withValues(alpha: .16);
          mark = Icon(Icons.error_outline_rounded, size: 17, color: ink);
        case ActivityDayState.notRecorded:
          line = cs.outline.withValues(alpha: .8);
          dashed = true;
          mark = Icon(Icons.remove_rounded, size: 16, color: muted);
        case ActivityDayState.upcoming:
          line = cs.outlineVariant.withValues(alpha: .8);
        case ActivityDayState.none:
          fill = cs.surfaceContainerHighest.withValues(alpha: .35);
      }
    }
    final cell = SizedBox(
      height: 48,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(10),
          border: line == null || dashed ? null : Border.all(color: line),
        ),
        child: CustomPaint(
          painter: dashed ? _DashedBorder(line!) : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${day.date.day}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: muted,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 2),
              SizedBox(height: 20, child: Center(child: mark)),
            ],
          ),
        ),
      ),
    );
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Tooltip(message: label, child: cell),
    );
  }
}

class _DashedBorder extends CustomPainter {
  const _DashedBorder(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.75),
          const Radius.circular(10),
        ),
      );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color;
    for (final PathMetric metric in path.computeMetrics()) {
      for (var at = 0.0; at < metric.length; at += 7) {
        canvas.drawPath(
          metric.extractPath(at, math.min(at + 4, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color;
}

/// The latest few doses of a medication, with a way into History.
class MedicationRecentSection extends ConsumerWidget {
  const MedicationRecentSection({
    super.key,
    required this.detail,
    this.flat = false,
  });

  final MedicationCareDetail detail;
  final bool flat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final recent = ref
        .watch(medicationActivityProvider(detail.pill.id))
        .valueOrNull
        ?.recent;
    return MedicationSection(
      key: const ValueKey('medication-recent'),
      flat: flat,
      title: l.tm_recentTitle,
      trailing: const MedicationHistoryLink(),
      children: [
        if (recent == null || recent.isEmpty)
          Text(
            recent == null ? '' : l.tm_recentEmpty,
            style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          )
        else
          // One column, newest first: the list is five at most, so two
          // columns would leave an orphan and read in a zigzag.
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < recent.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                _RecentTile(
                  key: ValueKey('recent-${recent[i].occurrenceId}'),
                  record: recent[i],
                ),
              ],
            ],
          ),
      ],
    );
  }
}

/// "See all in History": the History tab.
class MedicationHistoryLink extends StatelessWidget {
  const MedicationHistoryLink({super.key});

  @override
  Widget build(BuildContext context) => TextButton(
    key: const ValueKey('see-all-history'),
    style: TextButton.styleFrom(
      minimumSize: const Size(0, 44),
      padding: const EdgeInsets.symmetric(horizontal: 10),
    ),
    onPressed: () => context.go(AppPaths.logs),
    child: Text(AppLocalizations.of(context).tm_seeAllHistory),
  );
}

class _RecentTile extends StatelessWidget {
  const _RecentTile({super.key, required this.record});
  final ActivityRecord record;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final semantic = theme.extension<AppSemanticColors>()!;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final at = record.at;
    final day = DateTime(at.year, at.month, at.day) == today
        ? l.t08_today
        : DateFormat.MMMEd(
            Localizations.localeOf(context).toString(),
          ).format(at);
    final when = record.timeKnown ? '$day · ${clockAt(context, at)}' : day;
    final (String word, Color? ink) = switch (record.status) {
      'taken' => (l.t08_taken, semantic.statusTaken),
      'skipped' => (l.t08_skipped, semantic.statusSkipped),
      'missed' => (l.dashboard_statusMissed, semantic.statusMissed),
      _ => (l.t08_unrecorded, null),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: .6)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(when, style: theme.textTheme.bodyLarge),
                if (record.asNeeded)
                  Text(
                    l.t08_asNeeded,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: ink == null
                  ? cs.surfaceContainerHighest
                  : ink.withValues(alpha: .16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              word,
              style: theme.textTheme.labelMedium?.copyWith(
                color: ink ?? cs.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
