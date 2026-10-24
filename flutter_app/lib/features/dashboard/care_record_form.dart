import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../settings/presentation/settings_screen.dart';
import '../settings/presentation/settings_overview.dart';

import '../../core/medication/care_recording.dart';
import '../../core/medication/reviewed_stock.dart' show CareStockOutcome;
import '../../core/medication/care_sharing_provider.dart';
import '../../core/medication/medication_amount.dart';
import '../../core/medication/medication_amount_label.dart';
import '../../core/medication/medication_command.dart';
import '../../core/medication/routine_definition.dart';
import '../../core/medication/unit_names.dart';
import '../../core/workspace/workspace_context.dart';
import '../../core/workspace/workspace_provider.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/layouts/window_size.dart';
import '../../shared/widgets/care_state.dart';
import '../../shared/motion/app_motion.dart';
import '../../shared/widgets/durable_save_feedback.dart';
import '../../shared/widgets/sync_thread.dart';
import '../../shared/format/clock.dart';

bool sameCareContext(WorkspaceContext a, WorkspaceContext b) =>
    a.workspaceId == b.workspaceId &&
    a.ownerUserId == b.ownerUserId &&
    a.authorId == b.authorId &&
    a.kind == b.kind &&
    a.accessEpoch == b.accessEpoch &&
    a.endpoint == b.endpoint &&
    a.sessionGeneration == b.sessionGeneration &&
    a.networkEpoch == b.networkEpoch;

bool careServiceIsCurrent(WidgetRef ref, CareRecordingService service) {
  final state = ref.read(workspaceContextProvider);
  return !state.isLoading &&
      !state.hasError &&
      state.asData != null &&
      sameCareContext(state.requireValue, service.context);
}

String careAmountLabel(AppLocalizations l, MedicationAmount amount) =>
    amount.isUnknown
    ? l.t08_unknown
    : formatMedicationAmount(amount, languageCode: l.localeName);

/// A recorded outcome in words. [late] marks a dose taken after it had been
/// recorded as missed.
String careOutcomeLabel(
  AppLocalizations l,
  String state, {
  bool late = false,
}) => switch (state) {
  'taken' => late ? l.dose_takenLate : l.t08_taken,
  'skipped' => l.t08_skipped,
  'missed' => l.dashboard_statusMissed,
  _ => l.t08_unrecorded,
};
String careSharingLabel(AppLocalizations l, CareSharingOutcome sharing) =>
    switch (sharing) {
      CareSharingOutcome.reconciled => l.t10_sharingReconciled,
      CareSharingOutcome.localOnly => l.t10_savedLocal,
      CareSharingOutcome.pending => l.t10_sharingPending,
      CareSharingOutcome.acknowledged => l.t10_sharingAccepted,
      CareSharingOutcome.needsReview => l.t10_sharingReview,
      CareSharingOutcome.uncertain => l.t10_sharingUncertain,
    };
String careInstantLabel(BuildContext context, DateTime? time) => time == null
    ? AppLocalizations.of(context).t08_unknownTime
    : clockDateTime(context, time.toLocal());

class CareRecordValues {
  const CareRecordValues({
    required this.amount,
    required this.actualAt,
    required this.actualTimeKnown,
    required this.state,
    this.note,
  });
  final MedicationAmount amount;
  final DateTime? actualAt;
  final bool actualTimeKnown;
  final MedicationState state;
  final String? note;
}

enum _TimeChoice { now, chosen, unknown }

/// This form prepares once at review and keeps that exact intent on retry.
class CareRecordForm extends ConsumerStatefulWidget {
  const CareRecordForm({
    super.key,
    required this.service,
    required this.personName,
    required this.medicationName,
    required this.localDate,
    required this.amount,
    required this.prepare,
    this.initialState = MedicationState.taken,
    this.correction = false,
    this.allowSkip = true,
    this.initialActualAt,
    this.initialNote,
  });
  final CareRecordingService service;
  final String personName, medicationName, localDate;
  final MedicationAmount amount;
  final MedicationState initialState;
  final bool correction, allowSkip;
  final DateTime? initialActualAt;
  final String? initialNote;
  final Future<PreparedCareIntent> Function(CareRecordValues values) prepare;
  @override
  ConsumerState<CareRecordForm> createState() => _CareRecordFormState();
}

class _CareRecordFormState extends ConsumerState<CareRecordForm> {
  final _quantity = TextEditingController();
  final _unit = TextEditingController();
  final _note = TextEditingController();
  late bool _unknownAmount;
  late MedicationState _state;
  late _TimeChoice _time;
  DateTime? _chosen;
  PreparedCareIntent? _intent;
  PreparedCareIntent? _undo;
  CareRecordingReceipt? _receipt;
  bool _busy = false, _attempted = false;
  String? _error;
  bool _unitLocalized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_unitLocalized) {
      _unitLocalized = true;
      _unit.text = unitFieldText(
        AppLocalizations.of(context),
        widget.amount.unit,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _unknownAmount = widget.amount.isUnknown;
    _quantity.text = widget.amount.quantityText ?? '';
    _state = widget.initialState;
    _note.text = widget.initialNote ?? '';
    _chosen = widget.initialActualAt?.toLocal();
    _time = widget.correction
        ? (_chosen == null ? _TimeChoice.unknown : _TimeChoice.chosen)
        : widget.localDate == routineDateKey(DateTime.now())
        ? _TimeChoice.now
        : _TimeChoice.unknown;
  }

  @override
  void dispose() {
    _quantity.dispose();
    _unit.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _chooseTime() async {
    final now = DateTime.now();
    final initial = _chosen ?? parseRoutineDate(widget.localDate);
    final date = await showDatePicker(
      context: context,
      initialDate: initial.isAfter(now)
          ? now
          : initial.isBefore(DateTime(1900))
          ? DateTime(1900)
          : initial,
      firstDate: DateTime(1900),
      lastDate: now,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_chosen ?? now),
    );
    if (time == null || !mounted) return;
    final chosen = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (chosen.hour != time.hour ||
        chosen.minute != time.minute ||
        chosen.isAfter(DateTime.now())) {
      setState(() => _error = AppLocalizations.of(context).t10_timeInvalid);
      return;
    }
    setState(() {
      _chosen = chosen;
      _time = _TimeChoice.chosen;
      _error = null;
    });
  }

  Future<void> _review() async {
    if (_busy || !careServiceIsCurrent(ref, widget.service)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final amount = _state == MedicationState.skipped || _unknownAmount
          ? const MedicationAmount.unknown()
          : MedicationAmount.known(
              _quantity.text,
              unitFromFieldText(
                AppLocalizations.of(context),
                _unit.text,
                widget.amount.unit,
              ),
            );
      final actual = _state == MedicationState.skipped
          ? null
          : switch (_time) {
              _TimeChoice.now => DateTime.now().toUtc(),
              _TimeChoice.chosen => _chosen?.toUtc(),
              _TimeChoice.unknown => null,
            };
      if (_state == MedicationState.taken &&
          _time == _TimeChoice.chosen &&
          actual == null) {
        throw const FormatException('Choose a time');
      }
      final intent = await widget.prepare(
        CareRecordValues(
          amount: amount,
          actualAt: actual,
          actualTimeKnown: actual != null,
          state: _state,
          note: _note.text.trim().isEmpty ? null : _note.text.trim(),
        ),
      );
      if (!mounted || !careServiceIsCurrent(ref, widget.service)) return;
      setState(() => _intent = intent);
    } on Object {
      if (mounted && careServiceIsCurrent(ref, widget.service)) {
        setState(() => _error = AppLocalizations.of(context).t08_recordError);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save({bool undo = false}) async {
    if (_busy || !careServiceIsCurrent(ref, widget.service)) return;
    setState(() {
      _busy = true;
      _attempted = true;
      _error = null;
    });
    try {
      if (undo) _undo ??= await widget.service.prepareUndo(_receipt!);
      final receipt = await widget.service.commit(undo ? _undo! : _intent!);
      await widget.service.access.requireCurrent(widget.service.context);
      if (!mounted || !careServiceIsCurrent(ref, widget.service)) return;
      setState(() => _receipt = receipt);
    } on Object {
      if (mounted && careServiceIsCurrent(ref, widget.service)) {
        setState(() => _error = AppLocalizations.of(context).t10_recordError);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    ref.watch(workspaceContextProvider);
    if (!careServiceIsCurrent(ref, widget.service)) {
      return Scaffold(
        appBar: AppBar(),
        body: CareState(title: l.t08_unavailable, body: l.t08_unavailableBody),
      );
    }
    final text = Theme.of(context).textTheme;
    final intent = _intent;
    final receipt = _receipt;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.correction ? l.t10_correct : l.t10_recordDose),
      ),
      body: SafeArea(
        child: CareTransition(
          child: ContentListView(
            key: ValueKey(
              intent == null
                  ? 'edit'
                  : receipt == null
                  ? 'review'
                  : 'saved/${receipt.event.id}',
            ),
            padding: const EdgeInsets.all(24),
            children: [
              Text(l.t08_forPerson(widget.personName), style: text.titleMedium),
              const SizedBox(height: 12),
              Text(widget.medicationName, style: text.headlineMedium),
              const SizedBox(height: 24),
              if (receipt != null) ...[
                Text(
                  careOutcomeLabel(l, receipt.current.state),
                  style: text.headlineSmall,
                ),
                const SizedBox(height: 16),
                DurableSaveFeedback(
                  label: careSharingLabel(l, receipt.sharing),
                ),
                if (receipt.event.action == 'undo' &&
                    receipt.stock == CareStockOutcome.unchanged) ...[
                  const SizedBox(height: 12),
                  Text(
                    l.t08_undoStockUnchanged,
                    key: const ValueKey('undo-stock-unchanged'),
                    style: text.bodyMedium,
                  ),
                ],
                const SizedBox(height: 20),
                if (receipt.event.action != 'undo')
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _save(undo: true),
                    icon: const Icon(Icons.undo),
                    label: Text(l.t08_undo),
                  ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).pop(receipt),
                  child: Text(l.t10_done),
                ),
              ] else if (intent != null) ...[
                Text(l.t10_reviewRecord, style: text.titleLarge),
                const SizedBox(height: 16),
                CareFactLine(
                  label: l.t10_outcome,
                  value: careOutcomeLabel(l, _state.name),
                ),
                if (_state == MedicationState.taken) ...[
                  CareFactLine(
                    label: l.t10_recordedAmount,
                    value: careAmountLabel(l, intent.amount),
                  ),
                  CareFactLine(
                    label: l.t10_actual,
                    value: careInstantLabel(context, intent.actualAt),
                  ),
                  if (intent.actualTimeKnown)
                    Text(l.t10_timeHere, style: text.bodySmall),
                ],
                if (intent.note != null)
                  CareFactLine(label: l.t10_notes, value: intent.note!),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: Text(
                    _busy
                        ? l.t08_saving
                        : _attempted
                        ? l.shared_retry
                        : l.t10_saveRecord,
                  ),
                ),
                if (!_attempted)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _intent = null),
                    child: Text(l.t10_edit),
                  ),
              ] else ...[
                if (widget.allowSkip)
                  DropdownButtonFormField<MedicationState>(
                    initialValue: _state,
                    decoration: InputDecoration(labelText: l.t10_outcome),
                    items: [
                      for (final state in [
                        MedicationState.taken,
                        MedicationState.skipped,
                      ])
                        DropdownMenuItem(
                          value: state,
                          child: Text(careOutcomeLabel(l, state.name)),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _state = v!),
                  ),
                if (_state == MedicationState.taken) ...[
                  const SizedBox(height: 20),
                  Text(l.t10_actual, style: text.titleMedium),
                  RadioGroup<_TimeChoice>(
                    groupValue: _time,
                    onChanged: (v) {
                      if (!_busy) setState(() => _time = v!);
                    },
                    child: Column(
                      children: [
                        for (final choice in _TimeChoice.values)
                          RadioListTile<_TimeChoice>(
                            contentPadding: EdgeInsets.zero,
                            value: choice,
                            enabled: !_busy,
                            title: Text(switch (choice) {
                              _TimeChoice.now => l.t08_takenNow,
                              _TimeChoice.chosen => l.t10_chooseTime,
                              _TimeChoice.unknown => l.t08_unknownTime,
                            }),
                          ),
                      ],
                    ),
                  ),
                  if (_time == _TimeChoice.chosen) ...[
                    Text(l.t10_timeHere),
                    OutlinedButton(
                      onPressed: _busy ? null : _chooseTime,
                      child: Text(
                        _chosen == null
                            ? l.t10_chooseTime
                            : careInstantLabel(context, _chosen),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l.t08_unknown),
                    value: _unknownAmount,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _unknownAmount = v),
                  ),
                  if (!_unknownAmount) ...[
                    TextField(
                      controller: _quantity,
                      enabled: !_busy,
                      keyboardType: TextInputType.text,
                      decoration: InputDecoration(labelText: l.t08_amount),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _unit,
                      enabled: !_busy,
                      decoration: InputDecoration(labelText: l.t08_unit),
                    ),
                  ],
                ],
                const SizedBox(height: 20),
                TextField(
                  controller: _note,
                  enabled: !_busy,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(labelText: l.t10_notes),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _review,
                  child: Text(_busy ? l.shared_loading : l.t10_reviewRecord),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class CareFactLine extends StatelessWidget {
  const CareFactLine({super.key, required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(value, style: Theme.of(context).textTheme.bodyLarge),
      ],
    ),
  );
}

/// Sharing freshness is workspace-scoped evidence, never a connectivity guess.
class CareSharingSummary extends ConsumerWidget {
  const CareSharingSummary({super.key, this.detailed = false, this.refreshing});
  final bool detailed;

  /// True while the screen's own pull to refresh runs, so the compact thread
  /// shows that sync even when nothing was waiting.
  final ValueListenable<bool>? refreshing;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    if (!detailed) {
      return SyncThreadSummary(
        refreshing: refreshing,
        onOpen: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const SettingsScreen(section: SettingsSection.data),
          ),
        ),
      );
    }
    final state = ref.watch(careSharingStatusProvider);
    if (state.isLoading) return const SizedBox.shrink();
    final status = state.asData?.value;
    if (status?.isLocalOnly == true) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            status?.lastCarePullAt == null
                ? l.t10_freshnessUnknown
                : l.t10_sharedUpdated(
                    careInstantLabel(context, status!.lastCarePullAt),
                  ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (status != null &&
              status.pendingCount +
                      status.needsReviewCount +
                      status.uncertainCount >
                  0)
            Text(
              l.t10_sharingCounts(
                status.pendingCount,
                status.needsReviewCount,
                status.uncertainCount,
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}
