import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/medication/care_provider.dart' show CareDayRequest;
import '../../../core/medication/routine_definition.dart';
import '../../../core/utils/app_clock.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/stock_recount_note.dart';
import '../../../shared/format/clock.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/status_chip.dart';
import '../../../shared/widgets/stock_state_label.dart';
import '../../pills/presentation/medication_identity.dart';
import '../as_needed/as_needed_section.dart';
import '../today_layout/low_stock_notice.dart' show expiryDetail;
import '../care_record_form.dart' show careAmountLabel;
import 'coming_up.dart';
import 'today_card.dart';
import 'stock_overview.dart';
import 'week_dots.dart';
import 'week_strip.dart';

/// A card's heading with a quiet trailing word or link.
class _CardHeading extends StatelessWidget {
  const _CardHeading({required this.title, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              title,
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}

/// The column Today shows beside (expanded) or below (medium) the chosen
/// layout: the As needed cards, the Stock of what you keep and This week.
/// On a medium window it ends with Coming up.
///
/// Every part is read-only except the As needed cards, which keep their own
/// hold-to-record path, and "Add stock", which opens the stock editor.
class TodaySideColumn extends ConsumerWidget {
  const TodaySideColumn({
    super.key,
    required this.request,
    this.showAsNeeded = true,
    this.showComingUp = false,
  });

  final CareDayRequest request;

  /// False while the As needed cards sit under the layout instead.
  final bool showAsNeeded;
  final bool showComingUp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(todayProvider);
    return Column(
      key: const ValueKey('today-side-column'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showAsNeeded)
          AsNeededSection(
            key: ValueKey('as-needed-card/${request.localDate}'),
            request: request,
            card: true,
            maxColumns: 3,
          ),
        LayoutBuilder(
          builder: (context, box) {
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final beside = box.maxWidth >= 520 && scale <= 1.3;
            const stock = StockCard(key: ValueKey('stock-card'));
            final week = WeekCard(
              key: const ValueKey('week-card'),
              request: request,
            );
            return Padding(
              padding: EdgeInsets.only(top: showAsNeeded ? 16 : 0),
              // Side by side, each card is as tall as its own content and
              // they start at the same line: a short This week card does not
              // stretch to the height of a long Stock list.
              child: beside
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Expanded(child: stock),
                        const SizedBox(width: 16),
                        Expanded(child: week),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [stock, const SizedBox(height: 16), week],
                    ),
            );
          },
        ),
        if (showComingUp && request.localDate == today)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: ComingUpCard(key: ValueKey('coming-up-card')),
          ),
      ],
    );
  }
}

/// How long a medication's stock lasts, in words.
String stockLastsLabel(AppLocalizations l, StockRow row) {
  if (row.level == StockLevel.out) return l.tt_stockOut;
  if (row.asNeeded) return l.tt_stockAsNeeded;
  final forecast = row.forecast;
  if (forecast == null) return '';
  if (forecast.lastsPastHorizon) return l.tt_stockLong;
  final today = forecast.days.first.date;
  final end = forecast.runsOutOn!;
  final days = math.max(
    1,
    DateTime.utc(
      end.year,
      end.month,
      end.day,
    ).difference(DateTime.utc(today.year, today.month, today.day)).inDays,
  );
  return days >= 14
      ? l.tt_stockAboutWeeks(days ~/ 7)
      : l.tt_stockAboutDays(days);
}

/// What is left of each medication whose stock you keep, lowest first, with
/// how long it lasts. A row that runs low turns amber and offers Add stock.
class StockCard extends ConsumerWidget {
  const StockCard({super.key});

  /// More than this many rows are left to the Medications page ("All").
  static const maxRows = 5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final overview = ref.watch(todayStockProvider).asData?.value;
    final rows = (overview?.rows ?? const <StockRow>[]).take(maxRows).toList();
    final expiryOnly = overview?.expiryOnly ?? const <StockRow>[];
    return TodayCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardHeading(
            title: l.tt_stockTitle,
            trailing: TextButton(
              key: const ValueKey('stock-all'),
              onPressed: () => context.go('/pills'),
              // The word ends on the card's own edge, like the count in the
              // This week heading; the touch target still reaches past it.
              style: TextButton.styleFrom(
                padding: const EdgeInsetsDirectional.only(start: 16),
                minimumSize: const Size(48, 44),
                alignment: AlignmentDirectional.centerEnd,
              ),
              child: Semantics(
                label: l.tt_stockAllLabel,
                excludeSemantics: true,
                child: Text(l.tt_stockAll),
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (overview == null)
            const SizedBox(height: 48)
          else if (rows.isEmpty && expiryOnly.isEmpty)
            Text(
              l.tt_stockEmpty,
              style: text.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          else
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: 14),
              _StockRowView(row: rows[i], canAddStock: overview.canAddStock),
            ],
          for (final row in expiryOnly) ...[
            if (rows.isNotEmpty || row != expiryOnly.first)
              const SizedBox(height: 14),
            _ExpiryOnlyRow(row: row),
          ],
        ],
      ),
    );
  }
}

/// A medicine whose stock is not counted but whose expiry date is near or
/// past: its name and the expiry in words.
class _ExpiryOnlyRow extends StatelessWidget {
  const _ExpiryOnlyRow({required this.row});
  final StockRow row;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final detail = expiryDetail(l, row.expiry) ?? '';
    return Semantics(
      container: true,
      label: '${row.name}. $detail',
      excludeSemantics: true,
      child: Row(
        key: ValueKey('stock-expiry-row-${row.pillId}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PillMark(
            size: 34,
            pillId: row.pillId,
            name: row.name,
            color: medicationTint(id: row.pillId, color: row.color),
            fallbackShape: medicationShapeOf(row.unit),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: text.bodySmall?.copyWith(
                    color: statusToneColor(theme, StatusTone.attention),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StockRowView extends ConsumerWidget {
  const _StockRowView({required this.row, required this.canAddStock});
  final StockRow row;
  final bool canAddStock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final colors = theme.colorScheme;
    final semantic = theme.extension<AppSemanticColors>();
    final ink = switch (row.level) {
      StockLevel.ok => semantic?.statusTaken ?? colors.primary,
      StockLevel.low => statusToneColor(theme, StatusTone.attention),
      StockLevel.out => colors.error,
    };
    // A bare count: the unit is typed free text with no plural form.
    final left = row.left;
    final lasts = stockLastsLabel(l, row);
    final fraction = row.level == StockLevel.out ? 0.0 : row.fraction;
    return Semantics(
      container: true,
      label: [
        l.tt_stockRow(row.name, l.tt_stockLeft(left)),
        if (lasts.isNotEmpty) lasts,
        if (row.low) l.tt_lowStockNotice,
        if (row.needsRecount) l.stock_needsRecount,
        ?expiryDetail(l, row.expiry),
      ].join('. '),
      excludeSemantics: true,
      child: Row(
        key: ValueKey('stock-row-${row.pillId}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PillMark(
            size: 34,
            pillId: row.pillId,
            name: row.name,
            color: medicationTint(id: row.pillId, color: row.color),
            fallbackShape: medicationShapeOf(row.unit),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The name has the whole line, so a long one wraps instead
                // of being cut; the count and how long it lasts follow it.
                Text(
                  row.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 10,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    // Low and out carry an icon and words, so the state is
                    // never colour alone; the tan or red is a second signal.
                    if (row.level == StockLevel.ok)
                      Text(l.tt_stockLeft(left), style: text.titleSmall)
                    else
                      StockStateLabel(
                        key: ValueKey('stock-state-${row.pillId}'),
                        state: row.level == StockLevel.out
                            ? StockState.out
                            : StockState.low,
                        left: left,
                        style: text.titleSmall,
                        color: ink,
                      ),
                    if (row.needsRecount)
                      StockRecountNote(
                        key: ValueKey('stock-recount-${row.pillId}'),
                        style: text.bodySmall,
                      ),
                    // "Out" already says it; the forecast has nothing to add.
                    if (lasts.isNotEmpty && row.level != StockLevel.out)
                      Text(
                        lasts,
                        style: text.bodySmall?.copyWith(
                          color: row.low ? ink : colors.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                if (expiryDetail(l, row.expiry) case final expiry?)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      key: ValueKey('stock-expiry-${row.pillId}'),
                      expiry,
                      style: text.bodySmall?.copyWith(
                        color: statusToneColor(theme, StatusTone.attention),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (fraction != null) ...[
                  const SizedBox(height: 8),
                  _RefillBar(
                    fraction: fraction,
                    mark: row.refillMark,
                    ink: ink,
                  ),
                ],
                if (row.low && canAddStock)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      key: ValueKey('stock-add-${row.pillId}'),
                      onPressed: () =>
                          openStockEditor(context, ref, row.pillId),
                      style: TextButton.styleFrom(
                        foregroundColor: ink,
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(48, 44),
                        alignment: AlignmentDirectional.centerStart,
                        textStyle: text.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: Text(l.tt_addStock),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The stock bar: the fill, and a tick where the stock counts as low, so the
/// refill point can be read without relying on the fill's colour.
class _RefillBar extends StatelessWidget {
  const _RefillBar({
    required this.fraction,
    required this.mark,
    required this.ink,
  });
  final double fraction;
  final double? mark;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: SizedBox(
        height: 10,
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 2,
                height: 6,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 6,
                    color: ink,
                    backgroundColor: colors.onSurface.withValues(alpha: .12),
                  ),
                ),
              ),
              if (mark != null)
                Positioned(
                  key: const ValueKey('stock-refill-tick'),
                  left: (box.maxWidth * mark!).clamp(1.0, box.maxWidth - 1) - 1,
                  top: 0,
                  bottom: 0,
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

/// The seven days ending on the viewed day, each with a dot for what was
/// recorded, and the total recorded across them.
class WeekCard extends ConsumerWidget {
  const WeekCard({super.key, required this.request});
  final CareDayRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final dots = ref.watch(weekDotsProvider(request)).asData?.value;
    return TodayCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardHeading(
            title: l.tt_week,
            trailing: dots == null
                ? null
                : Text(
                    l.tt_weekRecorded(weekRecorded(dots)),
                    style: text.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
          ),
          const SizedBox(height: 16),
          if (dots == null)
            const SizedBox(height: 48)
          else
            WeekDotsRow(dots: dots),
          const SizedBox(height: 16),
          Text(
            l.tt_weekHint,
            style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// The next planned doses after today: when, which, and that they are only
/// planned. Informational; nothing here can be recorded.
class ComingUpCard extends ConsumerWidget {
  const ComingUpCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final today = ref.watch(todayProvider);
    final doses = ref.watch(comingUpProvider(today)).asData?.value;
    return TodayCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardHeading(title: l.tt_comingUp),
          const SizedBox(height: 12),
          if (doses == null)
            const SizedBox(height: 48)
          else if (doses.isEmpty)
            Text(
              l.tt_comingUpNone,
              style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            )
          else
            for (var i = 0; i < doses.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              ComingUpRow(dose: doses[i], today: today),
            ],
        ],
      ),
    );
  }
}

/// One planned dose: its day and time, the medication and a "Planned" tag.
///
/// On a card it sits in its own outline. [framed] false draws it flat, for a
/// list that already has its own surface, such as the Day overview sheet.
class ComingUpRow extends StatelessWidget {
  const ComingUpRow({
    super.key,
    required this.dose,
    required this.today,
    this.framed = true,
  });
  final ComingUpDose dose;
  final String today;
  final bool framed;

  String _part(AppLocalizations l) {
    final hour = int.tryParse(dose.localTime.split(':').first);
    if (hour == null) return '';
    return hour >= 5 && hour < 12
        ? l.r07_morning
        : hour >= 12 && hour < 18
        ? l.r07_afternoon
        : hour >= 18 && hour < 22
        ? l.r07_evening
        : l.r07_night;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final colors = theme.colorScheme;
    final locale = Localizations.localeOf(context).toString();
    final date = parseRoutineDate(dose.localDate);
    final tomorrow = parseRoutineDate(today);
    final isTomorrow =
        routineDateKey(
          DateTime.utc(tomorrow.year, tomorrow.month, tomorrow.day + 1),
        ) ==
        dose.localDate;
    final day = isTomorrow
        ? l.tt_tomorrow
        : DateFormat.MMMEd(locale).format(date);
    final shortDay = DateFormat.E(locale).format(date);
    final time = clockText(context, dose.localTime);
    final detail = [
      day,
      _part(l),
      if (!dose.amount.isUnknown) careAmountLabel(l, dose.amount),
    ].where((part) => part.isNotEmpty).join(' · ');
    final planned = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        l.tt_comingUpPlanned,
        style: text.labelMedium?.copyWith(color: colors.onSurfaceVariant),
      ),
    );
    // Large text leaves the name no room beside the chip: it goes under the
    // detail instead.
    final stacked = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    return Semantics(
      container: true,
      label: '${dose.medication}. $detail, $time. ${l.tt_comingUpPlanned}',
      excludeSemantics: true,
      child: Container(
        key: ValueKey(
          framed
              ? 'coming-up-${dose.pillId}'
              : 'overview-coming-up-${dose.pillId}',
        ),
        padding: framed
            ? const EdgeInsets.symmetric(horizontal: 14, vertical: 12)
            : const EdgeInsets.symmetric(vertical: 8),
        decoration: framed
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: colors.outlineVariant),
              )
            : null,
        child: Row(
          children: [
            // A fixed column, so the marks and names of every row start on
            // the same line whatever the time or day reads.
            SizedBox(
              width: MediaQuery.textScalerOf(context).scale(72),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shortDay,
                    style: text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    time,
                    maxLines: 1,
                    softWrap: false,
                    style: text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            PillMark(
              size: 34,
              pillId: dose.pillId,
              name: dose.medication,
              color: medicationTint(id: dose.pillId, color: dose.color),
              fallbackShape: medicationShapeOf(dose.amount.unit),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    dose.medication,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (stacked) ...[const SizedBox(height: 6), planned],
                ],
              ),
            ),
            if (!stacked) ...[const SizedBox(width: 8), planned],
          ],
        ),
      ),
    );
  }
}
