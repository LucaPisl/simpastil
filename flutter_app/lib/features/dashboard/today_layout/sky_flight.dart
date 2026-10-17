import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../shared/widgets/capsule_mark.dart';

/// Starts the flight of a just-recorded dose's check from the card to its
/// mark in the sky. [from] is the capsule's centre in global coordinates.
typedef SkyFlightLauncher = void Function(String occurrenceId, Offset from);

/// Offers a [SkyFlightLauncher] to the receipt capsules below it. Without a
/// scope (other screens, tests) a take simply has no flight.
class SkyFlightScope extends InheritedWidget {
  const SkyFlightScope({super.key, required this.launch, required super.child});

  final SkyFlightLauncher launch;

  static SkyFlightLauncher? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SkyFlightScope>()?.launch;

  @override
  bool updateShouldNotify(SkyFlightScope old) => false;
}

/// How long one flight lasts.
const skyFlightDuration = Duration(milliseconds: 520);

/// Flies a taken capsule from [from] to [to] (both global) in the root
/// overlay, then removes itself. The flight is only a ghost of the card's own
/// receipt: it never carries information, ignores touches and is hidden from
/// semantics, so nothing waits for it. Completes when it ends (or at once if
/// there is no overlay).
Future<void> playCapsuleFlight(
  BuildContext context, {
  required Offset from,
  required Offset to,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  final box = overlay?.context.findRenderObject();
  if (overlay == null || box is! RenderBox || !box.attached) {
    return Future.value();
  }
  final done = Completer<void>();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _CapsuleFlight(
      from: box.globalToLocal(from),
      to: box.globalToLocal(to),
      onEnd: () {
        entry.remove();
        entry.dispose();
        if (!done.isCompleted) done.complete();
      },
    ),
  );
  overlay.insert(entry);
  return done.future;
}

class _CapsuleFlight extends StatefulWidget {
  const _CapsuleFlight({
    required this.from,
    required this.to,
    required this.onEnd,
  });
  final Offset from;
  final Offset to;
  final VoidCallback onEnd;

  @override
  State<_CapsuleFlight> createState() => _CapsuleFlightState();
}

class _CapsuleFlightState extends State<_CapsuleFlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: skyFlightDuration)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) widget.onEnd();
        })
        ..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// A quadratic arc that lifts toward the sky before it settles on the mark.
  Offset _at(double t) {
    final a = widget.from, b = widget.to;
    final control = Offset(
      (a.dx + b.dx) / 2,
      math.min(a.dy, b.dy) - math.max(48, (a.dy - b.dy).abs() * .25),
    );
    final u = 1 - t;
    return a * (u * u) + control * (2 * u * t) + b * (t * t);
  }

  @override
  Widget build(BuildContext context) {
    const size = 26.0;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = Curves.easeInOutCubic.transform(_c.value);
            final p = _at(t);
            final scale = 1.15 - .65 * t;
            final fade = _c.value < .8 ? 1.0 : (1 - _c.value) / .2;
            return Stack(
              children: [
                Positioned(
                  left: p.dx - size / 2,
                  top: p.dy - size / 2,
                  child: Opacity(
                    opacity: fade.clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: scale,
                      child: const CapsuleMark(size: size, progress: 1),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
