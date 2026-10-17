import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';
import '../../../core/medication/medication_amount.dart';
import '../../../core/medication/occurrence_materializer.dart';
import '../../../core/medication/reviewed_time_zone.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../core/medication/routine_provider.dart';
import '../../../core/medication/routine_repository.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/format/clock.dart';
import '../../../shared/widgets/readable_zone_picker.dart';
import 'day_lid.dart';
import 'dose_dial.dart';
import 'routine_presentation.dart';

/// The same reviewed engine and stable time-slot identities serve setup and edits.
class RoutineEditor extends ConsumerStatefulWidget {
  const RoutineEditor({
    super.key,
    required this.pillId,
    required this.amount,
    required this.onSaved,
    this.initial,
    this.routineId,
    this.expectedRevision = 0,
    this.earliestBoundary,
    this.onDraft,
    this.onSkip,
    this.setupPresentation = false,
    this.now = DateTime.now,
  });
  final String pillId;
  final MedicationAmount amount;
  final RoutineDefinition? initial;
  final String? routineId;
  final int expectedRevision;
  final DateTime? earliestBoundary;
  final Future<void> Function(RoutineDefinition, DateTime)? onDraft;
  final VoidCallback onSaved;
  final VoidCallback? onSkip;
  final bool setupPresentation;
  final DateTime Function() now;
  @override
  ConsumerState<RoutineEditor> createState() => _RoutineEditorState();
}

class _RoutineEditorState extends ConsumerState<RoutineEditor> {
  late RoutineKind _kind;
  late List<RoutineTime> _times;
  int _skyFocus = 0;
  late Set<int> _weekdays;
  final _interval = TextEditingController();
  final _quantity = TextEditingController();
  final _unit = TextEditingController();
  late bool _unknown;
  String? _zone, _anchor, _start, _end, _error;
  DateTime? _boundary;
  bool _boundaryChosen = false;
  bool _loadingZone = false, _zoneUnavailable = false, _busy = false;
  Timer? _draftTimer;
  Future<void> _draftWrite = Future.value();
  ReviewedRoutinePreview? _preview;
  RoutineRepository? _repository;
  bool get _editing => widget.expectedRevision > 0;
  @override
  void initState() {
    super.initState();
    final prior = widget.initial;
    _kind = prior?.kind ?? RoutineKind.daily;
    _times =
        prior?.times.toList() ??
        [const RoutineTime(slotId: 'morning', hour: 8, minute: 0)];
    _weekdays = prior?.weekdays.toSet() ?? {DateTime.now().weekday};
    _interval.text = '${prior?.everyDays ?? 2}';
    _anchor = prior?.anchorDate;
    _start = prior?.startDate;
    _end = prior?.endDate;
    _zone = prior?.timeZone;
    final amount = prior?.amount ?? widget.amount;
    _unknown = amount.isUnknown;
    _quantity.text = amount.quantityText ?? '';
    _unit.text = amount.unit ?? '';
    if (_editing) _boundary = _defaultBoundary(widget.now());
    if (_zone == null) _detectZone();
  }

  DateTime _defaultBoundary(DateTime now) {
    final nextMinute = DateTime.fromMillisecondsSinceEpoch(
      (now.millisecondsSinceEpoch ~/ 60000 + 1) * 60000,
      isUtc: true,
    );
    final earliest = widget.earliestBoundary;
    return earliest != null && earliest.isAfter(nextMinute)
        ? earliest
        : nextMinute;
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    _interval.dispose();
    _quantity.dispose();
    _unit.dispose();
    super.dispose();
  }

  Future<void> _detectZone() async {
    if (_loadingZone) return;
    setState(() {
      _loadingZone = true;
      _zoneUnavailable = false;
    });
    try {
      final zone = await ref.refresh(deviceTimeZoneProvider.future);
      if (mounted) setState(() => _zone ??= zone);
    } on Object {
      if (mounted) setState(() => _zoneUnavailable = true);
    } finally {
      if (mounted) setState(() => _loadingZone = false);
    }
  }

  RoutineDefinition _definition() {
    final zone = _zone!;
    final local = tz.TZDateTime.now(tz.getLocation(zone));
    return RoutineDefinition(
      kind: _kind,
      timeZone: zone,
      times: _kind == RoutineKind.prn ? [] : _times,
      weekdays: _kind == RoutineKind.weekdays ? _weekdays.toList() : [],
      everyDays: _kind == RoutineKind.interval
          ? int.tryParse(_interval.text)
          : null,
      anchorDate: _kind == RoutineKind.interval
          ? _anchor ?? routineDateKey(local)
          : null,
      startDate: _start,
      endDate: _end,
      amount: _unknown
          ? const MedicationAmount.unknown()
          : MedicationAmount.known(_quantity.text.trim(), _unit.text.trim()),
    );
  }

  void _changed() {
    setState(() {
      _preview = null;
      _error = null;
    });
    _draftTimer?.cancel();
    if (widget.onDraft == null || _zone == null) return;
    _draftTimer = Timer(const Duration(milliseconds: 450), () {
      _draftWrite = _draftWrite.then((_) async {
        if (!mounted || _busy) return;
        try {
          await widget.onDraft!(_definition(), DateTime.now().toUtc());
        } on ArgumentError {
          // Partial input remains visible; saving requires a valid review.
        } on FormatException {
          // A fraction may be incomplete while it is being entered.
        } on Object {
          if (mounted) {
            setState(() => _error = AppLocalizations.of(context).t08_saveError);
          }
        }
      });
    });
  }

  bool _owns(RoutineRepository repository) {
    if (!mounted) return false;
    final state = ref.read(routineRepositoryProvider);
    return !state.hasError &&
        !state.isLoading &&
        identical(state.asData?.value, repository);
  }

  Future<void> _review() async {
    if (_busy || _zone == null) return;
    final ready = ref.read(routineRepositoryProvider);
    final repository = ready.asData?.value;
    if (ready.hasError || ready.isLoading || repository == null) return;
    _draftTimer?.cancel();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _draftWrite;
      if (!_owns(repository)) return;
      final definition = _definition();
      final now = widget.now().toUtc();
      if (_editing && !_boundaryChosen) {
        // Editing may outlast the initially displayed next-minute boundary.
        // Refresh only the automatic default; the preview shows the new time.
        _boundary = _defaultBoundary(now);
      }
      final boundary = _editing ? _boundary! : now;
      if (_editing && !boundary.isAfter(now)) {
        setState(
          () => _error = AppLocalizations.of(context).t09_futureBoundary,
        );
        return;
      }
      final local = tz.TZDateTime.from(
        boundary.isAfter(now) ? boundary : now,
        tz.getLocation(definition.timeZone),
      );
      final preview = await repository.preview(
        pillId: widget.pillId,
        routineId: widget.routineId,
        expectedRevision: widget.expectedRevision,
        definition: definition,
        effectiveFrom: boundary,
        fromLocalDate: routineDateKey(local),
        throughLocalDate: routineDateKey(
          DateTime.utc(local.year, local.month, local.day + 30),
        ),
      );
      if (!_owns(repository)) return;
      await widget.onDraft?.call(definition, preview.effectiveFrom);
      if (_owns(repository)) {
        setState(() {
          _repository = repository;
          _preview = preview;
        });
      }
    } on RoutineConflict {
      if (mounted) {
        setState(
          () => _error = AppLocalizations.of(context).t09_reviewConflict,
        );
      }
    } on Object {
      if (mounted) {
        setState(
          () => _error = AppLocalizations.of(context).t08_invalidRoutine,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final preview = _preview;
    final repository = _repository;
    if (_busy || preview == null || repository == null || !_owns(repository)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await repository.saveReviewed(preview);
      if (_owns(repository)) widget.onSaved();
    } on RoutineConflict {
      if (_owns(repository)) {
        setState(() {
          _preview = null;
          _error = AppLocalizations.of(context).t09_reviewConflict;
        });
      }
    } on Object {
      if (_owns(repository)) {
        setState(() => _error = AppLocalizations.of(context).t08_saveError);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _time(int? index) async {
    final prior = index == null
        ? const TimeOfDay(hour: 20, minute: 0)
        : TimeOfDay(hour: _times[index].hour, minute: _times[index].minute);
    final value = await showTimePicker(context: context, initialTime: prior);
    if (!mounted || value == null) return;
    final time = RoutineTime(
      slotId: index == null ? const Uuid().v4() : _times[index].slotId,
      hour: value.hour,
      minute: value.minute,
    );
    if (index == null) {
      _times.add(time);
    } else {
      _times[index] = time;
    }
    _skyFocus = index ?? _times.length - 1;
    _changed();
  }

  /// A capsule dragged on the dial, or stepped by a screen reader. Picking
  /// one up without moving it only focuses it.
  void _dragTime(int index, TimeOfDay value) {
    final prior = _times[index];
    if (prior.hour == value.hour && prior.minute == value.minute) {
      setState(() => _skyFocus = index);
      return;
    }
    _times[index] = RoutineTime(
      slotId: prior.slotId,
      hour: value.hour,
      minute: value.minute,
    );
    _skyFocus = index;
    _changed();
  }

  Future<void> _date(String? value, ValueChanged<String> setValue) async {
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: value == null ? now : parseRoutineDate(value),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (!mounted || selected == null) return;
    setValue(routineDateKey(selected));
    _changed();
  }

  Future<void> _changeBoundary() async {
    final zone = _zone;
    if (zone == null) return;
    final local = tz.TZDateTime.from(_boundary!, tz.getLocation(zone));
    final today = tz.TZDateTime.now(tz.getLocation(zone));
    final date = await showDatePicker(
      context: context,
      initialDate: local.isBefore(today) ? today : local,
      firstDate: DateTime(today.year, today.month, today.day),
      lastDate: DateTime(2100),
    );
    if (!mounted || date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(local),
    );
    if (!mounted || time == null) return;
    _boundaryChosen = true;
    _boundary = OccurrenceMaterializer.resolveReviewedLocalTime(
      localDate: routineDateKey(date),
      hour: time.hour,
      minute: time.minute,
      timeZone: zone,
    );
    _changed();
  }

  Widget _dateControl(
    String label,
    String? value,
    ValueChanged<String?> setValue, {
    required String key,
  }) => Row(
    children: [
      Expanded(
        child: OutlinedButton(
          key: ValueKey(key),
          onPressed: _busy ? null : () => _date(value, setValue),
          child: Text(
            '$label · ${value == null ? AppLocalizations.of(context).t09_notSet : routineDateLabel(context, value)}',
          ),
        ),
      ),
      if (value != null)
        IconButton(
          tooltip: AppLocalizations.of(context).t09_clearDate,
          onPressed: _busy
              ? null
              : () {
                  setValue(null);
                  _changed();
                },
          icon: const Icon(Icons.close),
        ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final preview = _preview;
    final ready = ref.watch(routineRepositoryProvider);
    final available =
        !ready.hasError && !ready.isLoading && ready.asData != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CareTransition(
          child: preview == null
              ? Column(
                  key: const ValueKey('routine-edit'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.setupPresentation ? l.r08_repeat : l.t09_pattern,
                      style: text.titleLarge?.copyWith(
                        fontWeight: widget.setupPresentation
                            ? FontWeight.w700
                            : null,
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<RoutineKind>(
                      key: const ValueKey('routine-pattern'),
                      initialValue: _kind,
                      decoration: widget.setupPresentation
                          ? const InputDecoration(
                              prefixIcon: Icon(Icons.repeat),
                            )
                          : null,
                      isExpanded: true,
                      items: [
                        for (final kind in RoutineKind.values)
                          DropdownMenuItem(
                            value: kind,
                            child: Text(switch (kind) {
                              RoutineKind.daily => l.t08_daily,
                              RoutineKind.weekdays => l.t09_weekdays,
                              RoutineKind.interval => l.t09_interval,
                              RoutineKind.prn => l.t09_prn,
                            }),
                          ),
                      ],
                      onChanged: _busy
                          ? null
                          : (kind) {
                              if (kind == null) return;
                              _kind = kind;
                              if (kind != RoutineKind.prn && _times.isEmpty) {
                                _times.add(
                                  const RoutineTime(
                                    slotId: 'morning',
                                    hour: 8,
                                    minute: 0,
                                  ),
                                );
                              }
                              _changed();
                            },
                    ),
                    const SizedBox(height: 16),
                    if (_kind == RoutineKind.weekdays)
                      Wrap(
                        spacing: 8,
                        children: [
                          for (var d = 1; d <= 7; d++)
                            FilterChip(
                              key: ValueKey('weekday-$d'),
                              showCheckmark: false,
                              avatar: DayLid(open: _weekdays.contains(d)),
                              label: Text(
                                DateFormat(
                                  '',
                                  Localizations.localeOf(context).toString(),
                                ).dateSymbols.SHORTWEEKDAYS[d % 7],
                              ),
                              selected: _weekdays.contains(d),
                              onSelected: _busy
                                  ? null
                                  : (yes) {
                                      yes
                                          ? _weekdays.add(d)
                                          : _weekdays.remove(d);
                                      _changed();
                                    },
                            ),
                        ],
                      ),
                    if (_kind == RoutineKind.interval) ...[
                      TextField(
                        key: const ValueKey('routine-interval'),
                        controller: _interval,
                        enabled: !_busy,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: l.t09_everyDays),
                        onChanged: (_) => _changed(),
                      ),
                      const SizedBox(height: 12),
                      _dateControl(
                        l.t09_anchor,
                        _anchor ??
                            routineDateKey(
                              _zone == null
                                  ? DateTime.now()
                                  : tz.TZDateTime.now(tz.getLocation(_zone!)),
                            ),
                        (v) => _anchor = v,
                        key: 'routine-anchor',
                      ),
                    ],
                    if (_kind == RoutineKind.prn)
                      Text(l.t09_prnHelp, style: text.bodyLarge),
                    if (_kind != RoutineKind.prn) ...[
                      if (_times.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: DoseDial(
                            key: const ValueKey('routine-dial'),
                            focus: _skyFocus.clamp(0, _times.length - 1),
                            times: [
                              for (final t in _times)
                                TimeOfDay(hour: t.hour, minute: t.minute),
                            ],
                            onChanged: _busy ? null : _dragTime,
                          ),
                        ),
                      for (var i = 0; i < _times.length; i++)
                        Row(
                          children: [
                            Expanded(
                              child: widget.setupPresentation
                                  ? Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Material(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primaryContainer,
                                        borderRadius: BorderRadius.circular(14),
                                        clipBehavior: Clip.antiAlias,
                                        child: InkWell(
                                          key: ValueKey('routine-time-$i'),
                                          onTap: _busy ? null : () => _time(i),
                                          child: Padding(
                                            padding: const EdgeInsets.all(16),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        l.r08_scheduledTime,
                                                        style: text.bodyMedium
                                                            ?.copyWith(
                                                              color: Theme.of(context)
                                                                  .colorScheme
                                                                  .onPrimaryContainer,
                                                            ),
                                                      ),
                                                      Text(
                                                        TimeOfDay(
                                                          hour: _times[i].hour,
                                                          minute:
                                                              _times[i].minute,
                                                        ).format(context),
                                                        style: text
                                                            .headlineLarge
                                                            ?.copyWith(
                                                              fontSize: 36,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700,
                                                              color: Theme.of(context)
                                                                  .colorScheme
                                                                  .onPrimaryContainer,
                                                            ),
                                                      ),
                                                      Text(
                                                        _unknown
                                                            ? l.t08_unknown
                                                            : '${_quantity.text} ${_unit.text}',
                                                        style: text.bodyLarge?.copyWith(
                                                          color: Theme.of(context)
                                                              .colorScheme
                                                              .onPrimaryContainer,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Icon(
                                                  Icons.schedule,
                                                  size: 30,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onPrimaryContainer,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    )
                                  : OutlinedButton(
                                      key: ValueKey('routine-time-$i'),
                                      onPressed: _busy ? null : () => _time(i),
                                      child: Text(
                                        TimeOfDay(
                                          hour: _times[i].hour,
                                          minute: _times[i].minute,
                                        ).format(context),
                                      ),
                                    ),
                            ),
                            if (_times.length > 1)
                              IconButton(
                                tooltip: l.t08_removeTime,
                                onPressed: _busy
                                    ? null
                                    : () {
                                        _times.removeAt(i);
                                        _changed();
                                      },
                                icon: const Icon(Icons.remove_circle_outline),
                              ),
                          ],
                        ),
                      TextButton.icon(
                        onPressed: _busy ? null : () => _time(null),
                        icon: const Icon(Icons.add),
                        label: Text(l.t08_addTime),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Text(l.t08_amount, style: text.titleMedium),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.t08_unknown),
                      value: _unknown,
                      onChanged: _busy
                          ? null
                          : (v) {
                              _unknown = v;
                              _changed();
                            },
                    ),
                    if (!_unknown) ...[
                      TextField(
                        key: const ValueKey('routine-quantity'),
                        controller: _quantity,
                        enabled: !_busy,
                        decoration: InputDecoration(
                          labelText: l.t08_quantity,
                          hintText: l.t08_quantityHint,
                        ),
                        onChanged: (_) => _changed(),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('routine-unit'),
                        controller: _unit,
                        enabled: !_busy,
                        decoration: InputDecoration(labelText: l.t08_unit),
                        onChanged: (_) => _changed(),
                      ),
                    ],
                    const SizedBox(height: 20),
                    ExpansionTile(
                      key: const ValueKey('routine-optional-dates'),
                      tilePadding: widget.setupPresentation
                          ? const EdgeInsets.symmetric(horizontal: 12)
                          : EdgeInsets.zero,
                      shape: widget.setupPresentation
                          ? RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: Theme.of(
                                  context,
                                ).colorScheme.outlineVariant,
                              ),
                            )
                          : null,
                      collapsedShape: widget.setupPresentation
                          ? RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: Theme.of(
                                  context,
                                ).colorScheme.outlineVariant,
                              ),
                            )
                          : null,
                      leading: widget.setupPresentation
                          ? const Icon(Icons.calendar_today_outlined)
                          : null,
                      title: Text(l.t09_dates),
                      children: [
                        _dateControl(
                          l.t09_startDate,
                          _start,
                          (v) => _start = v,
                          key: 'routine-start',
                        ),
                        _dateControl(
                          l.t09_endDate,
                          _end,
                          (v) => _end = v,
                          key: 'routine-end',
                        ),
                      ],
                    ),
                    if (_editing && _zone != null) ...[
                      const SizedBox(height: 20),
                      Text(l.t09_changesFrom, style: text.titleMedium),
                      OutlinedButton(
                        key: const ValueKey('routine-boundary'),
                        onPressed: _busy ? null : _changeBoundary,
                        child: Text(
                          routineInstantLabel(context, _boundary!, _zone!),
                        ),
                      ),
                      Text(
                        readableZone(context, _zone!),
                        style: text.bodyMedium,
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                final zone = await chooseReadableZone(context);
                                if (!mounted || zone == null) return;
                                _zone = zone;
                                _changed();
                              },
                        child: Text(l.t09_changeZone),
                      ),
                      Text(l.t09_zoneHelp, style: text.bodyMedium),
                    ],
                    if (_loadingZone) const LinearProgressIndicator(),
                    if (_zoneUnavailable) ...[
                      Text(l.t08_phoneTimeUnavailable),
                      TextButton(
                        key: const ValueKey('retry-device-time'),
                        onPressed: _detectZone,
                        child: Text(l.shared_retry),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      key: const ValueKey('review-routine'),
                      onPressed: _busy || _zone == null || !available
                          ? null
                          : _review,
                      child: Text(
                        _busy
                            ? l.t08_saving
                            : _editing
                            ? l.t09_reviewChanges
                            : l.t08_preview,
                      ),
                    ),
                    if (widget.onSkip != null)
                      TextButton(
                        onPressed: _busy ? null : widget.onSkip,
                        child: Text(l.t08_notNow),
                      ),
                  ],
                )
              : Column(
                  key: const ValueKey('routine-preview'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_editing) ...[
                      Text(l.t09_before, style: text.titleMedium),
                      Text(
                        routineSummary(context, widget.initial!),
                        style: text.bodyLarge,
                      ),
                      const SizedBox(height: 20),
                      Text(l.t09_after, style: text.titleMedium),
                      Text(
                        routineSummary(context, preview.definition),
                        style: text.bodyLarge,
                      ),
                      const SizedBox(height: 20),
                      Text(l.t09_changesFrom, style: text.titleMedium),
                      Text(
                        routineInstantLabel(
                          context,
                          preview.effectiveFrom,
                          preview.definition.timeZone,
                        ),
                      ),
                      Text(readableZone(context, preview.definition.timeZone)),
                      const SizedBox(height: 12),
                      Text(l.t09_preserveRecords),
                      const SizedBox(height: 24),
                    ],
                    Text(
                      _kind == RoutineKind.prn ? l.t09_prn : l.t09_nextEntries,
                      style: text.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    if (_kind == RoutineKind.prn)
                      Text(l.t09_prnHelp, style: text.bodyLarge)
                    else if (preview.upcoming.isEmpty)
                      Text(l.t09_noPreview, style: text.bodyLarge)
                    else if (widget.setupPresentation)
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 4,
                        ),
                        child: Column(
                          children: [
                            for (
                              var i = 0;
                              i < preview.upcoming.take(5).length;
                              i++
                            ) ...[
                              if (i > 0)
                                Divider(
                                  height: 1,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.outlineVariant,
                                ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                child: LayoutBuilder(
                                  builder: (context, bounds) {
                                    final entry = preview.upcoming[i];
                                    final planned = tz.TZDateTime.from(
                                      entry.plannedAt,
                                      tz.getLocation(entry.timeZone),
                                    );
                                    final date = Text(
                                      DateFormat.yMMMEd(
                                        Localizations.localeOf(
                                          context,
                                        ).toString(),
                                      ).format(planned),
                                      style: text.bodyLarge,
                                    );
                                    final time = Text(
                                      clockAt(context, planned),
                                      style: text.titleLarge?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    );
                                    return MediaQuery.textScalerOf(
                                              context,
                                            ).scale(16) >
                                            22
                                        ? Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [date, time],
                                          )
                                        : Row(
                                            children: [
                                              Expanded(child: date),
                                              const SizedBox(width: 12),
                                              time,
                                            ],
                                          );
                                  },
                                ),
                              ),
                            ],
                          ],
                        ),
                      )
                    else
                      for (final entry in preview.upcoming.take(5))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text(
                            routineInstantLabel(
                              context,
                              entry.plannedAt,
                              entry.timeZone,
                            ),
                            style: text.titleMedium,
                          ),
                        ),
                    const SizedBox(height: 16),
                    Text(
                      routineSummary(context, preview.definition),
                      style: text.bodyLarge,
                    ),
                    if (preview.definition.anchorDate != null)
                      Text(
                        '${l.t09_anchor} · ${routineDateLabel(context, preview.definition.anchorDate!)}',
                      ),
                    if (_start != null)
                      Text(
                        '${l.t09_startDate} · ${routineDateLabel(context, _start!)}',
                      ),
                    if (_end != null)
                      Text(
                        '${l.t09_endDate} · ${routineDateLabel(context, _end!)}',
                      ),
                    const SizedBox(height: 12),
                    Text(
                      '${l.t08_amount}: ${preview.definition.amount.isUnknown ? l.t08_unknown : '${preview.definition.amount.quantityText} ${preview.definition.amount.unit}'}',
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      key: const ValueKey('save-routine'),
                      onPressed: _busy ? null : _save,
                      child: Text(_busy ? l.t08_saving : l.t08_saveRoutine),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _preview = null),
                      child: Text(l.t08_edit),
                    ),
                  ],
                ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ],
    );
  }
}
