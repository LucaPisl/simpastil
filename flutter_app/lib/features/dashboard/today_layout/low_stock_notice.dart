import 'package:flutter/material.dart';

import '../../../core/medication/expiry.dart';
import '../../../core/medication/unit_names.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/status_chip.dart';
import '../../../shared/widgets/stock_state_label.dart';
import '../today_side/stock_overview.dart';

/// The tan the low-stock notices share on every layout.
Color lowStockInk(BuildContext context) =>
    statusToneColor(Theme.of(context), StatusTone.attention);

/// What is left in words: "Refill soon · 5 left", or "Out of stock".
String lowStockDetail(AppLocalizations l, StockRow row) {
  if (row.level == StockLevel.out) return l.tt_lowDetailOut;
  final unit = row.unit;
  if (unit == null) return l.tt_refillSoon(row.left);
  // The unit in the app's language and in the right number ("5 tablets").
  final name = medicationUnitName(
    l,
    unit,
    unitCountFor(_leftQuantity(row.left)),
  );
  return l.tt_refillSoon('${row.left} ${name ?? unit}');
}

/// The number in a count shown to a person (`5`, `7,5`, `½`, `3⅓`), for
/// choosing the singular or plural of its unit; null when it has no number.
double? _leftQuantity(String left) {
  const glyphs = {'½': .5, '¼': .25, '¾': .75, '⅓': 1 / 3, '⅔': 2 / 3};
  final match = RegExp(
    r'^[−-]?(\d*)([,.]\d+)?([½¼¾⅓⅔])?$',
  ).firstMatch(left.trim());
  if (match == null) return null;
  final whole = double.tryParse(match.group(1) ?? '') ?? 0;
  final decimal = match.group(2) == null
      ? 0.0
      : double.tryParse('0.${match.group(2)!.substring(1)}') ?? 0.0;
  return whole + decimal + (glyphs[match.group(3)] ?? 0);
}

/// The expiry state in words: "Expires in 12 days", "Expires today" or
/// "Expired". Null when there is nothing to say.
String? expiryDetail(AppLocalizations l, ExpiryState state) {
  switch (state.phase) {
    case ExpiryPhase.expired:
      return l.mx_expiredBadge;
    case ExpiryPhase.soon:
      final days = state.daysLeft ?? 0;
      return days <= 0 ? l.mx_expiryDetailToday : l.mx_expiryDetailSoon(days);
    case ExpiryPhase.none:
    case ExpiryPhase.ok:
      return null;
  }
}

/// Everything a notice row says about [row]: the stock detail when it runs
/// low, then the expiry detail when it is near or past.
///
/// With [expiryOnly] the stock part is left out: a medication that is both low
/// and near its expiry date appears under both headings, each saying its own
/// part.
String stockNoticeDetail(
  AppLocalizations l,
  StockRow row, {
  bool expiryOnly = false,
}) => [
  if (row.low && !expiryOnly) lowStockDetail(l, row),
  ?expiryDetail(l, row.expiry),
].join(' · ');

/// One medication that runs low or nears its expiry date, as the same quiet
/// tan row on every Today layout: its name, "Refill soon · 5 left", and
/// "Later" (hides it until tomorrow, for the whole account) and "Add stock"
/// (opens the existing stock editor) where the layout has them. It records
/// nothing.
///
/// On a narrow row or at large text the buttons move under the words, so the
/// name is never squeezed to a sliver.
class LowStockRow extends StatelessWidget {
  const LowStockRow({
    super.key,
    required this.row,
    this.onAddStock,
    this.onLater,
    this.expiryOnly = false,
  });

  final StockRow row;

  /// Say only the expiry part of the row (see [stockNoticeDetail]).
  final bool expiryOnly;
  final VoidCallback? onAddStock;
  final VoidCallback? onLater;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme, text = theme.textTheme;
    final base = lowStockInk(context);
    final surface = Color.alphaBlend(
      base.withValues(alpha: theme.brightness == Brightness.dark ? .16 : .10),
      colors.surface,
    );
    final ink = AppTheme.readable(base, [surface], minimum: 4.5);
    final muted = AppTheme.readable(colors.onSurfaceVariant, [
      surface,
    ], minimum: 4.5);
    final showLow = row.low && !expiryOnly;
    final detail = stockNoticeDetail(l, row, expiryOnly: expiryOnly);
    // An expiry-only row's detail already starts with "Expires" or "Expired",
    // so only a low-stock row gets its heading word in front.
    final info = Semantics(
      label: showLow
          ? '${l.tt_lowStockNotice}. ${row.name}. $detail'
          : '${row.name}. $detail',
      excludeSemantics: true,
      child: Row(
        children: [
          Icon(
            showLow
                ? stockStateIcon(
                    row.level == StockLevel.out
                        ? StockState.out
                        : StockState.low,
                  )
                : Icons.event_busy_outlined,
            size: 18,
            color: ink,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  row.name,
                  style: text.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
                Text(detail, style: text.bodyMedium?.copyWith(color: ink)),
              ],
            ),
          ),
        ],
      ),
    );
    final buttonStyle = TextButton.styleFrom(
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 10),
    );
    final buttons = <Widget>[
      if (onLater != null)
        TextButton(
          key: const ValueKey('low-stock-later'),
          onPressed: onLater,
          style: buttonStyle.copyWith(
            foregroundColor: WidgetStatePropertyAll(muted),
          ),
          child: Text(l.tt_later),
        ),
      if (onAddStock != null && showLow)
        TextButton(
          key: const ValueKey('low-stock-add'),
          onPressed: onAddStock,
          style: buttonStyle.copyWith(
            foregroundColor: WidgetStatePropertyAll(ink),
            textStyle: WidgetStatePropertyAll(
              text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          child: Text(l.tt_addStock),
        ),
    ];
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    return Material(
      key: ValueKey('low-stock-${row.pillId}'),
      color: surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 2, 4, 2),
        child: LayoutBuilder(
          builder: (context, box) {
            final words = Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: info,
            );
            if (buttons.isEmpty) return words;
            if (box.maxWidth >= 320 * scale) {
              return Row(
                children: [
                  Expanded(child: words),
                  const SizedBox(width: 4),
                  ...buttons,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: words,
                ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Wrap(spacing: 4, children: buttons),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The rows that run low, and the rows near or past their expiry date. A
/// medication that is both is in both lists, so it is never missing from the
/// heading that fits one of its reasons.
///
/// Each group gets its own heading ("Low stock", "Expires soon"), so an
/// expiry notice never sits under "Low stock".
({List<StockRow> low, List<StockRow> expiring}) splitStockNotices(
  Iterable<StockRow> rows,
) => (
  low: [
    for (final row in rows)
      if (row.low) row,
  ],
  expiring: [
    for (final row in rows)
      if (row.expiry.needsNotice) row,
  ],
);

/// The heading of the expiry group: "Expired or expiring soon" when it holds
/// a medication that is already expired, else "Expires soon".
String expiryNoticeHeading(AppLocalizations l, Iterable<StockRow> members) =>
    members.any((row) => row.expiry.phase == ExpiryPhase.expired)
    ? l.rvu_expiredOrExpiringSoon
    : l.rvm_expiresSoonNotice;

/// The notices under their headings, for a layout that gives them their own
/// section.
class LowStockSection extends StatelessWidget {
  const LowStockSection({
    super.key,
    required this.rows,
    required this.onAddStock,
    required this.onLater,
  });

  final List<StockRow> rows;
  final void Function(StockRow row)? onAddStock;
  final void Function(StockRow row)? onLater;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final groups = splitStockNotices(rows);
    Widget group(
      String heading,
      List<StockRow> members, {
      bool expiryOnly = false,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Semantics(
            header: true,
            child: Text(
              heading,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        for (final row in members)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: lowStockRowFor(
              row,
              onAddStock,
              onLater,
              expiryOnly: expiryOnly,
            ),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (groups.low.isNotEmpty) group(l.tt_lowStockNotice, groups.low),
        if (groups.expiring.isNotEmpty)
          group(
            expiryNoticeHeading(l, groups.expiring),
            groups.expiring,
            expiryOnly: true,
          ),
      ],
    );
  }
}

/// [LowStockRow] for [row], binding the layout data's callbacks to it.
LowStockRow lowStockRowFor(
  StockRow row,
  void Function(StockRow row)? onAddStock,
  void Function(StockRow row)? onLater, {
  bool expiryOnly = false,
}) => LowStockRow(
  row: row,
  expiryOnly: expiryOnly,
  onAddStock: onAddStock == null ? null : () => onAddStock(row),
  onLater: onLater == null ? null : () => onLater(row),
);
