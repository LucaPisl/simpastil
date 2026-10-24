import 'package:flutter/material.dart';

import '../../../core/db/database.dart';
import '../../../core/errors/app_error.dart';
import '../../../core/inventory/exact_stock.dart';
import '../../../l10n/app_localizations.dart';
import '../pill_repository.dart';
import 'medication_form_kit.dart';

/// Asks how many are left and returns the count, or null when cancelled.
///
/// A medicine counted in a unit accepts parts (`7.5`, `7 1/2`); a plain whole
/// count accepts whole numbers only.
Future<ExactStock?> showStockRecountDialog(
  BuildContext context, {
  required Pill pill,
}) => showDialog<ExactStock>(
  context: context,
  builder: (_) => _StockRecountDialog(pill: pill),
);

class _StockRecountDialog extends StatefulWidget {
  const _StockRecountDialog({required this.pill});

  final Pill pill;

  @override
  State<_StockRecountDialog> createState() => _StockRecountDialogState();
}

class _StockRecountDialogState extends State<_StockRecountDialog> {
  final _controller = TextEditingController();
  String? _error;

  bool get _parts => widget.pill.stockUnit != null;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final l = AppLocalizations.of(context);
    final count = ExactStock.tryParseInput(_controller.text);
    final valid =
        count != null &&
        count.inRange &&
        !count.isNegative &&
        (_parts || count.isWhole);
    if (!valid) {
      setState(
        () => _error = _parts ? l.mf_stockNumberNeeded : l.mf_numberNeeded,
      );
      return;
    }
    Navigator.of(context).pop(count);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    const target = Size(64, 48);
    return AlertDialog(
      title: Text(l.stock_recountTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StockWholeField(
            key: const ValueKey('recount-field'),
            controller: _controller,
            wholeOnly: _parts,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _save(),
            decoration: InputDecoration(
              labelText: l.stock_recountField,
              suffixText: widget.pill.stockUnit,
              errorText: _error,
            ),
          ),
          if (_parts) ...[
            const SizedBox(height: 12),
            StockPartButton(
              controller: _controller,
              unit: widget.pill.stockUnit,
            ),
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
          key: const ValueKey('recount-save'),
          style: FilledButton.styleFrom(minimumSize: target),
          onPressed: _save,
          child: Text(l.shared_save),
        ),
      ],
    );
  }
}

/// Saves [count] as the medicine's corrected stock through the same update the
/// edit sheet uses, keeping every other field as it is. That command also
/// clears the "needs a recount" mark.
Future<Result<Pill>> recountPillStock(
  PillRepository repository,
  Pill pill,
  ExactStock count,
) {
  final unit = pill.stockUnit;
  return repository.update(
    pill.id,
    name: pill.name,
    dosage: pill.dosage,
    notes: pill.notes,
    color: pill.color,
    currentStock: unit == null ? count.floor : null,
    stockQuantity: unit == null ? null : count,
    stockUnit: unit,
    lowStockThreshold: pill.lowStockThreshold,
    isPrn: pill.isPrn,
    stockCounted: true,
  );
}
