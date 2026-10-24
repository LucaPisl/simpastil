import 'dart:async';
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../../../shared/motion/app_motion.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/theme/app_theme.dart';
import 'receipt_moment.dart';

// A dose's main button answers its own press. Once the receipt lands, its
// label and icon cross-fade into a check that draws itself while the fill
// turns from violet to the taken green ("Taken 8:02"); it holds, then
// settles into the outlined Undo in the same place. Never an overshoot, a
// scale-up or a pulse. A skip plays the same with the skip glyph on a
// neutral fill. Undo is live from the moment the receipt lands.
//
// Under reduce motion the button switches straight to Undo; the status words
// and the receipt haptic carry the moment.

/// Ink drawn while the glyph draws its stroke.
const _draw = AppMotion.standard;

/// How long "Taken 8:02" stays before it settles.
const _hold = Duration(milliseconds: 600);

/// The settle into Undo, or the time a list row gives the collapse.
const _settle = AppMotion.standard;

/// How long a save may take before the button says "Saving…". A quicker
/// one (nearly every save, on the phone's own disk) shows no words of its
/// own, so the button changes once, into its receipt.
const _slowSave = Duration(milliseconds: 400);

/// What the button becomes once its moment has played.
enum DoseSettle {
  /// The outlined Undo, in the same slot (the deck's card).
  undo,

  /// Nothing of its own: after the hold the row collapses into its one-line
  /// done row (the list layouts), so [DoseActionButton.onSettled] fires then.
  collapse,
}

/// The size and padding of one look of the button. The width is either the
/// content's own or, when [expand], the slot's whole width.
@immutable
class DoseButtonShape {
  const DoseButtonShape({
    required this.height,
    required this.radius,
    required this.iconSize,
    required this.expand,
    this.padding,
  });

  final double height;
  final double radius;
  final double iconSize;
  final bool expand;

  /// Null keeps the Material default for a button with an icon.
  final EdgeInsetsGeometry? padding;

  static DoseButtonShape lerp(DoseButtonShape a, DoseButtonShape b, double t) =>
      t <= 0
      ? a
      : t >= 1
      ? b
      : DoseButtonShape(
          height: a.height + (b.height - a.height) * t,
          radius: a.radius + (b.radius - a.radius) * t,
          iconSize: a.iconSize + (b.iconSize - a.iconSize) * t,
          expand: b.expand,
          padding: a.padding != null && b.padding != null
              ? EdgeInsetsGeometry.lerp(a.padding, b.padding, t)
              : (t < .5 ? a.padding : b.padding),
        );
}

/// The fill, ink and outline of one look.
typedef _Paint = ({Color fill, Color ink, Color edge});

_Paint _lerp(_Paint a, _Paint b, double t) => (
  fill: _mix(a.fill, b.fill, t),
  ink: _mix(a.ink, b.ink, t),
  edge: _mix(a.edge, b.edge, t),
);

/// Blends two colours as paint does: a clear end adds no hue of its own, so
/// the taken green fades out as green instead of passing through the
/// violet of the clear Undo fill (which [Color.lerp] would mix in).
Color _mix(Color a, Color b, double t) {
  final alpha = a.a + (b.a - a.a) * t;
  if (alpha == 0) return b.withValues(alpha: 0);
  double channel(double x, double y) =>
      ((x * a.a + (y * b.a - x * a.a) * t) / alpha).clamp(0, 1);
  return Color.from(
    alpha: alpha,
    red: channel(a.r, b.r),
    green: channel(a.g, b.g),
    blue: channel(a.b, b.b),
    colorSpace: a.colorSpace,
  );
}

enum _Look { take, done, undo }

/// A dose's main button through its whole life: "Taken now" while due, the
/// check moment once its receipt lands, then Undo.
///
/// It plays the moment only for the receipt the deck stored ([moment], not
/// an undo), once per receipt ([claim] of `button/<token>`); a sync or a
/// rebuild shows the final look. An Undo receipt eases back to "Taken now".
class DoseActionButton extends StatefulWidget {
  const DoseActionButton({
    super.key,
    required this.done,
    required this.skipped,
    required this.filled,
    required this.takeLabel,
    required this.doneLabel,
    required this.undoLabel,
    required this.savingLabel,
    required this.saving,
    required this.onPressed,
    required this.moment,
    required this.claim,
    required this.takeShape,
    this.undoShape,
    this.settle = DoseSettle.undo,
    this.onSettled,
    this.takeKey,
    this.undoKey,
    this.focusNode,
    this.hint,
  });

  /// Taken or skipped: the button is Undo (or is becoming it).
  final bool done;
  final bool skipped;

  /// The weight of "Taken now": filled for the next due slot, outlined for a
  /// later or missed dose.
  final bool filled;
  final String takeLabel;

  /// "Taken 8:02" or "Skipped".
  final String doneLabel;
  final String undoLabel;
  final String savingLabel;
  final bool saving;

  /// Take while due, Undo once done; null disables.
  final VoidCallback? onPressed;
  final ReceiptMoment? moment;
  final bool Function(String token) claim;
  final DoseButtonShape takeShape;

  /// The Undo's shape; [takeShape] when null.
  final DoseButtonShape? undoShape;
  final DoseSettle settle;

  /// Called once the moment has played (or was not to play) for a
  /// [DoseSettle.collapse] button, so the row may collapse.
  final VoidCallback? onSettled;
  final Key? takeKey;
  final Key? undoKey;
  final FocusNode? focusNode;

  /// Read after the label, for example "For Casey".
  final String? hint;

  @override
  State<DoseActionButton> createState() => _DoseActionButtonState();
}

class _DoseActionButtonState extends State<DoseActionButton>
    with SingleTickerProviderStateMixin {
  /// One clock for the whole moment: draw, hold, then settle.
  late final AnimationController _clock = AnimationController(vsync: this);

  /// What the clock is playing: the moment forward, or an Undo back.
  _Play _play = _Play.still;

  /// The take weight the moment started from, kept for the Undo's way back
  /// (a done dose is never in the next slot, so [widget.filled] has moved
  /// on).
  late bool _filled = widget.filled;

  /// The take's shape the same way: the check plays at the size the person
  /// pressed.
  late DoseButtonShape _takeShape = widget.takeShape;

  Duration get _total => widget.settle == DoseSettle.undo
      ? _draw + _hold + _settle
      : _draw + _hold;

  bool _mounted = false;

  /// The dose's new state reached the row a frame before its receipt (the
  /// store is faster than the save's return): hold the saving take until the
  /// receipt lands, so the moment plays for it.
  bool _waiting = false;

  bool get _done => widget.done && !_waiting;

  /// The save has run past [_slowSave].
  bool _slow = false;
  Timer? _slowTimer;

  void _watchSave() {
    if (!widget.saving) {
      _slowTimer?.cancel();
      _slowTimer = null;
      _slow = false;
    } else if (_slowTimer == null && !_slow) {
      _slowTimer = Timer(_slowSave, () {
        _slowTimer = null;
        if (mounted && widget.saving) setState(() => _slow = true);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_mounted) return;
    _mounted = true;
    // A row rebuilt into the moment (a list row whose actions changed shape)
    // plays it if nothing else has.
    if (widget.done) _arrive();
    _watchSave();
  }

  @override
  void didUpdateWidget(DoseActionButton old) {
    super.didUpdateWidget(old);
    _watchSave();
    if (!widget.done) {
      _filled = widget.filled;
      _takeShape = widget.takeShape;
    }
    if (_waiting) {
      if (widget.done && widget.saving && widget.moment == old.moment) return;
      _waiting = false;
      if (widget.done) _arrive();
    } else if (!old.done && widget.done) {
      if (widget.saving && widget.moment == old.moment) {
        _waiting = true;
        return;
      }
      _arrive();
    } else if (old.done && !widget.done) {
      _leave();
    } else if (widget.done && widget.saving && _play == _Play.forward) {
      // Undo pressed mid-moment: show the Undo it pressed, saving.
      _play = _Play.still;
      _clock.stop();
      _settledLater();
    }
  }

  void _arrive() {
    final moment = widget.moment;
    final plays =
        moment != null &&
        !moment.undo &&
        !AppMotion.quiet(context) &&
        widget.claim('button/${moment.token}');
    if (!plays) {
      _play = _Play.still;
      _clock.value = 0;
      if (widget.settle == DoseSettle.collapse) _settledLater();
      return;
    }
    _play = _Play.forward;
    _clock
      ..duration = _total
      ..forward(from: 0).whenCompleteOrCancel(() {
        if (!mounted || _play != _Play.forward) return;
        setState(() => _play = _Play.still);
        _settled();
      });
  }

  void _leave() {
    if (AppMotion.quiet(context)) {
      _play = _Play.still;
      return;
    }
    _play = _Play.back;
    _clock
      ..duration = AppMotion.standard
      ..forward(from: 0).whenCompleteOrCancel(() {
        if (mounted && _play == _Play.back) {
          setState(() => _play = _Play.still);
        }
      });
  }

  bool _told = false;

  /// [_settled] after this frame, for calls made while building.
  void _settledLater() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _settled());

  void _settled() {
    if (_told || !mounted) return;
    _told = true;
    widget.onSettled?.call();
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _clock.dispose();
    super.dispose();
  }

  _Paint _paintOf(_Look look, ThemeData theme) {
    final colors = theme.colorScheme;
    final edge = _themeSide(theme)?.color ?? colors.outline;
    switch (look) {
      case _Look.take:
        return _filled
            ? (
                fill: colors.primary,
                ink: colors.onPrimary,
                edge: colors.primary,
              )
            : (
                fill: colors.primary.withValues(alpha: 0),
                ink: colors.primary,
                edge: edge,
              );
      case _Look.undo:
        return (
          fill: colors.primary.withValues(alpha: 0),
          ink: colors.primary,
          edge: edge,
        );
      case _Look.done:
        if (widget.skipped) {
          final fill = colors.surfaceContainerHighest;
          return (
            fill: fill,
            ink: AppTheme.readable(colors.onSurfaceVariant, [
              fill,
            ], minimum: 4.5),
            edge: fill,
          );
        }
        final taken = theme.extension<AppSemanticColors>()!.statusTaken;
        final fill = Color.alphaBlend(
          taken.withValues(
            alpha: theme.brightness == Brightness.dark ? .24 : .16,
          ),
          colors.surface,
        );
        return (
          fill: fill,
          ink: AppTheme.readable(taken, [fill], minimum: 4.5),
          edge: fill,
        );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _clock,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final takeShape = _takeShape;
    final undoShape = widget.undoShape ?? takeShape;
    // Each look with its weight in this frame.
    late final List<(_Look, double)> layers;
    late final _Paint paint;
    late final DoseButtonShape shape;
    var glyph = 1.0;
    double wide(DoseButtonShape a, DoseButtonShape b, double t) =>
        (a.expand ? 1 - t : 0) + (b.expand ? t : 0);
    late final double width;
    switch (_play) {
      case _Play.forward:
        final ms = _clock.value * _total.inMilliseconds;
        final draw = AppMotion.curve.transform(
          (ms / _draw.inMilliseconds).clamp(0, 1),
        );
        final settleStart = (_draw + _hold).inMilliseconds;
        final settle = widget.settle == DoseSettle.undo
            ? AppMotion.curve.transform(
                ((ms - settleStart) / _settle.inMilliseconds).clamp(0, 1),
              )
            : 0.0;
        glyph = draw;
        layers = [
          (_Look.take, 1 - draw),
          (_Look.done, draw * (1 - settle)),
          (_Look.undo, settle),
        ];
        paint = _lerp(
          _lerp(_paintOf(_Look.take, theme), _paintOf(_Look.done, theme), draw),
          _paintOf(_Look.undo, theme),
          settle,
        );
        shape = DoseButtonShape.lerp(takeShape, undoShape, settle);
        width = wide(takeShape, undoShape, settle);
      case _Play.back:
        final t = AppMotion.curve.transform(_clock.value);
        layers = [(_Look.undo, 1 - t), (_Look.take, t)];
        paint = _lerp(
          _paintOf(_Look.undo, theme),
          _paintOf(_Look.take, theme),
          t,
        );
        shape = DoseButtonShape.lerp(undoShape, takeShape, t);
        width = wide(undoShape, takeShape, t);
      case _Play.still:
        final look = !_done
            ? _Look.take
            : widget.settle == DoseSettle.undo
            ? _Look.undo
            : _Look.done;
        layers = [(look, 1)];
        paint = _paintOf(look, theme);
        shape = look == _Look.take ? takeShape : undoShape;
        width = shape.expand ? 1 : 0;
    }
    final undoing = _done && _play != _Play.back;
    final enabled = widget.onPressed != null;
    final colors = theme.colorScheme;
    var fill = paint.fill, ink = paint.ink, edge = paint.edge;
    if (_play != _Play.still) {
      // Mid-way a dark fill turning light (or back) meets an ink turning the
      // other way, and the words fade into it: there the clearer of the two
      // ends' inks carries them (black or white where neither is enough).
      final behind = Color.alphaBlend(fill, colors.surface);
      if (AppTheme.contrast(ink, behind) < 4.5) {
        final clearer =
            [for (final (look, _) in layers) _paintOf(look, theme).ink].reduce(
              (a, b) =>
                  AppTheme.contrast(a, behind) >= AppTheme.contrast(b, behind)
                  ? a
                  : b,
            );
        ink = AppTheme.readable(clearer, [behind], minimum: 4.5);
      }
    }
    if (_play == _Play.still && (_slow || (!enabled && !widget.saving))) {
      // The saving look, once a save is slow enough to need words, and the
      // usual disabled look. A quick save keeps the look it was pressed in:
      // the press itself answered the touch.
      final filledLook = !undoing && _filled;
      if (_slow) {
        if (filledLook) {
          fill = colors.primary.withValues(alpha: .78);
          ink = colors.onPrimary;
          edge = fill;
        } else {
          ink = colors.onSurface.withValues(alpha: .8);
        }
      } else {
        fill = filledLook
            ? colors.onSurface.withValues(alpha: .12)
            : fill.withValues(alpha: 0);
        ink = colors.onSurface.withValues(alpha: .38);
        edge = filledLook ? fill : colors.onSurface.withValues(alpha: .12);
      }
    }

    String wordsOf(_Look look) => switch (look) {
      _ when _slow && _play == _Play.still => widget.savingLabel,
      _Look.take => widget.takeLabel,
      _Look.done => widget.doneLabel,
      _Look.undo => widget.undoLabel,
    };
    Widget iconOf(_Look look) => switch (look) {
      _Look.take => Icon(Icons.check_circle_outline, size: shape.iconSize),
      _Look.undo => Icon(Icons.undo, size: shape.iconSize),
      _Look.done => CustomPaint(
        size: Size.square(shape.iconSize),
        painter: _GlyphPainter(
          skipped: widget.skipped,
          progress: glyph,
          color: ink,
        ),
      ),
    };
    final shown = [
      for (final (look, weight) in layers)
        if (weight > 0) (look, weight),
    ];
    // Each look is a whole, its own icon beside its own words and centred on
    // its own, and looks fade through as wholes: the old look is all but gone
    // before the new one appears, so two sets of words never overlap, the
    // button is never blank for a frame, and nothing slides when their
    // length changes.
    Widget part(_Look look) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(dimension: shape.iconSize, child: iconOf(look)),
        const SizedBox(width: 8),
        Flexible(
          child: Text(wordsOf(look), maxLines: 2, textAlign: TextAlign.center),
        ),
      ],
    );
    final content = Stack(
      alignment: Alignment.center,
      children: [
        for (final (look, weight) in shown)
          Opacity(
            opacity: ((weight - .45) / .55).clamp(0, 1),
            child: part(look),
          ),
      ],
    );
    final functional = !_done || _play == _Play.back
        ? (widget.saving ? widget.savingLabel : widget.takeLabel)
        : (widget.saving ? widget.savingLabel : widget.undoLabel);
    final radius = BorderRadius.circular(shape.radius);
    final button = OutlinedButton(
      key: undoing ? widget.undoKey : widget.takeKey,
      focusNode: widget.focusNode,
      onPressed: widget.onPressed,
      style: ButtonStyle(
        // The clock sets the fill and the outline every frame; the button's
        // own easing would trail them (a violet ring around a green fill).
        animationDuration: Duration.zero,
        minimumSize: WidgetStatePropertyAll(Size(0, shape.height)),
        padding: WidgetStatePropertyAll(
          shape.padding ?? const EdgeInsets.symmetric(horizontal: 20),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: radius),
        ),
        backgroundColor: WidgetStatePropertyAll(fill),
        foregroundColor: WidgetStatePropertyAll(ink),
        iconColor: WidgetStatePropertyAll(ink),
        side: WidgetStatePropertyAll(
          BorderSide(color: edge, width: _themeSide(theme)?.width ?? 1),
        ),
        iconSize: WidgetStatePropertyAll(shape.iconSize),
      ),
      child: Semantics(
        label: functional,
        hint: widget.hint,
        excludeSemantics: true,
        // A content-sized button eases between the looks' widths. A
        // zero-length AnimatedSize re-dirties itself mid-layout, so Reduce
        // motion takes the plain content.
        child: AppMotion.quiet(context)
            ? content
            : AnimatedSize(
                duration: AppMotion.standard,
                curve: AppMotion.curve,
                // Growing words are never clipped while the width eases.
                clipBehavior: Clip.none,
                child: content,
              ),
      ),
    );
    // The full width eases in or out with the shape, so a small outlined
    // "Taken now" settles into a full-width Undo without a jump.
    return Pressable(
      radius: radius,
      child: LayoutBuilder(
        builder: (context, box) {
          final full = box.hasBoundedWidth ? box.maxWidth : 0.0;
          final sized = ConstrainedBox(
            constraints: BoxConstraints(minWidth: full * width),
            child: button,
          );
          return width >= 1
              ? sized
              : Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: sized,
                );
        },
      ),
    );
  }
}

enum _Play { still, forward, back }

/// The outline the theme gives outlined buttons (wider in high contrast).
BorderSide? _themeSide(ThemeData theme) =>
    theme.outlinedButtonTheme.style?.side?.resolve(const {});

/// The check (or, for a skip, the circle and its slash) drawn as one stroke,
/// [progress] of the way along.
class _GlyphPainter extends CustomPainter {
  _GlyphPainter({
    required this.skipped,
    required this.progress,
    required this.color,
  });

  final bool skipped;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final s = size.shortestSide / 24;
    final path = Path();
    if (skipped) {
      path
        ..addOval(
          Rect.fromCircle(center: Offset(12 * s, 12 * s), radius: 8.5 * s),
        )
        ..moveTo(6 * s, 6 * s)
        ..lineTo(18 * s, 18 * s);
    } else {
      path
        ..moveTo(4.5 * s, 12.5 * s)
        ..lineTo(9.5 * s, 17.5 * s)
        ..lineTo(19.5 * s, 7 * s);
    }
    final metrics = path.computeMetrics().toList();
    final total = metrics.fold<double>(0, (sum, m) => sum + m.length);
    var left = total * progress.clamp(0, 1);
    final drawn = Path();
    for (final PathMetric metric in metrics) {
      if (left <= 0) break;
      drawn.addPath(metric.extractPath(0, left.clamp(0, metric.length)), .zero);
      left -= metric.length;
    }
    canvas.drawPath(
      drawn,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2 * s
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.progress != progress || old.color != color || old.skipped != skipped;
}
