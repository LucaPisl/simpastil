import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import '../../../core/medication/routine_definition.dart';
import '../../../l10n/app_localizations.dart';

/// How often the routine repeats, without its times, e.g. "Every day" or
/// "Mon, Wed".
String routinePatternLabel(BuildContext context, RoutineDefinition definition) {
  final l = AppLocalizations.of(context);
  final symbols = DateFormat(
    '',
    Localizations.localeOf(context).toString(),
  ).dateSymbols;
  return switch (definition.kind) {
    RoutineKind.daily => l.t08_daily,
    RoutineKind.weekdays =>
      definition.weekdays.map((d) => symbols.SHORTWEEKDAYS[d % 7]).join(', '),
    RoutineKind.interval => l.t09_everyN(definition.everyDays!),
    RoutineKind.prn => l.t09_prn,
  };
}

String routineSummary(BuildContext context, RoutineDefinition definition) {
  final pattern = routinePatternLabel(context, definition);
  final times = definition.times
      .map((t) => TimeOfDay(hour: t.hour, minute: t.minute).format(context))
      .join(' · ');
  return times.isEmpty ? pattern : '$pattern · $times';
}

String routineDateLabel(BuildContext context, String value) => DateFormat.yMMMd(
  Localizations.localeOf(context).toString(),
).format(parseRoutineDate(value));

String routineInstantLabel(
  BuildContext context,
  DateTime instant,
  String zone,
) {
  final local = tz.TZDateTime.from(instant, tz.getLocation(zone));
  return '${DateFormat.yMMMEd(Localizations.localeOf(context).toString()).format(local)} · ${TimeOfDay.fromDateTime(local).format(context)}';
}
