import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/inventory/low_stock.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';

/// A capsule fill-level gauge for remaining stock. The fill eases to its value
/// the first time it is shown and again, once, whenever the stock changes; a
/// change also sends one soft sheen along the liquid. It never overshoots, so
/// no frame shows more or less stock than there is, and nothing loops (quiet
/// motion: already there). The number
/// is always printed beside the capsule and spoken as "N left", so the level
/// is never colour-only.
class StockCapsule extends StatefulWidget {
  const StockCapsule({
    super.key,
    required this.stock,
    this.threshold,
    this.capacity,
    this.color,
    this.runsLowInDays,
  });

  final int stock;

  /// The medication's own colour; the fill uses it unless stock is low.
  final Color? color;
  final int? threshold;

  /// Whole days until the routine takes the stock to its low-stock level
  /// ([daysUntilLowStock]), when it can be forecast. Under two weeks reads as
  /// low, as on Today and in the blister ([isLowStock]).
  final int? runsLowInDays;

  /// What a full capsule means. Defaults to a comfortable multiple of the
  /// low-stock threshold, never less than the current stock.
  final int? capacity;

  @override
  State<StockCapsule> createState() => _StockCapsuleState();
}

class _StockCapsuleState extends State<StockCapsule>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fill = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
  );
  bool _started = false;
  double _from = 0;
  double _to = 0;

  /// Only a change of stock gets the sheen; the first appearance does not.
  bool _sheen = false;

  double get _level =>
      _from + (_to - _from) * Curves.easeOutCubic.transform(_fill.value);

  int get _capacity => math.max(
    1,
    widget.capacity ??
        math.max(widget.stock, math.max((widget.threshold ?? 0) * 4, 30)),
  );

  double get _target => (widget.stock / _capacity).clamp(0.0, 1.0);

  void _go({bool changed = false}) {
    if (AppMotion.quiet(context)) {
      _from = _to = _target;
      _sheen = false;
      _fill.value = 1;
      return;
    }
    _from = _level;
    _to = _target;
    _sheen = changed;
    _fill.forward(from: 0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _go();
    }
  }

  @override
  void didUpdateWidget(StockCapsule old) {
    super.didUpdateWidget(old);
    if (old.stock != widget.stock ||
        old.threshold != widget.threshold ||
        old.capacity != widget.capacity) {
      _go(changed: true);
    }
  }

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final t = widget.threshold;
    final attention =
        widget.stock <= 0 ||
        isLowStock(
          stock: widget.stock,
          threshold: t,
          runsLowInDays: widget.runsLowInDays,
        );
    final base = widget.color ?? cs.primary;
    final fillColor = attention ? cs.error : base;
    final label = l.sc_stockLeft(widget.stock);
    final negative = widget.stock < 0;
    final spoken = negative
        ? (Localizations.localeOf(context).languageCode == 'ro'
              ? 'Atenție: stoc negativ. $label'
              : 'Warning: negative stock. $label')
        : label;
    final numberText = widget.stock.toString();
    final at = label.indexOf(numberText);
    final style = text.titleMedium?.copyWith(
      color: attention ? cs.error : cs.onSurfaceVariant,
    );
    final strong = style?.copyWith(
      fontWeight: FontWeight.w800,
      color: attention ? cs.error : cs.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Semantics(
      label: spoken,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _fill,
              builder: (context, _) => CustomPaint(
                size: const Size(84, 26),
                painter: _CapsulePainter(
                  level: _level,
                  sheen: _sheen ? _fill.value : 0,
                  fill: fillColor,
                  shell: cs.surfaceContainerHighest,
                  outline: cs.outline,
                  glass: cs.surface,
                  mark: widget.threshold == null
                      ? null
                      : (widget.threshold! / _capacity).clamp(0.0, 1.0),
                ),
              ),
            ),
            const SizedBox(width: 10),
            if (negative) ...[
              Icon(Icons.warning_amber_rounded, size: 18, color: cs.error),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: at < 0
                  ? Text(label, style: strong)
                  : Text.rich(
                      TextSpan(
                        style: style,
                        children: [
                          TextSpan(text: label.substring(0, at)),
                          TextSpan(text: numberText, style: strong),
                          TextSpan(
                            text: label.substring(at + numberText.length),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A glass tube: an open track with tick marks, a liquid fill that ends in a
/// soft rounded surface, a glint along the top and an optional low-stock
/// notch. There is no thumb, so it cannot be read as a switch.
class _CapsulePainter extends CustomPainter {
  const _CapsulePainter({
    required this.level,
    required this.fill,
    required this.shell,
    required this.outline,
    required this.glass,
    required this.mark,
    this.sheen = 0,
  });

  /// 0..1 progress of the one-off sheen along the liquid; 0 draws none.
  final double sheen;
  final double level;
  final Color fill, shell, outline, glass;
  final double? mark;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    final body = RRect.fromRectAndRadius(Offset.zero & size, radius);
    canvas.drawRRect(body, Paint()..color = shell);
    canvas.save();
    canvas.clipRRect(body);
    const inset = 3.0;
    final inner = Rect.fromLTWH(
      inset,
      inset,
      size.width - inset * 2,
      size.height - inset * 2,
    );
    final width = inner.width * level;
    RRect? liquid;
    if (width > 0) {
      liquid = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          inner.left,
          inner.top,
          math.max(width, inner.height),
          inner.height,
        ),
        Radius.circular(inner.height / 2),
      );
      canvas.drawRRect(
        liquid,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color.lerp(fill, glass, .25)!, fill],
          ).createShader(liquid.outerRect),
      );
    }
    if (sheen > 0 && sheen < 1 && liquid != null) {
      final x = inner.left + math.max(width, inner.height) * sheen;
      final band = Rect.fromLTRB(x - 14, inner.top, x + 14, inner.bottom);
      // The glint stays inside the liquid, never spilling onto empty glass.
      canvas.save();
      canvas.clipRRect(liquid);
      canvas.drawRect(
        band,
        Paint()
          ..shader = LinearGradient(
            colors: [
              glass.withValues(alpha: 0),
              glass.withValues(alpha: .45 * math.sin(math.pi * sheen)),
              glass.withValues(alpha: 0),
            ],
          ).createShader(band),
      );
      canvas.restore();
    }
    final tick = Paint()
      ..color = outline.withValues(alpha: .35)
      ..strokeWidth = 1;
    for (final f in const [.25, .5, .75]) {
      final x = inner.left + inner.width * f;
      canvas.drawLine(
        Offset(x, size.height - inset - 3),
        Offset(x, size.height - inset),
        tick,
      );
    }
    if (mark != null) {
      final x = inner.left + inner.width * mark!;
      canvas.drawLine(
        Offset(x, inset),
        Offset(x, size.height - inset),
        Paint()
          ..color = outline.withValues(alpha: .7)
          ..strokeWidth = 1.2,
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.height / 2, 4.5, size.width - size.height, 2),
        const Radius.circular(1),
      ),
      Paint()..color = glass.withValues(alpha: .45),
    );
    canvas.restore();
    canvas.drawRRect(
      body.deflate(.75),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = outline,
    );
  }

  @override
  bool shouldRepaint(_CapsulePainter o) =>
      o.level != level ||
      o.sheen != sheen ||
      o.fill != fill ||
      o.shell != shell ||
      o.outline != outline ||
      o.glass != glass ||
      o.mark != mark;
}
