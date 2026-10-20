import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/medication/routine_definition.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/theme/pill_colors.dart';
import '../analytics/analytics_providers.dart';
import '../analytics/stock_changes.dart';

/// The stock changes of one day in History: each medication whose count went
/// up or down, with the count before and after and when it was recorded.
///
/// It only shows what the stock ledger already holds, and shows nothing at all
/// on a day without a change, so a quiet day stays quiet.
class HistoryStockChanges extends ConsumerWidget {
  const HistoryStockChanges({super.key, required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final changes =
        ref.watch(dayStockChangesProvider(routineDateKey(day))).value ??
        const <StockChange>[];
    if (changes.isEmpty) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      key: const ValueKey('history-stock-changes'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 10),
          child: Semantics(
            header: true,
            child: Text(
              l.th_stockChanges,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        Material(
          color: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: colors.outline, width: .8),
          ),
          child: Column(
            children: [
              for (var i = 0; i < changes.length; i++) ...[
                if (i > 0) Divider(height: 1, color: colors.outlineVariant),
                _StockChangeRow(
                  key: ValueKey('stock-change-${changes[i].eventId}'),
                  change: changes[i],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _StockChangeRow extends StatelessWidget {
  const _StockChangeRow({super.key, required this.change});

  final StockChange change;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final time = TimeOfDay.fromDateTime(change.at).format(context);
    final summary = l.th_stockChangeRow(
      change.pillName,
      change.before,
      change.after,
    );
    final kind = switch (change.kind) {
      'refill' => l.th_stockKindRefill,
      'correction' => l.th_stockKindCorrection,
      'dose_reversal' => l.th_stockKindUndone,
      _ => null,
    };
    return Semantics(
      label: l.th_stockChangeSemantics(
        change.pillName,
        change.before,
        change.after,
        time,
      ),
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: CircleAvatar(
                  radius: 6,
                  backgroundColor:
                      tryColorFromHex(change.pillColor) ?? colors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(summary, style: theme.textTheme.bodyLarge),
                    if (kind != null)
                      Text(
                        kind,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                time,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
