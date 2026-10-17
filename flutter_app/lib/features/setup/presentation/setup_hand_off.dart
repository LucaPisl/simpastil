import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/tab_hand_off.dart';
import '../../../shared/scene/horizon_scene.dart';
import 'setup_organiser.dart';

/// Carries the setup organiser's flattened [line] onto Today's day arc as
/// Today appears. The line is drawn above every page, so it stays put while
/// setup gives way to Today. Today's sky is held until the line has
/// arrived and then rises by itself, so the sun is only ever drawn by
/// Today. Call it right before going to Today, with the root [overlay] and
/// Today's sunrise [hold] taken while setup is still mounted.
void startSetupHandOff(
  OverlayState overlay,
  ValueNotifier<bool> hold,
  SetupOrganiserLine line,
) {
  hold.value = true;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => SetupHandOff(
      line: line,
      onDone: () => entry
        ..remove()
        ..dispose(),
    ),
  );
  overlay.insert(entry);
}

/// The line on its way from setup to Today's arc. It waits up to [wait] for
/// the arc to be on screen, then bends onto it in [flight], following the
/// arc while Today's page settles, and fades as the real path rises under
/// it. Without an arc it simply fades. It releases the hold on Today's sky
/// however it ends.
class SetupHandOff extends ConsumerStatefulWidget {
  const SetupHandOff({super.key, required this.line, required this.onDone});

  final SetupOrganiserLine line;
  final VoidCallback onDone;

  static const wait = Duration(milliseconds: 900);
  static const flight = Duration(milliseconds: 620);
  static const fade = Duration(milliseconds: 240);

  @override
  ConsumerState<SetupHandOff> createState() => _SetupHandOffState();
}

class _SetupHandOffState extends ConsumerState<SetupHandOff>
    with TickerProviderStateMixin {
  late final ValueNotifier<bool> _hold;
  late final HorizonMarkLocator _sky;
  late final AnimationController _wait = AnimationController(
    vsync: this,
    duration: SetupHandOff.wait,
  );
  late final AnimationController _flight = AnimationController(
    vsync: this,
    duration: SetupHandOff.flight,
  );
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: SetupHandOff.fade,
    value: 1,
  );
  HorizonArc? _arc;
  Offset _origin = Offset.zero;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _hold = ref.read(todaySunriseHoldProvider);
    _sky = ref.read(todaySkyLocatorProvider);
    _wait
      ..addListener(_look)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _fadeAway();
      });
    _flight
      ..addListener(_follow)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _finish();
      });
    _fade.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) _finish();
    });
    _wait.forward();
  }

  void _place() {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      _origin = box.localToGlobal(Offset.zero);
    }
  }

  void _look() {
    final arc = _sky.arc();
    if (arc == null) return;
    _place();
    _arc = arc;
    _wait.stop();
    _flight.forward();
  }

  void _follow() {
    // Today's page may still be settling: keep bending onto where the arc
    // is now.
    _arc = _sky.arc() ?? _arc;
    if (_flight.value >= SetupHandOffPainter.fadeFrom) _hold.value = false;
  }

  void _fadeAway() {
    _hold.value = false;
    _fade.reverse();
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _hold.value = false;
    widget.onDone();
  }

  @override
  void dispose() {
    if (_hold.value) _hold.value = false;
    _wait.dispose();
    _flight.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedBuilder(
      animation: Listenable.merge([_flight, _fade]),
      builder: (context, _) => CustomPaint(
        key: const ValueKey('setup-hand-off'),
        size: Size.infinite,
        painter: SetupHandOffPainter(
          line: widget.line,
          arc: _arc,
          t: _flight.value,
          shown: _fade.value,
          origin: _origin,
        ),
      ),
    ),
  );
}

/// Draws the organiser's line bending onto Today's arc: every point along
/// the line travels to the same share of the day on the arc.
class SetupHandOffPainter extends CustomPainter {
  const SetupHandOffPainter({
    required this.line,
    required this.arc,
    required this.t,
    required this.shown,
    this.origin = Offset.zero,
  });

  final SetupOrganiserLine line;
  final HorizonArc? arc;

  /// The flight, 0 on the organiser and 1 on the arc.
  final double t;

  /// 1 drawn, 0 gone (the fade when no arc came).
  final double shown;

  /// The painter's own top-left in global coordinates.
  final Offset origin;

  static const samples = 64;

  /// The share of the flight from which the line fades into the real path.
  static const fadeFrom = .7;

  /// Where share [s] of the line is on its way to the arc, [k] of the way
  /// there.
  @visibleForTesting
  static Offset pointAt(
    SetupOrganiserLine line,
    HorizonArc? arc,
    double s,
    double k,
  ) {
    final flat = Offset.lerp(line.from, line.to, s)!;
    return arc == null ? flat : Offset.lerp(flat, arc.at(s), k)!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final k = Curves.easeInOutCubic.transform(t);
    final alpha = shown * (1 - ((t - fadeFrom) / (1 - fadeFrom)).clamp(0, 1));
    if (alpha <= 0) return;
    final arc = this.arc;
    final path = Path();
    for (var i = 0; i <= samples; i++) {
      final p = pointAt(line, arc, i / samples, k) - origin;
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    final color = arc == null
        ? line.color
        : Color.lerp(line.color, arc.line, k)!;
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = lerpDouble(2, 1.5, k)!
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color.withValues(alpha: color.a * alpha),
    );
  }

  @override
  bool shouldRepaint(SetupHandOffPainter old) =>
      old.line != line ||
      old.arc != arc ||
      old.t != t ||
      old.shown != shown ||
      old.origin != origin;
}
