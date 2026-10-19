import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../shared/motion/app_motion.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/capsule_mark.dart';
import 'sky_flight.dart';

/// The taken moment shared by every Today layout: the receipt capsule, the
/// settle halo and the rolling count. All three are edge-triggered by the
/// receipt the hosting deck State stored (see `TodayLayoutData`), so syncs,
/// notification actions and rebuilt rows never celebrate.

typedef ReceiptMoment = ({String occurrenceId, String token, bool undo});

/// The card's capsule: brand mark while due, a check once taken.
///
/// It animates only for the receipt this State stored ([moment]): a take
/// morphs dashes into a check, clicks the halves shut and sends one sage ring
/// out to 72 dp; an Undo folds the check back with no ring. Any other change
/// (sync, notification, rebuild) shows the final frame. Quiet mode always
/// shows the final frame.
class ReceiptCapsule extends StatefulWidget {
  const ReceiptCapsule({
    super.key,
    required this.taken,
    required this.moment,
    required this.claim,
    required this.onDone,
  });
  final bool taken;
  final ReceiptMoment? moment;
  final bool Function(String token) claim;
  final ValueChanged<String> onDone;

  @override
  State<ReceiptCapsule> createState() => _ReceiptCapsuleState();
}

class _ReceiptCapsuleState extends State<ReceiptCapsule>
    with TickerProviderStateMixin {
  static const _size = 26.0;
  late final AnimationController _morph = AnimationController(
    vsync: this,
    value: widget.taken ? 1 : 0,
  );
  late final AnimationController _ring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );
  String? _playing;

  /// How far the ring may reach: 72 dp, or less where the capsule sits near
  /// a screen edge, so the moment is never cut by the edge (Timeline rail).
  double _reach = 72;

  void _measureReach() {
    final box = context.findRenderObject() as RenderBox?;
    final width = MediaQuery.maybeSizeOf(context)?.width;
    if (box == null || !box.hasSize || !box.attached || width == null) return;
    final x = box.localToGlobal(box.size.center(Offset.zero)).dx;
    final room = math.min(x, width - x) - 4;
    _reach = room.clamp(box.size.shortestSide, 72.0);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _play();
    });
  }

  @override
  void didUpdateWidget(ReceiptCapsule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.moment?.token != oldWidget.moment?.token) {
      _play();
    } else if (widget.taken != oldWidget.taken && _playing == null) {
      _morph.value = widget.taken ? 1 : 0;
    }
  }

  void _play() {
    final moment = widget.moment;
    final target = widget.taken ? 1.0 : 0.0;
    if (moment == null || !widget.claim(moment.token)) {
      if (_playing == null) _morph.value = target;
      return;
    }
    final token = moment.token;
    _playing = token;
    void finish() {
      if (!mounted || _playing != token) return;
      _playing = null;
      widget.onDone(token);
    }

    if (AppMotion.quiet(context)) {
      _morph.value = target;
      _ring.value = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) => finish());
      return;
    }
    if (moment.undo) {
      _ring.value = 0;
      _morph
          .animateTo(
            target,
            duration: AppMotion.standard,
            curve: Curves.easeInOutCubic,
          )
          .whenCompleteOrCancel(finish);
      return;
    }
    _measureReach();
    _sendCheckToSky(moment.occurrenceId);
    _morph.value = 0;
    _morph.animateTo(
      target,
      duration: const Duration(milliseconds: 460),
      curve: Curves.easeOutCubic,
    );
    _ring.forward(from: 0).whenCompleteOrCancel(finish);
  }

  /// A durable take sends a ghost of the check up to its mark in the sky
  /// (when the screen offers a flight). The card has already changed; the
  /// flight carries no information of its own.
  void _sendCheckToSky(String occurrenceId) {
    final launch = SkyFlightScope.of(context);
    if (launch == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return;
      launch(occurrenceId, box.localToGlobal(box.size.center(Offset.zero)));
    });
  }

  @override
  void dispose() {
    final token = _playing;
    if (token != null) {
      final done = widget.onDone;
      WidgetsBinding.instance.addPostFrameCallback((_) => done(token));
    }
    _morph.dispose();
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return CustomPaint(
      painter: _ReceiptRingPainter(
        ring: _ring,
        color: semantic.statusTaken,
        reach: _reach,
      ),
      child: AnimatedBuilder(
        animation: Listenable.merge([_morph, _ring]),
        // The glyph swells once (1.0 -> 1.2 -> 1.0) in the ring's first half.
        builder: (context, _) => Transform.scale(
          scale: 1 + .2 * math.sin(math.pi * (_ring.value / .5).clamp(0, 1)),
          child: CapsuleMark(size: _size, progress: _morph.value),
        ),
      ),
    );
  }
}

class _ReceiptRingPainter extends CustomPainter {
  _ReceiptRingPainter({
    required this.ring,
    required this.color,
    required this.reach,
  }) : super(repaint: ring);
  final Animation<double> ring;
  final Color color;
  final double reach;

  @override
  void paint(Canvas canvas, Size size) {
    final t = ring.value;
    if (t <= 0 || t >= 1) return;
    final eased = Curves.easeOutCubic.transform(t);
    final fade = math.pow(1 - t, 1.2).toDouble();
    final center = size.center(Offset.zero);
    final inner = size.shortestSide / 2;
    final radius = inner + (reach - inner) * eased;
    // A soft sage wash fills the ring, so the moment reads around the
    // capsule even where the card edge clips the outer stroke.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: .28 * fade),
            color.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 + 2.5 * (1 - eased)
        ..color = color.withValues(alpha: .95 * fade),
    );
    // A second, later ring keeps the receipt on screen for the eye.
    final late = ((t - .25) / .75).clamp(0.0, 1.0);
    if (late > 0) {
      final e2 = Curves.easeOutCubic.transform(late);
      canvas.drawCircle(
        center,
        inner + (reach * 2 / 3 - inner) * e2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1 + 1.5 * (1 - e2)
          ..color = color.withValues(alpha: .7 * (1 - late)),
      );
    }
  }

  @override
  bool shouldRepaint(_ReceiptRingPainter old) =>
      old.ring != ring || old.color != color || old.reach != reach;
}

/// Settle: when a take brings the day to zero, a soft sage halo widens once
/// behind the count while the words change to "All recorded for today".
class SettleHalo extends StatefulWidget {
  const SettleHalo({
    super.key,
    required this.token,
    required this.claim,
    required this.onDone,
    required this.child,
  });
  final String? token;
  final bool Function(String token) claim;
  final ValueChanged<String> onDone;
  final Widget child;

  @override
  State<SettleHalo> createState() => _SettleHaloState();
}

class _SettleHaloState extends State<SettleHalo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _halo = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _play();
    });
  }

  @override
  void didUpdateWidget(SettleHalo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.token != oldWidget.token) _play();
  }

  void _play() {
    final token = widget.token;
    if (token == null || !widget.claim('settle/$token')) return;
    void finish() {
      if (mounted) widget.onDone(token);
    }

    if (AppMotion.quiet(context)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => finish());
      return;
    }
    _halo.forward(from: 0).whenCompleteOrCancel(finish);
  }

  @override
  void dispose() {
    _halo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _HaloPainter(
      halo: _halo,
      color: Theme.of(context).extension<AppSemanticColors>()!.statusTaken,
      rtl: Directionality.of(context) == TextDirection.rtl,
    ),
    child: widget.child,
  );
}

class _HaloPainter extends CustomPainter {
  _HaloPainter({required this.halo, required this.color, required this.rtl})
    : super(repaint: halo);
  final Animation<double> halo;
  final Color color;
  final bool rtl;

  @override
  void paint(Canvas canvas, Size size) {
    final t = halo.value;
    if (t <= 0 || t >= 1 || size.isEmpty) return;
    final widen = Curves.easeOutCubic.transform(t);
    // Rises quickly, then fades slowly as it widens.
    final glow = math.sin(math.pi * math.pow(t, .55)).toDouble();
    final center = Offset(rtl ? size.width - 56 : 56, size.height / 2);
    final radius = 28 + (size.width * .7) * widen;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(1, .42);
    canvas.translate(-center.dx, -center.dy);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: .26 * glow),
            color.withValues(alpha: .1 * glow),
            color.withValues(alpha: 0),
          ],
          stops: const [0, .55, 1],
        ).createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HaloPainter old) =>
      old.halo != halo || old.color != color || old.rtl != rtl;
}

/// One part of a dose's receipt: its state words, its action or its sharing
/// line. Every part of one dose is keyed by the same [receipt] (state and
/// version), so a durable take swaps all of them in the same frame with one
/// fade-through: the old parts fade out completely before the new ones fade
/// in, and Undo or "Saved on this device" can never precede the Taken state.
/// A null [child] holds no space (a part that only exists once recorded).
class ReceiptSwap extends StatelessWidget {
  const ReceiptSwap({super.key, required this.receipt, this.child});
  final String receipt;
  final Widget? child;

  /// The key every part of one dose's receipt shares.
  static String of(String state, int stateVersion) => '$state/$stateVersion';

  @override
  Widget build(BuildContext context) {
    final keyed = KeyedSubtree(
      key: ValueKey(receipt),
      child: child ?? const SizedBox(width: double.infinity),
    );
    if (AppMotion.quiet(context)) return keyed;
    // A part that grows or shrinks with the receipt eases its neighbours.
    return AnimatedSize(
      duration: AppMotion.standard,
      curve: AppMotion.curve,
      alignment: AlignmentDirectional.topStart,
      child: AnimatedSwitcher(
        duration: AppMotion.standard,
        switchInCurve: Curves.linear,
        switchOutCurve: Curves.linear,
        // Start-aligned, so a narrower part never sits centred on a wider
        // one and then jumps when the outgoing part leaves.
        layoutBuilder: (current, previous) => Stack(
          alignment: AlignmentDirectional.topStart,
          children: [
            for (final outgoing in previous)
              ExcludeSemantics(child: IgnorePointer(child: outgoing)),
            ?current,
          ],
        ),
        transitionBuilder: (child, animation) {
          // Fade-through: each half of the animation belongs to one side,
          // so the two receipts never show at once.
          final opacity = animation.drive(
            CurveTween(curve: const Interval(.5, 1, curve: AppMotion.curve)),
          );
          return AnimatedBuilder(
            animation: opacity,
            builder: (context, child) =>
                IgnorePointer(ignoring: opacity.value == 0, child: child),
            child: FadeTransition(opacity: opacity, child: child),
          );
        },
        child: keyed,
      ),
    );
  }
}

/// Count words roll up like a counter; quiet mode swaps them in place.
class RollingLabel extends StatelessWidget {
  const RollingLabel({super.key, required this.text, this.style});
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final label = Text(text, key: ValueKey(text), style: style);
    if (AppMotion.quiet(context)) return label;
    return AnimatedSwitcher(
      duration: AppMotion.emphasis,
      switchInCurve: AppMotion.curve,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [
          for (final outgoing in previous)
            ExcludeSemantics(child: IgnorePointer(child: outgoing)),
          ?current,
        ],
      ),
      transitionBuilder: (child, animation) {
        final incoming = child.key == ValueKey(text);
        return ClipRect(
          child: SlideTransition(
            position: Tween(
              begin: Offset(0, incoming ? .7 : -.7),
              end: Offset.zero,
            ).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
        );
      },
      child: label,
    );
  }
}
