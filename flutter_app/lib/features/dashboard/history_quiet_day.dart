import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../l10n/app_localizations.dart';
import '../../shared/motion/app_motion.dart';

/// A day in History with nothing on it. It says which day, and hangs a
/// slack, empty thread between the nearest days that do have records: its
/// ends run into the "Earlier" and "Later" links, so they read as the
/// thread going on. With no earlier day its end is tied off in a knot.
///
/// A day before [seenFrom] is one this phone never saw: it says so instead,
/// and the thread is tied off there, since nothing earlier is on this phone.
class HistoryQuietDay extends StatefulWidget {
  const HistoryQuietDay({
    super.key,
    required this.day,
    this.earlier,
    this.later,
    this.seenFrom,
    this.person,
    required this.onSelect,
  });

  final DateTime day;

  /// The first day this phone can speak for, if known.
  final DateTime? seenFrom;

  /// The person being viewed; null for everyone.
  final String? person;

  /// The nearest day before [day] with records, if any.
  final DateTime? earlier;

  /// The nearest day after [day] with records, if any.
  final DateTime? later;
  final ValueChanged<DateTime> onSelect;

  static const duration = Duration(milliseconds: 900);

  /// How long a link tugs the thread before its day slides over.
  static const tugDuration = Duration(milliseconds: 180);

  @override
  State<HistoryQuietDay> createState() => _HistoryQuietDayState();
}

class _HistoryQuietDayState extends State<HistoryQuietDay>
    with TickerProviderStateMixin {
  /// The thread falling slack once, when the day opens.
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: HistoryQuietDay.duration,
  );

  /// A link pulling the slack its way; [_side] -1 earlier, +1 later.
  late final AnimationController _tug = AnimationController(
    vsync: this,
    duration: HistoryQuietDay.tugDuration,
  );
  int _side = 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.quiet(context)) {
      _settle.value = 1;
    } else if (_settle.value == 0 && !_settle.isAnimating) {
      _settle.forward();
    }
  }

  @override
  void dispose() {
    _settle.dispose();
    _tug.dispose();
    super.dispose();
  }

  Future<void> _go(DateTime day, int side) async {
    if (AppMotion.quiet(context)) return widget.onSelect(day);
    _side = side;
    await _tug.forward(from: 0).orCancel.catchError((_) {});
    if (mounted) widget.onSelect(day);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toString();
    final long = DateFormat.MMMMEEEEd(locale);
    final short = DateFormat.MMMEd(locale);
    final seenFrom = widget.seenFrom, person = widget.person;
    final unseen =
        seenFrom != null && widget.day.isBefore(DateUtils.dateOnly(seenFrom));
    final earlier = unseen ? null : widget.earlier, later = widget.later;
    final thread = ExcludeSemantics(
      child: SizedBox(
        height: 44,
        child: CustomPaint(
          key: const ValueKey('history-quiet-path'),
          painter: QuietPathPainter(
            progress: _settle,
            tug: _tug,
            side: _side,
            knot: earlier == null,
            loose: later == null,
            rtl: Directionality.of(context) == TextDirection.rtl,
            line: theme.colorScheme.onSurfaceVariant.withValues(
              alpha: unseen ? .38 : .6,
            ),
          ),
        ),
      ),
    );
    final before = earlier == null
        ? null
        : TextButton.icon(
            key: const ValueKey('history-quiet-earlier'),
            onPressed: () => _go(earlier, -1),
            icon: const Icon(Icons.chevron_left),
            label: Text(l.history_earlierRecords(short.format(earlier))),
          );
    final after = later == null
        ? null
        : TextButton(
            key: const ValueKey('history-quiet-later'),
            onPressed: () => _go(later, 1),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(l.history_laterRecords(short.format(later))),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (unseen) ...[
            Text(
              long.format(widget.day),
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
          ],
          Text(
            !unseen
                ? l.history_quietDay(long.format(widget.day))
                : person == null
                ? l.history_unseenTitleAll
                : l.history_unseenTitle(person),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            !unseen
                ? l.history_quietDayBody
                : person == null
                ? l.history_unseenBodyAll(long.format(seenFrom))
                : l.history_unseenBody(person, long.format(seenFrom)),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, bounds) {
              // The links sit at the thread's ends while they fit beside
              // it; at large text the thread spans the page above them.
              if (bounds.maxWidth >= 320 &&
                  MediaQuery.textScalerOf(context).scale(16) <= 24) {
                return Row(
                  children: [
                    if (before != null) Flexible(child: before),
                    Expanded(child: thread),
                    if (after != null) Flexible(child: after),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  thread,
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 8,
                    runSpacing: 4,
                    children: [?before, ?after],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// An empty, slack thread. It falls slack once ([progress]) with a small
/// bounce; a [tug] pulls the slack toward [side]. A [knot] ties off the
/// earlier end; a [loose] later end hangs free.
class QuietPathPainter extends CustomPainter {
  QuietPathPainter({
    required this.progress,
    required this.tug,
    required this.side,
    required this.knot,
    required this.loose,
    required this.rtl,
    required this.line,
  }) : super(repaint: Listenable.merge([progress, tug]));

  final Animation<double> progress, tug;
  final int side;
  final bool knot, loose, rtl;
  final Color line;

  /// The rest sag in dp.
  static const slack = 9.0;

  /// The sag while settling: from taut to slack, past it once, and back.
  static double sagAt(double t) =>
      slack * (1 - math.exp(-5.5 * t) * math.cos(10.5 * t));

  @override
  void paint(Canvas canvas, Size size) {
    if (rtl) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    final w = size.width, y = size.height / 2 - 4;
    final pull = Curves.easeOutCubic.transform(tug.value);
    final sag = sagAt(progress.value) * (1 - .7 * pull);
    final x0 = knot ? 8.0 : 0.0;
    final end = loose ? Offset(w - 6, y + 12) : Offset(w, y);
    final low = (x0 + end.dx) / 2 + side * (end.dx - x0) * .28 * pull;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = line;
    canvas.drawPath(
      Path()
        ..moveTo(x0, y)
        ..cubicTo(
          x0 + (low - x0) * .55,
          y + sag * 1.33,
          low + (end.dx - low) * .45,
          y + sag * 1.33,
          end.dx,
          end.dy,
        ),
      stroke,
    );
    if (knot) {
      // A small overhand knot: a bead with a short tail.
      canvas.drawCircle(Offset(x0, y), 3.2, Paint()..color = line);
      canvas.drawLine(Offset(x0 - 1, y + 1), Offset(x0 - 5, y + 7), stroke);
    }
  }

  @override
  bool shouldRepaint(QuietPathPainter old) =>
      old.progress != progress ||
      old.tug != tug ||
      old.side != side ||
      old.knot != knot ||
      old.loose != loose ||
      old.rtl != rtl ||
      old.line != line;
}
