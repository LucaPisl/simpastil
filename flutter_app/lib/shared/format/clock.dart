import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Times as the phone shows them: 24-hour when the phone says so, otherwise
/// the language's own clock ("8:00 AM" in English, "08:00" in Romanian).
///
/// Only for words on screen. Stored, exported and synced times stay HH:mm.
String clockTime(BuildContext context, TimeOfDay time) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      time,
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

/// [clockTime] for a moment already in the zone it should be read in.
String clockAt(BuildContext context, DateTime at) =>
    clockTime(context, TimeOfDay.fromDateTime(at));

/// Whether this phone and language read times on a 12-hour clock.
bool usesTwelveHourClock(BuildContext context) =>
    switch (MaterialLocalizations.of(context).timeOfDayFormat(
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    )) {
      TimeOfDayFormat.h_colon_mm_space_a ||
      TimeOfDayFormat.a_space_h_colon_mm => true,
      _ => false,
    };

/// An hour on its own, as on a ruler: "08:00" on a 24-hour clock, "8 AM" on
/// a 12-hour one.
String clockHour(BuildContext context, int hour) => usesTwelveHourClock(context)
    ? DateFormat.j(Localizations.localeOf(context).toString())
          .format(DateTime(2000, 1, 1, hour % 24))
          // intl 0.20.3 (CLDR 47) separates the hour from AM/PM with a narrow
          // no-break space; the rest of the app writes a plain space.
          .replaceAll('\u202f', ' ')
    : clockTime(context, TimeOfDay(hour: hour % 24, minute: 0));

/// [clockTime] for a stored wall time ("HH:mm" or "HH:mm:ss"). Anything that
/// is not one is shown as written.
String clockText(BuildContext context, String stored) {
  final parts = stored.split(':');
  final hour = int.tryParse(parts.first);
  final minute = parts.length > 1 ? int.tryParse(parts[1]) : null;
  if (hour == null || minute == null || hour > 23 || minute > 59) {
    return stored;
  }
  return clockTime(context, TimeOfDay(hour: hour, minute: minute));
}

/// A date and a time on the phone's clock ("Oct 13, 2026 1:13 PM"), with
/// [at] read as it is, in the zone it should be read in.
String clockDateTime(BuildContext context, DateTime at) =>
    '${DateFormat.yMMMd(Localizations.localeOf(context).toString()).format(at)} '
    '${clockAt(context, at)}';

/// Joins each time in [text] to its day period with a no-break space, so
/// "9:00 AM" wraps as one word, never as "9:00" over "AM".
String keepTimesWhole(String text) => text.replaceAllMapped(
  RegExp(r'(\d) (?=[AaPp]\.?[Mm]\b)'),
  (m) => '${m[1]}\u00A0',
);

/// Attaches each middle-dot separator in [text] to the item after it with a
/// no-break space, so a wrapped line never ends with a dangling "·": a break
/// falls before the separator and the next line starts with "· item".
String keepSeparatorsAttached(String text) =>
    text.replaceAll(' · ', ' ·\u00A0');
