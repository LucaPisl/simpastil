import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../core/db/database.dart';
import '../../../shared/format/clock.dart';
import '../../../core/errors/app_error.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/motion/staggered_entrance.dart';
import '../../../shared/widgets/drag_handle.dart';
import '../../../shared/widgets/review_failure_message.dart';
import '../../../shared/widgets/readable_zone_picker.dart';
import '../../../core/sync/auto_sync_service.dart';
import '../../profiles/profile_provider.dart';
import '../../schedules/presentation/dose_dial.dart';
import '../schedule_provider.dart';
import 'medication_form_kit.dart';

// ── Day-of-week ISO indices ──────────────────────────────────────────────────

const _kDayIsos = [1, 2, 3, 4, 5, 6, 7];

List<String> _dayLabels(AppLocalizations l) => [
  l.schedules_dayMon,
  l.schedules_dayTue,
  l.schedules_dayWed,
  l.schedules_dayThu,
  l.schedules_dayFri,
  l.schedules_daySat,
  l.schedules_daySun,
];

// ── Public API ────────────────────────────────────────────────────────────────

Future<void> showAddEditScheduleSheet({
  required BuildContext context,
  required String pillId,
  bool pillIsPrn = false,
  Schedule? schedule,
  String? repairIssueId,
  int? repairIssueRevision,
  String? repairIssueCode,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _AddEditScheduleSheet(
      pillId: pillId,
      pillIsPrn: pillIsPrn,
      schedule: schedule,
      repairIssueId: repairIssueId,
      repairIssueRevision: repairIssueRevision,
      repairIssueCode: repairIssueCode,
    ),
  );
}

// ── Sheet ─────────────────────────────────────────────────────────────────────

class _AddEditScheduleSheet extends ConsumerStatefulWidget {
  const _AddEditScheduleSheet({
    required this.pillId,
    required this.pillIsPrn,
    this.schedule,
    this.repairIssueId,
    this.repairIssueRevision,
    this.repairIssueCode,
  });

  final String pillId;
  final bool pillIsPrn;
  final Schedule? schedule;
  final String? repairIssueId;
  final int? repairIssueRevision;
  final String? repairIssueCode;

  @override
  ConsumerState<_AddEditScheduleSheet> createState() =>
      _AddEditScheduleSheetState();
}

class _AddEditScheduleSheetState extends ConsumerState<_AddEditScheduleSheet> {
  late TimeOfDay _time;
  late bool _isDaily; // true = daily; false = specific days
  late Set<int> _selectedDays; // ISO weekday ints
  late bool _isActive;
  DateTime _effectiveFromLocalDate = DateTime.now();
  late final TextEditingController _timeZoneController;
  bool _isSaving = false;
  bool _daysNeeded = false;
  AppError? _submissionError;
  final Object _sectionIdentity = Object();

  @override
  void initState() {
    super.initState();
    final s = widget.schedule;
    _timeZoneController = TextEditingController(
      text: s?.timeZone ?? tz.local.name,
    );
    _time = s != null
        ? TimeOfDay(hour: s.hour, minute: s.minute)
        : TimeOfDay.now();
    _isDaily = s == null || s.frequency == 'daily';
    _isActive = s?.isActive ?? true;

    if (s != null && s.frequency != 'daily' && s.frequencyDays != null) {
      // Parse stored JSON day list
      try {
        final raw =
            (s.frequencyDays!
                    .replaceAll('[', '')
                    .replaceAll(']', '')
                    .split(','))
                .map((e) => int.tryParse(e.trim()) ?? 0)
                .where((d) => d >= 1 && d <= 7)
                .toSet();
        _selectedDays = raw;
      } catch (_) {
        _selectedDays = {};
      }
    } else {
      _selectedDays = {};
    }
  }

  bool get _isPrn => widget.pillIsPrn || widget.schedule?.frequency == 'prn';

  bool get _isEditMode => widget.schedule != null;
  bool get _isRepairMode =>
      widget.schedule != null &&
      widget.repairIssueId != null &&
      widget.repairIssueRevision != null;
  bool get _isTimezoneReviewRepair =>
      _isRepairMode &&
      widget.repairIssueCode == 'schedule_timezone_review_required';
  bool get _isFrequencyRepair =>
      _isRepairMode &&
      widget.repairIssueCode == 'invalid_schedule_frequency_days';

  bool get _isLegacyPrnRecovery {
    final schedule = widget.schedule;
    return !_isRepairMode &&
        widget.pillIsPrn &&
        schedule != null &&
        schedule.frequency == 'prn' &&
        schedule.frequencyDays == null &&
        schedule.serverId == null &&
        schedule.revision == 1 &&
        schedule.syncStatus == 'pending' &&
        !schedule.isActive &&
        !schedule.isDeleted &&
        schedule.timeZoneStatus == 'legacy_unknown' &&
        schedule.timeZone == null;
  }

  @override
  void dispose() {
    _timeZoneController.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked != null) setState(() => _time = picked);
  }

  Future<void> _submit() async {
    final l = AppLocalizations.of(context);
    if (!_isPrn && !_isDaily && _selectedDays.isEmpty) {
      // Said calmly next to the days, where the fix is.
      setState(() => _daysNeeded = true);
      return;
    }

    setState(() {
      _isSaving = true;
      _submissionError = null;
    });

    final repo = ref.read(scheduleRepositoryProvider);
    final frequency = _isPrn
        ? 'prn'
        : _isDaily
        ? 'daily'
        : 'custom';
    final days = _isPrn || _isDaily ? null : (_selectedDays.toList()..sort());

    Result<Schedule> result;
    try {
      if (_isLegacyPrnRecovery) {
        result = await repo.recoverLegacyPrn(
          localId: widget.schedule!.id,
          timeZone: _timeZoneController.text.trim(),
        );
      } else if (_isRepairMode) {
        result = await repo.repair(
          localId: widget.schedule!.id,
          issueId: widget.repairIssueId!,
          expectedIssueRevision: widget.repairIssueRevision!,
          hour: _time.hour,
          minute: _time.minute,
          frequency: frequency,
          frequencyDays: days,
          isActive: _isActive,
          timeZone: _timeZoneController.text.trim(),
          effectiveFromLocalDate: DateTime(
            _effectiveFromLocalDate.year,
            _effectiveFromLocalDate.month,
            _effectiveFromLocalDate.day,
          ),
        );
      } else if (_isEditMode) {
        result = await repo.update(
          widget.schedule!.id,
          hour: _time.hour,
          minute: _time.minute,
          frequency: frequency,
          frequencyDays: days,
          isActive: _isActive,
        );
      } else {
        result = await repo.create(
          pillId: widget.pillId,
          hour: _time.hour,
          minute: _time.minute,
          frequency: frequency,
          frequencyDays: days,
          isActive: _isActive,
        );
      }
    } on Object {
      // A thrown failure must still end in a message, never a stuck Save.
      result = const Err(UnknownError());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }

    if (!mounted) return;

    switch (result) {
      case Ok():
        if (_isRepairMode || _isLegacyPrnRecovery) {
          try {
            await ref
                .read(autoSyncServiceProvider)
                .syncNow(ref.read(currentUserIdProvider));
          } catch (_) {
            // A queued restoration remains durable and paused until its
            // receipt; a server repair stays visible until account sync.
          }
        }
        if (!mounted) return;
        Navigator.of(context).pop();
      case Err(:final error):
        if (_isRepairMode || _isLegacyPrnRecovery) {
          setState(() => _submissionError = error);
        } else {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(_errorMessage(l, error))));
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      maxChildSize: 0.9,
      minChildSize: 0.4,
      expand: false,
      builder: (_, scrollController) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          children: [
            const DragHandle(),

            Expanded(
              child: SingleChildScrollView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: FocusTraversalGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _isLegacyPrnRecovery
                            ? l.schedules_restorePrnTitle
                            : _isEditMode
                            ? l.schedules_editTitle
                            : l.schedules_newTitle,
                        style: text.titleLarge,
                      ),
                      if (_isLegacyPrnRecovery) ...[
                        const SizedBox(height: 12),
                        Text(l.schedules_restorePrnExplanation),
                        const SizedBox(height: 12),
                        Text(
                          l.schedules_restorePrnZone,
                          style: text.labelMedium,
                        ),
                        const SizedBox(height: 6),
                        OutlinedButton.icon(
                          onPressed: _isSaving
                              ? null
                              : () async {
                                  final zone = await chooseReadableZone(
                                    context,
                                  );
                                  if (zone != null && mounted) {
                                    setState(
                                      () => _timeZoneController.text = zone,
                                    );
                                  }
                                },
                          icon: const Icon(Icons.public_outlined),
                          label: Text(
                            readableZone(context, _timeZoneController.text),
                          ),
                        ),
                      ],
                      if (_isRepairMode) ...[
                        const SizedBox(height: 12),
                        Container(
                          key: const ValueKey('schedule-repair-summary'),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest.withValues(
                              alpha: 0.5,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l.t09_before, style: text.labelMedium),
                              const SizedBox(height: 6),
                              if (!_isPrn) ...[
                                Text(
                                  '${l.schedules_timeLabel}: ${clockTime(context, _time)}',
                                  style: text.titleMedium,
                                ),
                                const SizedBox(height: 4),
                              ],
                              Text(
                                '${l.schedules_frequencyLabel}: ${_repairFrequencyLabel(l)}',
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _isActive
                                    ? l.schedules_active
                                    : l.schedules_paused,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${l.t08_zone}: ${readableZone(context, _timeZoneController.text)}',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          Localizations.localeOf(context).languageCode == 'ro'
                              ? 'Data de la care se aplică programul reparat'
                              : 'Apply the repaired schedule from',
                          style: text.labelMedium,
                        ),
                        const SizedBox(height: 6),
                        OutlinedButton.icon(
                          onPressed: _pickEffectiveDate,
                          icon: const Icon(Icons.calendar_today_outlined),
                          label: Text(_dateLabel(_effectiveFromLocalDate)),
                        ),
                        const SizedBox(height: 12),
                        if (_isTimezoneReviewRepair) ...[
                          Text(l.t08_zone, style: text.labelMedium),
                          const SizedBox(height: 6),
                          OutlinedButton.icon(
                            key: const ValueKey('schedule-repair-zone'),
                            onPressed: _isSaving
                                ? null
                                : () async {
                                    final zone = await chooseReadableZone(
                                      context,
                                    );
                                    if (zone != null && mounted) {
                                      setState(
                                        () => _timeZoneController.text = zone,
                                      );
                                    }
                                  },
                            icon: const Icon(Icons.public_outlined),
                            label: Text(
                              readableZone(context, _timeZoneController.text),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(l.t08_zoneHelp, style: text.bodySmall),
                        ],
                      ],
                      const SizedBox(height: 24),

                      if (_isPrn) ...[
                        Text(l.t08_asNeeded, style: text.titleMedium),
                        const SizedBox(height: 8),
                        Text(l.t10_prnHint),
                        const SizedBox(height: 24),
                      ] else ...[
                        // ── When: time card with its day sky ─────────────────
                        if (!_isRepairMode)
                          FormSection(
                            index: 0,
                            identity: _sectionIdentity,
                            icon: Icons.wb_twilight_rounded,
                            title: l.mf_sectionWhen,
                            children: [_timeCard(context)],
                          ),

                        // ── Repeat ───────────────────────────────────────────
                        if (!_isRepairMode || _isFrequencyRepair)
                          FormSection(
                            index: 1,
                            identity: _sectionIdentity,
                            icon: Icons.repeat_rounded,
                            title: l.schedules_frequencyLabel,
                            children: [
                              Semantics(
                                label: l.schedules_frequencySemantic(
                                  _isDaily
                                      ? l.schedules_daily
                                      : l.schedules_specificDays,
                                ),
                                child: SegmentedButton<bool>(
                                  segments: [
                                    ButtonSegment(
                                      value: true,
                                      label: Text(l.schedules_daily),
                                      icon: const Icon(Icons.repeat),
                                    ),
                                    ButtonSegment(
                                      value: false,
                                      label: Text(l.schedules_specificDays),
                                      icon: const Icon(
                                        Icons.calendar_today_outlined,
                                      ),
                                    ),
                                  ],
                                  selected: {_isDaily},
                                  onSelectionChanged: (s) => setState(() {
                                    _isDaily = s.first;
                                    _daysNeeded = false;
                                  }),
                                ),
                              ),
                              // ── Day-of-week picker ─────────────────────────
                              AnimatedSize(
                                duration: AppMotion.duration(context),
                                curve: AppMotion.curve,
                                alignment: Alignment.topCenter,
                                child: _isDaily
                                    ? const SizedBox(width: double.infinity)
                                    : Padding(
                                        padding: const EdgeInsets.only(top: 14),
                                        child: _DayPicker(
                                          selected: _selectedDays,
                                          onToggle: (iso) => setState(() {
                                            if (_selectedDays.contains(iso)) {
                                              _selectedDays.remove(iso);
                                            } else {
                                              _selectedDays.add(iso);
                                            }
                                            if (_selectedDays.isNotEmpty) {
                                              _daysNeeded = false;
                                            }
                                          }),
                                        ),
                                      ),
                              ),
                              if (_daysNeeded && !_isDaily)
                                Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: Semantics(
                                    liveRegion: true,
                                    child: Text(
                                      l.mf_daysNeeded,
                                      key: const ValueKey(
                                        'schedule-days-needed',
                                      ),
                                      style: text.bodyMedium?.copyWith(
                                        color: cs.error,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                      ],

                      // ── Active toggle ─────────────────────────────────────────
                      if (!_isRepairMode)
                        StaggeredEntrance(
                          index: 2,
                          identity: _sectionIdentity,
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: cs.outlineVariant.withValues(alpha: .5),
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        l.schedules_active,
                                        style: text.titleSmall,
                                      ),
                                      Text(
                                        l.schedules_activeSubtitle,
                                        style: text.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                Switch(
                                  value: _isActive,
                                  onChanged: (v) =>
                                      setState(() => _isActive = v),
                                ),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(height: 32),

                      if (_submissionError != null) ...[
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            reviewFailureMessage(l, _submissionError!),
                            style: text.bodyMedium?.copyWith(color: cs.error),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      // ── Submit ────────────────────────────────────────────────
                      FilledButton(
                        onPressed:
                            _isSaving || (_isLegacyPrnRecovery && !_isActive)
                            ? null
                            : _submit,
                        child: _isSaving
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(l.shared_save),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _timeCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    return Semantics(
      label: l.schedules_timeSemantic(clockTime(context, _time)),
      button: true,
      child: Pressable(
        radius: BorderRadius.circular(18),
        child: Material(
          color: cs.surface,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('schedule-time-card'),
            onTap: _pickTime,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                  child: DoseDial(
                    key: const ValueKey('schedule-dial'),
                    times: [_time],
                    onChanged: _isSaving
                        ? null
                        : (_, time) => setState(() => _time = time),
                    trailing: ExcludeSemantics(
                      child: Icon(
                        Icons.edit_outlined,
                        size: 18,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _repairFrequencyLabel(AppLocalizations l) {
    if (_isPrn) return l.t08_asNeeded;
    if (_isDaily) return l.schedules_daily;
    final days = _selectedDays.toList()..sort();
    final labels = _dayLabels(l);
    final dayLabel = days.isEmpty || days.any((day) => day < 1 || day > 7)
        ? l.shared_unknown
        : days.map((day) => labels[day - 1]).join(', ');
    return '${l.schedules_specificDays} · $dayLabel';
  }

  Future<void> _pickEffectiveDate() async {
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate:
          _effectiveFromLocalDate.isBefore(
            DateTime(today.year, today.month, today.day),
          )
          ? DateTime(today.year, today.month, today.day)
          : _effectiveFromLocalDate,
      firstDate: DateTime(today.year, today.month, today.day),
      lastDate: DateTime(today.year + 10, 12, 31),
    );
    if (picked != null) setState(() => _effectiveFromLocalDate = picked);
  }

  String _dateLabel(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  String _errorMessage(AppLocalizations l, AppError error) => switch (error) {
    NetworkError() => l.error_noConnection,
    NotFoundError() => l.error_pillNotFound,
    ServerError(:final statusCode) => l.error_serverError(statusCode),
    _ => l.shared_somethingWentWrong,
  };
}

// ── Day picker ────────────────────────────────────────────────────────────────

class _DayPicker extends StatelessWidget {
  const _DayPicker({required this.selected, required this.onToggle});

  final Set<int> selected;
  final ValueChanged<int> onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labels = _dayLabels(AppLocalizations.of(context));

    return Row(
      children: [
        for (var i = 0; i < _kDayIsos.length; i++)
          Expanded(
            child: Builder(
              builder: (context) {
                final iso = _kDayIsos[i];
                final label = labels[i];
                final isOn = selected.contains(iso);
                return Semantics(
                  label: label,
                  button: true,
                  selected: isOn,
                  onTap: () => onToggle(iso),
                  excludeSemantics: true,
                  child: Pressable(
                    radius: BorderRadius.circular(24),
                    onTap: () => onToggle(iso),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: AnimatedContainer(
                          duration: AppMotion.duration(
                            context,
                            milliseconds: 160,
                          ),
                          curve: AppMotion.curve,
                          constraints: const BoxConstraints(minHeight: 40),
                          decoration: BoxDecoration(
                            color: isOn
                                ? cs.primary
                                : cs.surfaceContainerHighest,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          padding: const EdgeInsets.all(4),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: isOn
                                    ? cs.onPrimary
                                    : cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
