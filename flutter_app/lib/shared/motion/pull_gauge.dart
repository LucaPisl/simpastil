import 'package:flutter/widgets.dart';

/// How far a list is pulled down past its top: 0 at rest and 1 at the
/// refresh threshold (a quarter of the viewport), up to 1.4. A drawing reads
/// it to give under the finger, then the value eases back to 0 on release.
/// Feedback only; refresh status stays in words.
///
/// Feed it the list's scroll notifications through [handle].
class PullGauge {
  PullGauge({required TickerProvider vsync})
    : _back = AnimationController(
        vsync: vsync,
        duration: const Duration(milliseconds: 380),
      ) {
    _back.addListener(() {
      value.value = _from * (1 - Curves.easeOutCubic.transform(_back.value));
    });
  }

  final ValueNotifier<double> value = ValueNotifier(0);
  final AnimationController _back;
  double _from = 0;

  /// The drag that pulls fully, about where the refresh arms, so the
  /// drawing and the spinner agree on any phone.
  double _extent = 90;

  /// Reads one notification of the pulled list. [quiet] (reduced motion)
  /// keeps the value at 0. Never consumes the notification.
  bool handle(ScrollNotification n, {required bool quiet}) {
    if (n.depth != 0) return false;
    _extent = (n.metrics.viewportDimension * .25).clamp(90.0, 200.0);
    if (quiet) {
      if (value.value != 0) value.value = 0;
      return false;
    }
    if (n is ScrollStartNotification) {
      _back.stop();
    } else if (n is OverscrollNotification &&
        n.dragDetails != null &&
        (n.overscroll < 0 || value.value > 0)) {
      // Overscroll upward (a drag back up on a short page) releases it.
      value.value = (value.value - n.overscroll / _extent).clamp(0.0, 1.4);
    } else if (n is ScrollUpdateNotification && n.metrics.pixels < 0) {
      value.value = (-n.metrics.pixels / _extent).clamp(0.0, 1.4);
    } else if (n is ScrollUpdateNotification &&
        n.dragDetails != null &&
        value.value > 0 &&
        (n.scrollDelta ?? 0) > 0) {
      // Dragging back up releases it again instead of leaving it held.
      value.value = (value.value - n.scrollDelta! / _extent).clamp(0.0, 1.4);
    } else if (n is ScrollEndNotification && value.value > 0) {
      _from = value.value;
      _back.forward(from: 0);
    }
    return false;
  }

  void dispose() {
    _back.dispose();
    value.dispose();
  }
}
