import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../l10n/app_localizations.dart';
import '../../shared/format/clock.dart';
import '../../shared/layouts/window_size.dart';

/// What the "Other time" pop-up came back with.
sealed class OtherTimeChoice {
  const OtherTimeChoice();
}

/// Record the dose as taken at [at] (UTC).
final class TakenAtChoice extends OtherTimeChoice {
  const TakenAtChoice(this.at);
  final DateTime at;
}

/// The person wants the amount or a note too: open Dose details.
final class OpenDetailsChoice extends OtherTimeChoice {
  const OpenDetailsChoice();
}

/// "When did they take it?": a day and a time, nothing else. Amount and note
/// stay in Dose details. A bottom sheet on the phone, a dialog elsewhere.
///
/// The day and time are read in the dose's own time zone ([zone]), the zone
/// its planned time is shown in. Nothing after [now] can be saved.
Future<OtherTimeChoice?> showOtherTimeSheet(
  BuildContext context, {
  required String personName,
  required String medicationName,
  required String amountLabel,
  required tz.Location zone,
  required String plannedLocalDate,
  required TimeOfDay plannedTime,
  DateTime Function() now = DateTime.now,
}) {
  final content = OtherTimeForm(
    personName: personName,
    medicationName: medicationName,
    amountLabel: amountLabel,
    zone: zone,
    plannedLocalDate: plannedLocalDate,
    plannedTime: plannedTime,
    now: now,
  );
  if (WindowClass.of(context) == WindowClass.compact) {
    return showModalBottomSheet<OtherTimeChoice>(
      context: context,
      // Above the navigation bar, as a step of its own.
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => content,
    );
  }
  return showDialog<OtherTimeChoice>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(padding: const EdgeInsets.only(top: 12), child: content),
      ),
    ),
  );
}

@visibleForTesting
class OtherTimeForm extends StatefulWidget {
  const OtherTimeForm({
    super.key,
    required this.personName,
    required this.medicationName,
    required this.amountLabel,
    required this.zone,
    required this.plannedLocalDate,
    required this.plannedTime,
    this.now = DateTime.now,
  });

  final String personName, medicationName, amountLabel, plannedLocalDate;
  final tz.Location zone;
  final TimeOfDay plannedTime;
  final DateTime Function() now;

  @override
  State<OtherTimeForm> createState() => _OtherTimeFormState();
}

class _OtherTimeFormState extends State<OtherTimeForm> {
  late DateTime _planned; // the planned day, a date-only DateTime
  late DateTime _day;
  late TimeOfDay _time;

  @override
  void initState() {
    super.initState();
    final parts = widget.plannedLocalDate.split('-').map(int.parse).toList();
    _planned = DateTime(parts[0], parts[1], parts[2]);
    _day = _planned;
    _time = widget.plannedTime;
    // A dose taken ahead of its time starts on the time it is now, never on
    // one that has not come yet.
    final now = tz.TZDateTime.from(widget.now(), widget.zone);
    final moment = _moment;
    if (moment != null && moment.isAfter(now)) {
      _day = DateTime(now.year, now.month, now.day);
      _time = TimeOfDay(hour: now.hour, minute: now.minute);
    }
  }

  DateTime get _today {
    final now = tz.TZDateTime.from(widget.now(), widget.zone);
    return DateTime(now.year, now.month, now.day);
  }

  /// The planned day up to today, plus a day chosen from the calendar that
  /// falls outside that run.
  List<DateTime> _days() {
    final today = _today;
    final days = <DateTime>[];
    for (
      var d = _planned.isAfter(today) ? today : _planned;
      !d.isAfter(today);
      d = DateTime(d.year, d.month, d.day + 1)
    ) {
      days.add(d);
    }
    if (!days.contains(_day)) {
      days
        ..add(_day)
        ..sort();
    }
    return days;
  }

  /// The chosen moment in the dose's zone, or null when the wall time does
  /// not exist that day (a clock change skips it).
  tz.TZDateTime? get _moment {
    final at = tz.TZDateTime(
      widget.zone,
      _day.year,
      _day.month,
      _day.day,
      _time.hour,
      _time.minute,
    );
    return at.hour == _time.hour && at.minute == _time.minute ? at : null;
  }

  Future<void> _pickDay() async {
    final today = _today;
    final picked = await showDatePicker(
      context: context,
      initialDate: _day.isAfter(today) ? today : _day,
      firstDate: DateTime(1900),
      lastDate: today,
    );
    if (picked != null && mounted) {
      setState(() => _day = DateTime(picked.year, picked.month, picked.day));
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked != null && mounted) setState(() => _time = picked);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme, text = theme.textTheme;
    final locale = Localizations.localeOf(context).toString();
    final moment = _moment;
    final future = moment != null && moment.isAfter(widget.now());
    final problem = moment == null
        ? l.t10_timeInvalid
        : future
        ? l.rec_future
        : null;
    final plannedWhen =
        '${DateFormat.E(locale).format(_planned)} '
        '${clockTime(context, widget.plannedTime)}';
    final dayWords = DateFormat.MMMMEEEEd(locale).format(_day);
    final timeWords = clockTime(context, _time);
    final today = _today;
    final days = _days();
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(15),
    );

    Widget dayChip(DateTime day) {
      final selected = day == _day;
      final isToday = day == today;
      return Padding(
        padding: const EdgeInsetsDirectional.only(end: 8),
        child: Semantics(
          button: true,
          selected: selected,
          label: isToday
              ? '${l.rec_today}, ${DateFormat.MMMMEEEEd(locale).format(day)}'
              : DateFormat.MMMMEEEEd(locale).format(day),
          excludeSemantics: true,
          child: Material(
            color: selected ? colors.primaryContainer : colors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: selected ? colors.primary : colors.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: InkWell(
              key: ValueKey(
                'other-time-day-${DateFormat('y-MM-dd').format(day)}',
              ),
              borderRadius: BorderRadius.circular(14),
              onTap: () => setState(() => _day = day),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 64, minHeight: 64),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        DateFormat.E(locale).format(day),
                        style: text.labelMedium?.copyWith(
                          color: selected
                              ? colors.onPrimaryContainer
                              : colors.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '${day.day}',
                        style: text.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: selected
                              ? colors.onPrimaryContainer
                              : colors.onSurface,
                        ),
                      ),
                      if (isToday)
                        Text(
                          l.rec_today,
                          style: text.labelSmall?.copyWith(
                            color: selected
                                ? colors.onPrimaryContainer
                                : colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            header: true,
            child: Text(
              l.rec_sheetTitle(widget.personName),
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l.rec_sheetPlanned(
              widget.medicationName,
              widget.amountLabel,
              plannedWhen,
            ),
            style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          Text(l.rec_day, style: text.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              // Loose, so a short run of days starts at the left edge and
              // the calendar follows it; a long one scrolls.
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  // The newest days sit at the end, beside the calendar.
                  reverse: true,
                  child: Row(children: [for (final d in days) dayChip(d)]),
                ),
              ),
              IconButton.outlined(
                key: const ValueKey('other-time-calendar'),
                tooltip: l.rec_anotherDay,
                constraints: const BoxConstraints(minWidth: 56, minHeight: 64),
                style: IconButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  side: BorderSide(color: colors.outlineVariant),
                ),
                onPressed: _pickDay,
                icon: const Icon(Icons.calendar_month_outlined),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(l.rec_time, style: text.titleSmall),
          const SizedBox(height: 8),
          Material(
            color: colors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: colors.outlineVariant),
            ),
            child: InkWell(
              key: const ValueKey('other-time-change'),
              borderRadius: BorderRadius.circular(14),
              onTap: _pickTime,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                child: Row(
                  children: [
                    Icon(Icons.schedule, color: colors.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        timeWords,
                        style: text.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 12,
                        ),
                        child: Text(
                          l.rec_change,
                          style: text.labelLarge?.copyWith(
                            color: colors.primary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: problem == null
                    ? colors.surfaceContainerHigh
                    : colors.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                problem ?? l.rec_summary(dayWords, timeWords),
                key: const ValueKey('other-time-summary'),
                style: text.bodyMedium?.copyWith(
                  color: problem == null
                      ? colors.onSurface
                      : colors.onErrorContainer,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: buttonShape,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l.shared_cancel),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const ValueKey('other-time-save'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: buttonShape,
                  ),
                  onPressed: problem != null
                      ? null
                      : () => Navigator.of(
                          context,
                        ).pop(TakenAtChoice(moment!.toUtc())),
                  child: Text(l.shared_save),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              key: const ValueKey('other-time-details'),
              onPressed: () =>
                  Navigator.of(context).pop(const OpenDetailsChoice()),
              child: Text(l.rec_details, textAlign: TextAlign.center),
            ),
          ),
        ],
      ),
    );
  }
}
