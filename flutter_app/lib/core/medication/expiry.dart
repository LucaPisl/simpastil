/// How near a medicine is to its expiry date.
enum ExpiryPhase { none, ok, soon, expired }

/// The notice appears this many days before the expiry date.
const int expiryNoticeDays = 30;

class ExpiryState {
  const ExpiryState(this.phase, this.daysLeft);
  static const none = ExpiryState(ExpiryPhase.none, null);

  final ExpiryPhase phase;

  /// Whole days from [today] to the expiry date; negative once expired.
  final int? daysLeft;

  bool get needsNotice =>
      phase == ExpiryPhase.soon || phase == ExpiryPhase.expired;
}

/// The date of a `yyyy-MM-dd` expiry as a calendar date, or null.
DateTime? parseExpiryDate(String? expiresOn) {
  if (expiresOn == null) return null;
  final parts = expiresOn.split('-');
  if (parts.length != 3) return null;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return null;
  final date = DateTime(y, m, d);
  return date.year == y && date.month == m && date.day == d ? date : null;
}

String expiryDateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// Where [expiresOn] stands on the calendar day of [now] (device-local).
///
/// The expiry day itself is the last good day: the notice starts
/// [expiryNoticeDays] days before it and the medicine is expired the day
/// after. Calendar days are compared, so a daylight-saving change never moves
/// the answer.
ExpiryState expiryState(String? expiresOn, DateTime now) {
  final date = parseExpiryDate(expiresOn);
  if (date == null) return ExpiryState.none;
  final today = DateTime.utc(now.year, now.month, now.day);
  final left = DateTime.utc(
    date.year,
    date.month,
    date.day,
  ).difference(today).inDays;
  if (left < 0) return ExpiryState(ExpiryPhase.expired, left);
  if (left <= expiryNoticeDays) return ExpiryState(ExpiryPhase.soon, left);
  return ExpiryState(ExpiryPhase.ok, left);
}
