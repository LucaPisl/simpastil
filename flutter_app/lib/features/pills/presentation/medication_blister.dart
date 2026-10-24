import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/inventory/low_stock.dart';
import '../../../l10n/app_localizations.dart';
import 'medication_identity.dart';
import '../../../shared/motion/app_motion.dart';

/// How one medication's supply reads in the blister card. It follows the
/// same rule ([isLowStock]) as the stock card on Today and the summary above
/// the list, so they never disagree.
enum BlisterState {
  /// A full, domed pocket: there is enough.
  full,

  /// A dimpled pocket: at or under the low-stock level, or the routine
  /// reaches it within two weeks.
  refill,

  /// A pushed-through pocket: none left.
  empty,

  /// An outlined pocket: supply is not tracked.
  untracked,
}

BlisterState blisterStateOf(int? stock, int? threshold, {int? runsLowInDays}) {
  if (stock == null) return BlisterState.untracked;
  if (stock <= 0) return BlisterState.empty;
  if (isLowStock(
    stock: stock,
    threshold: threshold,
    runsLowInDays: runsLowInDays,
  )) {
    return BlisterState.refill;
  }
  return BlisterState.full;
}

@immutable
class BlisterCell {
  const BlisterCell({
    required this.id,
    required this.name,
    required this.color,
    this.shape = MedicationShape.capsule,
    this.stock,
    this.stockText,
    this.threshold,
    this.runsLowInDays,
  });

  final String id, name;
  final Color color;

  /// The silhouette of the medication's pill.
  final MedicationShape shape;
  final int? stock, threshold;

  /// The count as printed, when it is the exact stock in a unit.
  final String? stockText;

  /// Whole days until the routine takes the stock to its low-stock level
  /// ([daysUntilLowStock]); null for as-needed medication or no forecast.
  final int? runsLowInDays;

  BlisterState get state =>
      blisterStateOf(stock, threshold, runsLowInDays: runsLowInDays);
}

/// A small blister card: one pocket per medication, in its colour, showing
/// at a glance which needs attention, with the same facts in words beside
/// it. A faint foil sheen moves across it only while the list scrolls. A new
/// medication's pocket presses into place and a refill puffs its pocket back
/// up. Tapping a pocket presses it in and calls [onTap]. Nothing runs at
/// rest.
class MedicationBlister extends StatefulWidget {
  const MedicationBlister({
    super.key,
    required this.cells,
    required this.onTap,
    this.scroll,
  });

  final List<BlisterCell> cells;
  final ValueChanged<String> onTap;

  /// The list the card sits in; its offset moves the sheen.
  final ScrollController? scroll;

  /// The card shows only when some medication tracks its supply.
  static bool shows(List<BlisterCell> cells) =>
      cells.any((c) => c.state != BlisterState.untracked);

  static const pocket = Size(26, 40);

  /// Distance between pocket centres: each pocket's touch area is 48 × 48.
  static const pitch = 48.0;
  static const padding = 8.0;

  @override
  State<MedicationBlister> createState() => _MedicationBlisterState();
}

class _MedicationBlisterState extends State<MedicationBlister> {
  late Set<String> _known;
  final _arriving = <String>{};

  @override
  void initState() {
    super.initState();
    _known = {for (final c in widget.cells) c.id};
  }

  @override
  void didUpdateWidget(MedicationBlister old) {
    super.didUpdateWidget(old);
    final now = {for (final c in widget.cells) c.id};
    // Only the pockets new in this update press into place.
    _arriving
      ..clear()
      ..addAll(now.difference(_known));
    _known = now;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final cells = widget.cells;
    final refill = [
      for (final c in cells)
        if (c.state == BlisterState.refill) c.name,
    ];
    final empty = [
      for (final c in cells)
        if (c.state == BlisterState.empty) c.name,
    ];
    final words = [
      if (empty.isNotEmpty) l.blister_empty(empty.join(', ')),
      if (refill.isNotEmpty) l.blister_refill(refill.join(', ')),
      if (empty.isEmpty && refill.isEmpty) l.blister_fine,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // The card hugs its pockets: as many columns as fit in a little over
        // half the width, and rows only as full as there are medications.
        final room = constraints.maxWidth * .6 - 2 * MedicationBlister.padding;
        final fit = math.max(1, (room / MedicationBlister.pitch).floor());
        final rows = (cells.length / fit).ceil();
        final columns = (cells.length / rows).ceil();
        final card = Semantics(
          container: true,
          explicitChildNodes: true,
          label: l.blister_label,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _FoilPainter(
                foil: _foilOf(cs),
                edge: cs.outlineVariant.withValues(alpha: .6),
              ),
              foregroundPainter: _SheenPainter(
                scroll: widget.scroll,
                color: cs.primary.withValues(alpha: .10),
              ),
              child: Padding(
                padding: const EdgeInsets.all(MedicationBlister.padding),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var r = 0; r < rows; r++)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (
                            var i = r * columns;
                            i < math.min(cells.length, (r + 1) * columns);
                            i++
                          )
                            _Pocket(
                              key: ValueKey('blister-${cells[i].id}'),
                              cell: cells[i],
                              foil: _foilOf(cs),
                              arriving: _arriving.contains(cells[i].id),
                              onTap: () => widget.onTap(cells[i].id),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        return Row(
          children: [
            card,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final w in words)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        w,
                        style: text.bodyMedium?.copyWith(
                          color: w == l.blister_fine
                              ? cs.onSurfaceVariant
                              : cs.onSurface,
                          fontWeight: w == l.blister_fine
                              ? null
                              : FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

Color _foilOf(ColorScheme cs) =>
    Color.lerp(cs.surfaceContainerHigh, cs.outline, .10)!;

/// One medication's pocket and its 48 × 48 touch area.
class _Pocket extends StatefulWidget {
  const _Pocket({
    super.key,
    required this.cell,
    required this.foil,
    required this.arriving,
    required this.onTap,
  });

  final BlisterCell cell;
  final Color foil;
  final bool arriving;
  final VoidCallback onTap;

  @override
  State<_Pocket> createState() => _PocketState();
}

class _PocketState extends State<_Pocket> {
  bool _pressed = false;
  late double _dome = domeOf(widget.cell.state);
  late bool _arrived = !widget.arriving;
  bool _hidden = false;
  Timer? _reveal;

  /// The page above this one, while there is one; the pocket counts as
  /// covered until it has gone entirely.
  Animation<double>? _above;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final above = ModalRoute.of(context)?.secondaryAnimation;
    if (above != _above) {
      _above?.removeStatusListener(_aboveMoved);
      _above = above?..addStatusListener(_aboveMoved);
    }
  }

  void _aboveMoved(AnimationStatus _) {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _above?.removeStatusListener(_aboveMoved);
    _reveal?.cancel();
    super.dispose();
  }

  /// Shows the pocket as it now is. A change made while the pocket could not
  /// be seen, such as a refill on the medication's page, waits until that
  /// page has gone and a beat more, so the puff is seen rather than lost
  /// behind it.
  void _follow(bool live, bool quiet) {
    if (!live) {
      _hidden = true;
      return;
    }
    final changed = _dome != domeOf(widget.cell.state) || !_arrived;
    if (_hidden && changed && !quiet) {
      _reveal?.cancel();
      _reveal = Timer(AppMotion.micro, () {
        if (mounted) setState(() => _reveal = null);
      });
    }
    _hidden = false;
    if (_reveal == null) {
      _dome = domeOf(widget.cell.state);
      _arrived = true;
    }
  }

  /// How domed a pocket in [state] stands: 1 full, low dimpled, 0 flat.
  static double domeOf(BlisterState state) => switch (state) {
    BlisterState.full => 1,
    BlisterState.refill => .3,
    BlisterState.empty || BlisterState.untracked => 0,
  };

  void _press(bool down) {
    if (_pressed != down) setState(() => _pressed = down);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final quiet = AppMotion.quiet(context);
    final cell = widget.cell;
    final label = switch (cell.state) {
      BlisterState.full => l.blister_cellFull(
        cell.name,
        cell.stockText ?? '${cell.stock!}',
      ),
      BlisterState.refill => l.blister_cellRefill(
        cell.name,
        cell.stockText ?? '${cell.stock!}',
      ),
      BlisterState.empty => l.blister_cellEmpty(cell.name),
      BlisterState.untracked => l.blister_cellUntracked(cell.name),
    };
    _follow(
      TickerMode.valuesOf(context).enabled && (_above?.isDismissed ?? true),
      quiet,
    );
    return Semantics(
      container: true,
      button: true,
      label: label,
      onTapHint: l.blister_show,
      onTap: widget.onTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _press(true),
          onTapUp: (_) => _press(false),
          onTapCancel: () => _press(false),
          onTap: widget.onTap,
          child: SizedBox.square(
            dimension: MedicationBlister.pitch,
            child: TweenAnimationBuilder<double>(
              // A pocket added after the card first showed presses into
              // place; the rest are simply there.
              tween: Tween(
                begin: widget.arriving && !quiet ? 0 : 1,
                end: _arrived || quiet ? 1 : 0,
              ),
              duration: AppMotion.emphasis,
              curve: AppMotion.curve,
              builder: (context, arrive, _) => TweenAnimationBuilder<double>(
                // A refill puffs a dimpled pocket back up, a little past.
                tween: Tween(end: _dome),
                duration: quiet ? Duration.zero : AppMotion.emphasis,
                curve: Curves.easeOutBack,
                builder: (context, d, _) => TweenAnimationBuilder<double>(
                  tween: Tween(end: _pressed ? .35 : 1),
                  duration: quiet ? Duration.zero : AppMotion.micro,
                  curve: AppMotion.curve,
                  builder: (context, press, _) => CustomPaint(
                    // Pressed, every pocket sinks a little into the foil.
                    painter: BlisterPocketPainter(
                      sink: (1 - press) / .65,
                      state: cell.state,
                      color: cell.color,
                      shape: cell.shape,
                      foil: widget.foil,
                      hole: Color.lerp(widget.foil, cs.scrim, .45)!,
                      tear: Color.lerp(widget.foil, cs.onSurface, .35)!,
                      surface: cs.surface,
                      ink: cs.onSurface,
                      dome: d * press,
                      arrive: arrive,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The card's foil: a soft rounded sheet with an embossed edge.
class _FoilPainter extends CustomPainter {
  _FoilPainter({required this.foil, required this.edge});

  final Color foil, edge;

  @override
  void paint(Canvas canvas, Size size) {
    final card = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(14),
    );
    canvas.drawRRect(card, Paint()..color = foil);
    canvas.drawRRect(
      card.deflate(.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = edge,
    );
  }

  @override
  bool shouldRepaint(_FoilPainter old) => old.foil != foil || old.edge != edge;
}

/// A faint diagonal band of light that slides across the foil as the list
/// scrolls, and stands still when it does.
class _SheenPainter extends CustomPainter {
  _SheenPainter({required this.scroll, required this.color})
    : super(repaint: scroll);

  final ScrollController? scroll;
  final Color color;

  /// Scroll distance for the band to cross the card once.
  static const travel = 320.0;

  @override
  void paint(Canvas canvas, Size size) {
    final s = scroll;
    final offset = s != null && s.hasClients ? s.offset : 0.0;
    final band = size.width * .45;
    final span = size.width + 2 * band;
    // At the top of the list the band waits just off the card's left edge.
    final x = (offset / travel * span) % span - band;
    final card = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(14),
    );
    canvas.save();
    canvas.clipRRect(card);
    final rect = Rect.fromLTWH(x, 0, band, size.height);
    canvas.drawRect(
      rect.inflate(size.height),
      Paint()
        ..shader = LinearGradient(
          begin: const Alignment(-1, -.4),
          end: const Alignment(1, .4),
          colors: [
            color.withValues(alpha: 0),
            color,
            color.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SheenPainter old) =>
      old.scroll != scroll || old.color != color;
}

/// One pocket of the blister, centred in its touch area: a clear plastic
/// dome with the medication's capsule inside, pressed into the foil.
class BlisterPocketPainter extends CustomPainter {
  BlisterPocketPainter({
    required this.state,
    required this.color,
    required this.foil,
    required this.hole,
    required this.tear,
    required this.dome,
    required this.arrive,
    required this.surface,
    required this.ink,
    this.shape = MedicationShape.capsule,
    this.sink = 0,
  });

  final BlisterState state;
  final Color color, foil, hole, tear;

  /// The page's surface and text colours, which shade the capsule's second
  /// half and outline as on the medication's card.
  final Color surface, ink;

  /// The silhouette of the pill in the pocket.
  final MedicationShape shape;

  /// 1 fully domed, 0.3 dimpled, 0 flat. It overshoots a little on a puff.
  final double dome;

  /// 0 to 1 as a new pocket presses into place.
  final double arrive;

  /// 0 at rest, 1 while a finger presses the pocket.
  final double sink;

  @override
  void paint(Canvas canvas, Size size) {
    if (arrive <= 0) return;
    final c = size.center(Offset.zero);
    final alpha = arrive.clamp(0.0, 1.0);
    canvas.save();
    // Arriving, the pocket comes down onto the foil from a little above.
    final lift = 1 + .25 * (1 - arrive) - .08 * sink;
    canvas.translate(c.dx, c.dy);
    canvas.scale(lift);
    canvas.translate(-c.dx, -c.dy);
    final rect = Rect.fromCenter(
      center: c,
      width: MedicationBlister.pocket.width,
      height: MedicationBlister.pocket.height,
    );
    final pocket = RRect.fromRectAndRadius(
      rect,
      Radius.circular(rect.width / 2),
    );

    // The heat-seal ring pressed into the foil around every pocket.
    canvas.drawRRect(
      pocket.inflate(3),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Color.lerp(foil, tear, .4)!.withValues(alpha: .7 * alpha),
    );

    switch (state) {
      case BlisterState.untracked:
        _dashed(
          canvas,
          Path()..addRRect(pocket.deflate(1)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..strokeCap = StrokeCap.round
            ..color = color.withValues(alpha: .8 * alpha),
        );
      case BlisterState.empty:
        _pushedThrough(canvas, pocket, rect, alpha);
      case BlisterState.full || BlisterState.refill:
        _withCapsule(canvas, pocket, rect, alpha);
    }
    canvas.restore();
  }

  /// Pushed through: the plastic crushed flat into a dark hollow, and the
  /// foil over it torn open along a jagged line.
  void _pushedThrough(Canvas canvas, RRect pocket, Rect rect, double alpha) {
    canvas.drawRRect(pocket, Paint()..color = hole.withValues(alpha: alpha));
    final y = rect.top + rect.height * .42;
    final edge = Path()..moveTo(rect.left, y + 2);
    const teeth = 5;
    for (var i = 1; i <= teeth; i++) {
      edge.lineTo(rect.left + rect.width * i / teeth, y + (i.isOdd ? -4 : 3));
    }
    canvas.save();
    canvas.clipRRect(pocket);
    // The flap of foil still hanging over the top of the hollow.
    canvas.drawPath(
      Path.from(edge)
        ..lineTo(rect.right, rect.top)
        ..lineTo(rect.left, rect.top)
        ..close(),
      Paint()..color = foil.withValues(alpha: alpha),
    );
    canvas.restore();
    canvas.drawPath(
      edge,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round
        ..color = tear.withValues(alpha: alpha),
    );
  }

  /// The capsule in its dome. As [dome] falls the plastic dimples, its light
  /// moves to the other side and a crease shows across it.
  void _withCapsule(Canvas canvas, RRect pocket, Rect rect, double alpha) {
    final k = ((dome - .3) / .7).clamp(0.0, 1.25);
    final up = k.clamp(0.0, 1.0);
    // The plastic casts a little shadow on the foil when it stands up.
    if (k > 0) {
      canvas.drawRRect(
        pocket.shift(Offset(0, 1.5 * k)),
        Paint()
          ..color = Colors.black.withValues(alpha: .28 * up * alpha)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
      );
    }
    canvas.drawRRect(
      pocket,
      Paint()..color = Color.lerp(foil, surface, .5)!.withValues(alpha: alpha),
    );

    // The pill itself, in the medication's own silhouette as on its card,
    // sitting lower when the plastic is pressed down onto it. It carries no
    // letter: the pocket is too small, and the name is written beside it.
    final side = rect.width * .86;
    final at = rect.center.translate(0, 1.5 * (1 - up));
    canvas.save();
    canvas.translate(at.dx - side / 2, at.dy - side / 2);
    canvas.saveLayer(
      Offset.zero & Size.square(side),
      Paint()..color = Color.fromRGBO(0, 0, 0, alpha),
    );
    MedicationMarkPainter(
      base: color,
      light: Color.lerp(color, surface, .55)!,
      outline: Color.lerp(color, ink, .45)!,
      shape: shape,
    ).paint(canvas, Size.square(side));
    canvas.restore();
    canvas.restore();

    // The clear plastic over it: a rim, and light that sits on the left of a
    // dome and slides to the right as it dimples.
    canvas.drawRRect(
      pocket.deflate(.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: (.16 + .14 * up) * alpha),
    );
    final glint = Rect.fromLTWH(
      rect.left + 4 + (rect.width - 13) * (1 - up),
      rect.top + 6,
      5,
      rect.height * (.25 + .2 * up),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(glint, const Radius.circular(2.5)),
      Paint()..color = Colors.white.withValues(alpha: (.18 + .3 * up) * alpha),
    );
    if (up < 1) {
      // The dimple's crease across the plastic.
      final y = rect.center.dy - 3;
      canvas.drawPath(
        Path()
          ..moveTo(rect.left + 3, y)
          ..quadraticBezierTo(rect.center.dx, y + 7, rect.right - 3, y),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..strokeCap = StrokeCap.round
          ..color = ink.withValues(alpha: .45 * (1 - up) * alpha),
      );
    }
  }

  static void _dashed(Canvas canvas, Path path, Paint paint) {
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 7) {
        canvas.drawPath(metric.extractPath(d, d + 3.5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(BlisterPocketPainter old) =>
      old.state != state ||
      old.shape != shape ||
      old.color != color ||
      old.foil != foil ||
      old.hole != hole ||
      old.tear != tear ||
      old.surface != surface ||
      old.ink != ink ||
      old.dome != dome ||
      old.arrive != arrive ||
      old.sink != sink;
}

/// Draws the eye to one medication's card after its pocket was tapped: the
/// card swells a touch and its edge lights up once, each time [count]
/// rises. In quiet mode only the edge lights. Nothing runs at rest.
class BlisterPulse extends StatefulWidget {
  const BlisterPulse({
    super.key,
    required this.count,
    required this.color,
    required this.child,
  });

  final int count;
  final Color color;
  final Widget child;

  @override
  State<BlisterPulse> createState() => _BlisterPulseState();
}

class _BlisterPulseState extends State<BlisterPulse>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: AppMotion.emphasis * 2,
  );

  @override
  void didUpdateWidget(BlisterPulse old) {
    super.didUpdateWidget(old);
    if (widget.count > old.count) _pulse.forward(from: 0);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final quiet = AppMotion.quiet(context);
    return AnimatedBuilder(
      animation: _pulse,
      child: widget.child,
      builder: (context, child) {
        final t = _pulse.value;
        // Up quickly, down slowly. The tree keeps its shape at rest so the
        // card below never loses its state.
        final k = t < .3
            ? Curves.easeOut.transform(t / .3)
            : 1 - Curves.easeInOut.transform((t - .3) / .7);
        return Transform.scale(
          scale: quiet ? 1 : 1 + .03 * k,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: widget.color.withValues(alpha: .9 * k),
                width: 2,
              ),
            ),
            child: child,
          ),
        );
      },
    );
  }
}
