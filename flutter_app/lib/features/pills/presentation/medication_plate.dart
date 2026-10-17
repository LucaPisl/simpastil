import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../../shared/motion/app_motion.dart';
import 'medication_identity.dart';

/// The medication card grows into the detail page's plate (a container
/// transform): the surface lifts out of the grid, widens and takes on the
/// medication's colour while the card's words fade away inside it and the
/// plate's words fade in; the mark arcs up to the top of the plate with a
/// turn. Back plays the same flight home.
Object medicationSurfaceTag(String id) => ('medication-surface', id);
Object medicationMarkTag(String id) => ('medication-mark', id);

/// The plate's wash of the medication's colour over the page.
Color medicationPlateColor(BuildContext context, Color tint) {
  final cs = Theme.of(context).colorScheme;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return Color.lerp(cs.surfaceContainerLow, tint, dark ? .2 : .13)!;
}

const double _cardRadius = 16;
const double _plateRadius = 28;

/// The surface with its words: the white card in the grid ([t] 0) or the
/// tinted plate on the detail page ([t] 1), and every step between.
class _SurfaceBody extends StatelessWidget {
  const _SurfaceBody({required this.tint, required this.t, this.child});
  final Color tint;
  final double t;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outlineVariant;
    return Material(
      color: Color.lerp(
        Theme.of(context).colorScheme.surface,
        medicationPlateColor(context, tint),
        t,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          _cardRadius + (_plateRadius - _cardRadius) * t,
        ),
        side: BorderSide(color: outline.withValues(alpha: .55 * (1 - t))),
      ),
      // Lifted while in flight, resting at either end.
      elevation: 8 * math.sin(math.pi * t),
      shadowColor: tint.withValues(alpha: .4),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// One end's words, as they were laid out there, scaled to the surface's
/// width as it changes and faded by [opacity].
Widget _wordsOf(BuildContext heroContext, double opacity) {
  final body = (heroContext.widget as Hero).child as _SurfaceBody;
  final box = heroContext.findRenderObject() as RenderBox?;
  final words = body.child;
  if (opacity <= 0 || words == null || box == null || !box.hasSize) {
    return const SizedBox.shrink();
  }
  return Opacity(
    opacity: opacity,
    child: FittedBox(
      fit: BoxFit.fitWidth,
      alignment: Alignment.topCenter,
      clipBehavior: Clip.hardEdge,
      child: SizedBox.fromSize(size: box.size, child: words),
    ),
  );
}

Widget _surfaceShuttle(
  Color tint,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext from,
  BuildContext to,
) {
  final push = direction == HeroFlightDirection.push;
  final card = push ? from : to;
  final plate = push ? to : from;
  return AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      // 0 is the card, 1 the plate, whichever way the flight goes.
      final t = animation.value;
      return _SurfaceBody(
        tint: tint,
        t: t,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _wordsOf(card, 1 - const Interval(0, .3).transform(t)),
            _wordsOf(
              plate,
              const Interval(.35, .85, curve: Curves.easeOut).transform(t),
            ),
          ],
        ),
      );
    },
  );
}

/// A medication card in the grid that grows into its detail page. [child]
/// holds the card's words; the mark is laid over it by the caller, outside
/// this hero, so it can fly on its own path.
class MedicationCardSurface extends StatelessWidget {
  const MedicationCardSurface({
    super.key,
    required this.id,
    required this.tint,
    required this.child,
  });
  final String id;
  final Color tint;
  final Widget child;

  @override
  Widget build(BuildContext context) => Hero(
    tag: medicationSurfaceTag(id),
    flightShuttleBuilder: (flight, animation, direction, from, to) =>
        _surfaceShuttle(tint, animation, direction, from, to),
    child: _SurfaceBody(tint: tint, t: 0, child: child),
  );
}

/// The medication's mark, flying between the card and the plate. In flight
/// it grows or shrinks with the hero and turns once along the arc.
class MedicationMarkHero extends StatelessWidget {
  const MedicationMarkHero({
    super.key,
    required this.id,
    required this.color,
    required this.shape,
    this.size = 58,
  });

  final String id;
  final Color color;
  final MedicationShape shape;
  final double size;

  @override
  Widget build(BuildContext context) => Hero(
    tag: medicationMarkTag(id),
    flightShuttleBuilder: (flight, animation, direction, from, to) =>
        AnimatedBuilder(
          animation: animation,
          builder: (context, _) => LayoutBuilder(
            builder: (context, box) => Transform.rotate(
              // A third of a turn at mid-flight, back to upright on landing.
              angle: math.sin(math.pi * animation.value) * .55,
              child: MedicationMark(
                color: color,
                shape: shape,
                size: box.biggest.shortestSide,
              ),
            ),
          ),
        ),
    child: MedicationMark(color: color, shape: shape, size: size),
  );
}

/// The top of the medication detail page: the medication's mark on a plate
/// of its colour, its name and whose it is, and its stock. The mark can be
/// picked up ([SpringyMark]).
class MedicationPlate extends StatelessWidget {
  const MedicationPlate({
    super.key,
    required this.id,
    required this.tint,
    required this.shape,
    required this.children,
  });

  final String id;
  final Color tint;
  final MedicationShape shape;

  /// The words under the mark.
  final List<Widget> children;

  static const _top = 18.0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Hero(
          tag: medicationSurfaceTag(id),
          flightShuttleBuilder: (flight, animation, direction, from, to) =>
              _surfaceShuttle(tint, animation, direction, from, to),
          child: _SurfaceBody(
            tint: tint,
            t: 1,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                20,
                _top + SpringyMark.height + 10,
                20,
                22,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ),
        // Over the plate rather than in it, so it flies on its own arc.
        Positioned(
          top: _top,
          left: 0,
          right: 0,
          child: Center(
            child: SpringyMark(
              tint: tint,
              child: MedicationMarkHero(
                id: id,
                color: tint,
                shape: shape,
                size: 104,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Pan that claims the pointer at touch slop instead of the larger pan
/// slop, so a drag that starts on the mark is the mark's, not the list's.
class _MarkPan extends PanGestureRecognizer {
  _MarkPan() : super(debugOwner: null);

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      globalDistanceMoved.abs() >
      computeHitSlop(pointerDeviceKind, gestureSettings);
}

/// A mark that can be picked up: it follows a drag on a short elastic leash,
/// leans with it and its shadow shrinks as it lifts; let go, it springs home
/// with a bounce. A tap squashes it like a soft capsule. Nothing moves
/// unless touched.
class SpringyMark extends StatefulWidget {
  const SpringyMark({super.key, required this.tint, required this.child});
  final Color tint;
  final Widget child;

  /// The room the mark and its shadow take on the plate.
  static const height = 128.0;

  @override
  State<SpringyMark> createState() => _SpringyMarkState();
}

class _SpringyMarkState extends State<SpringyMark>
    with TickerProviderStateMixin {
  /// Under-damped on purpose: a visible bounce or two, then rest.
  static const _home = SpringDescription(mass: 1, stiffness: 380, damping: 13);
  static const _wobble = SpringDescription(
    mass: 1,
    stiffness: 520,
    damping: 11,
  );

  /// How far the leash stretches, at most.
  static const _reach = 38.0;

  // Released offset, scaled by [_return] (1 at release, 0 home).
  Offset _held = Offset.zero;
  Offset _raw = Offset.zero;
  Offset _released = Offset.zero;
  late final AnimationController _return = AnimationController.unbounded(
    vsync: this,
  )..addListener(_tick);
  late final AnimationController _squash = AnimationController.unbounded(
    vsync: this,
  )..addListener(_tick);
  bool _dragging = false;

  void _tick() => setState(() {});

  @override
  void dispose() {
    _return.dispose();
    _squash.dispose();
    super.dispose();
  }

  Offset get _offset => _dragging ? _held : _released * _return.value;

  Offset _leash(Offset raw) {
    final d = raw.distance;
    if (d == 0) return Offset.zero;
    final stretched = _reach * (1 - math.exp(-d / _reach));
    return raw * (stretched / d);
  }

  void _start(DragStartDetails _) {
    _return.stop();
    _dragging = true;
    _raw = _offset;
    _held = _raw;
    setState(() {});
  }

  void _update(DragUpdateDetails details) {
    _raw += details.delta;
    setState(() => _held = _leash(_raw));
  }

  void _end(DragEndDetails details) {
    _dragging = false;
    _released = _held;
    final distance = _released.distance;
    if (distance < .5 || AppMotion.quiet(context)) {
      _return.value = 0;
      return;
    }
    // The fling's speed toward home, in leash lengths per second.
    final toward =
        -details.velocity.pixelsPerSecond.dx * _released.dx -
        details.velocity.pixelsPerSecond.dy * _released.dy;
    final velocity = -(toward / distance) / distance * .25;
    HapticFeedback.selectionClick();
    _return.animateWith(SpringSimulation(_home, 1, 0, velocity));
  }

  void _tap() {
    if (AppMotion.quiet(context)) return;
    HapticFeedback.lightImpact();
    _squash.animateWith(SpringSimulation(_wobble, 0, 0, 7));
  }

  @override
  Widget build(BuildContext context) {
    final offset = _offset;
    final s = _squash.value.clamp(-1.2, 1.2);
    // Lifting (up) shrinks and softens the shadow on the plate.
    final lift = (-offset.dy / _reach).clamp(-1.0, 1.0);
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        _MarkPan: GestureRecognizerFactoryWithHandlers<_MarkPan>(
          _MarkPan.new,
          (pan) => pan
            ..onStart = _start
            ..onUpdate = _update
            ..onEnd = _end,
        ),
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              TapGestureRecognizer.new,
              (tap) => tap.onTap = _tap,
            ),
      },
      child: SizedBox(
        width: 168,
        height: SpringyMark.height,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // A round pool of the medication's colour, squashed flat into a
            // contact shadow (a gradient's radius follows the short side).
            Positioned(
              bottom: -32,
              child: Transform.translate(
                offset: Offset(offset.dx * .35, 0),
                child: Transform.scale(
                  scaleX: 1 - .3 * lift + .12 * s,
                  scaleY: .17 * (1 - .2 * lift),
                  child: Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          widget.tint.withValues(
                            alpha: (.42 - .2 * lift).clamp(.1, .6),
                          ),
                          widget.tint.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Transform.translate(
              offset: offset,
              child: Transform.rotate(
                angle: offset.dx / _reach * .32,
                child: Transform.scale(
                  scaleX: 1 + .12 * s,
                  scaleY: 1 - .14 * s,
                  alignment: Alignment.bottomCenter,
                  child: widget.child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
