import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/inventory/supply_forecast.dart';
import '../../../core/medication/medication_detail_repository.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../core/medication/routine_repository.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/theme/app_theme.dart';

/// The supply forecast for a local medication with counted stock, or null
/// when there is nothing meaningful to forecast (no stock, connected care, as needed
/// only, or an unreadable routine).
///
/// [stockOverride] projects a different count along the same routine, for a
/// stock edit that is not saved yet.
SupplyForecast? supplyForecastFor(
  MedicationCareDetail detail, {
  required bool local,
  required DateTime now,
  int? stockOverride,
}) {
  final stock = stockOverride ?? detail.pill.currentStock;
  if (stock == null || !local || detail.routineVersions.isEmpty) return null;
  try {
    return forecastSupply(
      stock: stock,
      threshold: detail.pill.lowStockThreshold,
      versions: [
        for (final v in detail.routineVersions)
          (
            effectiveFrom: v.effectiveFrom,
            definition: RoutineDefinition.fromJson(
              jsonDecode(v.definitionJson) as Map<String, dynamic>,
            ),
          ),
      ],
      now: now,
    );
  } on Object {
    return null;
  }
}

String _day(BuildContext context, DateTime date) =>
    DateFormat.MMMEd(Localizations.localeOf(context).toString()).format(date);

/// The one-line answer: until when the stock lasts.
String supplyHeadline(BuildContext context, SupplyForecast forecast) {
  final l = AppLocalizations.of(context);
  if (forecast.lastsPastHorizon) return l.supply_pastHorizon;
  if (forecast.stock == 0) return l.supply_none;
  final until = forecast.enoughUntil;
  if (until == null) {
    return forecast.shortToday
        ? l.supply_shortToday
        : l.supply_shortOn(_day(context, forecast.runsOutOn!));
  }
  return l.supply_until(_day(context, until));
}

/// One line on when [forecast]'s stock runs out, for the stock section and the
/// edit preview.
String stockRunsOutLine(BuildContext context, SupplyForecast forecast) {
  final l = AppLocalizations.of(context);
  if (forecast.stock == 0) return l.supply_none;
  if (forecast.lastsPastHorizon) return l.supply_pastHorizon;
  if (forecast.shortToday) return l.supply_shortToday;
  return l.tm_runsOutAround(
    DateFormat.MMMd(
      Localizations.localeOf(context).toString(),
    ).format(forecast.runsOutOn!),
  );
}

/// Whether the stock already falls short of today's doses, which is when the
/// answer should read as a warning.
bool stockRunsShort(SupplyForecast forecast) =>
    forecast.runsOutOn != null && forecast.enoughUntil == null;

/// A short form for the medication card.
String? supplyCardLine(BuildContext context, SupplyForecast forecast) {
  final l = AppLocalizations.of(context);
  if (forecast.lastsPastHorizon) return null;
  if (forecast.stock == 0) return l.supply_none;
  final short = DateFormat.MMMd(Localizations.localeOf(context).toString());
  final until = forecast.enoughUntil;
  if (until == null) {
    return forecast.shortToday
        ? l.supply_shortToday
        : l.supply_shortOn(short.format(forecast.runsOutOn!));
  }
  return l.supply_cardUntil(short.format(until));
}

/// The days ahead as a strip of small blister cells, one dot per planned
/// dose: filled while the stock covers it, an empty ring once it does not.
///
/// The boundary between filled and empty glides when the stock changes, so a
/// taken dose drains one dot and a refill pours them back along the strip.
/// On first appearance the dots drop in left to right.
class SupplyRunway extends StatefulWidget {
  const SupplyRunway({
    super.key,
    required this.forecast,
    required this.tint,
    this.days = 14,
    this.showTitle = true,
    this.showHeadline = true,
  });

  final SupplyForecast forecast;
  final Color tint;
  final int days;

  /// Whether the strip names itself "Supply"; a page that already has a
  /// heading for it leaves this out.
  final bool showTitle;

  /// Whether the one-line answer ("Enough until ...") leads the strip.
  final bool showHeadline;

  @override
  State<SupplyRunway> createState() => _SupplyRunwayState();
}

class _SupplyRunwayState extends State<SupplyRunway>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  Animation<double>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_drop.value > 0 || _drop.isAnimating) return;
    if (AppMotion.quiet(context)) {
      _drop.value = 1;
      return;
    }
    // Wait for the page to land, so the dots drop in where the eye is and
    // not under the plate's flight.
    final route = ModalRoute.of(context)?.animation;
    if (route == null || route.isCompleted) {
      _drop.forward();
    } else if (_route != route) {
      _route?.removeStatusListener(_landed);
      _route = route..addStatusListener(_landed);
    }
  }

  void _landed(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _route?.removeStatusListener(_landed);
    _route = null;
    if (mounted && _drop.value == 0) _drop.forward();
  }

  @override
  void dispose() {
    _route?.removeStatusListener(_landed);
    _drop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme, text = theme.textTheme;
    final semantic = theme.extension<AppSemanticColors>()!;
    final forecast = widget.forecast;
    final shown = forecast.days.take(widget.days).toList();
    final covered = shown.fold<int>(0, (n, d) => n + d.covered);
    final locale = Localizations.localeOf(context).toString();
    final refill = forecast.refillBy;
    final slots = shown.fold<int>(
      1,
      (n, d) => math.max(n, math.min(d.planned, _BlisterPainter.maxDots)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showTitle) ...[
          Text(l.supply_title, style: text.titleLarge),
          const SizedBox(height: 8),
        ],
        if (widget.showHeadline)
          Text(
            supplyHeadline(context, forecast),
            key: const ValueKey('supply-headline'),
            style: text.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: forecast.runsOutOn != null && forecast.enoughUntil == null
                  ? semantic.statusMissed
                  : null,
            ),
          ),
        if (refill != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              l.supply_refillBy(_day(context, refill)),
              key: const ValueKey('supply-refill'),
              style: text.bodyLarge,
            ),
          ),
        // The strip stands off whatever leads it; with nothing above it the
        // section's own spacing is enough.
        if (widget.showTitle || widget.showHeadline || refill != null)
          const SizedBox(height: 14),
        ExcludeSemantics(
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.4,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final cell = math.max(
                  18.0,
                  math.min(30.0, constraints.maxWidth / shown.length),
                );
                // The epsilon keeps a width that is exactly `shown.length` cells from
                // dividing to 13.999... and leaving the last day on a row of its own.
                final perRow = math.max(
                  1,
                  (constraints.maxWidth / cell + 1e-6).floor(),
                );
                final rows = <List<SupplyDay>>[
                  for (var i = 0; i < shown.length; i += perRow)
                    shown.sublist(i, math.min(i + perRow, shown.length)),
                ];
                var start = 0;
                return TweenAnimationBuilder<double>(
                  tween: Tween(end: covered.toDouble()),
                  duration: AppMotion.duration(context, milliseconds: 700),
                  curve: Curves.easeInOutCubic,
                  builder: (context, fill, _) => AnimatedBuilder(
                    animation: _drop,
                    builder: (context, _) {
                      start = 0;
                      return Column(
                        children: [
                          for (final row in rows)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                children: [
                                  for (final day in row)
                                    SizedBox(
                                      width: cell,
                                      child: _RunwayDay(
                                        day: day,
                                        index: shown.indexOf(day),
                                        count: shown.length,
                                        // Doses before this day, so the fill
                                        // can flow through the strip.
                                        before:
                                            (start += day.planned) -
                                            day.planned,
                                        fill: fill,
                                        drop: _drop.value,
                                        tint: widget.tint,
                                        empty: semantic.statusMissed,
                                        outline: colors.outlineVariant,
                                        label: DateFormat.E(
                                          locale,
                                        ).format(day.date).characters.first,
                                        number: '${day.date.day}',
                                        slots: slots,
                                        today: day == shown.first,
                                        runsOut: day.date == forecast.runsOutOn,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ),
        Text(
          l.supply_estimateNote,
          style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _RunwayDay extends StatelessWidget {
  const _RunwayDay({
    required this.day,
    required this.index,
    required this.count,
    required this.before,
    required this.fill,
    required this.drop,
    required this.tint,
    required this.empty,
    required this.outline,
    required this.label,
    required this.number,
    required this.slots,
    required this.today,
    required this.runsOut,
  });

  final SupplyDay day;
  final int slots;
  final int index;
  final int count;
  final int before;
  final double fill;
  final double drop;
  final Color tint;
  final Color empty;
  final Color outline;
  final String label;
  final String number;
  final bool today;
  final bool runsOut;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    // Each day drops in a little after the one before it.
    final local = ((drop * (1 + count * .06)) - index * .06).clamp(0.0, 1.0);
    final settle = Curves.easeOutBack.transform(local);
    final style = text.labelSmall?.copyWith(
      color: runsOut ? empty : colors.onSurfaceVariant,
      fontWeight: today || runsOut ? FontWeight.w800 : FontWeight.w500,
    );
    return Column(
      key: ValueKey('supply-day-${routineDateKey(day.date)}'),
      children: [
        Text(label, style: style),
        Text(number, style: style),
        const SizedBox(height: 4),
        Opacity(
          opacity: local,
          child: Transform.translate(
            offset: Offset(0, (1 - settle) * -10),
            child: CustomPaint(
              size: Size(14, 8 + slots * 10.0),
              painter: _BlisterPainter(
                planned: day.planned,
                before: before,
                fill: fill,
                tint: tint,
                empty: empty,
                outline: outline,
                today: today,
                runsOut: runsOut,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _BlisterPainter extends CustomPainter {
  const _BlisterPainter({
    required this.planned,
    required this.before,
    required this.fill,
    required this.tint,
    required this.empty,
    required this.outline,
    required this.today,
    required this.runsOut,
  });

  final int planned;
  final int before;
  final double fill;
  final Color tint;
  final Color empty;
  final Color outline;
  final bool today;
  final bool runsOut;

  static const maxDots = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.width / 2),
    );
    canvas.drawRRect(
      cell,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = today || runsOut ? 1.6 : 1
        ..color = runsOut ? empty : (today ? tint : outline),
    );
    if (planned == 0) {
      canvas.drawLine(
        Offset(size.width / 2 - 2.5, size.height / 2),
        Offset(size.width / 2 + 2.5, size.height / 2),
        Paint()
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round
          ..color = outline,
      );
      return;
    }
    final shown = math.min(planned, maxDots);
    const r = 4.0;
    // Doses sit centred in the cell, one 10 px slot each.
    final top = (size.height - shown * 10) / 2;
    for (var i = 0; i < shown; i++) {
      final center = Offset(size.width / 2, top + 10 * (i + .5));
      // How much of this dose the stock still holds, 0..1.
      final held = (fill - before - i).clamp(0.0, 1.0);
      if (held < 1) {
        canvas.drawCircle(
          center,
          r - .6,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = Color.lerp(
              runsOut ? empty : outline,
              tint,
              held,
            )!.withValues(alpha: runsOut ? .9 : 1),
        );
      }
      if (held > 0) {
        canvas.drawCircle(center, r * held, Paint()..color = tint);
      }
    }
    if (planned > maxDots) {
      final y = size.height - 3;
      canvas.drawCircle(
        Offset(size.width / 2, y),
        1.2,
        Paint()..color = outline,
      );
    }
  }

  @override
  bool shouldRepaint(_BlisterPainter old) =>
      old.planned != planned ||
      old.before != before ||
      old.fill != fill ||
      old.tint != tint ||
      old.empty != empty ||
      old.outline != outline ||
      old.today != today ||
      old.runsOut != runsOut;
}
