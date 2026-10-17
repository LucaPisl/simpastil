import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/medication/care_provider.dart' show CareDayRequest;
import '../../../l10n/app_localizations.dart';
import 'week_dots.dart';

/// One day of the week as a dot: a dashed ring when nothing is recorded, a
/// partly filled ring while some doses still wait, a filled dot with a check
/// when the day is done. The viewed day carries a heavier ring.
///
/// Drawn only; the caller supplies the words (see [weekDotLabel]).
class WeekDotMark extends StatelessWidget {
  const WeekDotMark({super.key, required this.dot, this.size = 28});
  final WeekDot dot;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _WeekDotPainter(
          state: dot.state,
          selected: dot.selected,
          ring: colors.primary,
          idle: colors.onSurfaceVariant.withValues(alpha: .55),
        ),
        child: dot.state == WeekDotState.done
            ? Icon(Icons.check, size: size * .6, color: colors.onPrimary)
            : null,
      ),
    );
  }
}

class _WeekDotPainter extends CustomPainter {
  const _WeekDotPainter({
    required this.state,
    required this.selected,
    required this.ring,
    required this.idle,
  });
  final WeekDotState state;
  final bool selected;
  final Color ring, idle;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final stroke = size.width * (selected ? .09 : .065);
    final radius = size.width / 2 - stroke / 2;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    switch (state) {
      case WeekDotState.done:
        canvas.drawCircle(center, size.width / 2, Paint()..color = ring);
      case WeekDotState.some:
        canvas.drawCircle(
          center,
          radius,
          Paint()..color = ring.withValues(alpha: .32),
        );
        canvas.drawCircle(center, radius, line..color = ring);
      case WeekDotState.empty:
        if (selected) {
          canvas.drawCircle(center, radius, line..color = ring);
          break;
        }
        // A dashed ring: fourteen dashes, each a little over half its share.
        line.color = idle;
        const dashes = 14;
        const sweep = 2 * math.pi / dashes;
        for (var i = 0; i < dashes; i++) {
          canvas.drawArc(
            Rect.fromCircle(center: center, radius: radius),
            i * sweep,
            sweep * .55,
            false,
            line,
          );
        }
    }
  }

  @override
  bool shouldRepaint(_WeekDotPainter old) =>
      old.state != state ||
      old.selected != selected ||
      old.ring != ring ||
      old.idle != idle;
}

/// What a screen reader says for one dot: the day and how many doses were
/// recorded on it.
String weekDotLabel(BuildContext context, WeekDot dot) {
  final locale = Localizations.localeOf(context).toString();
  return AppLocalizations.of(
    context,
  ).tt_weekDay(DateFormat.MMMEd(locale).format(dot.date), dot.recorded);
}

/// How many doses the dots of [dots] show as recorded.
int weekRecorded(Iterable<WeekDot> dots) =>
    dots.fold(0, (sum, dot) => sum + dot.recorded);

/// The seven dots of the week with a weekday under each, for the This week
/// card. [size] is the dot's largest diameter; each day shrinks to its share
/// of a narrow card instead of overflowing it.
class WeekDotsRow extends StatelessWidget {
  const WeekDotsRow({super.key, required this.dots, this.size = 28});
  final List<WeekDot> dots;
  final double size;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final dot in dots)
          Expanded(
            child: Semantics(
              label: weekDotLabel(context, dot),
              excludeSemantics: true,
              child: FittedBox(
                key: ValueKey('week-dot-${dot.date.day}'),
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    WeekDotMark(dot: dot, size: size),
                    const SizedBox(height: 6),
                    Text(
                      DateFormat.E(locale).format(dot.date),
                      maxLines: 1,
                      softWrap: false,
                      style: style?.copyWith(
                        fontWeight: dot.selected ? FontWeight.w700 : null,
                        color: dot.selected
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The phone's week: seven small dots, each with its weekday's initial, set
/// in the Today header. Not interactive; a screen reader reads each day.
class WeekStrip extends ConsumerWidget {
  const WeekStrip({super.key, required this.request});
  final CareDayRequest request;

  /// The dot's diameter on the strip.
  static const dot = 14.0;
  static const _gap = 4.0;
  static const _label = 10.0;

  /// The width of one day's column at [scaler]: the dot, or its initial when
  /// the text is large enough to be wider.
  static double columnWidth(TextScaler scaler) =>
      math.max(dot + 2, scaler.scale(_label) + 4);

  /// The width of the whole strip at [scaler].
  static double widthFor(TextScaler scaler) =>
      7 * columnWidth(scaler) + 6 * _gap;

  /// The height of the whole strip at [scaler]: the dot, its weekday initial
  /// and a point of slack for font rounding.
  static double heightFor(TextScaler scaler) =>
      dot + 2 + scaler.scale(_label) * 1.2 + 1;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scaler = MediaQuery.textScalerOf(context);
    final dots = ref.watch(weekDotsProvider(request)).asData?.value;
    final width = widthFor(scaler), height = heightFor(scaler);
    if (dots == null) {
      return SizedBox(
        key: const ValueKey('week-strip'),
        width: width,
        height: height,
      );
    }
    final locale = Localizations.localeOf(context).toString();
    final theme = Theme.of(context);
    final colW = columnWidth(scaler);
    return SizedBox(
      key: const ValueKey('week-strip'),
      width: width,
      height: height,
      child: Row(
        children: [
          for (var i = 0; i < dots.length; i++) ...[
            if (i > 0) const SizedBox(width: _gap),
            Semantics(
              label: weekDotLabel(context, dots[i]),
              excludeSemantics: true,
              child: SizedBox(
                width: colW,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    WeekDotMark(dot: dots[i], size: dot),
                    const SizedBox(height: 2),
                    Text(
                      DateFormat.EEEEE(locale).format(dots[i].date),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: _label,
                        height: 1.2,
                        fontWeight: dots[i].selected ? FontWeight.w700 : null,
                        color: dots[i].selected
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
