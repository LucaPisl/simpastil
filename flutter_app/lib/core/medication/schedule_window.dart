import '../db/database.dart' show Schedule;
import 'routine_definition.dart' show parseRoutineDate;

/// The optional interval and date-window fields of a connected schedule
/// (server contract: `everyDays`, `anchorDate`, `startDate`, `endDate`).
///
/// A schedule without any of them is exactly what shipped before: nothing
/// here changes its payload, its occurrence keys or its snapshots.
class ScheduleWindow {
  const ScheduleWindow({
    this.everyDays,
    this.anchorDate,
    this.startDate,
    this.endDate,
  });

  /// Reads the four keys from a wire or payload object; a missing key is null.
  factory ScheduleWindow.fromJson(Map<dynamic, dynamic> json) => ScheduleWindow(
    everyDays: json['everyDays'] as int?,
    anchorDate: json['anchorDate'] as String?,
    startDate: json['startDate'] as String?,
    endDate: json['endDate'] as String?,
  );

  final int? everyDays;
  final String? anchorDate;
  final String? startDate;
  final String? endDate;

  /// True when at least one of the four fields is set.
  bool get isSet =>
      everyDays != null ||
      anchorDate != null ||
      startDate != null ||
      endDate != null;

  /// The four wire keys, all present (explicit null clears on an update).
  Map<String, Object?> toJson() => {
    'everyDays': everyDays,
    'anchorDate': anchorDate,
    'startDate': startDate,
    'endDate': endDate,
  };

  /// Whether the fields are valid for [frequency] under the contract:
  /// an interval needs `everyDays` (1..36500) and `anchorDate`, any other
  /// frequency has neither, an as-needed schedule has no dates at all, every
  /// date is a real Gregorian `YYYY-MM-DD`, and the end is not before the
  /// start.
  bool isValidFor(String frequency) {
    final every = everyDays;
    if (frequency == 'interval') {
      if (every == null || every < 1 || every > 36500 || anchorDate == null) {
        return false;
      }
    } else if (every != null || anchorDate != null) {
      return false;
    }
    if (frequency == 'prn' && (startDate != null || endDate != null)) {
      return false;
    }
    for (final date in [anchorDate, startDate, endDate]) {
      if (date != null && !_isDate(date)) return false;
    }
    final start = startDate, end = endDate;
    return start == null || end == null || end.compareTo(start) >= 0;
  }

  static bool _isDate(String value) {
    try {
      parseRoutineDate(value);
      return true;
    } on ArgumentError {
      return false;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ScheduleWindow &&
      other.everyDays == everyDays &&
      other.anchorDate == anchorDate &&
      other.startDate == startDate &&
      other.endDate == endDate;

  @override
  int get hashCode => Object.hash(everyDays, anchorDate, startDate, endDate);
}

/// Whether a connected schedule with these fields has a dose on [date] (a UTC
/// calendar date). Same rule as `RoutineDefinition.includes` for an interval:
/// `date >= anchor` and `daysBetween(anchor, date) % everyDays == 0`; the
/// window then keeps only dates inside `[startDate, endDate]`.
bool scheduleWindowIncludes(
  String frequency,
  ScheduleWindow window,
  DateTime date,
) {
  final key = _key(date);
  final start = window.startDate, end = window.endDate;
  if ((start != null && key.compareTo(start) < 0) ||
      (end != null && key.compareTo(end) > 0)) {
    return false;
  }
  if (frequency != 'interval') return true;
  final anchor = parseRoutineDate(window.anchorDate!);
  return !date.isBefore(anchor) &&
      date.difference(anchor).inDays % window.everyDays! == 0;
}

String _key(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

extension ScheduleWindowOfRow on Schedule {
  /// The interval and date-window fields stored on this row.
  ScheduleWindow get window => ScheduleWindow(
    everyDays: everyDays,
    anchorDate: anchorDate,
    startDate: startDate,
    endDate: endDate,
  );
}
