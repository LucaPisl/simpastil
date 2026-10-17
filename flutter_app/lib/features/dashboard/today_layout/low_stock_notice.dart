import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/status_chip.dart';
import '../today_side/stock_overview.dart';

/// The notice for one medication that runs low, in words. A scheduled
/// medication says how long it lasts; one that is already at its level (or
/// as-needed, which has no routine to run through) says what is left.
String lowStockSentence(AppLocalizations l, StockRow row) {
  if (row.level == StockLevel.out) return l.tt_lowOut(row.name);
  final days = row.runsLowInDays;
  if (!row.asNeeded && days != null && days > 0) {
    return l.tt_lowRunsIn(row.name, days);
  }
  final unit = row.unit;
  return l.tt_lowNow(row.name, unit == null ? row.left : '${row.left} $unit');
}

/// The amber the low-stock notices share on every layout.
Color lowStockInk(BuildContext context) =>
    statusToneColor(Theme.of(context), StatusTone.attention);

/// A rounded amber strip around [child]: one look for every layout's notice.
class LowStockSurface extends StatelessWidget {
  const LowStockSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    this.radius = 14,
    this.onTap,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ink = lowStockInk(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(color: ink.withValues(alpha: .4)),
    );
    return Material(
      color: ink.withValues(alpha: .12),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? Padding(padding: padding, child: child)
          : InkWell(
              onTap: onTap,
              customBorder: shape,
              child: Padding(padding: padding, child: child),
            ),
    );
  }
}

/// "Add stock": a quiet text button in the notice's own ink. Tapping it
/// opens the existing stock editor; it records nothing.
class AddStockButton extends StatelessWidget {
  const AddStockButton({super.key, required this.onPressed, this.outlined});
  final VoidCallback onPressed;

  /// Draws it as an outlined button (Action inbox) instead of text.
  final bool? outlined;

  @override
  Widget build(BuildContext context) {
    final ink = lowStockInk(context);
    final label = Text(AppLocalizations.of(context).tt_addStock);
    final text = Theme.of(context).textTheme.labelLarge;
    if (outlined == true) {
      return OutlinedButton(
        key: const ValueKey('low-stock-add'),
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          side: BorderSide(color: ink.withValues(alpha: .7)),
          textStyle: text,
          minimumSize: const Size(0, 44),
        ),
        child: label,
      );
    }
    return TextButton(
      key: const ValueKey('low-stock-add'),
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: ink,
        textStyle: text?.copyWith(fontWeight: FontWeight.w700),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(48, 44),
      ),
      child: label,
    );
  }
}

/// One low-stock notice as a single amber line: a box icon, the sentence and,
/// when the workspace has a stock editor, "Add stock". Used by Timeline,
/// People lanes and Day planner, which each place it in their own structure.
class LowStockLine extends StatelessWidget {
  const LowStockLine({
    super.key,
    required this.row,
    this.onAddStock,
    this.dense = false,
  });
  final StockRow row;
  final VoidCallback? onAddStock;

  /// A chip-sized line, for a place with little room (the planner's
  /// all-day row, a person's lane).
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ink = lowStockInk(context);
    final text = Theme.of(context).textTheme;
    final sentence = lowStockSentence(l, row);
    return LowStockSurface(
      key: ValueKey('low-stock-${row.pillId}'),
      padding: EdgeInsets.fromLTRB(12, dense ? 6 : 8, 4, dense ? 6 : 8),
      radius: dense ? 12 : 14,
      child: Row(
        children: [
          Icon(Icons.inventory_2_outlined, size: 18, color: ink),
          const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              label: '${l.tt_lowStockNotice}. $sentence',
              excludeSemantics: true,
              child: Text(
                sentence,
                style: text.bodyMedium?.copyWith(color: ink),
              ),
            ),
          ),
          if (onAddStock != null) ...[
            const SizedBox(width: 4),
            AddStockButton(onPressed: onAddStock!),
          ] else
            const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// The Focus deck's notice: a slim amber line above the deck. Tapping it
/// opens the stock editor when the workspace has one.
class LowStockSlim extends StatelessWidget {
  const LowStockSlim({super.key, required this.row, this.onAddStock});
  final StockRow row;
  final VoidCallback? onAddStock;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ink = lowStockInk(context);
    final sentence = lowStockSentence(l, row);
    return Semantics(
      button: onAddStock != null,
      label: onAddStock == null
          ? '${l.tt_lowStockNotice}. $sentence'
          : '${l.tt_lowStockNotice}. $sentence. ${l.tt_addStock}',
      excludeSemantics: true,
      child: LowStockSurface(
        key: ValueKey('low-stock-${row.pillId}'),
        onTap: onAddStock,
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.inventory_2_outlined, size: 18, color: ink),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                sentence,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: ink),
              ),
            ),
            if (onAddStock != null) ...[
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, size: 20, color: ink),
            ],
          ],
        ),
      ),
    );
  }
}
