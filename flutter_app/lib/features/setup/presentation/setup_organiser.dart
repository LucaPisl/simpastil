import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/motion/app_motion.dart';
import '../../../shared/theme/focus_tokens.dart';
import '../setup_state.dart';

/// How many of the organiser's compartments hold a saved step's capsule. The
/// value follows the stored draft step, so a capsule drops in only after a
/// step was durably advanced.
int setupOrganiserFilled(SetupStep step) => switch (step) {
  SetupStep.start || SetupStep.person => 0,
  SetupStep.medication => 1,
  SetupStep.routine => 2,
  SetupStep.reminders => 3,
  SetupStep.ready || SetupStep.complete => 4,
};

/// The compartment the open form will fill, or null on the welcome and the
/// finish.
int? setupOrganiserCurrent(SetupStep step) => switch (step) {
  SetupStep.person => 0,
  SetupStep.medication => 1,
  SetupStep.routine => 2,
  SetupStep.reminders => 3,
  _ => null,
};

/// What the organiser showed: its full compartments and the outlined one.
typedef SetupOrganiserShown = ({int filled, int? current});

/// What the first-run organiser last showed for a draft. Setup's page is
/// built anew each time a step saves (the launch screen reloads the draft),
/// so this outlives it and lets the next organiser move on from there. It
/// never notifies: it is only read and written while building.
class SetupOrganiserMemory {
  String? _draft;
  SetupOrganiserShown? _shown;

  /// Records [shown] for [draft] and returns what was shown before, or null
  /// when this draft has shown nothing yet.
  SetupOrganiserShown? swap(String draft, SetupOrganiserShown shown) {
    final before = draft == _draft ? _shown : null;
    _draft = draft;
    _shown = shown;
    return before;
  }
}

final setupOrganiserMemoryProvider = Provider<SetupOrganiserMemory>(
  (ref) => SetupOrganiserMemory(),
);

/// The organiser's base as a line on the glass, once it has laid flat.
typedef SetupOrganiserLine = ({Offset from, Offset to, Color color});

/// The first-run header: a pill organiser with one lidded compartment per
/// setup step (person, medication, routine, reminders). Each saved step
/// drops a capsule into its compartment and the lid clicks shut with a light
/// haptic; going back opens the lid and lifts the capsule out. [finish] has
/// the lids ripple shut and the organiser lay flat into a line. Purely
/// decorative; quiet mode shows each state at once. Nothing runs at rest.
class SetupOrganiser extends StatefulWidget {
  const SetupOrganiser({
    super.key,
    required this.filled,
    this.current,
    this.from,
    this.height = 96,
  });

  /// Compartments holding a capsule, from the left.
  final int filled;

  /// The compartment being filled in now; it is outlined in the accent.
  final int? current;

  /// What an earlier organiser showed before this one replaced it (setup
  /// rebuilds its page while a step saves); it starts there and moves on.
  /// Null starts at rest.
  final SetupOrganiserShown? from;
  final double height;

  /// The compartment outlined for [filled] and [current]: before the first
  /// at the welcome, past the last at the finish.
  static int focusOf(int filled, int? current) =>
      current ?? (filled >= count ? count : -1);

  static const count = 4;
  static const drop = Duration(milliseconds: 560);
  static const lift = Duration(milliseconds: 420);
  static const finishing = Duration(milliseconds: 860);

  @override
  State<SetupOrganiser> createState() => SetupOrganiserState();
}

class SetupOrganiserState extends State<SetupOrganiser>
    with TickerProviderStateMixin {
  late final List<AnimationController> _fill = [
    for (var i = 0; i < SetupOrganiser.count; i++)
      AnimationController(
        vsync: this,
        duration: SetupOrganiser.drop,
        reverseDuration: SetupOrganiser.lift,
        value: i < (widget.from?.filled ?? widget.filled) ? 1 : 0,
      )..addStatusListener(_clicked),
  ];
  late final AnimationController _finish = AnimationController(
    vsync: this,
    duration: SetupOrganiser.finishing,
  )..addListener(_rippleClick);
  bool _rippled = false;
  bool _started = false;

  void _clicked(AnimationStatus status) {
    // The lid has just shut on a capsule.
    if (status == AnimationStatus.completed) HapticFeedback.lightImpact();
  }

  void _rippleClick() {
    if (_rippled || _finish.value < OrganiserPainter.rippleEnd) return;
    _rippled = true;
    HapticFeedback.lightImpact();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.from != null) _follow();
  }

  @override
  void didUpdateWidget(SetupOrganiser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filled != widget.filled) _follow();
  }

  void _follow() {
    final quiet = AppMotion.quiet(context);
    for (var i = 0; i < _fill.length; i++) {
      final full = i < widget.filled;
      final c = _fill[i];
      if (full ==
          (c.status == AnimationStatus.forward ||
              c.status == AnimationStatus.completed)) {
        continue;
      }
      if (quiet) {
        c.value = full ? 1 : 0;
      } else if (full) {
        c.forward();
      } else {
        c.reverse();
      }
    }
  }

  /// Ripples the lids shut and lays the organiser flat, then says where its
  /// line is on the glass. Null in quiet mode or when it is not laid out.
  Future<SetupOrganiserLine?> finish() async {
    if (AppMotion.quiet(context)) return null;
    try {
      await _finish.forward(from: 0).orCancel;
    } on TickerCanceled {
      return null;
    }
    if (!mounted) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final g = OrganiserGeometry(box.size);
    return (
      from: box.localToGlobal(Offset(g.plateLeft, g.base)),
      to: box.localToGlobal(Offset(g.plateRight, g.base)),
      color: Theme.of(context).colorScheme.primary,
    );
  }

  @override
  void dispose() {
    for (final c in _fill) {
      c.dispose();
    }
    _finish.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    // At the welcome nothing is outlined yet; at the finish the outline has
    // moved past the last compartment.
    final focus = SetupOrganiser.focusOf(widget.filled, widget.current);
    final from = widget.from;
    return ExcludeSemantics(
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: RepaintBoundary(
          child: TweenAnimationBuilder<double>(
            tween: Tween(
              begin: from == null
                  ? null
                  : SetupOrganiser.focusOf(
                      from.filled,
                      from.current,
                    ).toDouble(),
              end: focus.toDouble(),
            ),
            duration: AppMotion.duration(
              context,
              milliseconds: AppMotion.standard.inMilliseconds,
            ),
            curve: Curves.easeOutCubic,
            builder: (context, focus, _) => CustomPaint(
              painter: OrganiserPainter(
                fill: [for (final c in _fill) c],
                finish: _finish,
                focus: focus,
                edge: cs.outline,
                accent: cs.primary,
                glass: Color.alphaBlend(
                  cs.onSurface.withValues(alpha: .04),
                  cs.surface,
                ),
                tint: cs.primaryContainer,
                capsule: cs.primaryContainer,
                capsuleEdge: light ? FocusTokens.violet : cs.primary,
                // Outline grey turns heavy as a fill on a light page.
                shade: light ? cs.outlineVariant : cs.outline,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where the organiser's parts sit in a box of [size]. The organiser is
/// seen from the front and a little above, so each compartment shows its
/// front face, the band of its top, and a lid standing up behind it when
/// open.
@immutable
class OrganiserGeometry {
  factory OrganiserGeometry(Size size) {
    final base = size.height - 3;
    final width = math.min(
      (base - headroom) / (front + top + lift),
      (size.width - 24) / (SetupOrganiser.count + 3 * gapShare),
    );
    final gap = width * gapShare;
    final total = SetupOrganiser.count * width + 3 * gap;
    return OrganiserGeometry._(
      base: base,
      width: width,
      gap: gap,
      left: (size.width - total) / 2,
      total: total,
    );
  }

  const OrganiserGeometry._({
    required this.base,
    required this.width,
    required this.gap,
    required this.left,
    required this.total,
  });

  static const gapShare = .16;

  /// Room above an open lid for its pull tab and outline.
  static const headroom = 8.0;

  /// Heights as shares of a compartment's width: its front face, the band
  /// of its top seen from above, and how far an open lid stands over it.
  static const front = .56, top = .3, lift = .84;

  /// The floor the compartments stand on.
  final double base;

  /// One compartment's width, and the space between two.
  final double width, gap;
  final double left, total;

  /// The front edge of the top, and its back edge where the lids hinge.
  double get rim => base - width * front;
  double get hinge => rim - width * top;
  double leftOf(int i) => left + i * (width + gap);

  /// The plate under the compartments: what is left once it lies flat.
  double get plateLeft => left - gap * .6;
  double get plateRight => left + total + gap * .6;
}

/// Paints [SetupOrganiser]: translucent compartments on a plate, each with
/// a lid hinged along its back edge, and a capsule that falls in.
class OrganiserPainter extends CustomPainter {
  OrganiserPainter({
    required this.fill,
    required this.finish,
    required this.focus,
    required this.edge,
    required this.accent,
    required this.glass,
    required this.tint,
    required this.capsule,
    required this.capsuleEdge,
    required this.shade,
  }) : super(repaint: Listenable.merge([...fill, finish]));

  /// Per compartment: 0 empty with the lid open, 1 a capsule in and shut.
  final List<Animation<double>> fill;

  /// The finish: lids ripple shut, then everything lays flat on the plate.
  final Animation<double> finish;

  /// The compartment index outlined in the accent; fractions slide it.
  final double focus;
  final Color edge, accent, glass, tint, capsule, capsuleEdge;

  /// What shades an open compartment's inside and its standing lid.
  final Color shade;

  /// How far an empty compartment's lid stands open, past upright.
  static const open = 98 * math.pi / 180;

  /// How far a lid lifts as the ripple passes it.
  static const ripple = 30 * math.pi / 180;

  /// How far above the organiser it is seen from.
  static const _view = 20 * math.pi / 180;

  /// The share of [finish] by which the last lid has clapped shut.
  static const rippleEnd = .58;

  /// The capsule's fall, as a share of a fill.
  static const fallEnd = .6;

  /// Where the lid starts shutting, as a share of a fill.
  static const shutStart = .52;

  /// The lid's angle at fill [f] (0 shut).
  @visibleForTesting
  static double lidAt(double f) {
    final q = ((f - shutStart) / (1 - shutStart)).clamp(0.0, 1.0);
    return open * (1 - Curves.easeIn.transform(q));
  }

  /// How far the ripple lifts lid [i] at finish time [t].
  @visibleForTesting
  static double rippleAt(int i, double t) {
    final u = ((t - i * .09) / .31).clamp(0.0, 1.0);
    return ripple * math.sin(math.pi * u);
  }

  /// How flat the organiser lies at finish time [t], 0 standing.
  @visibleForTesting
  static double flatAt(double t) =>
      Curves.easeInOutCubic.transform(((t - .5) / .5).clamp(0.0, 1.0));

  @override
  void paint(Canvas canvas, Size size) {
    final g = OrganiserGeometry(size);
    final t = finish.value;
    final flat = flatAt(t);
    final stand = 1 - flat;
    final w = g.width;

    // The plate: once everything has laid flat it is the line that goes on.
    final plate = lerpDouble(3.2, 2, flat)!;
    canvas.drawRRect(
      RRect.fromLTRBR(
        g.plateLeft,
        g.base - plate / 2,
        g.plateRight,
        g.base + plate / 2,
        Radius.circular(plate),
      ),
      Paint()..color = Color.lerp(edge.withValues(alpha: .7), accent, flat)!,
    );
    if (stand <= 0) return;

    // Laying flat folds every compartment down onto the plate.
    canvas.save();
    canvas.translate(0, g.base);
    canvas.scale(1, stand);
    canvas.translate(0, -g.base);
    final band = g.rim - g.hinge;
    final r = Radius.circular(w * .12);
    for (var i = 0; i < fill.length; i++) {
      final f = fill[i].value;
      final x = g.leftOf(i);
      final lit = math.max((1 - (focus - i).abs()).clamp(0.0, 1.0), f);
      final line = Color.lerp(edge, accent, lit)!;
      final outline = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round
        ..color = line;

      // The lid, hinged along the back edge: standing up it is behind
      // the compartment and shows its inside; shut it covers the top.
      final angle = lidAt(f) + (f > 0 ? rippleAt(i, t) * f : 0);
      final edgeY = g.hinge + band * _lidReach(angle);
      final lidRect = RRect.fromLTRBR(
        x - 1,
        math.min(g.hinge, edgeY),
        x + w + 1,
        math.max(g.hinge, edgeY),
        r,
      );
      final shut = edgeY > g.hinge;
      final lidColor = Color.lerp(edge, accent, math.max(lit, f))!;
      void paintLid() {
        canvas.drawRRect(
          lidRect,
          Paint()
            ..color = shut
                ? lidColor
                : Color.alphaBlend(
                    Color.lerp(
                      shade,
                      accent,
                      math.max(lit, f),
                    )!.withValues(alpha: .18),
                    glass,
                  ),
        );
        canvas.drawRRect(
          lidRect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = lidColor,
        );
        // A pull tab on the free edge.
        final tab = w * .1;
        canvas.drawRRect(
          RRect.fromLTRBR(
            x + w / 2 - tab,
            shut ? edgeY - 1 : edgeY - tab * .7,
            x + w / 2 + tab,
            shut ? edgeY + tab * .7 : edgeY + 1,
            Radius.circular(tab),
          ),
          Paint()..color = lidColor,
        );
      }

      if (!shut) paintLid();

      // The top, seen from above: the dark opening while the lid is up.
      final opening = RRect.fromLTRBR(x, g.hinge, x + w, g.rim + r.x, r);
      canvas.drawRRect(
        opening,
        Paint()..color = Color.alphaBlend(shade.withValues(alpha: .22), glass),
      );
      canvas.drawRRect(opening, outline);

      // The capsule falls through the opening and comes to rest inside.
      final p = (f / fallEnd).clamp(0.0, 1.0);
      final cw = w * .6, ch = w * .24;
      final rest = g.base - w * OrganiserGeometry.front * .42;
      if (p > 0) {
        final from = g.hinge - w * .9;
        final y = lerpDouble(from, rest, Curves.easeIn.transform(p))!;
        final alpha = (p * 3).clamp(0.0, 1.0);
        canvas.save();
        canvas.translate(x + w / 2, y);
        canvas.rotate((i.isEven ? -8 : 7) * math.pi / 180);
        final body = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: cw, height: ch),
          Radius.circular(ch),
        );
        final ink = capsuleEdge.withValues(alpha: capsuleEdge.a * alpha);
        canvas.drawRRect(
          body,
          Paint()..color = capsule.withValues(alpha: capsule.a * alpha),
        );
        canvas.drawRRect(
          body,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3
            ..color = ink,
        );
        canvas.drawLine(
          Offset(0, -ch / 2 + 1),
          Offset(0, ch / 2 - 1),
          Paint()
            ..strokeWidth = 1.3
            ..color = ink,
        );
        canvas.restore();
      }

      // The front face, clear enough to see the capsule through.
      final face = RRect.fromLTRBAndCorners(
        x,
        g.rim,
        x + w,
        g.base - 1,
        bottomLeft: r,
        bottomRight: r,
      );
      canvas.drawRRect(
        face,
        Paint()
          ..color = Color.lerp(
            glass,
            tint,
            f * .5,
          )!.withValues(alpha: f > 0 ? .4 : .9),
      );
      canvas.drawRRect(face, outline);

      if (shut) paintLid();
    }
    canvas.restore();
  }

  /// Where a lid's free edge stands at [angle], in bands of the top below
  /// the hinge: 1 when shut over the top, 0 edge-on, negative standing up.
  static double _lidReach(double angle) =>
      (math.cos(angle) * math.sin(_view) - math.sin(angle) * math.cos(_view)) /
      math.sin(_view);

  @override
  bool shouldRepaint(OrganiserPainter old) =>
      old.focus != focus ||
      old.finish != finish ||
      old.edge != edge ||
      old.accent != accent ||
      old.glass != glass ||
      old.tint != tint ||
      old.capsule != capsule ||
      old.capsuleEdge != capsuleEdge ||
      old.shade != shade ||
      old.fill.length != fill.length ||
      [
        for (var i = 0; i < fill.length; i++) old.fill[i] != fill[i],
      ].any((changed) => changed);
}
