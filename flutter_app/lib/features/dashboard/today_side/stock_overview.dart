import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/inventory/low_stock.dart';
import '../../../core/l10n/locale_provider.dart';
import '../../../core/inventory/supply_forecast.dart';
import '../../../core/medication/expiry.dart';
import '../../../core/medication/medication_detail_provider.dart';
import '../../../core/storage/low_stock_dismissal_preference.dart';
import '../../../core/utils/app_clock.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../../pills/presentation/medication_detail_sections.dart'
    show showMedicationStockEditor;
import '../../pills/presentation/supply_runway.dart';
import '../as_needed/as_needed_summary.dart';

/// Where the low-stock level sits on a bar that scales the count to four times
/// that level: a quarter of the way along.
const double asNeededRefillMark = .25;

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
    this.refillMark,
    this.needsRecount = false,
    this.expiry = ExpiryState.none,
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

  /// 0..1 position along the bar where the stock counts as low (the refill
  /// point), drawn as a tick so the level is never read from colour alone.
  /// Null when there is no bar.
  final double? refillMark;
  final StockLevel level;

  /// Scheduled medication only: whole days from today until the stock
  /// reaches its low-stock level or runs out, whichever is first. Zero when
  /// it already has.
  final int? runsLowInDays;

  /// The runway along the routine for scheduled medication with a routine.
  final SupplyForecast? forecast;

  /// The count did not move for a dose it cannot subtract exactly.
  final bool needsRecount;

  /// Where the medicine stands against its expiry date.
  final ExpiryState expiry;

  bool get low => level != StockLevel.ok;

  /// Whether Today shows a notice for it: running low, or near or past its
  /// expiry date.
  bool get needsNotice => low || expiry.needsNotice;
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
    this.currentStockText,
    this.needsRecount = false,
    this.expiry = ExpiryState.none,
  });

  final String pillId;
  final String name;
  final String personId;
  final String personName;
  final String? color;
  final bool asNeeded;

  /// The stock of a scheduled medication in whole doses (`StockReading.whole`),
  /// null when it is not tracked.
  final int? currentStock;

  /// How [currentStock] reads when the stock is counted in a unit: the exact
  /// amount, for example `27½`, where [currentStock] counts whole doses. The
  /// low-stock rules keep using [currentStock].
  final String? currentStockText;

  /// The medication's own low-stock level, if set.
  final int? threshold;

  /// The runway along the routine, when there is one.
  final SupplyForecast? forecast;

  /// The stock of an as-needed medication, from the same `readStock` answer,
  /// null when untracked.
  final AsNeededStock? asNeededStock;

  /// See [StockRow.needsRecount].
  final bool needsRecount;

  /// Where the medicine stands against its expiry date.
  final ExpiryState expiry;
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
    final value = stock.value;
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
      refillMark: stock.fraction == null ? null : asNeededRefillMark,
      level: value <= 0
          ? StockLevel.out
          : stock.low
          ? StockLevel.low
          : StockLevel.ok,
      runsLowInDays: null,
      forecast: null,
      expiry: input.expiry,
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
  final double? refillMark;
  if (forecast != null) {
    // The bar counts days until the low-stock level, which is reached at
    // [lowStockHeadsUpDays] or sooner.
    fraction = soonest == null
        ? 1.0
        : (soonest / forecast.horizon).clamp(0.0, 1.0);
    refillMark = (lowStockHeadsUpDays / forecast.horizon).clamp(0.0, 1.0);
  } else if (threshold != null && threshold > 0) {
    fraction = (stock / (threshold * 4.0)).clamp(0.0, 1.0);
    refillMark = asNeededRefillMark;
  } else {
    fraction = null;
    refillMark = null;
  }
  return StockRow(
    pillId: input.pillId,
    name: input.name,
    personId: input.personId,
    personName: input.personName,
    color: input.color,
    asNeeded: false,
    left: input.currentStockText ?? '$stock',
    unit: null,
    fraction: fraction,
    refillMark: refillMark,
    level: level,
    runsLowInDays: level == StockLevel.ok ? null : soonest,
    forecast: forecast,
    needsRecount: input.needsRecount,
    expiry: input.expiry,
  );
}

/// A notice-only row for a medicine whose stock is not tracked but whose
/// expiry date is near or past; null when there is nothing to say.
StockRow? expiryOnlyRowFor(StockInput input) {
  if (!input.expiry.needsNotice) return null;
  return StockRow(
    pillId: input.pillId,
    name: input.name,
    personId: input.personId,
    personName: input.personName,
    color: input.color,
    asNeeded: input.asNeeded,
    left: '',
    unit: null,
    fraction: null,
    level: StockLevel.ok,
    runsLowInDays: null,
    forecast: null,
    expiry: input.expiry,
  );
}

/// Stock rows for [inputs]: lowest first, then by name.
List<StockRow> stockRowsFor(Iterable<StockInput> inputs) {
  final rows = [for (final input in inputs) ?stockRowFor(input)];
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

/// The medications that need a notice: running low or near or past expiry.
List<StockRow> noticeRows(Iterable<StockRow> rows) => [
  for (final row in rows)
    if (row.needsNotice) row,
];

/// Stock of everything the selected person (or everyone) takes, with the
/// medications that run low.
@immutable
class StockOverview {
  const StockOverview({
    required this.rows,
    required this.canAddStock,
    this.expiryOnly = const [],
  });
  const StockOverview.empty()
    : rows = const [],
      canAddStock = false,
      expiryOnly = const [];

  final List<StockRow> rows;

  /// Medicines without a stock count whose expiry date calls for a notice.
  final List<StockRow> expiryOnly;

  /// Whether "Add stock" is offered. Every workspace has a stock editor
  /// behind it (see [openStockEditor]), so a loaded overview always offers it.
  final bool canAddStock;

  List<StockRow> get low => lowStockRows(rows);

  /// Low-stock and expiry notices together, most urgent first.
  List<StockRow> get notices => [...noticeRows(rows), ...expiryOnly];
}

/// Live stock rows. Scheduled and as-needed medication that tracks stock
/// appear; everything else is left out. Read-only.
final todayStockProvider = Provider.autoDispose<AsyncValue<StockOverview>>((
  ref,
) {
  final list = ref.watch(medicationListProvider);
  final workspace = ref.watch(workspaceContextProvider);
  if (list.hasError) return AsyncError(list.error!, list.stackTrace!);
  final details = list.asData?.value;
  final context = workspace.asData?.value;
  if (details == null || context == null) return const AsyncLoading();
  // The forecast counts from today, so it is recomputed when the day changes.
  ref.watch(todayProvider);
  final now = ref.watch(appClockProvider)();
  final languageCode =
      ref.watch(localeOverrideProvider)?.languageCode ??
      PlatformDispatcher.instance.locale.languageCode;
  final inputs = [
    for (final detail in details)
      StockInput(
        expiry: expiryState(detail.pill.expiresOn, now),
        pillId: detail.pill.id,
        name: detail.review.name,
        personId: detail.person.id,
        personName: detail.person.name,
        color: detail.pill.color,
        asNeeded: detail.pill.isPrn,
        currentStock: detail.pill.isPrn ? null : detail.stock?.whole,
        currentStockText: detail.pill.isPrn
            ? null
            : detail.stock?.leftText(languageCode),
        threshold: detail.pill.lowStockThreshold,
        forecast: detail.pill.isPrn
            ? null
            : supplyForecastFor(detail, local: context.isLocal, now: now),
        asNeededStock: !detail.pill.isPrn || detail.stock == null
            ? null
            : asNeededStockOf(
                detail.stock!,
                detail.pill.lowStockThreshold,
                languageCode: languageCode,
              ),
        needsRecount: detail.stock?.needsRecount ?? false,
      ),
  ];
  final rows = stockRowsFor(inputs);
  final tracked = {for (final row in rows) row.pillId};
  return AsyncData(
    StockOverview(
      rows: rows,
      canAddStock: true,
      expiryOnly: [
        for (final input in inputs)
          if (!tracked.contains(input.pillId)) ?expiryOnlyRowFor(input),
      ],
    ),
  );
});

/// The medications that run low and were not put off with "Later" today.
final lowStockNoticesProvider = Provider.autoDispose<List<StockRow>>((ref) {
  final overview = ref.watch(todayStockProvider).asData?.value;
  if (overview == null) return const [];
  final dismissed = ref.watch(lowStockDismissalsProvider);
  ref.watch(todayProvider);
  final now = ref.watch(appClockProvider)();
  return [
    for (final row in overview.notices)
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
