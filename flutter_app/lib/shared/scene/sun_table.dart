/// Approximate sunrise and sunset for a mid-latitude (about 45 N, Romania)
/// location, in local wall-clock minutes after midnight with daylight saving
/// already folded in. This is decoration for the day sky, not an almanac.
class SunTimes {
  const SunTimes({required this.sunrise, required this.sunset});

  final double sunrise;
  final double sunset;

  double get daylight => sunset - sunrise;
}

abstract final class SunTable {
  // Mid-month anchors (day of month 15): sunrise, sunset in minutes.
  static const List<List<double>> _anchors = [
    [465, 1025], // Jan 15 07:45 / 17:05
    [440, 1065], // Feb 15
    [390, 1095], // Mar 15
    [395, 1200], // Apr 15 (after the spring clock change)
    [350, 1235], // May 15
    [330, 1265], // Jun 15
    [350, 1260], // Jul 15
    [385, 1225], // Aug 15
    [425, 1175], // Sep 15
    [460, 1125], // Oct 15
    [410, 1015], // Nov 15 (after the autumn clock change)
    [455, 1010], // Dec 15
  ];

  /// Linear interpolation between the neighbouring mid-month anchors.
  static SunTimes forDate(DateTime date) {
    final day = DateTime(date.year, date.month, date.day);
    final mid = DateTime(date.year, date.month, 15);
    final before = day.isBefore(mid);
    final otherMid = DateTime(date.year, date.month + (before ? -1 : 1), 15);
    final span = otherMid.difference(mid).inDays.abs();
    final t = day.difference(mid).inDays.abs() / span;
    final a = _anchors[date.month - 1];
    final b = _anchors[otherMid.month - 1];
    return SunTimes(
      sunrise: a[0] + (b[0] - a[0]) * t,
      sunset: a[1] + (b[1] - a[1]) * t,
    );
  }
}
