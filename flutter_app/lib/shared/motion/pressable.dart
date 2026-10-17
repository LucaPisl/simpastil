import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show kTouchSlop;

import 'app_motion.dart';

/// Physical press feedback: the surface sinks on a spring and a soft inner
/// highlight blooms from the touch point.
///
/// Driven by tap-down / tap-cancel, so inside a scrollable the press is
/// released as soon as a drag wins the gesture arena. A quick tap that
/// resolves before the press became visible still plays a short press pulse.
/// No tilt. Quiet mode keeps the highlight (state feedback) but drops scale.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.pressedScale = .975,
    this.radius,
  });

  final Widget child;

  /// When null the child's own controls handle taps: the press is then read
  /// from raw pointers (released past touch slop), never joins the gesture
  /// arena and adds no semantics, so it cannot steal a tap from the child or
  /// an ancestor.
  final VoidCallback? onTap;
  final double pressedScale;

  /// Clip for the inner highlight; match the child's shape.
  final BorderRadius? radius;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable>
    with SingleTickerProviderStateMixin {
  // 0 = at rest, 1 = fully pressed; the spring may briefly overshoot.
  late final AnimationController _press = AnimationController.unbounded(
    vsync: this,
  );
  final ValueNotifier<Offset?> _touch = ValueNotifier(null);
  bool _held = false;
  Offset? _pointerOrigin;

  @override
  void dispose() {
    _press.dispose();
    _touch.dispose();
    super.dispose();
  }

  void _springTo(double target) {
    if (AppMotion.quiet(context)) {
      _press.value = target;
      return;
    }
    _press.animateWith(
      SpringSimulation(AppMotion.spring, _press.value, target, _press.velocity),
    );
  }

  void _down(TapDownDetails details) {
    _held = true;
    _touch.value = details.localPosition;
    _springTo(1);
  }

  void _release() {
    if (!_held) return;
    _held = false;
    _springTo(0);
  }

  void _up(TapUpDetails details) {
    if (!_held) return;
    _held = false;
    if (AppMotion.quiet(context) || _press.value >= .6) {
      _springTo(0);
      return;
    }
    // Released before the press was felt: sink quickly, then spring back.
    _press
        .animateTo(1, duration: AppMotion.micro ~/ 2, curve: Curves.easeOut)
        .whenCompleteOrCancel(() {
          if (mounted && !_held) _springTo(0);
        });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final quiet = AppMotion.quiet(context);
    final radius = widget.radius ?? BorderRadius.zero;
    Widget surface = CustomPaint(
      foregroundPainter: _InnerHighlightPainter(
        press: _press,
        touch: _touch,
        color: scheme.primary,
        radius: radius,
      ),
      child: widget.child,
    );
    if (!quiet) {
      surface = AnimatedBuilder(
        animation: _press,
        builder: (context, child) => Transform.scale(
          scale: 1 - (1 - widget.pressedScale) * _press.value,
          child: child,
        ),
        child: surface,
      );
    }
    if (widget.onTap == null) {
      return Listener(
        onPointerDown: (event) {
          _pointerOrigin = event.position;
          _down(TapDownDetails(localPosition: event.localPosition));
        },
        onPointerMove: (event) {
          final origin = _pointerOrigin;
          if (origin != null &&
              (event.position - origin).distance > kTouchSlop) {
            _pointerOrigin = null;
            _release();
          }
        },
        onPointerUp: (event) {
          if (_pointerOrigin == null) return;
          _pointerOrigin = null;
          _up(TapUpDetails(kind: event.kind));
        },
        onPointerCancel: (_) {
          _pointerOrigin = null;
          _release();
        },
        child: surface,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _down,
      onTapUp: _up,
      onTapCancel: _release,
      onTap: widget.onTap,
      child: surface,
    );
  }
}

class _InnerHighlightPainter extends CustomPainter {
  _InnerHighlightPainter({
    required this.press,
    required this.touch,
    required this.color,
    required this.radius,
  }) : super(repaint: Listenable.merge([press, touch]));

  final Animation<double> press;
  final ValueListenable<Offset?> touch;
  final Color color;
  final BorderRadius radius;

  static const maxAlpha = .10;

  @override
  void paint(Canvas canvas, Size size) {
    final strength = press.value.clamp(0.0, 1.0);
    if (strength <= 0.001 || size.isEmpty) return;
    final rect = Offset.zero & size;
    final center = touch.value ?? rect.center;
    final reach = math.max(size.width, size.height) * .9;
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          color.withValues(alpha: maxAlpha * strength),
          color.withValues(alpha: maxAlpha * .35 * strength),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: reach));
    canvas.drawRRect(radius.toRRect(rect), paint);
  }

  @override
  bool shouldRepaint(_InnerHighlightPainter old) =>
      old.color != color || old.radius != radius;
}
