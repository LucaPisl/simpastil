import 'package:flutter/material.dart';

import '../../../core/inventory/exact_stock.dart';
import '../../../core/inventory/stock_format.dart';
import '../../../l10n/app_localizations.dart';
import 'medication_form_kit.dart';

/// A small dialog that asks how many to add to a medication's stock and
/// returns that amount, or null when cancelled. It shows the count now and the
/// new total as the amount is typed. Saving is the caller's: the amount is
/// recorded as a refill (`PillRepository.refill`), an append-only, idempotent
/// change of the stock by that amount, so adding twice never doubles because
/// of a retry and a dose taken on another device is never overwritten.
///
/// A count kept in a unit ([unit] set, and [parts] true) accepts a part
/// (`1/2`) through the same "Part" button as the recount; otherwise only a
/// whole number is accepted.
Future<ExactStock?> showAddStockDialog(
  BuildContext context, {
  required String medicationName,
  required ExactStock current,
  required bool parts,
  String? unit,
  bool needsRecount = false,
}) => showDialog<ExactStock>(
  context: context,
  builder: (_) => AddStockDialog(
    medicationName: medicationName,
    current: current,
    parts: parts,
    unit: unit,
    needsRecount: needsRecount,
  ),
);

class AddStockDialog extends StatefulWidget {
  const AddStockDialog({
    super.key,
    required this.medicationName,
    required this.current,
    required this.parts,
    this.unit,
    this.needsRecount = false,
  });

  final String medicationName;
  final ExactStock current;
  final bool parts;
  final String? unit;

  /// The count was marked for a recount; adding stock does not settle it.
  final bool needsRecount;

  @override
  State<AddStockDialog> createState() => _AddStockDialogState();
}

class _AddStockDialogState extends State<AddStockDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  ExactStock? get _amount {
    final value = ExactStock.tryParseInput(_controller.text);
    if (value == null || value.isNegative || value.isZero) return null;
    if (!widget.parts && !value.isWhole) return null;
    final total = widget.current + value;
    return value.inRange && total.inRange ? value : null;
  }

  void _add() {
    final amount = _amount;
    if (amount == null) {
      setState(() => _error = AppLocalizations.of(context).rvm_addStockNeeded);
      return;
    }
    Navigator.of(context).pop(amount);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final code = Localizations.localeOf(context).languageCode;
    const target = Size(64, 48);
    String show(ExactStock v) => formatExactStock(v, languageCode: code);
    return AlertDialog(
      key: const ValueKey('add-stock-dialog'),
      scrollable: true,
      title: Text(l.tm_addStock),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.medicationName,
            style: text.titleSmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            widget.unit == null
                ? l.rvm_addStockNow(show(widget.current))
                : l.rv3_addStockNowUnit(
                    show(widget.current),
                    stockUnitSuffix(
                      l,
                      widget.unit!,
                      quantity: widget.current.toDouble(),
                    ),
                  ),
            style: text.bodyLarge,
          ),
          const SizedBox(height: 16),
          // Rebuilds as the amount is typed: the unit suffix agrees with the
          // number (1 tablet, 3 tablets) and a zero or negative amount is
          // refused at once, in words.
          ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              final typed = ExactStock.tryParseInput(_controller.text);
              final notPositive =
                  typed != null && (typed.isNegative || typed.isZero);
              return StockWholeField(
                key: const ValueKey('add-stock-amount'),
                controller: _controller,
                wholeOnly: widget.parts,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _add(),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                decoration: InputDecoration(
                  labelText: l.rvm_addStockAmount,
                  suffixText: widget.unit == null
                      ? null
                      : stockUnitSuffix(
                          l,
                          widget.unit!,
                          // Zero, negative and empty take the plural: no
                          // "0 tablet".
                          quantity: typed == null || typed.isNegative
                              ? null
                              : typed.toDouble(),
                        ),
                  errorMaxLines: 3,
                  errorText:
                      _error ?? (notPositive ? l.rvm_addStockNeeded : null),
                ),
              );
            },
          ),
          if (widget.parts) ...[
            const SizedBox(height: 12),
            StockPartButton(controller: _controller, unit: widget.unit),
          ],
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              final amount = _amount;
              return Semantics(
                liveRegion: true,
                child: Text(
                  amount == null
                      ? ' '
                      : l.rvm_addStockTotal(show(widget.current + amount)),
                  key: const ValueKey('add-stock-total'),
                  style: text.titleMedium,
                ),
              );
            },
          ),
          if (widget.needsRecount) ...[
            const SizedBox(height: 8),
            Text(l.rvr_addStockRecountNote, style: text.bodyMedium),
          ],
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: target),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.shared_cancel),
        ),
        FilledButton(
          key: const ValueKey('add-stock-confirm'),
          style: FilledButton.styleFrom(minimumSize: target),
          onPressed: _add,
          child: Text(l.rvm_addStockAction),
        ),
      ],
    );
  }
}
