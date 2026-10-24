import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/medication/medication_amount.dart';
import '../../../core/medication/medication_extras.dart';
import '../../../core/medication/medication_detail_repository.dart';
import '../../../core/medication/medication_detail_provider.dart';
import '../../../core/medication/unit_names.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/widgets/care_state.dart';
import '../../setup/setup_state.dart';
import '../medication_look_provider.dart';
import '../medication_photo_repository.dart';
import 'medication_photo_field.dart';
import 'medication_edit_preview.dart';
import 'medication_extras_fields.dart';
import 'medication_detail_sections.dart' show hasOriginalDosageText;
import 'medication_form_kit.dart';
import 'medication_identity.dart';

/// Opens the edit form of [detail]: a sheet from the bottom on a phone or a
/// medium window, a wide dialog with a live preview beside the fields on an
/// expanded one. With [focusStock] it opens only the stock count instead (a
/// small sheet or dialog, so the keyboard leaves room), which saves through
/// the same form and repository.
Future<MedicationDetailSave?> showMedicationReview(
  BuildContext context,
  MedicationCareDetail detail,
  MedicationDetailRepository repository, {
  bool focusStock = false,
}) {
  final stockOnly = focusStock && repository.context.isLocal;
  Widget form({bool wide = false}) => _MedicationEdit(
    detail: detail,
    repository: repository,
    focusStock: focusStock,
    stockOnly: stockOnly,
    wide: wide,
  );
  if (WindowClass.of(context).isExpanded) {
    return showDialog<MedicationDetailSave>(
      context: context,
      builder: (dialog) {
        final size = MediaQuery.sizeOf(dialog);
        return Dialog(
          insetPadding: const EdgeInsets.all(24),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          child: stockOnly
              ? ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: form(wide: true),
                )
              : SizedBox(
                  width: math.min(1080, size.width - 48),
                  height: math.min(720, size.height - 48),
                  child: form(wide: true),
                ),
        );
      },
    );
  }
  return showModalBottomSheet<MedicationDetailSave>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Above the shell's navigation bar, like every other sheet.
    useRootNavigator: true,
    showDragHandle: true,
    builder: (_) => form(),
  );
}

class _MedicationEdit extends ConsumerStatefulWidget {
  const _MedicationEdit({
    required this.detail,
    required this.repository,
    this.focusStock = false,
    this.stockOnly = false,
    this.wide = false,
  });
  final MedicationCareDetail detail;
  final MedicationDetailRepository repository;

  /// Start with the cursor in the stock count.
  final bool focusStock;

  /// Show only the stock count, in a small dialog that keeps clear of the
  /// keyboard. Everything else keeps the values it was opened with, so the
  /// save is the same one the full form makes.
  final bool stockOnly;

  /// The expanded layout: fields in two columns, the preview beside them.
  final bool wide;
  @override
  ConsumerState<_MedicationEdit> createState() => _MedicationEditState();
}

class _MedicationEditState extends ConsumerState<_MedicationEdit> {
  late final TextEditingController _name,
      _strength,
      _form,
      _notes,
      _quantity,
      _unit,
      _stock;
  late bool _unknown;
  late final MedicationExtrasEditor _extras;

  /// The medication as last read: what Save checks the stored care against.
  /// It follows the stored care after a conflict, so a second Save compares
  /// with what the first one found; the typed choices are never replaced.
  late MedicationCareDetail _expected = widget.detail;

  /// Whether a person has dealt with the original dosage wording. The wording
  /// itself is never rewritten, so only this flag can retire the reminder.
  late bool _reviewed;
  late String? _color;

  /// The shape picked in this form; null until the person picks one.
  MedicationShape? _shape;
  final Object _identity = Object();
  final _stockFocus = FocusNode();
  bool _busy = false;
  String? _error;
  MedicationPhotoDraft _photo = const MedicationPhotoDraft();
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _extras.applyLocale(Localizations.localeOf(context).toString());
    if (!_unitLocalized) {
      _unitLocalized = true;
      // The field shows the unit in the app's language; the
      // stored one is written back unless the person edits it.
      _unit.text = unitFieldText(
        AppLocalizations.of(context),
        widget.detail.review.amount.unit,
      );
    }
  }

  bool _unitLocalized = false;

  String _unitToStore() => unitFromFieldText(
    AppLocalizations.of(context),
    _unit.text,
    widget.detail.review.amount.unit,
  );

  @override
  void initState() {
    super.initState();
    final r = widget.detail.review;
    _name = TextEditingController(text: r.name);
    _strength = TextEditingController(text: r.packageStrength);
    _form = TextEditingController(text: r.form);
    _notes = TextEditingController(text: r.notes);
    _quantity = TextEditingController(text: r.amount.quantityText);
    _unit = TextEditingController(text: r.amount.unit);
    _unknown = r.amount.isUnknown;
    _reviewed = r.legacyDosageReviewed;
    _color = widget.detail.pill.color;
    _extras = MedicationExtrasEditor(
      MedicationExtras.fromPill(widget.detail.pill),
    )..addListener(_extrasChanged);
    // The same count every screen shows: the balance doses lower, when there
    // is one.
    _stock = TextEditingController(text: widget.detail.stock?.text ?? '');
    if (widget.focusStock && widget.repository.context.isLocal) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _stockFocus.requestFocus();
      });
    }
  }

  void _extrasChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _extras
      ..removeListener(_extrasChanged)
      ..dispose();
    for (final c in [
      _name,
      _strength,
      _form,
      _notes,
      _quantity,
      _unit,
      _stock,
    ]) {
      c.dispose();
    }
    _stockFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final repository = widget.repository;
    bool owns() =>
        mounted &&
        identical(
          ref.read(medicationDetailRepositoryProvider).asData?.value,
          repository,
        );
    String? optional(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    final stockText = _stock.text.trim();
    // A part-dose balance (7.5 after half tablets) left as it was is not a
    // new count: it is kept, not rounded.
    final keptFraction =
        stockText == _expected.stock?.text &&
        _expected.stock!.value != _expected.stock!.whole;
    final stock = stockText.isEmpty || keptFraction
        ? null
        : int.tryParse(stockText);
    if (stockText.isNotEmpty && !keptFraction && stock == null) {
      setState(() {
        _busy = false;
        _error = AppLocalizations.of(context).mf_numberNeeded;
      });
      return;
    }
    final l = AppLocalizations.of(context);
    if (!widget.stockOnly && !_extras.isValid(l)) {
      setState(() {
        _busy = false;
        _error = l.mx_checkFields;
      });
      return;
    }
    try {
      if (!widget.stockOnly && _photo.changed) {
        // Local and idempotent, so a save that then conflicts can be repeated.
        final photos = ref.read(medicationPhotoRepositoryProvider);
        final staged = _photo.staged;
        if (staged != null) {
          await photos.save(_expected.pill.id, staged);
        } else {
          await photos.remove(_expected.pill.id);
        }
      }
      final prior = _expected.review;
      final saved = await repository.updateReviewed(
        expected: _expected,
        review: MedicationReview(
          name: _name.text.trim(),
          packageStrength: optional(_strength),
          form: optional(_form),
          notes: optional(_notes),
          amount: _unknown
              ? const MedicationAmount.unknown()
              : MedicationAmount.known(_quantity.text.trim(), _unitToStore()),
          originalDosage: prior.originalDosage,
          legacyDosageReviewed: _reviewed,
        ),
        currentStock: stock,
        color: widget.repository.context.isLocal ? _color : null,
        shape: widget.repository.context.isLocal ? _shape?.wire : null,
        extras: widget.stockOnly ? null : _extras.read(),
      );
      if (mounted && owns()) Navigator.of(context).pop(saved);
    } on MedicationDetailConflict {
      // Pick up the care as it is now, so the next Save is checked against it.
      MedicationCareDetail? latest;
      try {
        latest = await repository.load(_expected.pill.id);
      } on Object {
        latest = null;
      }
      if (owns()) {
        setState(() {
          if (latest != null) _expected = latest;
          _error = AppLocalizations.of(context).t09_reviewConflict;
        });
      }
    } on Object {
      if (owns()) {
        setState(() => _error = AppLocalizations.of(context).t08_saveError);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _dosageText() {
    if (_unknown) return null;
    final quantity = _quantity.text.trim(), unit = _unit.text.trim();
    return quantity.isEmpty || unit.isEmpty ? null : '$quantity $unit';
  }

  Widget _preview(Color tint, {required bool local}) => MedicationEditPreview(
    listenable: Listenable.merge([_name, _form, _quantity, _unit, _stock]),
    detail: widget.detail,
    local: local,
    name: () => _name.text,
    form: () => _form.text,
    shape: _currentShape,
    imprint: _imprint,
    dosage: _dosageText,
    stock: () => _stock.text,
    tint: tint,
  );

  Widget _what(AppLocalizations l, int index) => FormSection(
    index: index,
    identity: _identity,
    icon: Icons.medication_outlined,
    title: l.mf_sectionWhat,
    children: [
      TextField(
        key: const ValueKey('edit-medication-name'),
        controller: _name,
        enabled: !_busy,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: l.t08_medicationName),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _strength,
        enabled: !_busy,
        decoration: InputDecoration(labelText: l.t08_strength),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _form,
        enabled: !_busy,
        decoration: InputDecoration(labelText: l.t09_form),
      ),
    ],
  );

  Widget _dose(AppLocalizations l, int index) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return FormSection(
      index: index,
      identity: _identity,
      icon: Icons.straighten_rounded,
      title: l.mf_sectionDose,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(l.t08_unknown),
          value: _unknown,
          onChanged: _busy ? null : (v) => setState(() => _unknown = v),
        ),
        AnimatedSize(
          duration: AppMotion.duration(context),
          curve: AppMotion.curve,
          alignment: Alignment.topCenter,
          child: _unknown
              ? const SizedBox(width: double.infinity)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 4),
                    TextField(
                      key: const ValueKey('edit-medication-quantity'),
                      controller: _quantity,
                      enabled: !_busy,
                      decoration: InputDecoration(
                        labelText: l.t08_quantity,
                        hintText: l.t08_quantityHint,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('edit-medication-unit'),
                      controller: _unit,
                      enabled: !_busy,
                      decoration: InputDecoration(labelText: l.t08_unit),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        Text(
          l.t08_amountHelp,
          style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Text(
          l.t09_medicationAmountHelp,
          style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _look(AppLocalizations l, int index, Color tint) => FormSection(
    index: index,
    identity: _identity,
    icon: Icons.palette_outlined,
    title: l.mf_sectionLook,
    hint: l.mf_sectionLookHint,
    children: [
      TintPicker(
        selected: _color,
        enabled: !_busy,
        onSelected: (hex) => setState(() => _color = hex),
      ),
      const SizedBox(height: 16),
      _shapePicker(tint),
    ],
  );

  /// The shape now in force: the picked one, else the one the medication is
  /// drawn with (its stored shape, or the one its form implies).
  MedicationShape _currentShape() =>
      _shape ?? effectiveMedicationShape(widget.detail.pill.shape, _form.text);

  List<({String name, MedicationShape shape})> _others() {
    final pill = widget.detail.pill;
    return ref.watch(
      personMedicationsProvider((
        personId: pill.profileId,
        exceptPillId: pill.id,
      )),
    );
  }

  String _imprint() =>
      imprintAmong(name: _name.text, shape: _currentShape(), others: _others());

  Widget _shapePicker(Color tint) {
    final shape = _currentShape();
    final others = _others();
    final name = _name.text;
    return ShapePicker(
      selected: shape,
      tint: tint,
      imprint: _imprint(),
      enabled: !_busy,
      collisionName: collidingMedicationName(
        name: name,
        shape: shape,
        others: others,
      ),
      onSelected: (value) => setState(() => _shape = value),
    );
  }

  Widget _supply(AppLocalizations l, int index, Color tint) => FormSection(
    index: index,
    identity: _identity,
    icon: Icons.inventory_2_outlined,
    title: l.mf_sectionSupply,
    children: [
      StockStepper(
        fieldKey: const ValueKey('edit-medication-stock'),
        focusNode: _stockFocus,
        controller: _stock,
        enabled: !_busy,
        label: l.pills_currentStock,
        threshold: widget.detail.pill.lowStockThreshold,
        tint: tint,
      ),
    ],
  );

  Widget _notesSection(AppLocalizations l, int index) {
    final text = Theme.of(context).textTheme;
    return FormSection(
      index: index,
      identity: _identity,
      icon: Icons.sticky_note_2_outlined,
      title: l.mf_sectionNotes,
      children: [
        TextField(
          controller: _notes,
          enabled: !_busy,
          minLines: 2,
          maxLines: 5,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: l.t09_notes),
        ),
        if (hasOriginalDosageText(widget.detail.review.originalDosage)) ...[
          const SizedBox(height: 14),
          Text(
            _reviewed ? l.t09_legacyDosageReviewed : l.t09_legacyDosage,
            style: text.labelLarge,
          ),
          Text(widget.detail.review.originalDosage!),
          SwitchListTile.adaptive(
            key: const ValueKey('edit-medication-dosage-reviewed'),
            contentPadding: EdgeInsets.zero,
            title: Text(l.amountReview_markReviewed),
            subtitle: Text(l.amountReview_markReviewedHint),
            value: _reviewed,
            onChanged: _busy ? null : (v) => setState(() => _reviewed = v),
          ),
        ],
      ],
    );
  }

  List<Widget> _extraSections(int first) {
    final sections = medicationExtrasSections(
      context: context,
      editor: _extras,
      identity: _identity,
      firstIndex: first,
      enabled: !_busy,
      showLimits: widget.detail.pill.isPrn,
    );
    return [
      ...sections,
      _photoSection(AppLocalizations.of(context), first + sections.length),
    ];
  }

  Widget _photoSection(AppLocalizations l, int index) => FormSection(
    index: index,
    identity: _identity,
    icon: Icons.photo_camera_outlined,
    title: l.photo_title,
    children: [
      MedicationPhotoField(
        name: _name.text.trim().isEmpty
            ? widget.detail.pill.name
            : _name.text.trim(),
        stored: ref
            .watch(medicationPhotoProvider(widget.detail.pill.id))
            .asData
            ?.value
            ?.bytes,
        draft: _photo,
        enabled: !_busy,
        onChanged: (draft) => setState(() => _photo = draft),
      ),
    ],
  );

  Widget _errorBanner() {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: AppMotion.duration(context),
      curve: AppMotion.curve,
      alignment: Alignment.topCenter,
      child: _error == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Semantics(
                liveRegion: true,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.errorContainer.withValues(alpha: .55),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ExcludeSemantics(
                        child: Icon(
                          Icons.info_outline_rounded,
                          size: 20,
                          color: cs.onErrorContainer,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _error!,
                          style: text.bodyMedium?.copyWith(
                            color: cs.onErrorContainer,
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final current = ref.watch(medicationDetailRepositoryProvider);
    if (current.isLoading ||
        current.hasError ||
        !identical(current.asData?.value, widget.repository)) {
      return SizedBox(
        height: 260,
        child: CareState(title: l.t08_unavailable, body: l.t08_unavailableBody),
      );
    }
    final cs = Theme.of(context).colorScheme;
    final local = widget.repository.context.isLocal;
    final pill = widget.detail.pill;
    final tint = medicationTint(
      id: pill.id,
      color: local ? _color : pill.color,
    );
    if (widget.stockOnly) return _stockOnly(l, tint);
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.t09_editMedication, style: text.headlineSmall),
        const SizedBox(height: 4),
        Text(
          l.t08_forPerson(widget.detail.person.name),
          style: text.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
        ),
      ],
    );
    if (widget.wide) return _wide(l, title, tint, local);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          title,
          const SizedBox(height: 16),
          MedicationPreview(
            listenable: Listenable.merge([_name, _strength, _form]),
            name: () => _name.text,
            form: () => _form.text,
            shape: _currentShape,
            imprint: _imprint,
            detail: () => previewLine([_strength.text, _form.text]),
            tint: tint,
          ),
          const SizedBox(height: 10),
          _CollapsiblePreview(child: _preview(tint, local: local)),
          const SizedBox(height: 16),
          _what(l, 0),
          _dose(l, 1),
          if (local) ...[_look(l, 2, tint), _supply(l, 3, tint)],
          _notesSection(l, 4),
          ..._extraSections(5),
          _errorBanner(),
          const SizedBox(height: 20),
          Pressable(
            radius: BorderRadius.circular(14),
            child: FilledButton(
              key: const ValueKey('save-medication-review'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: _busy ? null : _save,
              child: Text(_busy ? l.t08_saving : l.t08_saveMedication),
            ),
          ),
        ],
      ),
    );
  }

  /// Just the stock count, for adding stock: the medication it belongs to,
  /// the stepper and the buttons, with room left for the keyboard.
  Widget _stockOnly(AppLocalizations l, Color tint) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final cs = theme.colorScheme;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        widget.wide ? 24 : 4,
        24,
        // A sheet rises above the keyboard by padding; a dialog already
        // moves clear of it.
        20 + (widget.wide ? 0 : MediaQuery.viewInsetsOf(context).bottom),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(l.tm_addStock, style: text.headlineSmall),
          ),
          const SizedBox(height: 4),
          Text(
            '${widget.detail.pill.name} · '
            '${l.t08_forPerson(widget.detail.person.name)}',
            style: text.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          StockStepper(
            fieldKey: const ValueKey('edit-medication-stock'),
            focusNode: _stockFocus,
            controller: _stock,
            enabled: !_busy,
            label: l.pills_currentStock,
            threshold: widget.detail.pill.lowStockThreshold,
            tint: tint,
          ),
          if (_error != null) _errorBanner(),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: const ValueKey('cancel-medication-review'),
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text(l.shared_cancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('save-medication-review'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(96, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: _busy ? null : _save,
                child: Text(_busy ? l.t08_saving : l.shared_save),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The expanded layout: a header with the actions, the fields in two
  /// columns and the live preview in a third that stays in view.
  Widget _wide(AppLocalizations l, Widget title, Color tint, bool local) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 20, 8),
          child: Row(
            children: [
              Expanded(child: title),
              TextButton(
                key: const ValueKey('cancel-medication-review'),
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text(l.shared_cancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('save-medication-review'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(96, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: _busy ? null : _save,
                child: Text(_busy ? l.t08_saving : l.shared_save),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [_errorBanner()],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.viewInsetsOf(context).bottom,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _what(l, 0),
                        _dose(l, 1),
                        if (!local) _notesSection(l, 2),
                        if (!local) ..._extraSections(3),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                if (local) ...[
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.viewInsetsOf(context).bottom,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _look(l, 2, tint),
                          _supply(l, 3, tint),
                          _notesSection(l, 4),
                          ..._extraSections(5),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
                SizedBox(
                  width: 320,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: cs.outlineVariant.withValues(alpha: .5),
                      ),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Semantics(
                            header: true,
                            child: Text(
                              l.tm_previewTitle,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(height: 12),
                          _preview(tint, local: local),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The preview under the identity card on a narrow screen: one line that
/// opens the dose card, the reminder and the stock after saving, closed until
/// asked for.
class _CollapsiblePreview extends StatefulWidget {
  const _CollapsiblePreview({required this.child});
  final Widget child;

  @override
  State<_CollapsiblePreview> createState() => _CollapsiblePreviewState();
}

class _CollapsiblePreviewState extends State<_CollapsiblePreview> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: .5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            child: InkWell(
              key: const ValueKey('edit-preview-toggle'),
              borderRadius: BorderRadius.circular(20),
              onTap: () => setState(() => _open = !_open),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: ExcludeSemantics(
                          excluding: false,
                          child: Text(
                            l.tm_previewTitle,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      AnimatedRotation(
                        turns: _open ? .5 : 0,
                        duration: AppMotion.duration(context),
                        curve: AppMotion.curve,
                        child: const Icon(Icons.expand_more_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // The preview opens in place; with motion off it simply appears.
          if (AppMotion.quiet(context))
            if (_open)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: widget.child,
              )
            else
              const SizedBox.shrink()
          else
            AnimatedSize(
              duration: AppMotion.duration(context),
              curve: AppMotion.curve,
              alignment: Alignment.topCenter,
              child: _open
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: widget.child,
                    )
                  : const SizedBox(width: double.infinity),
            ),
        ],
      ),
    );
  }
}
