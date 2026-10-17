import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../motion/app_motion.dart';
import '../scene/dose_bead.dart';
import '../scene/horizon_scene.dart';

/// Today's sky fills this in while it is mounted; the shell reads its arc.
final todaySkyLocatorProvider = Provider<HorizonMarkLocator>(
  (ref) => HorizonMarkLocator(),
);

/// True while setup's finish draws its line onto Today's arc: Today's sky
/// waits to rise until the line has arrived.
final todaySunriseHoldProvider = Provider<ValueNotifier<bool>>((ref) {
  final hold = ValueNotifier(false);
  ref.onDispose(hold.dispose);
  return hold;
});

/// History's day line fills this in while it is mounted.
final historyLineLocatorProvider = Provider<HandOffLineLocator>((ref) {
  final locator = HandOffLineLocator();
  ref.onDispose(locator.dispose);
  return locator;
});

/// A day drawn as a straight line, where it stands on the glass.
@immutable
class HandOffLine {
  const HandOffLine({
    required this.at,
    required this.color,
    required this.pin,
    this.now,
  });

  /// Where [minute] of the day sits on the line, in global coordinates,
  /// held to the line's ends.
  final Offset Function(double minute) at;
  final Color color, pin;

  /// The minute of the "now" pin, when the line shows today.
  final int? now;
}

/// Lets the shell find a day line on the glass and veil it while the
/// hand-off draws over it.
class HandOffLineLocator {
  HandOffLine? Function()? _resolve;

  /// 1 hides the line, 0 shows it. Only the hand-off sets it.
  final ValueNotifier<double> veil = ValueNotifier(0);

  void attach(HandOffLine? Function() resolve) => _resolve = resolve;

  void detach(HandOffLine? Function() resolve) {
    if (_resolve == resolve) _resolve = null;
  }

  /// The line as it stands now, or null when it is not on screen.
  HandOffLine? line() => _resolve?.call();

  void dispose() => veil.dispose();
}

/// Moves between the shell's tabs. Every change fades the new tab in. Going
/// from Today to History also lays Today's day arc flat onto History's day
/// line, and the sun sets into it as the "now" pin. Quiet mode changes tab
/// at once. Nothing runs at rest.
class TabHandOff extends ConsumerStatefulWidget {
  const TabHandOff({
    super.key,
    required this.index,
    required this.child,
    this.today = 0,
    this.history = 2,
  });

  final int index;
  final Widget child;

  /// Branch indexes of Today and History.
  final int today, history;

  static const fade = Duration(milliseconds: 200);
  static const flight = Duration(milliseconds: 560);

  @override
  ConsumerState<TabHandOff> createState() => _TabHandOffState();
}

class _TabHandOffState extends ConsumerState<TabHandOff>
    with TickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: TabHandOff.fade,
    value: 1,
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _fade,
    curve: Curves.easeOut,
  );
  late final AnimationController _flight = AnimationController(
    vsync: this,
    duration: TabHandOff.flight,
  );
  late final HandOffLineLocator _line;
  ({HorizonArc arc, HandOffLine line, Offset origin})? _route;

  @override
  void initState() {
    super.initState();
    _line = ref.read(historyLineLocatorProvider);
    // The line shows through again only as the drawn one fades, so the
    // swap is never seen.
    _flight.addListener(() => _line.veil.value = 1 - fadeOutAt(_flight.value));
    _flight.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      _line.veil.value = 0;
      setState(() => _route = null);
    });
  }

  /// How far the drawn line has faded at flight time [t].
  static double fadeOutAt(double t) => ((t - .7) / .3).clamp(0.0, 1.0);

  @override
  void didUpdateWidget(TabHandOff old) {
    super.didUpdateWidget(old);
    if (old.index == widget.index) return;
    _flight.stop();
    _route = null;
    _line.veil.value = 0;
    if (AppMotion.quiet(context)) {
      _fade.value = 1;
      return;
    }
    // From a little above nothing, so the change never flashes blank.
    _fade.forward(from: .2);
    if (old.index != widget.today || widget.index != widget.history) return;
    // Today is still laid out where it was: read its arc before it goes.
    final arc = ref.read(todaySkyLocatorProvider).arc();
    if (arc == null) return;
    _line.veil.value = 1;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final line = mounted && widget.index == widget.history
          ? _line.line()
          : null;
      final box = mounted ? context.findRenderObject() : null;
      if (line == null || box is! RenderBox || !box.hasSize) {
        _line.veil.value = 0;
        return;
      }
      setState(
        () => _route = (
          arc: arc,
          line: line,
          origin: box.localToGlobal(Offset.zero),
        ),
      );
      _flight.forward(from: 0);
    });
  }

  @override
  void dispose() {
    if (_line.veil.value != 0) _line.veil.value = 0;
    _fade.dispose();
    _flight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final route = _route;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        FadeTransition(opacity: _opacity, child: widget.child),
        if (route != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                key: const ValueKey('tab-hand-off'),
                painter: HandOffPainter(
                  flight: _flight,
                  arc: route.arc,
                  line: route.line,
                  origin: route.origin,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Draws Today's arc laying itself flat onto History's line: every minute
/// of the day travels from its place on the arc to its place on the line,
/// and the sun sinks into the line where "now" is.
class HandOffPainter extends CustomPainter {
  HandOffPainter({
    required this.flight,
    required this.arc,
    required this.line,
    required this.origin,
  }) : super(repaint: flight);

  final Animation<double> flight;
  final HorizonArc arc;
  final HandOffLine line;

  /// The painter's own top-left in global coordinates.
  final Offset origin;

  static const samples = 64;

  @override
  void paint(Canvas canvas, Size size) {
    final t = flight.value;
    final k = Curves.easeInOutCubic.transform(t);
    final shown = 1 - _TabHandOffState.fadeOutAt(t);
    if (shown <= 0) return;
    Offset morph(double share) =>
        Offset.lerp(arc.at(share), line.at(share * 1440), k)! - origin;

    final path = Path();
    for (var i = 0; i <= samples; i++) {
      final p = morph(i / samples);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    final color = Color.lerp(arc.line, line.color, k)!;
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = lerpDouble(1.5, 1.3, k)!
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: color.a * shown),
    );

    final sun = arc.sun;
    if (sun == null) return;
    // The sun sets a little ahead of the line, so it lands as the pin's head.
    final now = line.now;
    final share = now != null ? now / 1440 : arc.now;
    // It starts moving at once and lands by the time the line is flat,
    // keeping its size on the way and shrinking into the pin at the end.
    final u = (t / .7).clamp(0.0, 1.0);
    final s = Curves.easeOutCubic.transform(u);
    final base = morph(share);
    final head = base.translate(0, -9 * s);
    final c = Offset.lerp(sun - origin, head, s)!;
    final r = lerpDouble(11, 2.6, Curves.easeIn.transform(u))!;
    // Without a pin to become (another day is shown) the sun just goes out.
    final alpha = shown * (now == null ? 1 - s : 1);
    final tint = Color.lerp(arc.sunColor, line.pin, s)!;
    if (s < 1) {
      canvas.drawCircle(
        c,
        r * 3.2,
        Paint()
          ..shader = RadialGradient(
            colors: [
              arc.sunColor.withValues(alpha: .38 * (1 - s) * alpha),
              arc.sunColor.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: r * 3.2)),
      );
    }
    if (now != null && s > .55) {
      final stem = ((s - .55) / .45).clamp(0.0, 1.0);
      paintNowPin(
        canvas,
        base,
        color: line.pin.withValues(alpha: line.pin.a * stem * alpha),
        r: 0,
      );
    }
    canvas.drawCircle(
      c,
      r,
      Paint()..color = tint.withValues(alpha: tint.a * alpha),
    );
  }

  @override
  bool shouldRepaint(HandOffPainter old) =>
      old.arc != arc ||
      old.line != line ||
      old.origin != origin ||
      old.flight != flight;
}
