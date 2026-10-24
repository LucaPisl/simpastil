import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// How stock that needs attention reads. Ordinary stock has no state: it is
/// just a count.
enum StockState { low, out }

/// The icon that marks a [StockState]: a warning triangle for low, a barred
/// circle for out. The two differ in shape, not only in colour.
IconData stockStateIcon(StockState state) => switch (state) {
  StockState.low => Icons.warning_amber_rounded,
  StockState.out => Icons.block_rounded,
};

/// The words for a [StockState]: "Low · 6 left" (with the count in [left]) or
/// "Out".
String stockStateText(AppLocalizations l, StockState state, String left) =>
    switch (state) {
      StockState.low => l.stock_lowLeft(left),
      StockState.out => l.stock_out,
    };

/// A stock state as an icon and words, so low or out stock is never told by
/// colour alone. The colour ([color], normally the warning colour) is only a
/// second signal. Excluded from semantics: callers speak the state in their
/// own label.
class StockStateLabel extends StatelessWidget {
  const StockStateLabel({
    super.key,
    required this.state,
    required this.left,
    this.style,
    this.color,
    this.iconSize = 16,
  });

  final StockState state;

  /// The count as plain text, used by the low state.
  final String left;
  final TextStyle? style;
  final Color? color;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ink = color ?? style?.color ?? Theme.of(context).colorScheme.error;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(stockStateIcon(state), size: iconSize, color: ink),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            stockStateText(l, state, left),
            style: style?.copyWith(color: ink, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}
