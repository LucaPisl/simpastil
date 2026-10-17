import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/db/database.dart' show MedicationOccurrence, OccurrenceEvent;
import '../../core/medication/care_recording.dart';
import '../../core/medication/late_dose.dart';
import '../../core/medication/occurrence_detail_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/motion/app_motion.dart';
import '../../shared/theme/focus_tokens.dart';
import 'care_record_form.dart';
import 'today_layout/today_layout.dart';
import '../../shared/format/clock.dart';

/// How far along a dose's story one station is.
enum DoseStationKind {
  /// Happened, and nothing more is owed.
  done,

  /// Happened here; still on its way somewhere.
  waiting,

  /// Has not happened yet.
  open,

  /// Needs someone to look.
  attention,
}

/// One stop on a dose's story: what happened, and an optional aside.
@immutable
class DoseStation {
  const DoseStation({required this.title, this.aside, required this.kind});
  final String title;
  final String? aside;
  final DoseStationKind kind;
}

/// How long [minutes] is, in words.
String doseStoryDuration(AppLocalizations l, int minutes) => minutes < 60
    ? l.story_minutes('$minutes')
    : l.story_hoursMinutes('${minutes ~/ 60}', '${minutes % 60}');

/// How far the actual time sat from the plan, in words. Within five minutes
/// either way counts as the planned time.
String doseStoryOffset(AppLocalizations l, Duration offset) {
  final minutes = offset.inMinutes;
  if (minutes.abs() < 5) return l.story_onTime;
  final words = doseStoryDuration(l, minutes.abs());
  return minutes > 0 ? l.story_after(words) : l.story_before(words);
}

/// The dose's story, read only from facts already recorded: the plan, what
/// was recorded and when, and where the record stands with shared care.
List<DoseStation> doseStoryStations(
  BuildContext context,
  OccurrenceCareDetail detail,
) {
  final l = AppLocalizations.of(context);
  final row = detail.occurrence;
  final head = detail.head;
  // As-needed and timeless doses have no plan to measure against; their
  // story starts with what happened.
  final stations = [
    if (row.source != 'prn' && row.plannedLocalTime != null)
      DoseStation(
        title: l.story_plannedFor(clockText(context, row.plannedLocalTime!)),
        kind: DoseStationKind.done,
      ),
  ];
  if (row.state == 'pending' || head == null) {
    stations.add(
      DoseStation(title: l.story_notYet, kind: DoseStationKind.open),
    );
    return stations;
  }
  final event = head.event;
  final missed = DoseStation(
    title: l.dose_markedMissedAuto,
    kind: DoseStationKind.done,
  );
  // A miss stands on its own: it has no actual time to show.
  if (row.state == 'missed') {
    stations.add(missed);
  } else {
    // A dose taken late keeps the miss it followed in its story.
    if (isTakenLate(row.state, event)) stations.add(missed);
    _addRecorded(l, context, stations, row, event);
  }
  final sharing = detail.sharing;
  if (sharing != null) {
    stations.add(
      DoseStation(
        title: careSharingLabel(l, sharing),
        kind: switch (sharing) {
          CareSharingOutcome.localOnly ||
          CareSharingOutcome.acknowledged ||
          CareSharingOutcome.reconciled => DoseStationKind.done,
          CareSharingOutcome.pending => DoseStationKind.waiting,
          _ => DoseStationKind.attention,
        },
      ),
    );
  }
  return stations;
}

void _addRecorded(
  AppLocalizations l,
  BuildContext context,
  List<DoseStation> stations,
  MedicationOccurrence row,
  OccurrenceEvent event,
) {
  final known = event.actualTimeKnown && event.actualAt != null;
  final time = known ? recordedTimeLabel(context, event, row) : null;
  stations.add(
    DoseStation(
      title: time == null
          ? l.story_recordedNoTime
          : row.state == 'skipped'
          ? l.story_skippedAt(time)
          : l.story_takenAt(time),
      aside: known && row.plannedAt != null && row.source != 'prn'
          ? doseStoryOffset(l, event.actualAt!.difference(row.plannedAt!))
          : null,
      kind: DoseStationKind.done,
    ),
  );
}

/// A rail that draws itself down through each station of a dose's story.
/// Plays once when it first appears and again only when the story grows;
/// it costs nothing at rest.
class DoseStory extends StatefulWidget {
  const DoseStory({super.key, required this.stations});
  final List<DoseStation> stations;

  static const duration = Duration(milliseconds: 1100);

  @override
  State<DoseStory> createState() => _DoseStoryState();
}

class _DoseStoryState extends State<DoseStory>
    with SingleTickerProviderStateMixin {
  late final AnimationController _draw;

  /// Stations before this one stay landed while the story replays.
  int _from = 0;

  @override
  void initState() {
    super.initState();
    _draw = AnimationController(vsync: this, duration: DoseStory.duration);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.quiet(context)) {
      _draw.value = 1;
    } else if (!_draw.isAnimating && _draw.value == 0) {
      _draw.forward();
    }
  }

  @override
  void didUpdateWidget(DoseStory old) {
    super.didUpdateWidget(old);
    final now = widget.stations;
    final first = [
      for (var i = 0; i < now.length; i++)
        if (i >= old.stations.length ||
            old.stations[i].kind != now[i].kind ||
            old.stations[i].title != now[i].title)
          i,
    ];
    // Replays from the first station that changed, so earlier stations stay
    // put.
    if (first.isNotEmpty && !AppMotion.quiet(context)) {
      _from = first.first;
      _draw.forward(from: _startOf(_from, now.length));
    }
  }

  @override
  void dispose() {
    _draw.dispose();
    super.dispose();
  }

  /// Where station [i] of [n] starts landing on the 0..1 timeline.
  static double _startOf(int i, int n) => n <= 1 ? 0 : i / n * .72;

  /// How far station [i] of [n] has landed at [t].
  double _landed(double t, int i, int n) =>
      i < _from ? 1 : ((t - _startOf(i, n)) / .28).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final stations = widget.stations;
    final n = stations.length;
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _draw,
      builder: (context, _) {
        final t = _draw.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < n; i++)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 32,
                      child: ExcludeSemantics(
                        child: CustomPaint(
                          key: ValueKey('dose-story-rail-$i'),
                          painter: DoseRailPainter(
                            kind: stations[i].kind,
                            next: i + 1 < n ? stations[i + 1].kind : null,
                            first: i == 0,
                            landed: Curves.easeOutBack.transform(
                              _landed(t, i, n),
                            ),
                            reach: i + 1 < n
                                ? Curves.easeInOut.transform(
                                    ((t - _startOf(i, n) - .1) /
                                            (_startOf(i + 1, n) -
                                                _startOf(i, n)))
                                        .clamp(0.0, 1.0),
                                  )
                                : 0,
                            line: cs.outlineVariant,
                            surface: cs.surface,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Opacity(
                        opacity: Curves.easeOut.transform(_landed(t, i, n)),
                        child: Transform.translate(
                          offset: Offset(
                            0,
                            6 *
                                (1 -
                                    Curves.easeOut.transform(_landed(t, i, n))),
                          ),
                          child: Padding(
                            padding: EdgeInsets.only(
                              top: 2,
                              bottom: i + 1 < n ? 22 : 2,
                            ),
                            child: MergeSemantics(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    stations[i].title,
                                    style: text.titleMedium?.copyWith(
                                      color:
                                          stations[i].kind ==
                                              DoseStationKind.open
                                          ? cs.onSurfaceVariant
                                          : null,
                                    ),
                                  ),
                                  if (stations[i].aside != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: _Aside(stations[i].aside!),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Aside extends StatelessWidget {
  const _Aside(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: FocusTokens.violet.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(
                child: Icon(Icons.schedule, size: 15, color: cs.primary),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  text,
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: cs.primary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One station's stretch of the rail: the line arriving from above, its
/// node, and the line leaving downwards as far as [reach].
class DoseRailPainter extends CustomPainter {
  const DoseRailPainter({
    required this.kind,
    required this.next,
    required this.first,
    required this.landed,
    required this.reach,
    required this.line,
    required this.surface,
  });

  final DoseStationKind kind;
  final DoseStationKind? next;
  final bool first;

  /// 0..1 (may overshoot) as the node lands.
  final double landed;

  /// 0..1, how much of the line to the next station is drawn.
  final double reach;
  final Color line, surface;

  static const nodeY = 13.0;
  static const radius = 7.0;

  static Color colourOf(DoseStationKind kind) => switch (kind) {
    DoseStationKind.done => FocusTokens.sage,
    DoseStationKind.waiting => FocusTokens.violet,
    DoseStationKind.open => FocusTokens.lavender,
    DoseStationKind.attention => const Color(0xFFE0A84F),
  };

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    final centre = Offset(x, nodeY);
    // The stub of rail just above the node belongs to the line arriving from
    // the station above, so it shows only once this station has landed and
    // continues that line's look.
    if (!first && landed > 0) {
      final waiting =
          kind == DoseStationKind.waiting || kind == DoseStationKind.open;
      final paint = _stroke(
        Color.lerp(colourOf(kind), line, .35)!,
        dashed: waiting,
      );
      final from = Offset(x, 0), to = Offset(x, centre.dy - radius);
      waiting
          ? _dashed(canvas, from, to, paint)
          : canvas.drawLine(from, to, paint);
    }
    if (next != null && reach > 0) {
      final end =
          centre.dy + radius + (size.height - centre.dy - radius) * reach;
      final paint = _stroke(
        Color.lerp(colourOf(kind), line, .35)!,
        dashed: next == DoseStationKind.waiting || next == DoseStationKind.open,
      );
      if (next == DoseStationKind.waiting || next == DoseStationKind.open) {
        _dashed(canvas, Offset(x, centre.dy + radius), Offset(x, end), paint);
      } else {
        canvas.drawLine(Offset(x, centre.dy + radius), Offset(x, end), paint);
      }
    }
    if (landed <= 0) return;
    final r = radius * landed;
    final colour = colourOf(kind);
    if (kind == DoseStationKind.waiting || kind == DoseStationKind.attention) {
      canvas.drawCircle(
        centre,
        r * 1.9,
        Paint()
          ..color = colour.withValues(alpha: .18 * math.min(1, landed))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
    }
    if (kind == DoseStationKind.open) {
      canvas.drawCircle(centre, r, Paint()..color = surface);
      canvas.drawCircle(
        centre,
        r - 1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = colour,
      );
      return;
    }
    canvas.drawCircle(centre, r, Paint()..color = colour);
    if (kind == DoseStationKind.done && landed > .6) {
      final tick = Path()
        ..moveTo(centre.dx - r * .45, centre.dy + r * .02)
        ..lineTo(centre.dx - r * .1, centre.dy + r * .38)
        ..lineTo(centre.dx + r * .5, centre.dy - r * .36);
      canvas.drawPath(
        tick,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = FocusTokens.white.withValues(
            alpha: ((landed - .6) / .4).clamp(0.0, 1.0),
          ),
      );
    }
  }

  Paint _stroke(Color colour, {required bool dashed}) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..strokeCap = dashed ? StrokeCap.round : StrokeCap.butt
    ..color = colour;

  void _dashed(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dash = 4.0, gap = 5.0;
    final length = (to - from).distance;
    for (var d = 2.0; d < length; d += dash + gap) {
      canvas.drawLine(
        Offset.lerp(from, to, d / length)!,
        Offset.lerp(from, to, math.min(d + dash, length) / length)!,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(DoseRailPainter old) =>
      old.kind != kind ||
      old.next != next ||
      old.first != first ||
      old.landed != landed ||
      old.reach != reach ||
      old.line != line ||
      old.surface != surface;
}
