/// One counted as-needed dose: the instant it counts at.
///
/// That is the time the person gave, or, when they did not know it, the
/// moment it was recorded. The count is over absolute instants, so a window
/// that crosses midnight, a time-zone change or a daylight-saving change
/// never moves a dose in or out of it.
class PrnLimitDose {
  const PrnLimitDose(this.at);
  final DateTime at;
}

enum PrnLimitBreach { none, daily, gap, both }

class PrnLimitState {
  const PrnLimitState({
    required this.countIn24h,
    required this.maxPer24h,
    required this.minGapMinutes,
    required this.breach,
    required this.nextAllowedAt,
  });

  /// Doses in the 24 hours up to now.
  final int countIn24h;
  final int? maxPer24h;
  final int? minGapMinutes;
  final PrnLimitBreach breach;

  /// The earliest moment another dose is within both limits; null when it
  /// already is, or when no limit is set.
  final DateTime? nextAllowedAt;

  bool get hasLimit => maxPer24h != null || minGapMinutes != null;
  bool get overLimit => breach != PrnLimitBreach.none;
  bool get atDailyMax => maxPer24h != null && countIn24h >= maxPer24h!;
}

const Duration prnWindow = Duration(hours: 24);

/// Judges one more dose at [at] against the limits.
///
/// The 24-hour window is the 24 hours before [at]; doses recorded later than
/// [at] are not counted (a backdated dose is judged where it falls). The gap
/// is measured from the latest earlier dose.
PrnLimitState evaluatePrnLimit({
  required int? maxPer24h,
  required int? minGapMinutes,
  required Iterable<PrnLimitDose> doses,
  required DateTime at,
}) {
  final instants = [
    for (final d in doses)
      if (!d.at.isAfter(at)) d.at.toUtc(),
  ]..sort();
  final moment = at.toUtc();
  final windowStart = moment.subtract(prnWindow);
  final inWindow = [
    for (final d in instants)
      if (d.isAfter(windowStart)) d,
  ];
  var dailyBreach = false;
  DateTime? next;
  if (maxPer24h != null && inWindow.length >= maxPer24h) {
    dailyBreach = true;
    // Another dose fits once enough of the oldest ones have left the window.
    final index = inWindow.length - maxPer24h;
    next = inWindow[index].add(prnWindow);
  }
  var gapBreach = false;
  if (minGapMinutes != null && instants.isNotEmpty) {
    final ready = instants.last.add(Duration(minutes: minGapMinutes));
    if (ready.isAfter(moment)) {
      gapBreach = true;
      if (next == null || ready.isAfter(next)) next = ready;
    }
  }
  return PrnLimitState(
    countIn24h: inWindow.length,
    maxPer24h: maxPer24h,
    minGapMinutes: minGapMinutes,
    breach: dailyBreach && gapBreach
        ? PrnLimitBreach.both
        : dailyBreach
        ? PrnLimitBreach.daily
        : gapBreach
        ? PrnLimitBreach.gap
        : PrnLimitBreach.none,
    nextAllowedAt: (dailyBreach || gapBreach) ? next?.toLocal() : null,
  );
}
