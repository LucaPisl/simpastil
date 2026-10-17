import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/format/clock.dart';

/// Part of the day a scheduled time falls in, for words beside a time.
enum DayPart { morning, afternoon, evening, night }

DayPart dayPartOf(TimeOfDay t) {
  final m = t.hour * 60 + t.minute;
  if (m >= 5 * 60 && m < 12 * 60) return DayPart.morning;
  if (m >= 12 * 60 && m < 17 * 60) return DayPart.afternoon;
  if (m >= 17 * 60 && m < 21 * 60) return DayPart.evening;
  return DayPart.night;
}

String dayPartLabel(AppLocalizations l, DayPart part) => switch (part) {
  DayPart.morning => l.r07_morning,
  DayPart.afternoon => l.r07_afternoon,
  DayPart.evening => l.r07_evening,
  DayPart.night => l.r07_night,
};

/// The spoken summary of a set of scheduled times on the phone's clock, e.g.
/// "8:00 AM, Morning; 8:30 PM, Evening".
String spokenTimesLabel(BuildContext context, List<TimeOfDay> times) {
  final l = AppLocalizations.of(context);
  return times
      .map(
        (t) =>
            l.mf_skyTime(clockTime(context, t), dayPartLabel(l, dayPartOf(t))),
      )
      .join('; ');
}
