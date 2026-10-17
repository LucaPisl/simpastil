import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/inventory/low_stock.dart';
import '../../../core/inventory/supply_forecast.dart';
import '../../../core/medication/medication_detail_provider.dart';
import '../../../core/storage/low_stock_dismissal_preference.dart';
import '../../../core/utils/app_clock.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../../pills/presentation/medication_detail_sections.dart'
    show showMedicationStockEditor;
import '../../pills/presentation/supply_runway.dart';
import '../as_needed/as_needed_summary.dart';

/// How the stock of one medication stands.
enum StockLevel { ok, low, out }

/// One medication's remaining stock, ready to draw. Read-only: nothing here
/// changes a count; stock moves only through dose records and the stock
/// editor.
@immutable
class StockRow {
  const StockRow({
    required this.pillId,
    required this.name,
    required this.personId,
    required this.personName,
    required this.color,
    required this.asNeeded,
    required this.left,
    required this.unit,
    required this.fraction,
    required this.level,
    required this.runsLowInDays,
    required this.forecast,
  });

  final String pillId;
  final String name;
  final String personId;
  final String personName;

  /// The medication's own colour as `#RRGGBB`, if it has one.
  final String? color;
  final bool asNeeded;

  /// Plain-text count, for example `12` or `7.5`.
  final String left;
  final String? unit;

  /// 0..1 fill for a bar; null when there is nothing to scale by.
  final double? fraction;
  final StockLevel level;

  /// Scheduled medication only: whole days from today until the stock
  /// reaches its low-stock level or runs out, whichever is first. Zero when
  /// it already has.
  final int? runsLowInDays;

  /// The runway along the routine for scheduled medication with a routine.
  final SupplyForecast? forecast;

  bool get low => level != StockLevel.ok;
}

/// One medication's inputs to [stockRowFor], independent of the database.
@immutable
class StockInput {
  const StockInput({
    required this.pillId,
    required this.name,
    required this.personId,
    required this.personName,
    required this.color,
    required this.asNeeded,
    required this.currentStock,
    required this.threshold,
    required this.forecast,
    required this.asNeededStock,
  });

  final String pillId;
  final String name;
  final String personId;
  final String personName;
  final String? color;
  final bool asNeeded;

  /// The counted stock of a scheduled medication (doses), null when it is not
  /// tracked.
  final int? currentStock;

  /// The medication's own low-stock level, if set.
  final int? threshold;

  /// The runway along the routine, when there is one.
  final SupplyForecast? forecast;

  /// The reviewed balance of an as-needed medication, null when untracked.
  final AsNeededStock? asNeededStock;
}

/// The stock row for one medication, or null when its stock is not tracked.
///
/// Scheduled medication runs low when it is out, at or under its own
/// low-stock level, or when its routine runs through the stock within
/// [lowStockHeadsUpDays] days. As-needed medication is low only at or under
/// its own level (there is no routine to run through), which is the same
/// rule the as-needed cards use.
StockRow? stockRowFor(StockInput input) {
  if (input.asNeeded) {
    final stock = input.asNeededStock;
    if (stock == null) return null;
    final value = double.tryParse(stock.left);
    return StockRow(
      pillId: input.pillId,
      name: input.name,
      personId: input.personId,
      personName: input.personName,
      color: input.color,
      asNeeded: true,
      left: stock.left,
      unit: stock.unit,
      fraction: stock.fraction,
      level: value != null && value <= 0
          ? StockLevel.out
          : stock.low
          ? StockLevel.low
          : StockLevel.ok,
      runsLowInDays: null,
      forecast: null,
    );
  }
  final stock = input.currentStock;
  if (stock == null) return null;
  final threshold = input.threshold;
  final forecast = input.forecast;
  final soonest = daysUntilLowStock(forecast);
  final level = stock <= 0
      ? StockLevel.out
      : isLowStock(stock: stock, threshold: threshold, runsLowInDays: soonest)
      ? StockLevel.low
      : StockLevel.ok;
  final double? fraction;
  if (forecast != null) {
    fraction = soonest == null
        ? 1.0
        : (soonest / forecast.horizon).clamp(0.0, 1.0);
  } else if (threshold != null && threshold > 0) {
    fraction = (stock / (threshold * 4.0)).clamp(0.0, 1.0);
  } else {
    fraction = null;
  }
  return StockRow(
    pillId: input.pillId,
    name: input.name,
    personId: input.personId,
    personName: input.personName,
    color: input.color,
    asNeeded: false,
    left: '$stock',
    unit: null,
    fraction: fraction,
    level: level,
    runsLowInDays: level == StockLevel.ok ? null : soonest,
    forecast: forecast,
  );
}

/// Stock rows for [inputs]: lowest first, then by name.
List<StockRow> stockRowsFor(Iterable<StockInput> inputs) {
  final rows = [
    for (final input in inputs)
      if (stockRowFor(input) case final row?) row,
  ];
  int rank(StockRow r) => switch (r.level) {
    StockLevel.out => 0,
    StockLevel.low => 1,
    StockLevel.ok => 2,
  };
  rows.sort((a, b) {
    final byLevel = rank(a).compareTo(rank(b));
    if (byLevel != 0) return byLevel;
    final ad = a.runsLowInDays, bd = b.runsLowInDays;
    if (ad != null && bd != null && ad != bd) return ad.compareTo(bd);
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return rows;
}

/// The medications that run low, in the same order.
List<StockRow> lowStockRows(Iterable<StockRow> rows) => [
  for (final row in rows)
    if (row.low) row,
];

/// Stock of everything the selected person (or everyone) takes, with the
/// medications that run low.
@immutable
class StockOverview {
  const StockOverview({required this.rows, required this.canAddStock});
  const StockOverview.empty() : rows = const [], canAddStock = false;

  final List<StockRow> rows;

  /// Whether "Add stock" is offered. Every workspace has a stock editor
  /// behind it (see [openStockEditor]), so a loaded overview always offers it.
  final bool canAddStock;

  List<StockRow> get low => lowStockRows(rows);
}

/// Live stock rows. Scheduled and as-needed medication that tracks stock
/// appear; everything else is left out. Read-only.
final todayStockProvider = Provider.autoDispose<AsyncValue<StockOverview>>((
  ref,
) {
  final list = ref.watch(medicationListProvider);
  final summaries = ref.watch(asNeededSummariesProvider);
  final workspace = ref.watch(workspaceContextProvider);
  if (list.hasError) return AsyncError(list.error!, list.stackTrace!);
  final details = list.asData?.value;
  final context = workspace.asData?.value;
  if (details == null || context == null) return const AsyncLoading();
  final byPill = summaries.asData?.value ?? const {};
  // The forecast counts from today, so it is recomputed when the day changes.
  ref.watch(todayProvider);
  final now = ref.watch(appClockProvider)();
  final rows = stockRowsFor([
    for (final detail in details)
      StockInput(
        pillId: detail.pill.id,
        name: detail.review.name,
        personId: detail.person.id,
        personName: detail.person.name,
        color: detail.pill.color,
        asNeeded: detail.pill.isPrn,
        currentStock: detail.pill.currentStock,
        threshold: detail.pill.lowStockThreshold,
        forecast: detail.pill.isPrn
            ? null
            : supplyForecastFor(detail, local: context.isLocal, now: now),
        asNeededStock: byPill[detail.pill.id]?.stock,
      ),
  ]);
  return AsyncData(StockOverview(rows: rows, canAddStock: true));
});

/// The medications that run low and were not put off with "Later" today.
final lowStockNoticesProvider = Provider.autoDispose<List<StockRow>>((ref) {
  final overview = ref.watch(todayStockProvider).asData?.value;
  if (overview == null) return const [];
  final dismissed = ref.watch(lowStockDismissalsProvider);
  ref.watch(todayProvider);
  final now = ref.watch(appClockProvider)();
  return [
    for (final row in overview.low)
      if (!lowStockDismissed(dismissed, row.pillId, now)) row,
  ];
});

/// Opens the stock editor for [pillId], the same one the Medications page
/// opens for its own "Add stock": the medication's edit sheet with the stock
/// stepper in view in a local workspace, the medication sheet in a connected
/// one. Returns after the editor closes. Adds no write path of its own: the
/// editor saves through the repository as everywhere else.
Future<void> openStockEditor(
  BuildContext context,
  WidgetRef ref,
  String pillId,
) async {
  final repository = await ref.read(medicationDetailRepositoryProvider.future);
  final detail = await repository.load(pillId);
  if (!context.mounted) return;
  await showMedicationStockEditor(context, detail, repository);
}
