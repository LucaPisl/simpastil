import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/storage/layout_family_preference.dart';
import '../../../shared/motion/app_motion.dart';

/// Lays a newly chosen layout onto Today, top to bottom.
///
/// The choice is made in Settings, over Today, so the swap itself happens out
/// of sight. The reveal waits until Today is the visible location again and
/// then wipes the new layout in from the top with a short rise, so the first
/// thing seen after Apply is the day being rearranged rather than a cut.
///
/// The wipe starts as soon as the covering route begins to leave, holding
/// the layout back for that first beat. The first build never reveals, and
/// quiet motion shows the layout at once.
class LayoutReveal extends StatefulWidget {
  const LayoutReveal({super.key, required this.family, required this.child});

  final LayoutFamily family;
  final Widget child;

  /// The wipe, after a beat for the route that covered Today to leave.
  static const duration = Duration(milliseconds: 1300);
  static const hold = .22;

  // Today's day view is rebuilt from scratch when its data reloads, which
  // often happens just as Settings closes. The last family shown and when
  // its reveal started live here, so a fresh element carries on the reveal
  // instead of cutting to the end of it.
  static LayoutFamily? _shown;
  static DateTime? _startedAt;

  @visibleForTesting
  static void resetForTesting() {
    _shown = null;
    _startedAt = null;
  }

  @override
  State<LayoutReveal> createState() => _LayoutRevealState();
}

class _LayoutRevealState extends State<LayoutReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: LayoutReveal.duration,
    value: 1,
  );
  bool _pending = false;
  bool _started = false;
  double? _visibleHeight;
  GoRouter? _router;
  ModalRoute<Object?>? _outer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = GoRouter.maybeOf(context);
    if (router != _router) {
      _router?.routerDelegate.removeListener(_onLocation);
      _router = router?..routerDelegate.addListener(_onLocation);
    }
    // Today lives in a branch navigator inside the shell's page; Settings
    // covers the shell's page in the root navigator. Find the outermost
    // route that holds this widget.
    ModalRoute<Object?>? outer;
    BuildContext? at = context;
    while (at != null) {
      final route = ModalRoute.of(at);
      if (route == null) break;
      outer = route;
      at = route.navigator?.context;
    }
    _outer = outer;
    if (_started) return;
    _started = true;
    _arrive(widget.family);
  }

  @override
  void didUpdateWidget(LayoutReveal old) {
    super.didUpdateWidget(old);
    if (old.family != widget.family) _arrive(widget.family);
  }

  void _arrive(LayoutFamily family) {
    final shown = LayoutReveal._shown;
    if (shown == null || AppMotion.quiet(context)) {
      LayoutReveal._shown = family;
      LayoutReveal._startedAt = null;
      _reveal.value = 1;
      return;
    }
    if (shown == family) {
      // A reveal of this family may still be under way: pick it up.
      final started = LayoutReveal._startedAt;
      if (started == null) return;
      final done =
          DateTime.now().difference(started).inMicroseconds /
          LayoutReveal.duration.inMicroseconds;
      if (done < 1) _reveal.forward(from: done.clamp(0.0, 1.0));
      return;
    }
    // Out of sight the new layout simply stands; it is hidden only when the
    // wipe starts, so a missed reveal can never leave Today blank.
    _pending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeReveal());
  }

  void _onLocation() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeReveal());

  /// Today is on screen when nothing covers its outermost route.
  bool get _visible => _outer?.isCurrent ?? true;

  void _maybeReveal() {
    if (!mounted || !_pending || !_visible) return;
    _pending = false;
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      final top = box.localToGlobal(Offset.zero).dy;
      _visibleHeight = (MediaQuery.sizeOf(context).height - top).clamp(
        200.0,
        box.size.height,
      );
    }
    LayoutReveal._shown = widget.family;
    LayoutReveal._startedAt = DateTime.now();
    _reveal.forward(from: 0);
  }

  @override
  void dispose() {
    _router?.routerDelegate.removeListener(_onLocation);
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _reveal,
    child: widget.child,
    builder: (context, child) {
      final t = _reveal.value;
      if (t >= 1) return child!;
      final p = Curves.easeOutCubic.transform(
        ((t - LayoutReveal.hold) / (1 - LayoutReveal.hold)).clamp(0.0, 1.0),
      );
      // The edge crosses what is on screen of the layout, not all of it: a
      // long day's list would otherwise have its visible top laid in a blink.
      final screen = _visibleHeight ?? MediaQuery.sizeOf(context).height;
      return ShaderMask(
        key: const ValueKey('layout-reveal-wipe'),
        blendMode: BlendMode.dstIn,
        // A soft edge travels down the layout; above it is laid, below it
        // still to come.
        shaderCallback: (bounds) {
          const edge = 180.0;
          final at = p * (screen + edge);
          final height = bounds.height <= 0 ? 1.0 : bounds.height;
          return LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: const [Colors.white, Colors.transparent],
            stops: [
              ((at - edge) / height).clamp(0.0, 1.0),
              (at / height).clamp(0.0, 1.0),
            ],
          ).createShader(bounds);
        },
        child: Transform.translate(
          offset: Offset(0, (1 - p) * 24),
          child: child,
        ),
      );
    },
  );
}
