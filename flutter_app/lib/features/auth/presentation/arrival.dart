import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../../shared/motion/app_motion.dart';
import '../../../shared/theme/focus_tokens.dart';

/// The quiet ground behind connecting to a server: the page colour with a
/// violet glow above the mark, in either theme.
class ArrivalBackdrop extends StatelessWidget {
  const ArrivalBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final surface = theme.colorScheme.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface,
        gradient: RadialGradient(
          center: const Alignment(0, -1.05),
          radius: 1.25,
          colors: [
            FocusTokens.violet.withValues(alpha: dark ? .30 : .16),
            (dark ? FocusTokens.violet : FocusTokens.lavender).withValues(
              alpha: dark ? .07 : .34,
            ),
            surface,
          ],
          stops: const [0, .45, 1],
        ),
      ),
      child: SizedBox.expand(child: child),
    );
  }
}

/// The connection drawn as a path: this phone, then the server, the key and
/// the account. Each step the person completes extends the line to the next
/// station, which takes its check as the line arrives.
///
/// Decorative: the step is always also said in words next to it.
class ConnectionPath extends StatefulWidget {
  const ConnectionPath({super.key, required this.reached});

  /// Stations already passed: 0 on the server step, 1 on the key step,
  /// 2 on the account step.
  final int reached;

  static const stations = 3;

  @override
  State<ConnectionPath> createState() => _ConnectionPathState();
}

class _ConnectionPathState extends State<ConnectionPath>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reach = AnimationController(
    vsync: this,
    upperBound: ConnectionPath.stations.toDouble(),
    value: widget.reached.toDouble(),
  );

  @override
  void didUpdateWidget(ConnectionPath oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reached == widget.reached) return;
    final target = widget.reached.toDouble();
    if (AppMotion.quiet(context)) {
      _reach.value = target;
      return;
    }
    final forward = widget.reached > oldWidget.reached;
    _reach.animateTo(
      target,
      duration: Duration(
        milliseconds:
            (forward ? 720 : 420) * (widget.reached - oldWidget.reached).abs(),
      ),
      curve: forward ? Curves.easeInOutCubic : Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _reach.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: SizedBox(
        height: 56,
        child: CustomPaint(
          size: const Size(double.infinity, 56),
          painter: ConnectionPathPainter(
            reach: _reach,
            line: scheme.primary,
            idle: scheme.outline,
            station: scheme.surfaceContainerHigh,
            ink: scheme.onSurfaceVariant,
            onLine: scheme.onPrimary,
          ),
        ),
      ),
    );
  }
}

class ConnectionPathPainter extends CustomPainter {
  ConnectionPathPainter({
    required this.reach,
    required this.line,
    required this.idle,
    required this.station,
    required this.ink,
    required this.onLine,
  }) : super(repaint: reach);

  final Animation<double> reach;
  final Color line;
  final Color idle;
  final Color station;
  final Color ink;
  final Color onLine;

  static const _icons = [
    Icons.dns_outlined,
    Icons.key_outlined,
    Icons.person_outline,
  ];
  static const _radius = 17.0;

  @override
  void paint(Canvas canvas, Size size) {
    final r = reach.value;
    final y = size.height / 2;
    final width = math.min(size.width, 320.0);
    final left = (size.width - width) / 2 + 12;
    final right = left + width - 24 - _radius;
    // Phone at 0, stations at 1..3.
    double xAt(double i) =>
        lerpDouble(left, right, i / ConnectionPath.stations)!;

    // Ahead: a dotted path still to walk.
    final ahead = Paint()
      ..color = idle.withValues(alpha: .7)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final head = xAt(r + 1);
    for (var x = head + 6; x < right - _radius; x += 7) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + 2, right), y), ahead);
    }

    // Walked: a solid line from the phone to the head, the head a bright dot.
    final walked = Paint()
      ..color = line
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(xAt(0) + 9, y), Offset(head, y), walked);
    final moving = (r - r.roundToDouble()).abs() > .001;
    if (moving) {
      canvas.drawCircle(
        Offset(head, y),
        7,
        Paint()..color = line.withValues(alpha: .25),
      );
      canvas.drawCircle(Offset(head, y), 3.4, Paint()..color = line);
    }

    // The phone this journey starts from.
    _icon(canvas, Icons.smartphone_outlined, Offset(xAt(0), y), 20, ink);

    for (var i = 1; i <= ConnectionPath.stations; i++) {
      final c = Offset(xAt(i.toDouble()), y);
      // How far this station is done: its check draws as the line arrives.
      final done = ((r + 1 - i) / .35).clamp(0.0, 1.0);
      // The next station to reach glows; it is reached when done hits 1.
      final current = (1 - (r + 1 - i).abs()).clamp(0.0, 1.0);
      final pop = math.sin(done * math.pi) * .12;
      final radius = _radius * (1 + pop);

      if (current > 0 && done < 1) {
        canvas.drawCircle(
          c,
          radius + 6 * current,
          Paint()..color = line.withValues(alpha: .16 * current),
        );
      }
      canvas.drawCircle(
        c,
        radius,
        Paint()..color = Color.lerp(station, line, done)!,
      );
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = Color.lerp(Color.lerp(idle, line, current)!, line, done)!,
      );
      final iconColor = Color.lerp(ink, onLine, done)!;
      if (done < 1) {
        _icon(
          canvas,
          _icons[i - 1],
          c,
          18,
          iconColor.withValues(alpha: 1 - done),
        );
      }
      if (done > 0) _check(canvas, c, done, onLine);
    }
  }

  void _icon(Canvas canvas, IconData icon, Offset c, double size, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: size,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, c - Offset(painter.width / 2, painter.height / 2));
  }

  void _check(Canvas canvas, Offset c, double t, Color color) {
    final a = c + const Offset(-6, .5);
    final b = c + const Offset(-1.6, 5);
    final d = c + const Offset(6.5, -4.5);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final first = (t / .4).clamp(0.0, 1.0);
    final second = ((t - .4) / .6).clamp(0.0, 1.0);
    canvas.drawLine(a, Offset.lerp(a, b, first)!, paint);
    if (second > 0) canvas.drawLine(b, Offset.lerp(b, d, second)!, paint);
  }

  @override
  bool shouldRepaint(ConnectionPathPainter old) =>
      old.line != line ||
      old.idle != idle ||
      old.station != station ||
      old.ink != ink ||
      old.onLine != onLine;
}

/// Swaps one step of the connection for the next along the reading
/// direction: forward slides in from the end, back from the start. The
/// outgoing step can no longer be touched, focused or read.
class ArrivalStepSwitcher extends StatelessWidget {
  const ArrivalStepSwitcher({
    super.key,
    required this.step,
    required this.forward,
    required this.child,
  });

  final Object step;
  final bool forward;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.duration(context, milliseconds: 420);
    final direction = Directionality.of(context) == TextDirection.rtl ? -1 : 1;
    final travel = (forward ? .14 : -.14) * direction;
    return AnimatedSize(
      duration: duration,
      curve: AppMotion.curve,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: Curves.linear,
        switchOutCurve: Curves.linear,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [
            for (final outgoing in previous)
              ExcludeFocus(
                child: ExcludeSemantics(child: IgnorePointer(child: outgoing)),
              ),
            if (current != null) current,
          ],
        ),
        transitionBuilder: (child, animation) {
          final incoming = child.key == ValueKey(step);
          // The incoming step waits for the outgoing one to clear half way.
          final fade = animation.drive(
            CurveTween(curve: const Interval(.35, 1, curve: Curves.easeOut)),
          );
          final slide = animation.drive(CurveTween(curve: Curves.easeOutCubic));
          return FadeTransition(
            opacity: fade,
            child: AnimatedBuilder(
              animation: slide,
              builder: (context, child) => FractionalTranslation(
                translation: Offset(
                  (1 - slide.value) * (incoming ? travel : -travel),
                  0,
                ),
                child: child,
              ),
              child: child,
            ),
          );
        },
        child: KeyedSubtree(key: ValueKey(step), child: child),
      ),
    );
  }
}
