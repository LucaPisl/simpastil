import 'package:flutter/material.dart';

import '../../../core/medication/medication_amount.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/format/clock.dart';
import '../../../shared/motion/app_motion.dart';
import '../../pills/presentation/medication_identity.dart';
import '../care_record_form.dart' show careAmountLabel;
import 'as_needed_controller.dart';
import 'as_needed_option.dart';

/// Opens the one-step dose editor for [option]. Resolves true once a dose was
/// saved; the card then shows its success moment back on Today.
Future<bool?> openAsNeededDoseEditor(
  BuildContext context, {
  required AsNeededOption option,
  required AsNeededController controller,
}) => Navigator.of(context).push<bool>(
  MaterialPageRoute<bool>(
    builder: (_) => AsNeededDoseEditor(option: option, controller: controller),
  ),
);

enum _When { now, m15, h1, h3, pick, unknown }

/// Amount, time and an optional note for one as-needed dose, saved in a single
/// step. Nothing is prepared until Save, and Save prepares and commits the
/// dose through the same path as holding the card.
class AsNeededDoseEditor extends StatefulWidget {
  const AsNeededDoseEditor({
    super.key,
    required this.option,
    required this.controller,
  });
  final AsNeededOption option;
  final AsNeededController controller;

  @override
  State<AsNeededDoseEditor> createState() => _AsNeededDoseEditorState();
}

class _AsNeededDoseEditorState extends State<AsNeededDoseEditor> {
  final _note = TextEditingController();
  final _quantity = TextEditingController();
  final _unit = TextEditingController();
  late MedicationAmount _amount = widget.option.usualAmount;
  bool _amountUnsure = false;
  late _When _when = _today ? _When.now : _When.unknown;
  DateTime? _picked;
  bool _saving = false;
  String? _error;

  bool get _today => widget.controller.viewingToday;

  /// The viewed day, for picking a time on a day that has passed.
  DateTime get _viewedDay {
    final d = parseRoutineDate(widget.controller.localDate());
    return DateTime(d.year, d.month, d.day);
  }

  @override
  void initState() {
    super.initState();
    if (widget.option.usualAmount.isUnknown) {
      _quantity.addListener(_syncTyped);
      _unit.addListener(_syncTyped);
    }
  }

  @override
  void dispose() {
    _note.dispose();
    _quantity.dispose();
    _unit.dispose();
    super.dispose();
  }

  void _syncTyped() {
    MedicationAmount next;
    try {
      next = _quantity.text.trim().isEmpty && _unit.text.trim().isEmpty
          ? const MedicationAmount.unknown()
          : MedicationAmount.known(_quantity.text, _unit.text);
      _error = null;
    } on FormatException {
      next = const MedicationAmount.unknown();
      _error = AppLocalizations.of(context).t08_invalidAmount;
    }
    setState(() => _amount = next);
  }

  double? get _number {
    if (_amount.isUnknown) return null;
    return _amount.numerator!.toDouble() / _amount.denominator!.toDouble();
  }

  double get _step {
    final usual = widget.option.usualAmount;
    if (usual.isUnknown) return 1;
    final v = usual.numerator!.toDouble() / usual.denominator!.toDouble();
    return v < 1 ? v : 1;
  }

  String _format(double v) {
    final text = v == v.roundToDouble()
        ? v.round().toString()
        : v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
    return text;
  }

  void _bump(int direction) {
    final unit = widget.option.usualAmount.unit;
    final current = _number;
    if (unit == null || current == null) return;
    final next = current + direction * _step;
    if (next <= 0) return;
    setState(() {
      _amount = MedicationAmount.known(_format(next), unit);
      _amountUnsure = false;
    });
  }

  Duration? _offset(_When w) => switch (w) {
    _When.m15 => const Duration(minutes: 15),
    _When.h1 => const Duration(hours: 1),
    _When.h3 => const Duration(hours: 3),
    _ => null,
  };

  /// The time the dose would be recorded at, or null when it is not known.
  DateTime? _time(DateTime now) {
    if (_when == _When.unknown) return null;
    if (_when == _When.pick) return _picked;
    if (_when == _When.now) return now;
    return now.subtract(_offset(_when)!);
  }

  /// A chip that reaches back across midnight stays out of reach: a dose is
  /// recorded on the day being viewed.
  bool _reachable(_When w, DateTime now) {
    final offset = _offset(w);
    if (offset == null) return true;
    final at = now.subtract(offset);
    return at.year == now.year && at.month == now.month && at.day == now.day;
  }

  Future<void> _pick() async {
    final now = DateTime.now();
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_today ? now : _viewedDay),
    );
    if (picked == null || !mounted) return;
    final day = _today ? DateTime(now.year, now.month, now.day) : _viewedDay;
    final at = DateTime(
      day.year,
      day.month,
      day.day,
      picked.hour,
      picked.minute,
    );
    if (_today && at.isAfter(now)) {
      setState(() => _error = AppLocalizations.of(context).t10_timeInvalid);
      return;
    }
    setState(() {
      _picked = at;
      _when = _When.pick;
      _error = null;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final l = AppLocalizations.of(context);
    final now = DateTime.now();
    if (_when == _When.pick && _picked == null) return;
    final amount = _amountUnsure ? const MedicationAmount.unknown() : _amount;
    setState(() {
      _saving = true;
      _error = null;
    });
    final pillId = widget.option.pillId;
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();
    final ok = await widget.controller.record(
      widget.option,
      amount: amount,
      at: _time(now),
      note: note,
      reveal: false,
      fresh: true,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      widget.controller.reveal(
        pillId,
        delay: AppMotion.quiet(context) ? Duration.zero : AppMotion.standard,
      );
      return;
    }
    final saveFailed = widget.controller.runOf(pillId).saveFailed;
    widget.controller.clearError(pillId);
    setState(() {
      _saving = false;
      _error = saveFailed ? l.t08_saveError : l.t08_recordError;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final option = widget.option;
    final now = DateTime.now();
    final tint = medicationTint(id: option.pill.id, color: option.pill.color);
    final at = _time(now);
    final amount = _amountUnsure ? const MedicationAmount.unknown() : _amount;
    final amountText = careAmountLabel(l, amount);
    final saveLabel = at == null
        ? l.asn_saveNoTime(amountText)
        : l.asn_save(amountText, clockAt(context, at));
    final canSave =
        !_saving && !(_when == _When.pick && _picked == null) && !_typedInvalid;

    final whenChips = <(_When, String)>[
      if (_today) (_When.now, l.asn_whenNow),
      if (_today) (_When.m15, l.asn_when15),
      if (_today) (_When.h1, l.asn_when1h),
      if (_today) (_When.h3, l.asn_when3h),
      (
        _When.pick,
        _when == _When.pick && _picked != null
            ? clockAt(context, _picked!)
            : l.asn_whenPick,
      ),
      (_When.unknown, l.asn_whenUnknown),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(l.asn_editorTitle)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                children: [
                  Row(
                    children: [
                      MedicationMark(
                        color: tint,
                        shape: option.shape,
                        size: 44,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l.t08_forPerson(option.person.name),
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            Text(
                              option.pill.name,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _Label(l.asn_amountLabel),
                  const SizedBox(height: 8),
                  if (option.usualAmount.isUnknown)
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('as-needed-quantity'),
                            controller: _quantity,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              labelText: l.t08_amount,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            key: const ValueKey('as-needed-unit'),
                            controller: _unit,
                            decoration: InputDecoration(labelText: l.t08_unit),
                          ),
                        ),
                      ],
                    )
                  else
                    _Stepper(
                      label: _amountUnsure ? l.t08_unknown : amountText,
                      enabled: !_amountUnsure,
                      onMinus: () => _bump(-1),
                      onPlus: () => _bump(1),
                    ),
                  const SizedBox(height: 8),
                  FilterChip(
                    key: const ValueKey('as-needed-amount-unsure'),
                    label: Text(l.asn_amountNotSure),
                    selected: _amountUnsure,
                    onSelected: (v) => setState(() => _amountUnsure = v),
                  ),
                  const SizedBox(height: 24),
                  _Label(l.asn_whenLabel),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final (w, text) in whenChips)
                        ChoiceChip(
                          key: ValueKey('as-needed-when-${w.name}'),
                          label: Text(text),
                          selected: _when == w,
                          onSelected: _reachable(w, now)
                              ? (_) {
                                  if (w == _When.pick) {
                                    _pick();
                                  } else {
                                    setState(() {
                                      _when = w;
                                      _error = null;
                                    });
                                  }
                                }
                              : null,
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    key: const ValueKey('as-needed-note'),
                    controller: _note,
                    maxLength: 500,
                    maxLines: null,
                    decoration: InputDecoration(
                      labelText: l.t10_notes,
                      counterText: '',
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.error,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('as-needed-save'),
                  onPressed: canSave ? _save : null,
                  child: Text(_saving ? l.t08_saving : saveLabel),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool get _typedInvalid =>
      widget.option.usualAmount.isUnknown &&
      !_amountUnsure &&
      (_quantity.text.trim().isNotEmpty != _unit.text.trim().isNotEmpty ||
          _amount.isUnknown &&
              (_quantity.text.trim().isNotEmpty ||
                  _unit.text.trim().isNotEmpty));
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.labelLarge?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w700,
    ),
  );
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.enabled,
    required this.onMinus,
    required this.onPlus,
  });
  final String label;
  final bool enabled;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .6),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('as-needed-amount-minus'),
            tooltip: l.asn_amountDecrease,
            onPressed: enabled ? onMinus : null,
            icon: const Icon(Icons.remove_rounded),
          ),
          Expanded(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('as-needed-amount-plus'),
            tooltip: l.asn_amountIncrease,
            onPressed: enabled ? onPlus : null,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
    );
  }
}
