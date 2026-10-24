import 'package:flutter/material.dart';

import '../../../core/inventory/low_stock.dart';
import '../../../core/medication/expiry.dart';
import '../../../core/medication/medication_activity.dart';
import '../../../core/medication/medication_detail_repository.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/stock_state_label.dart';
import '../../dashboard/today_layout/low_stock_notice.dart' show expiryDetail;
import 'medication_identity.dart';
import 'supply_runway.dart';

/// The stock entries of [items] for the list's summary: each count with the
/// days until its routine takes it to the low-stock level, when that can be
/// forecast.
List<StockEntry> stockEntriesOf(
  Iterable<MedicationCareDetail> items, {
  required bool local,
  required DateTime now,
}) => [
  for (final m in items)
    (
      name: m.pill.name,
      asNeeded: m.pill.isPrn,
      stock: m.stock?.whole,
      threshold: m.pill.lowStockThreshold,
      needsRecount: m.stock?.needsRecount ?? false,
      runsLowInDays: m.pill.isPrn
          ? null
          : daysUntilLowStock(supplyForecastFor(m, local: local, now: now)),
    ),
];

/// The names of the medications of [items] that are expired or expire within
/// the notice window, for the list's header.
List<String> expiringNamesOf(
  Iterable<MedicationCareDetail> items, {
  required DateTime now,
}) => [
  for (final m in items)
    if (expiryState(m.pill.expiresOn, now).needsNotice) m.pill.name,
];

/// "Expired or expiring within 30 days: A, B", under the list's stock status.
/// Nothing when no medication needs the notice.
class MedicationExpiryNote extends StatelessWidget {
  const MedicationExpiryNote({super.key, required this.summary});

  final MedicationListSummary summary;

  @override
  Widget build(BuildContext context) {
    if (summary.expiring.isEmpty) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final ink = AppTheme.readable(
      theme.extension<AppSemanticColors>()?.statusWarning ??
          theme.colorScheme.tertiary,
      [theme.colorScheme.surface],
      minimum: 4.5,
    );
    return Padding(
      key: const ValueKey('medication-expiry-note'),
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.event_busy_outlined, size: 18, color: ink),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l.rvm_expiryHeader(summary.expiring.join(', ')),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Color _statusColor(BuildContext context, StockStatus status) {
  final scheme = Theme.of(context).colorScheme;
  final semantic = Theme.of(context).extension<AppSemanticColors>();
  return switch (status) {
    StockStatus.fine => semantic?.statusTaken ?? scheme.primary,
    StockStatus.soon => semantic?.statusWarning ?? scheme.tertiary,
    StockStatus.out => semantic?.statusMissed ?? scheme.error,
    StockStatus.recount => semantic?.statusWarning ?? scheme.tertiary,
    StockStatus.untracked => scheme.outline,
  };
}

String _statusTitle(AppLocalizations l, StockStatus status) => switch (status) {
  StockStatus.fine => l.tm_stockFine,
  StockStatus.soon => l.tm_stockSoon,
  StockStatus.out => l.tm_stockOut,
  StockStatus.recount => l.tm_stockRecount,
  StockStatus.untracked => l.tm_stockUntracked,
};

String _statusBody(AppLocalizations l, MedicationListSummary summary) =>
    switch (summary.status) {
      StockStatus.fine => l.tm_stockFineBody,
      StockStatus.soon ||
      StockStatus.out ||
      StockStatus.recount => summary.attention.join(', '),
      StockStatus.untracked => l.tm_stockUntrackedBody,
    };

/// One line on how the stock stands, above the list of a medium window. The
/// status is a word, not only a colour.
class MedicationStockStrip extends StatelessWidget {
  const MedicationStockStrip({super.key, required this.summary});

  final MedicationListSummary summary;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      key: const ValueKey('medication-stock-strip'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: .5)),
      ),
      child: Row(
        children: [
          _Dot(color: _statusColor(context, summary.status)),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: _statusTitle(l, summary.status),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextSpan(
                    text: '   ${_statusBody(l, summary)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// The three counts above the list of an expanded window: how the stock
/// stands, how many medications are scheduled and how many are as needed.
class MedicationStatChips extends StatelessWidget {
  const MedicationStatChips({
    super.key,
    required this.summary,
    required this.scheduledNames,
  });

  final MedicationListSummary summary;

  /// The scheduled medications, in the list's order.
  final List<String> scheduledNames;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _StatChip(
              key: const ValueKey('stat-stock'),
              leading: _Dot(color: _statusColor(context, summary.status)),
              title: _statusTitle(l, summary.status),
              body: _statusBody(l, summary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StatChip(
              key: const ValueKey('stat-scheduled'),
              leading: _Count(summary.scheduled),
              title: l.tm_scheduledLabel,
              body: scheduledNames.join(', '),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StatChip(
              key: const ValueKey('stat-as-needed'),
              leading: _Count(summary.asNeeded),
              title: l.t09_prn,
              body: l.tm_asNeededBody,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    super.key,
    required this.leading,
    required this.title,
    required this.body,
  });

  final Widget leading;
  final String title, body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: .5)),
      ),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (body.isNotEmpty)
                  Text(
                    body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 12,
    height: 12,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _Count extends StatelessWidget {
  const _Count(this.count);
  final int count;

  @override
  Widget build(BuildContext context) => Text(
    '$count',
    style: Theme.of(
      context,
    ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
  );
}

/// A medication as one compact row: its mark, name, a line on its schedule
/// and what is left of it. In the list beside the detail pane it is the
/// selection; on a medium window it is a tile that opens the detail page.
///
/// Tap and long press belong to one [InkWell]; when [checked] is set the row
/// is in selection mode and the mark gives way to a checkbox.
class MedicationCompactRow extends StatelessWidget {
  const MedicationCompactRow({
    super.key,
    required this.id,
    required this.name,
    required this.tint,
    required this.shape,
    required this.subtitle,
    required this.stock,
    required this.threshold,
    this.stockText,
    this.needsRecount = false,
    this.expiry = ExpiryState.none,
    this.dosageNeedsReview = false,
    this.stockInline = false,
    this.selected = false,
    this.checked,
    this.onTap,
    this.onLongPress,
    this.onCheckedChanged,
  });

  final String id, name, subtitle;
  final Color tint;
  final MedicationShape shape;
  final int? stock, threshold;

  /// The count as printed, when it is the exact stock in a unit.
  final String? stockText;

  /// The count did not move for a dose it cannot subtract exactly.
  final bool needsRecount;

  /// Where the expiry date stands; a tag with words and an icon shows when it
  /// is near or past.
  final ExpiryState expiry;

  /// The medication keeps its original dosage text and it has not been
  /// reviewed; the row says so, as the phone card does.
  final bool dosageNeedsReview;

  /// Shows the stock after the schedule instead of at the end of the row.
  final bool stockInline;

  /// This row is the one the detail pane shows.
  final bool selected;

  /// Null outside selection mode.
  final bool? checked;
  final VoidCallback? onTap, onLongPress;
  final ValueChanged<bool?>? onCheckedChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Semantics(
      selected: selected,
      child: AnimatedContainer(
        duration: AppMotion.duration(context),
        curve: AppMotion.curve,
        decoration: BoxDecoration(
          color: selected
              ? cs.primaryContainer.withValues(alpha: dark ? .38 : .55)
              : cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected
                ? cs.primary
                : cs.outlineVariant.withValues(alpha: .5),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey('medication-$id'),
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: checked != null
                        ? Checkbox(
                            key: ValueKey('select-medication-$id'),
                            value: checked,
                            onChanged: onCheckedChanged,
                          )
                        : DecoratedBox(
                            decoration: BoxDecoration(
                              color: tint.withValues(alpha: dark ? .22 : .16),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Center(
                              child: ExcludeSemantics(
                                child: PillMark(
                                  pillId: id,
                                  name: name,
                                  color: tint,
                                  fallbackShape: shape,
                                  size: 30,
                                ),
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        if (stockInline)
                          Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (subtitle.isNotEmpty)
                                Text(
                                  subtitle,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              _StockText(
                                key: ValueKey('medication-stock-$id'),
                                stock: stock,
                                stockText: stockText,
                                needsRecount: needsRecount,
                                threshold: threshold,
                              ),
                            ],
                          )
                        else if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        if (dosageNeedsReview)
                          Text(
                            AppLocalizations.of(context).t09_legacyDosage,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        if (expiry.needsNotice)
                          MedicationExpiryTag(
                            key: ValueKey('medication-expiry-$id'),
                            state: expiry,
                          ),
                      ],
                    ),
                  ),
                  if (!stockInline) ...[
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 104),
                      child: _StockText(
                        key: ValueKey('medication-stock-$id'),
                        stock: stock,
                        stockText: stockText,
                        needsRecount: needsRecount,
                        threshold: threshold,
                        end: true,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Expires in 12 days", "Expires today" or "Expired" on a row: an icon and
/// words, in the tan the notices share (red once expired).
class MedicationExpiryTag extends StatelessWidget {
  const MedicationExpiryTag({
    super.key,
    required this.state,
    this.center = false,
  });

  final ExpiryState state;

  /// Centres the tag, for a card.
  final bool center;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final semantic = theme.extension<AppSemanticColors>();
    final expired = state.phase == ExpiryPhase.expired;
    final ink = AppTheme.readable(
      expired
          ? semantic?.statusMissed ?? cs.error
          : semantic?.statusWarning ?? cs.tertiary,
      [cs.surfaceContainerLow, cs.primaryContainer],
      minimum: 4.5,
    );
    final text = expiryDetail(l, state);
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ExcludeSemantics(
            child: Icon(Icons.event_busy_outlined, size: 16, color: ink),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              textAlign: center ? TextAlign.center : TextAlign.start,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What is left of a medication, for a row. A low count reads "Low · N left"
/// and an empty one "Out", each with its own icon, and a negative one carries
/// a warning icon and is spoken as a warning, like the capsule on the
/// medication's page. The warning colour is only a second signal.
class _StockText extends StatelessWidget {
  const _StockText({
    super.key,
    required this.stock,
    required this.threshold,
    this.stockText,
    this.needsRecount = false,
    this.end = false,
  });

  final int? stock, threshold;

  /// The count as printed, when it is the exact stock in a unit.
  final String? stockText;

  /// A recount is due: the words and a warning icon say so, not colour alone.
  final bool needsRecount;

  /// Right-aligns the text, for the end of a row.
  final bool end;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final count = stock;
    final warning =
        theme.extension<AppSemanticColors>()?.statusMissed ?? cs.error;
    if (count == null) {
      return Text(
        l.tm_noCount,
        maxLines: 2,
        textAlign: end ? TextAlign.end : TextAlign.start,
        style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
      );
    }
    final negative = count < 0;
    final low = count <= 0 || (threshold != null && count <= threshold!);
    final state = negative || !low
        ? null
        : count == 0
        ? StockState.out
        : StockState.low;
    final recount = needsRecount && state == null && !negative;
    // A recount is not urgent: it takes the same tan as the detail page,
    // and red stays for a count that is low, out or below zero.
    final tone = low
        ? warning
        : recount
        ? theme.extension<AppSemanticColors>()?.statusWarning ?? cs.tertiary
        : null;
    final label = state != null
        ? stockStateText(l, state, stockText ?? '$count')
        : recount
        ? l.stock_needsRecountLeft(stockText ?? '$count')
        : l.pills_stockLeft(stockText ?? '$count');
    return Semantics(
      label: negative ? l.tm_stockNegativeSpoken(label) : label,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: end
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: [
            if (negative || recount || state != null) ...[
              Icon(
                state == null
                    ? Icons.warning_amber_rounded
                    : stockStateIcon(state),
                size: 16,
                color: tone,
              ),
              const SizedBox(width: 3),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 2,
                textAlign: end ? TextAlign.end : TextAlign.start,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tone ?? cs.onSurfaceVariant,
                  fontWeight: tone != null ? FontWeight.w700 : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
