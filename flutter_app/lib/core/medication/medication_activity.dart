import '../inventory/low_stock.dart';
import 'adherence_calculator.dart';
import 'routine_definition.dart';

/// How one day of a scheduled medication went, from its due doses only.
enum ActivityDayState {
  /// No dose was planned that day.
  none,

  /// Doses are planned but none has come due yet (later today).
  upcoming,

  /// Every due dose was taken.
  taken,

  /// Some due doses were taken or skipped and others were not, or a mix of
  /// taken and skipped.
  partial,

  /// Every due dose was skipped on purpose.
  skipped,

  /// Every due dose was recorded as missed, or missed and the rest left
  /// without a record.
  missed,

  /// A due dose was left without a record. This is what the app calls "not
  /// recorded": it does not say the dose was missed.
  notRecorded,
}

/// One day of the last-14-days view of a medication.
class ActivityDay {
  const ActivityDay({
    required this.date,
    required this.state,
    this.taken = 0,
    this.skipped = 0,
    this.missed = 0,
    this.notRecorded = 0,
    this.asNeeded = 0,
  });

  /// The device-local calendar day, at midnight.
  final DateTime date;
  final ActivityDayState state;

  /// Due scheduled doses of the day by how they went.
  final int taken, skipped, missed, notRecorded;

  /// As-needed doses taken that day.
  final int asNeeded;
}

/// A past dose in a medication's recent list.
class ActivityRecord {
  const ActivityRecord({
    required this.occurrenceId,
    required this.status,
    required this.at,
    required this.timeKnown,
    required this.asNeeded,
  });

  final String occurrenceId;

  /// `taken`, `skipped`, `missed` (recorded as missed) or `unrecorded` (due
  /// with no record, shown as "Not recorded").
  final String status;

  /// When a scheduled dose was planned, or when an as-needed dose was taken
  /// (its day when the time is not known).
  final DateTime at;

  /// Whether [at] carries a time of day rather than a day only.
  final bool timeKnown;
  final bool asNeeded;
}

/// A medication's last days at a glance, derived read-only from the dose
/// ledger. Nothing here is stored.
class MedicationActivity {
  const MedicationActivity({
    required this.days,
    required this.recent,
    required this.hasAnyRecord,
  });

  /// The last days, oldest first; today is the last one.
  final List<ActivityDay> days;

  /// The latest past doses, newest first.
  final List<ActivityRecord> recent;

  /// Whether the ledger holds any dose of this medication in the window the
  /// view looked at.
  final bool hasAnyRecord;

  /// Days on which every due dose was taken.
  int get takenDays =>
      days.where((d) => d.state == ActivityDayState.taken).length;

  /// Days that had at least one dose come due.
  int get dueDays => days
      .where(
        (d) =>
            d.state != ActivityDayState.none &&
            d.state != ActivityDayState.upcoming,
      )
      .length;

  /// As-needed doses taken across [days].
  int get asNeededTotal => days.fold(0, (n, d) => n + d.asNeeded);
}

/// The last [days] days of [pillId], and its last [recentLimit] past doses
/// (taken, skipped, missed or not recorded) from the same [items].
///
/// [items] comes from `calculateOccurrenceAdherence`, so a due scheduled dose
/// with no record already reads as `unrecorded`, and `missed` means a miss
/// the app recorded. Superseded occurrences (replaced
/// by an edited routine) never count. [now] is the device's local time.
MedicationActivity medicationActivityFrom({
  required Iterable<AdherenceHistoryItem> items,
  required String pillId,
  required DateTime now,
  int days = 14,
  int recentLimit = 5,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final dates = [
    for (var i = days - 1; i >= 0; i--)
      DateTime(today.year, today.month, today.day - i),
  ];
  final first = routineDateKey(dates.first);
  final last = routineDateKey(dates.last);

  final taken = <String, int>{};
  final skipped = <String, int>{};
  final missed = <String, int>{};
  final notRecorded = <String, int>{};
  final upcoming = <String, int>{};
  final asNeeded = <String, int>{};
  final records = <ActivityRecord>[];
  var any = false;

  void bump(Map<String, int> into, String key) =>
      into.update(key, (n) => n + 1, ifAbsent: () => 1);

  for (final item in items) {
    if (item.pillId != pillId || item.superseded) continue;
    any = true;
    final planned = item.plannedAt?.toLocal();
    final actual = item.actualTimeKnown ? item.actualAt?.toLocal() : null;
    final at = actual ?? planned;
    final prn = item.source == 'prn';

    if (prn) {
      if (item.status != 'taken') continue;
      final String key;
      if (actual != null) {
        key = routineDateKey(actual);
      } else if (item.plannedLocalDate != null) {
        key = item.plannedLocalDate!;
      } else {
        continue;
      }
      if (key.compareTo(first) >= 0 && key.compareTo(last) <= 0) {
        bump(asNeeded, key);
      }
      final when = at ?? _dayOf(key);
      records.add(
        ActivityRecord(
          occurrenceId: item.occurrenceId,
          status: 'taken',
          at: when,
          timeKnown: actual != null,
          asNeeded: true,
        ),
      );
      continue;
    }

    final key =
        item.plannedLocalDate ??
        (planned == null ? null : routineDateKey(planned));
    if (key == null) continue;
    final inWindow = key.compareTo(first) >= 0 && key.compareTo(last) <= 0;
    switch (item.status) {
      case 'taken':
        if (inWindow) bump(taken, key);
      case 'skipped':
        if (inWindow) bump(skipped, key);
      case 'missed':
        if (inWindow) bump(missed, key);
      case 'unrecorded':
        if (inWindow) bump(notRecorded, key);
      case 'pending':
        // Not due yet: only a planned dose of an active routine counts.
        if (inWindow && item.expected) bump(upcoming, key);
    }
    if (item.status == 'taken' ||
        item.status == 'skipped' ||
        item.status == 'missed' ||
        item.status == 'unrecorded') {
      records.add(
        ActivityRecord(
          occurrenceId: item.occurrenceId,
          status: item.status,
          at: planned ?? _dayOf(key),
          timeKnown: planned != null,
          asNeeded: false,
        ),
      );
    }
  }

  final marks = <ActivityDay>[];
  for (final date in dates) {
    final key = routineDateKey(date);
    final t = taken[key] ?? 0;
    final s = skipped[key] ?? 0;
    final m = missed[key] ?? 0;
    final n = notRecorded[key] ?? 0;
    final u = upcoming[key] ?? 0;
    final due = t + s + m + n;
    final ActivityDayState state;
    if (due == 0) {
      state = u > 0 ? ActivityDayState.upcoming : ActivityDayState.none;
    } else if (n == due) {
      state = ActivityDayState.notRecorded;
    } else if (m + n == due) {
      state = ActivityDayState.missed;
    } else if (t == due) {
      state = ActivityDayState.taken;
    } else if (s == due) {
      state = ActivityDayState.skipped;
    } else {
      state = ActivityDayState.partial;
    }
    marks.add(
      ActivityDay(
        date: date,
        state: state,
        taken: t,
        skipped: s,
        missed: m,
        notRecorded: n,
        asNeeded: asNeeded[key] ?? 0,
      ),
    );
  }

  records.sort((a, b) {
    final byTime = b.at.compareTo(a.at);
    return byTime != 0 ? byTime : a.occurrenceId.compareTo(b.occurrenceId);
  });
  return MedicationActivity(
    days: List.unmodifiable(marks),
    recent: List.unmodifiable(records.take(recentLimit)),
    hasAnyRecord: any,
  );
}

DateTime _dayOf(String key) {
  final d = parseRoutineDate(key);
  return DateTime(d.year, d.month, d.day);
}

/// How a medication's stock stands, for the summary above the list.
enum StockStatus {
  /// No medication counts its stock.
  untracked,

  /// Counted stock, none of it low or running out soon.
  fine,

  /// Some counted stock is low by the shared rule ([isLowStock]): at its
  /// reminder level, or its routine reaches the level within two weeks.
  soon,

  /// Some counted stock is used up.
  out,
}

/// One medication as the stock summary reads it.
typedef StockEntry = ({
  String name,
  bool asNeeded,
  int? stock,
  int? threshold,

  /// Whole days until the routine takes the stock to its low-stock level or
  /// through it ([daysUntilLowStock]), when a routine can be forecast.
  int? runsLowInDays,
});

/// The medication list's counts and stock status.
class MedicationListSummary {
  const MedicationListSummary({
    required this.status,
    required this.attention,
    required this.scheduled,
    required this.asNeeded,
  });

  final StockStatus status;

  /// Names behind [StockStatus.soon] or [StockStatus.out], in list order.
  final List<String> attention;
  final int scheduled, asNeeded;
}

/// The stock status of [entries], with how many medications are scheduled and
/// as needed. "Low" is the same rule the stock card on Today and the blister
/// use ([isLowStock]), so the three never disagree.
MedicationListSummary summarizeMedications(Iterable<StockEntry> entries) {
  var scheduled = 0, asNeeded = 0, tracked = 0;
  final out = <String>[], soon = <String>[];
  for (final e in entries) {
    if (e.asNeeded) {
      asNeeded++;
    } else {
      scheduled++;
    }
    final stock = e.stock;
    if (stock == null) continue;
    tracked++;
    if (stock <= 0) {
      out.add(e.name);
    } else if (isLowStock(
      stock: stock,
      threshold: e.threshold,
      runsLowInDays: e.runsLowInDays,
    )) {
      soon.add(e.name);
    }
  }
  final StockStatus status;
  if (out.isNotEmpty) {
    status = StockStatus.out;
  } else if (soon.isNotEmpty) {
    status = StockStatus.soon;
  } else {
    status = tracked == 0 ? StockStatus.untracked : StockStatus.fine;
  }
  return MedicationListSummary(
    status: status,
    attention: [...out, ...soon],
    scheduled: scheduled,
    asNeeded: asNeeded,
  );
}

/// Stock after saving a stock edit: what is typed against what was stored.
class StockAfterSaving {
  const StockAfterSaving({
    required this.stock,
    required this.changedBy,
    required this.low,
  });

  /// The count the field holds; null when it is empty or not a number.
  final int? stock;

  /// How far it moves from the stored count; zero when nothing changes.
  final int changedBy;

  /// At or under the low-stock level, or out.
  final bool low;
}

StockAfterSaving stockAfterSaving({
  required String typed,
  required int? stored,
  required int? threshold,
}) {
  final text = typed.trim();
  final value = text.isEmpty ? null : int.tryParse(text);
  final low =
      value != null &&
      (value <= 0 || (threshold != null && value <= threshold));
  return StockAfterSaving(
    stock: value,
    changedBy: value == null ? 0 : value - (stored ?? value),
    low: low,
  );
}
