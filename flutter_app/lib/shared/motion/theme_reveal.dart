import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme/focus_tokens.dart';
import 'app_motion.dart';

/// Lets a new look spread across the whole app from the control that asked
/// for it: the old frame is held as a picture, and a circle of the new
/// appearance grows out of that control until it covers the screen.
///
/// Sits above the app, so it covers every route, dialog and banner. It costs
/// nothing at rest: the picture and the ticker exist only during a reveal.
class ThemeReveal extends StatefulWidget {
  const ThemeReveal({super.key, required this.child});
  final Widget child;

  static const duration = Duration(milliseconds: 820);

  /// The reveal above [context], or null where the app does not offer one
  /// (tests that mount a screen on its own).
  static ThemeRevealState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<ThemeRevealState>();

  @override
  State<ThemeReveal> createState() => ThemeRevealState();
}

class ThemeRevealState extends State<ThemeReveal>
    with SingleTickerProviderStateMixin {
  final _boundary = GlobalKey();
  late final AnimationController _spread;
  late final CurvedAnimation _curve;
  ui.Image? _old;
  Offset _origin = Offset.zero;

  @override
  void initState() {
    super.initState();
    _spread = AnimationController(vsync: this, duration: ThemeReveal.duration);
    _curve = CurvedAnimation(parent: _spread, curve: Curves.easeInOutCubic);
  }

  /// Whether an earlier frame is currently held over the app.
  bool get revealing => _old != null;

  /// Runs [change] behind a picture of the current frame, then uncovers the
  /// result from the centre of [from]. With quiet motion, or when the frame
  /// cannot be captured, [change] simply runs.
  Future<T> reveal<T>({
    required BuildContext from,
    required Future<T> Function() change,
  }) async {
    if (AppMotion.quiet(from) || revealing) return change();
    final ratio = View.of(context).devicePixelRatio;
    final image = await _capture(ratio);
    if (image == null || !mounted) {
      image?.dispose();
      return change();
    }
    // Where the control sat in the captured frame.
    final origin = from.mounted ? _originOf(from) : _centre();
    setState(() {
      _old = image;
      _origin = origin;
    });
    _spread.value = 0;
    try {
      final result = await change();
      if (mounted) {
        try {
          await _spread.forward().orCancel;
        } on TickerCanceled {
          // The app went away mid-reveal; the change itself is done.
        }
      }
      return result;
    } finally {
      _release();
    }
  }

  Offset _centre() =>
      ((context.findRenderObject() as RenderBox?)?.size ?? Size.zero).center(
        Offset.zero,
      );

  Offset _originOf(BuildContext from) {
    final self = context.findRenderObject() as RenderBox?;
    final box = from.findRenderObject() as RenderBox?;
    if (box == null || self == null || !box.attached) return _centre();
    return self.globalToLocal(box.localToGlobal(box.size.center(Offset.zero)));
  }

  Future<ui.Image?> _capture(double ratio) async {
    try {
      // The frame that is on screen now, not one still being laid out.
      await WidgetsBinding.instance.endOfFrame;
      final boundary =
          _boundary.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null || !boundary.attached) return null;
      return await boundary.toImage(pixelRatio: ratio);
    } on Object {
      return null;
    }
  }

  void _release() {
    final old = _old;
    if (old == null) return;
    if (mounted) setState(() => _old = null);
    old.dispose();
  }

  @override
  void dispose() {
    _curve.dispose();
    _spread.dispose();
    _old?.dispose();
    _old = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final old = _old;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          RepaintBoundary(key: _boundary, child: widget.child),
          if (old != null)
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: CustomPaint(
                    key: const ValueKey('theme-reveal'),
                    painter: ThemeRevealPainter(
                      old: old,
                      origin: _origin,
                      spread: _curve,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Paints the earlier frame everywhere outside a growing circle, with a soft
/// violet rim where the new appearance meets the old.
class ThemeRevealPainter extends CustomPainter {
  ThemeRevealPainter({
    required this.old,
    required this.origin,
    required this.spread,
  }) : super(repaint: spread);

  final ui.Image old;
  final Offset origin;
  final Animation<double> spread;

  /// The radius that covers the whole of [size] from [origin].
  static double reach(Size size, Offset origin) => [
    Offset.zero,
    size.topRight(Offset.zero),
    size.bottomLeft(Offset.zero),
    size.bottomRight(Offset.zero),
  ].map((corner) => (corner - origin).distance).reduce(math.max);

  @override
  void paint(Canvas canvas, Size size) {
    final t = spread.value;
    final radius = reach(size, origin) * t;
    final whole = Offset.zero & size;
    final circle = Rect.fromCircle(center: origin, radius: radius);

    canvas.save();
    canvas.clipPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(whole),
        Path()..addOval(circle),
      ),
    );
    canvas.drawImageRect(
      old,
      Offset.zero & Size(old.width.toDouble(), old.height.toDouble()),
      whole,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();

    if (radius <= 0) return;
    // The rim glows brightest early and is gone as the circle covers all.
    final fade = (1 - t) * math.min(1, t * 6);
    canvas.drawCircle(
      origin,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10)
        ..color = FocusTokens.violet.withValues(alpha: .34 * fade),
    );
    canvas.drawCircle(
      origin,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = FocusTokens.lavender.withValues(alpha: .8 * fade),
    );
  }

  @override
  bool shouldRepaint(ThemeRevealPainter old) =>
      old.old != this.old || old.origin != origin;
}
