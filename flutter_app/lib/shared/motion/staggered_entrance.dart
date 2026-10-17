import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'app_motion.dart';

/// Fades and rises a list item into place, staggered by [index].
///
/// * The stagger is capped: items at index >= [maxStaggered] share the last
///   delay, so a long list never makes anyone wait.
/// * It plays once per [identity] (for example `'pills-$profileId'`). Items
///   that mount after the entrance window of that identity — because the list
///   scrolled, rebuilt or the screen was revisited — appear in place.
/// * Quiet mode (reduced motion / accessible navigation) shows the final
///   frame. The child is always in the tree, so semantics never wait.
class StaggeredEntrance extends StatefulWidget {
  const StaggeredEntrance({
    super.key,
    required this.index,
    required this.identity,
    required this.child,
  });

  final int index;
  final Object identity;
  final Widget child;

  static const maxStaggered = 8;
  static const step = Duration(milliseconds: 40);
  static const rise = 12.0;

  /// Longest time after an identity's first frame during which newly mounted
  /// items still join the entrance.
  static Duration get window => step * maxStaggered + AppMotion.standard;

  static final LinkedHashMap<Object, Duration> _started =
      LinkedHashMap<Object, Duration>();
  static const _rememberedIdentities = 64;

  @visibleForTesting
  static void resetForTesting() => _started.clear();

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with TickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _progress;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_progress != null) return;
    _progress = _resolveEntrance();
  }

  @override
  void didUpdateWidget(StaggeredEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A reused element now shows a different list: treat it as a new mount.
    if (oldWidget.identity != widget.identity) {
      _controller?.dispose();
      _controller = null;
      _progress = _resolveEntrance();
    }
  }

  Animation<double> _resolveEntrance() {
    final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    final started = StaggeredEntrance._started;
    var firstFrame = started.remove(widget.identity);
    // A clock that went backwards (a new test binding) means a new session.
    if (firstFrame == null || firstFrame > now) firstFrame = now;
    started[widget.identity] = firstFrame; // most recently used last
    while (started.length > StaggeredEntrance._rememberedIdentities) {
      started.remove(started.keys.first);
    }
    if (AppMotion.quiet(context)) return kAlwaysCompleteAnimation;
    final elapsed = now - firstFrame;
    final slot = widget.index.clamp(0, StaggeredEntrance.maxStaggered);
    final delay = StaggeredEntrance.step * slot;
    // Items that mount after their own slot has started (scrolled in later,
    // rebuilt, revisited) appear in place: the entrance never replays.
    if (elapsed > delay) return kAlwaysCompleteAnimation;
    return _animate(delay - elapsed);
  }

  Animation<double> _animate(Duration delay) {
    final total = delay + AppMotion.standard;
    final controller = _controller = AnimationController(
      vsync: this,
      duration: total,
    )..forward();
    final start = delay.inMicroseconds / total.inMicroseconds;
    return CurvedAnimation(
      parent: controller,
      curve: Interval(start, 1, curve: AppMotion.curve),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress!;
    return AnimatedBuilder(
      animation: progress,
      builder: (context, child) => Opacity(
        opacity: progress.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - progress.value) * StaggeredEntrance.rise),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}
