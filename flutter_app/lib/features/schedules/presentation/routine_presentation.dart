import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import '../../../core/db/database.dart' show Schedule;
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

/// How often a connected schedule repeats, e.g. "Every day", "Mon, Wed" or
/// "Every 3 calendar days".
String connectedSchedulePatternLabel(BuildContext context, Schedule schedule) {
  final l = AppLocalizations.of(context);
  switch (schedule.frequency) {
    case 'prn':
      return l.t09_prn;
    case 'interval':
      final every = schedule.everyDays;
      return every == null ? l.t09_interval : l.t09_everyN(every);
    case 'custom':
      final symbols = DateFormat(
        '',
        Localizations.localeOf(context).toString(),
      ).dateSymbols;
      final days = <int>{};
      for (final part
          in (schedule.frequencyDays ?? '')
              .replaceAll('[', '')
              .replaceAll(']', '')
              .split(',')) {
        final iso = int.tryParse(part.trim());
        if (iso != null && iso >= 1 && iso <= 7) days.add(iso);
      }
      if (days.isEmpty) return l.schedules_specificDays;
      final ordered = days.toList()..sort();
      return ordered.map((iso) => symbols.SHORTWEEKDAYS[iso % 7]).join(', ');
    default:
      return l.t08_daily;
  }
}

/// The "From" and "Until" date lines a connected schedule carries, when it
/// has any. An interval also names the day it counts from.
List<String> connectedScheduleDateLines(
  BuildContext context,
  Schedule schedule,
) {
  final l = AppLocalizations.of(context);
  return [
    if (schedule.frequency == 'interval' && schedule.anchorDate != null)
      '${l.t09_anchor} · ${routineDateLabel(context, schedule.anchorDate!)}',
    if (schedule.startDate != null)
      '${l.t09_startDate} · ${routineDateLabel(context, schedule.startDate!)}',
    if (schedule.endDate != null)
      '${l.t09_endDate} · ${routineDateLabel(context, schedule.endDate!)}',
  ];
}
