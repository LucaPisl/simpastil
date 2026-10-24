import 'dart:convert';

import '../../core/db/database.dart';
import '../../core/inventory/exact_stock.dart';
import '../../core/inventory/pill_stock.dart';

/// What the stock changes of a day need to know about a medication.
typedef StockPill = ({
  String name,
  String? color,
  String profileId,
  ExactStock? currentStock,
});

/// One change to a medication's stock, with the count before and after it.
class StockChange {
  const StockChange({
    required this.eventId,
    required this.pillId,
    required this.pillName,
    required this.pillColor,
    required this.profileId,
    required this.kind,
    required this.before,
    required this.after,
    required this.at,
  });

  /// The inventory event this reads.
  final String eventId;
  final String pillId;
  final String pillName;
  final String? pillColor;
  final String profileId;

  /// The inventory event kind: `dose`, `dose_reversal`, `refill` or
  /// `correction`.
  final String kind;
  final ExactStock before;
  final ExactStock after;

  /// When the change was recorded, in local time.
  final DateTime at;
}

/// The stock changes recorded on the local calendar day of [day], newest first.
///
/// Reads the inventory ledger and stores nothing. A change is an inventory
/// event of kind `dose`, `dose_reversal`, `refill` or `correction`; the
/// `opening` count that starts a ledger is not a change and is left out. The
/// day is the local day the event was **recorded**, so a dose entered on
/// Monday for Sunday shows under Monday, next to the stock it moved.
///
/// The counts before and after come from walking the ledger back from the
/// medication's current stock: the last event ended at that stock and each
/// earlier one ended where the next began. That stays right when the ledger
/// has no opening event or a count was set while it was inactive. A medication
/// with no current stock counts forward from the ledger's own sum instead.
/// Events the server has folded into an opening count (`foldedIntoOpening` in
/// their provenance) are already part of that count and are skipped.
///
/// Medications that are not in [pills] (deleted, or another person's) yield
/// nothing.
List<StockChange> stockChangesForDay({
  required DateTime day,
  required Iterable<InventoryEvent> events,
  required Map<String, StockPill> pills,
}) {
  final byPill = <String, List<InventoryEvent>>{};
  for (final event in events) {
    if (!pills.containsKey(event.pillId) || _isFolded(event)) continue;
    (byPill[event.pillId] ??= []).add(event);
  }

  final changes = <StockChange>[];
  for (final entry in byPill.entries) {
    final pill = pills[entry.key]!;
    final ledger = entry.value..sort(_ledgerOrder);
    var after = pill.currentStock ?? sumExact(ledger.map(exactDeltaOf));
    for (final event in ledger.reversed) {
      final before = after - exactDeltaOf(event);
      if (event.kind != 'opening' && _isOnDay(event.recordedAt, day)) {
        changes.add(
          StockChange(
            eventId: event.id,
            pillId: event.pillId,
            pillName: pill.name,
            pillColor: pill.color,
            profileId: pill.profileId,
            kind: event.kind,
            before: before,
            after: after,
            at: event.recordedAt.toLocal(),
          ),
        );
      }
      after = before;
    }
  }
  changes.sort((a, b) {
    final byTime = b.at.compareTo(a.at);
    return byTime != 0 ? byTime : a.eventId.compareTo(b.eventId);
  });
  return changes;
}

bool _isOnDay(DateTime instant, DateTime day) {
  final local = instant.toLocal();
  return local.year == day.year &&
      local.month == day.month &&
      local.day == day.day;
}

/// Oldest first: by when it was recorded, then by the server's order, then by
/// id so two events at one instant never swap between reads.
int _ledgerOrder(InventoryEvent a, InventoryEvent b) {
  final byTime = a.recordedAt.compareTo(b.recordedAt);
  if (byTime != 0) return byTime;
  final bySequence = (a.serverSequence ?? 1 << 52).compareTo(
    b.serverSequence ?? 1 << 52,
  );
  return bySequence != 0 ? bySequence : a.id.compareTo(b.id);
}

bool _isFolded(InventoryEvent event) {
  final json = event.provenanceJson;
  if (json == null) return false;
  try {
    final decoded = jsonDecode(json);
    return decoded is Map && decoded['foldedIntoOpening'] is String;
  } on FormatException {
    return false;
  }
}
