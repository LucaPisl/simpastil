import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared/motion/app_motion.dart';

/// Naturally sized cards share one native scroll position. Selection is an
/// occurrence identity; list edits and viewport changes never reinterpret it.
class DoseCardStrip extends StatefulWidget {
  const DoseCardStrip({
    super.key,
    required this.ids,
    required this.labels,
    required this.selectedId,
    required this.onSelected,
    required this.cardBuilder,
    this.fullWidth = false,
    this.enabled = true,
  });

  final List<String> ids;
  final List<String> labels;
  final String selectedId;
  final ValueChanged<String> onSelected;
  final Widget Function(int index, bool actionable) cardBuilder;
  final bool fullWidth;
  final bool enabled;

  @override
  State<DoseCardStrip> createState() => _DoseCardStripState();
}

class _DoseCardStripState extends State<DoseCardStrip> {
  final _scroll = ScrollController(keepScrollOffset: false);
  double _stride = 0;
  bool _moving = false;
  bool _aligning = false;
  int _alignment = 0;

  @override
  void didUpdateWidget(DoseCardStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sameOrder = listEquals(oldWidget.ids, widget.ids);
    if (!sameOrder || oldWidget.selectedId != widget.selectedId) {
      _align(animate: sameOrder);
    }
  }

  void _align({required bool animate}) {
    final ticket = ++_alignment;
    _aligning = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || ticket != _alignment || !_scroll.hasClients) return;
      final index = widget.ids.indexOf(widget.selectedId);
      final target = (index.clamp(0, widget.ids.length - 1) * _stride).clamp(
        0.0,
        _scroll.position.maxScrollExtent,
      );
      final duration = animate ? AppMotion.duration(context) : Duration.zero;
      if ((_scroll.offset - target).abs() > .5) {
        if (duration == Duration.zero) {
          _scroll.jumpTo(target);
        } else {
          await _scroll.animateTo(
            target,
            duration: duration,
            curve: AppMotion.curve,
          );
        }
      }
      if (mounted && ticket == _alignment) {
        setState(() => _aligning = false);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      const gap = 12.0;
      final width = widget.fullWidth || bounds.maxWidth < 340
          ? bounds.maxWidth
          : bounds.maxWidth * .88;
      final stride = width + gap;
      if (_stride != stride) {
        _stride = stride;
        _align(animate: false);
      }
      return NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.depth != 0 ||
              notification.metrics.axis != Axis.horizontal) {
            return false;
          }
          if (notification is ScrollStartNotification) {
            setState(() => _moving = true);
          } else if (notification is ScrollEndNotification) {
            setState(() => _moving = false);
            if (!_aligning) {
              final index = (_scroll.offset / _stride).round().clamp(
                0,
                widget.ids.length - 1,
              );
              if (widget.ids[index] != widget.selectedId) {
                HapticFeedback.selectionClick();
              }
              widget.onSelected(widget.ids[index]);
            }
          }
          return false;
        },
        child: SingleChildScrollView(
          key: const ValueKey('focus-card-scroll'),
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          physics: widget.enabled
              ? _CardScrollPhysics(stride: stride)
              : const NeverScrollableScrollPhysics(),
          child: Padding(
            padding: EdgeInsetsDirectional.only(end: bounds.maxWidth - width),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < widget.ids.length; i++) ...[
                  if (i != 0) const SizedBox(width: gap),
                  SizedBox(
                    key: ValueKey('focus-card-${widget.ids[i]}'),
                    width: width,
                    child: _card(i),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );

  /// Neighbours of the focused card shrink toward 0.98 by scroll fraction:
  /// enough to read as depth, too little to look like the card resizing.
  Widget _scaled(int index, Widget child) => AnimatedBuilder(
    animation: _scroll,
    child: child,
    builder: (context, child) {
      if (_stride <= 0 || AppMotion.quiet(context)) return child!;
      final position = _scroll.hasClients
          ? _scroll.offset / _stride
          : widget.ids.indexOf(widget.selectedId).toDouble();
      final distance = (position - index).abs().clamp(0.0, 1.0);
      final scale = 1 - .02 * distance;
      if (scale == 1) return child!;
      return Transform.scale(
        scale: scale,
        alignment: Alignment.topCenter,
        child: child,
      );
    },
  );

  Widget _card(int index) {
    final selected = widget.ids[index] == widget.selectedId;
    final actionable = selected && !_moving && !_aligning && widget.enabled;
    final card = _scaled(
      index,
      ExcludeFocus(
        excluding: !actionable,
        child: ExcludeSemantics(
          excluding: !selected,
          child: IgnorePointer(
            ignoring: !actionable,
            child: widget.cardBuilder(index, actionable),
          ),
        ),
      ),
    );
    if (selected) return card;
    void select() {
      if (widget.enabled && !_moving) widget.onSelected(widget.ids[index]);
    }

    return Semantics(
      button: true,
      label: widget.labels[index],
      onTap: select,
      child: GestureDetector(
        key: index == widget.ids.indexOf(widget.selectedId) + 1
            ? const ValueKey('focus-next-peek')
            : null,
        behavior: HitTestBehavior.opaque,
        onTap: select,
        child: card,
      ),
    );
  }
}

/// Use Flutter's page settling, with the card stride as its page dimension.
class _CardScrollPhysics extends PageScrollPhysics {
  const _CardScrollPhysics({required this.stride, super.parent});
  final double stride;

  @override
  _CardScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _CardScrollPhysics(stride: stride, parent: buildParent(ancestor));

  /// A firmer settle than the platform's page spring, whose long, slow
  /// tail kept the cards creeping for most of a second after a swipe: this
  /// one is critically damped and comes to rest in about 0.3 s.
  @override
  SpringDescription get spring =>
      SpringDescription.withDampingRatio(mass: .5, stiffness: 300, ratio: 1);

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) => super.createBallisticSimulation(
    position.copyWith(viewportDimension: stride),
    velocity,
  );
}
