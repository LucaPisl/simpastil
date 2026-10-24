import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database.dart';
import '../../../core/errors/app_error.dart';
import '../../../core/inventory/exact_stock.dart';
import '../../../core/inventory/pill_stock.dart';
import '../../../core/inventory/stock_reading.dart';
import '../../../core/medication/stock_effect.dart';
import '../../../core/sync/ledger_mode_hint.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/theme/pill_colors.dart';
import '../../../shared/widgets/drag_handle.dart';
import '../../profiles/profile_provider.dart';
import '../medication_look_provider.dart';
import '../pill_provider.dart';
import 'medication_form_kit.dart';
import '../../../core/medication/medication_extras.dart';
import 'medication_extras_fields.dart';
import 'medication_identity.dart';

// ── Public API ────────────────────────────────────────────────────────────────

Future<void> showAddEditPillSheet({
  required BuildContext context,
  String? initialProfileId,
  Pill? pill,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) =>
        _AddEditPillSheet(initialProfileId: initialProfileId, pill: pill),
  );
}

// ── Sheet ─────────────────────────────────────────────────────────────────────

class _AddEditPillSheet extends ConsumerStatefulWidget {
  const _AddEditPillSheet({this.initialProfileId, this.pill});

  final String? initialProfileId;
  final Pill? pill;

  @override
  ConsumerState<_AddEditPillSheet> createState() => _AddEditPillSheetState();
}

class _AddEditPillSheetState extends ConsumerState<_AddEditPillSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _dosageController;
  late final TextEditingController _notesController;
  late String? _selectedColor;
  // Only a colour the person actually picked is written; an edit that never
  // touches the swatches keeps the medication's own colour (null stays null).
  bool _colorTouched = false;
  // The stock field was edited in this sheet: only then does saving count
  // the stock (and confirm a pending recount).
  bool _stockTouched = false;

  /// The shape the person picked; null until they do. A new medication then
  /// takes the suggestion, an existing one keeps what it has.
  MedicationShape? _pickedShape;

  /// The other medications of the people it is for, read in [build].
  List<({String name, MedicationShape shape})> _others = const [];
  final _nameAnchor = GlobalKey();
  final _stockAnchor = GlobalKey();
  final _thresholdAnchor = GlobalKey();
  late Set<String> _selectedProfileIds;
  bool _didInitProfileSelection = false;
  bool _isSaving = false;

  // ── PRN (as-needed) state ──────────────────────────────────────────────────
  late bool _isPrn;
  late final MedicationExtrasEditor _extras;

  // ── Inventory state ───────────────────────────────────────────────────────
  late bool _trackStock;
  late final TextEditingController _stockController;

  /// The unit a part-tablet count is kept in: the one the stock already has,
  /// else the amount per dose when it is tablets or capsules. Null until it is
  /// read (and for a medication that has neither), when only a whole count is
  /// accepted.
  String? _fractionUnit;

  /// Whether the connected server last advertised exact stock. Unknown reads
  /// as no, so only whole counts are accepted until the server says otherwise.
  bool _fractionalSupported = false;
  late final TextEditingController _thresholdController;

  // ── Sibling propagation state ─────────────────────────────────────────────
  List<Pill> _siblings = [];
  bool _propagate = false;
  final Set<PropagableField> _propagateFields = PropagableField.values.toSet();
  bool _fieldsExpanded = true;
  bool _didLoadSiblings = false;
  final Object _sectionIdentity = Object();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _extras.applyLocale(Localizations.localeOf(context).toString());
  }

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.pill?.name ?? '');
    _dosageController = TextEditingController(text: widget.pill?.dosage ?? '');
    _notesController = TextEditingController(text: widget.pill?.notes ?? '');
    _isPrn = widget.pill?.isPrn ?? false;
    _extras = MedicationExtrasEditor(
      widget.pill == null
          ? MedicationExtras.none
          : MedicationExtras.fromPill(widget.pill!),
    );
    _trackStock = widget.pill?.currentStock != null;
    final existingStock = widget.pill == null
        ? null
        : exactStockOf(widget.pill!);
    _fractionUnit = widget.pill?.stockUnit;
    _stockController = TextEditingController(
      text: existingStock?.toWire() ?? '',
    );
    var stockText = _stockController.text;
    _stockController.addListener(() {
      if (_stockController.text == stockText) return;
      stockText = _stockController.text;
      _stockTouched = true;
    });
    LedgerModeHint.readFractionalStock().then((supported) {
      if (mounted && supported) setState(() => _fractionalSupported = true);
    });
    if (widget.pill != null && _fractionUnit == null) _loadFractionUnit();
    _thresholdController = TextEditingController(
      text: widget.pill?.lowStockThreshold?.toString() ?? '',
    );
    _selectedColor = widget.pill != null
        ? widget.pill!.color
        : kPillColors.first.hex;
    _selectedProfileIds = widget.pill != null
        ? {widget.pill!.profileId}
        : {if (widget.initialProfileId != null) widget.initialProfileId!};
  }

  Future<void> _loadFractionUnit() async {
    final row =
        await (ref
                .read(databaseProvider)
                .select(ref.read(databaseProvider).medicationDetails)
              ..where((d) => d.pillId.equals(widget.pill!.id)))
            .getSingleOrNull();
    final unit = amountOfDetailRow(row)?.unit;
    if (!mounted || !isCountableStockUnit(unit)) return;
    setState(() => _fractionUnit = unit!.trim());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _dosageController.dispose();
    _notesController.dispose();
    _stockController.dispose();
    _thresholdController.dispose();
    _extras.dispose();
    super.dispose();
  }

  bool get _isEditMode => widget.pill != null;

  String? _nameError(AppLocalizations l) =>
      _nameController.text.trim().isEmpty ? l.mf_nameNeeded : null;

  String? _stockError(AppLocalizations l) {
    if (!_trackStock) return null;
    final n = ExactStock.tryParseInput(_stockController.text);
    if (n == null || !n.inRange) {
      return _fractionalSupported ? l.mf_stockNumberNeeded : l.mf_numberNeeded;
    }
    if (!n.isWhole && !_fractionalSupported) return l.mf_numberNeeded;
    if (!n.isWhole && _fractionUnit == null) {
      return l.mf_stockFractionNeedsUnit;
    }
    return null;
  }

  /// The alert level is optional; when given it must be a whole number >= 0.
  String? _thresholdError(AppLocalizations l) {
    if (!_trackStock) return null;
    final text = _thresholdController.text.trim();
    if (text.isEmpty) return null;
    final n = int.tryParse(text);
    return (n == null || n < 0) ? l.mf_numberNeeded : null;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Brings the first invalid field into view and says why Save did nothing.
  void _revealInvalidField() {
    final l = AppLocalizations.of(context);
    final fields = [
      (_nameAnchor, _nameError(l)),
      (_stockAnchor, _stockError(l)),
      (_thresholdAnchor, _thresholdError(l)),
    ];
    for (final (anchor, message) in fields) {
      if (message == null) continue;
      final target = anchor.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          duration: AppMotion.duration(context),
          alignment: .2,
        );
      }
      _showMessage(message);
      return;
    }
  }

  Future<void> _submit() async {
    if (_isSaving) return;
    if (!(_formKey.currentState?.validate() ?? false)) {
      _revealInvalidField();
      return;
    }
    if (!_extras.isValid(AppLocalizations.of(context))) {
      _showMessage(AppLocalizations.of(context).mx_checkFields);
      return;
    }
    if (!_isEditMode && _selectedProfileIds.isEmpty) {
      _showMessage(AppLocalizations.of(context).pills_selectAtLeastOneProfile);
      return;
    }
    setState(() => _isSaving = true);
    try {
      await _save();
    } on Object {
      if (mounted) {
        _showMessage(
          _errorMessage(const UnknownError(), AppLocalizations.of(context)),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  List<({String name, MedicationShape shape})> _watchOthers() {
    final people = _isEditMode
        ? {widget.pill!.profileId}
        : _selectedProfileIds.toSet();
    return [
      for (final id in people)
        ...ref.watch(
          personMedicationsProvider((
            personId: id,
            exceptPillId: widget.pill?.id,
          )),
        ),
    ];
  }

  /// The shape in force: the picked one; for an existing medication the one it
  /// is drawn with; for a new one the suggestion beside the others.
  MedicationShape _currentShape() {
    final picked = _pickedShape;
    if (picked != null) return picked;
    if (_isEditMode) {
      return ref.read(medicationLooksProvider).value?[widget.pill!.id]?.shape ??
          effectiveMedicationShape(widget.pill!.shape, null);
    }
    return suggestMedicationShape(
      form: _nameController.text,
      used: [for (final o in _others) o.shape],
    );
  }

  Future<void> _save() async {
    final repo = ref.read(pillRepositoryProvider);
    final name = _nameController.text.trim();
    final dosage = _dosageController.text.trim().isEmpty
        ? null
        : _dosageController.text.trim();
    final notes = _notesController.text.trim().isEmpty
        ? null
        : _notesController.text.trim();
    final exactStock = _trackStock
        ? ExactStock.tryParseInput(_stockController.text)
        : null;
    // A count in a unit (or any part of one) goes as an exact quantity; a plain
    // whole count keeps the integer it always was.
    final unit = exactStock == null
        ? null
        : (widget.pill?.stockUnit ??
              (exactStock.isWhole ? null : _fractionUnit));
    final currentStock =
        exactStock != null && unit == null && exactStock.isWhole
        ? exactStock.floor
        : null;
    final stockQuantity = unit == null ? null : exactStock;
    final lowStockThreshold = _trackStock
        ? int.tryParse(_thresholdController.text.trim())
        : null;

    if (_isEditMode) {
      final result = await repo.update(
        widget.pill!.id,
        name: name,
        dosage: dosage,
        notes: notes,
        color: _colorTouched ? _selectedColor : widget.pill!.color,
        shape: _pickedShape?.wire,
        currentStock: currentStock,
        stockQuantity: stockQuantity,
        stockUnit: unit,
        lowStockThreshold: lowStockThreshold,
        isPrn: _isPrn,
        extras: _extras.read(),
        stockCounted: _stockTouched,
      );

      if (!mounted) return;

      switch (result) {
        case Ok():
          // Propagate to siblings if requested.
          await _propagateToSiblings(context, ref);
          if (!mounted) return;
          Navigator.of(context).pop();
        case Err(:final error):
          _showMessage(_errorMessage(error, AppLocalizations.of(context)));
      }
    } else {
      AppError? firstError;
      var successCount = 0;
      final selected = _selectedProfileIds.toList()..sort();

      for (final profileId in selected) {
        final result = await repo.create(
          profileId: profileId,
          name: name,
          dosage: dosage,
          notes: notes,
          color: _selectedColor,
          shape: _currentShape().wire,
          currentStock: currentStock,
          stockQuantity: stockQuantity,
          stockUnit: unit,
          lowStockThreshold: lowStockThreshold,
          isPrn: _isPrn,
          extras: _extras.read(),
        );
        switch (result) {
          case Ok():
            successCount++;
          case Err(:final error):
            firstError ??= error;
        }
      }

      if (!mounted) return;

      if (successCount > 0) {
        Navigator.of(context).pop();
        if (firstError != null) {
          _showMessage(
            AppLocalizations.of(context).pills_addedToProfiles(successCount),
          );
        }
      } else {
        _showMessage(
          _errorMessage(
            firstError ?? const UnknownError(),
            AppLocalizations.of(context),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _others = _watchOthers();
    final text = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);
    final profiles = ref.watch(profileListProvider).value ?? const [];

    if (!_isEditMode && !_didInitProfileSelection && profiles.isNotEmpty) {
      _didInitProfileSelection = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final initialSelection = <String>{};
        if (widget.initialProfileId != null) {
          initialSelection.add(widget.initialProfileId!);
        } else {
          initialSelection.addAll(
            profiles.where((p) => p.profile.isActive).map((p) => p.profile.id),
          );
        }
        if (initialSelection.isEmpty) {
          initialSelection.addAll(profiles.map((p) => p.profile.id));
        }
        setState(() => _selectedProfileIds = initialSelection);
      });
    }

    // Load siblings once (edit mode only).
    if (_isEditMode && !_didLoadSiblings) {
      _didLoadSiblings = true; // set eagerly so rebuilds never re-schedule
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final mode = ref.read(siblingDetectionModeProvider);
        if (mode == SiblingDetectionMode.perPill) {
          // In perPill mode, _selectedProfileIds is used instead of _siblings.
          // Pre-check profiles that already have a pill with the same name.
          final userId = ref.read(currentUserIdProvider);
          try {
            final allSiblings = await ref
                .read(databaseProvider)
                .pillsDao
                .getSiblings(widget.pill!.id, userId, widget.pill!.name);
            if (!mounted) return;
            final siblingProfileIds = allSiblings
                .map((p) => p.profileId)
                .toSet();
            setState(() => _selectedProfileIds = siblingProfileIds);
          } catch (_) {
            // Query failure: leave _selectedProfileIds as-is (no pre-selection).
          }
          return;
        }
        final userId = ref.read(currentUserIdProvider);
        try {
          final siblings = await ref
              .read(databaseProvider)
              .pillsDao
              .getSiblings(
                widget.pill!.id,
                userId,
                widget.pill!.name,
                dosage: mode == SiblingDetectionMode.nameAndDosage
                    ? widget.pill!.dosage
                    : null,
              );
          if (!mounted) return;
          setState(() {
            _siblings = siblings;
            _propagate = siblings.isNotEmpty;
          });
        } catch (_) {
          // Sibling detection failed; proceed without propagation section.
        }
      });
    }

    final cs = Theme.of(context).colorScheme;
    final tint = medicationTint(
      id: widget.pill?.id ?? '',
      color: _selectedColor,
    );
    String? stockValidator(String? _) => _stockError(l);

    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      minChildSize: 0.5,
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
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: FocusTraversalGroup(
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _isEditMode
                              ? l.pills_editPillTitle
                              : l.pills_newPillTitle,
                          style: text.headlineSmall,
                        ),
                        const SizedBox(height: 16),
                        MedicationPreview(
                          listenable: Listenable.merge([
                            _nameController,
                            _dosageController,
                          ]),
                          name: () => _nameController.text,
                          form: () => _nameController.text,
                          shape: _currentShape,
                          imprint: () => imprintAmong(
                            name: _nameController.text,
                            shape: _currentShape(),
                            others: _others,
                          ),
                          detail: () => previewLine([
                            _dosageController.text,
                            if (_isPrn) l.asn_onlyWhenNeeded,
                          ]),
                          tint: tint,
                        ),
                        const SizedBox(height: 16),

                        // ── What it is ─────────────────────────────────────
                        FormSection(
                          index: 0,
                          identity: _sectionIdentity,
                          icon: Icons.medication_outlined,
                          title: l.mf_sectionWhat,
                          children: [
                            KeyedSubtree(
                              key: _nameAnchor,
                              child: TextFormField(
                                key: const ValueKey('pill-name'),
                                controller: _nameController,
                                autofocus: !_isEditMode,
                                maxLength: 100,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                decoration: InputDecoration(
                                  labelText: l.pills_nameLabel,
                                  counterText: '',
                                ),
                                validator: (_) => _nameError(l),
                                textInputAction: TextInputAction.next,
                              ),
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              key: const ValueKey('pill-dosage'),
                              controller: _dosageController,
                              maxLength: 50,
                              decoration: InputDecoration(
                                labelText: l.pills_dosageLabel,
                                counterText: '',
                              ),
                              textInputAction: TextInputAction.next,
                            ),
                            const SizedBox(height: 6),
                            SwitchListTile.adaptive(
                              key: const ValueKey('pill-only-when-needed'),
                              title: Text(l.asn_editorSwitch),
                              subtitle: Text(l.asn_editorSwitchHint),
                              value: _isPrn,
                              contentPadding: EdgeInsets.zero,
                              onChanged: (v) => setState(() => _isPrn = v),
                            ),
                          ],
                        ),

                        // ── How it looks ───────────────────────────────────
                        FormSection(
                          index: 1,
                          identity: _sectionIdentity,
                          icon: Icons.palette_outlined,
                          title: l.mf_sectionLook,
                          hint: l.mf_sectionLookHint,
                          children: [
                            TintPicker(
                              selected:
                                  _selectedColor ??
                                  medicationFallbackHex(widget.pill?.id ?? ''),
                              enabled: !_isSaving,
                              onSelected: (hex) => setState(() {
                                _selectedColor = hex;
                                _colorTouched = true;
                              }),
                            ),
                            const SizedBox(height: 16),
                            ListenableBuilder(
                              listenable: _nameController,
                              builder: (context, _) => ShapePicker(
                                selected: _currentShape(),
                                tint: tint,
                                imprint: imprintAmong(
                                  name: _nameController.text,
                                  shape: _currentShape(),
                                  others: _others,
                                ),
                                enabled: !_isSaving,
                                suggested: !_isEditMode && _pickedShape == null,
                                collisionName: collidingMedicationName(
                                  name: _nameController.text,
                                  shape: _currentShape(),
                                  others: _others,
                                ),
                                onSelected: (shape) =>
                                    setState(() => _pickedShape = shape),
                              ),
                            ),
                          ],
                        ),

                        // ── Supply ─────────────────────────────────────────
                        FormSection(
                          index: 2,
                          identity: _sectionIdentity,
                          icon: Icons.inventory_2_outlined,
                          title: l.mf_sectionSupply,
                          children: [
                            SwitchListTile.adaptive(
                              title: Text(l.pills_trackStock),
                              subtitle: Text(l.pills_trackStockSubtitle),
                              value: _trackStock,
                              contentPadding: EdgeInsets.zero,
                              onChanged: (v) => setState(() => _trackStock = v),
                            ),
                            AnimatedSize(
                              duration: AppMotion.duration(context),
                              curve: AppMotion.curve,
                              alignment: Alignment.topCenter,
                              child: !_trackStock
                                  ? const SizedBox(width: double.infinity)
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        const SizedBox(height: 8),
                                        KeyedSubtree(
                                          key: _stockAnchor,
                                          child: ListenableBuilder(
                                            listenable: _thresholdController,
                                            builder: (context, _) =>
                                                StockStepper(
                                                  fieldKey: const ValueKey(
                                                    'pill-stock',
                                                  ),
                                                  controller: _stockController,
                                                  label: l.pills_currentStock,
                                                  tint: tint,
                                                  enabled: !_isSaving,
                                                  threshold: int.tryParse(
                                                    _thresholdController.text
                                                        .trim(),
                                                  ),
                                                  validator: stockValidator,
                                                  parts:
                                                      _fractionalSupported &&
                                                      _fractionUnit != null,
                                                  unit: _fractionUnit,
                                                ),
                                          ),
                                        ),
                                        const SizedBox(height: 14),
                                        KeyedSubtree(
                                          key: _thresholdAnchor,
                                          child: TextFormField(
                                            key: const ValueKey(
                                              'pill-threshold',
                                            ),
                                            controller: _thresholdController,
                                            keyboardType: TextInputType.number,
                                            decoration: InputDecoration(
                                              labelText: l.pills_alertWhenBelow,
                                            ),
                                            validator: (_) =>
                                                _thresholdError(l),
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ],
                        ),

                        // ── Notes ──────────────────────────────────────────
                        FormSection(
                          index: 3,
                          identity: _sectionIdentity,
                          icon: Icons.sticky_note_2_outlined,
                          title: l.mf_sectionNotes,
                          children: [
                            TextFormField(
                              controller: _notesController,
                              minLines: 2,
                              maxLines: 4,
                              maxLength: 500,
                              textCapitalization: TextCapitalization.sentences,
                              decoration: InputDecoration(
                                labelText: l.pills_notesLabel,
                                counterText: '',
                                alignLabelWithHint: true,
                              ),
                              textInputAction: TextInputAction.done,
                            ),
                          ],
                        ),

                        ...medicationExtrasSections(
                          context: context,
                          editor: _extras,
                          identity: _sectionIdentity,
                          firstIndex: 4,
                          enabled: !_isSaving,
                          showLimits: _isPrn,
                        ),

                        // ── Who takes it ───────────────────────────────────
                        if (!_isEditMode ||
                            ref.watch(siblingDetectionModeProvider) ==
                                SiblingDetectionMode.perPill)
                          FormSection(
                            index: 4,
                            identity: _sectionIdentity,
                            icon: Icons.people_outline_rounded,
                            title: _isEditMode
                                ? l.pills_updateProfiles
                                : l.pills_assignToProfiles,
                            children: [
                              _ProfileMultiSelect(
                                profiles: profiles,
                                selected: _selectedProfileIds,
                                onSelectAll: () => setState(
                                  () => _selectedProfileIds = profiles
                                      .map((p) => p.profile.id)
                                      .toSet(),
                                ),
                                onSelectNone: () =>
                                    setState(() => _selectedProfileIds = {}),
                                onToggle: (profileId) => setState(() {
                                  if (_selectedProfileIds.contains(profileId)) {
                                    _selectedProfileIds.remove(profileId);
                                  } else {
                                    _selectedProfileIds.add(profileId);
                                  }
                                }),
                              ),
                            ],
                          ),
                        // Non-perPill propagation section (edit mode only)
                        if (_isEditMode) _buildPropagationSection(context),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // ── Save, always in reach ───────────────────────────────────
            DecoratedBox(
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                border: Border(
                  top: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: .6),
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: Pressable(
                  radius: BorderRadius.circular(14),
                  child: FilledButton(
                    key: const ValueKey('save-pill'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: _isSaving ? null : _submit,
                    child: _isSaving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l.shared_save),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPropagationSection(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final mode = ref.watch(siblingDetectionModeProvider);

    // perPill mode: reuse the profile multi-select (already shown in create mode).
    // The profile multi-select is already rendered in build() when !_isEditMode;
    // in perPill edit mode we include it via the normal `if (!_isEditMode || mode == perPill)`
    // condition — handled in build(). This method handles non-perPill propagation only.
    if (mode == SiblingDetectionMode.perPill || _siblings.isEmpty) {
      return const SizedBox.shrink();
    }

    final siblingCount = _siblings.length;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.secondary.withValues(alpha: 0.3)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Master toggle ───────────────────────────────────────────────────
            Row(
              children: [
                Checkbox(
                  value: _propagate,
                  onChanged: (v) => setState(() => _propagate = v ?? false),
                ),
                Expanded(
                  child: Text(
                    AppLocalizations.of(
                      context,
                    ).pills_alsoUpdateSiblings(siblingCount),
                    style: text.bodyMedium,
                  ),
                ),
                if (_propagate)
                  IconButton(
                    icon: Icon(
                      _fieldsExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        setState(() => _fieldsExpanded = !_fieldsExpanded),
                  ),
              ],
            ),
            // ── Field selector ──────────────────────────────────────────────────
            if (_propagate && _fieldsExpanded) ...[
              const Divider(height: 12),
              Text(
                AppLocalizations.of(context).pills_applyChangesTo,
                style: text.bodySmall,
              ),
              const SizedBox(height: 4),
              for (final field in PropagableField.values)
                SizedBox(
                  height: 36,
                  child: CheckboxListTile(
                    value: _propagateFields.contains(field),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _propagateFields.add(field);
                      } else {
                        _propagateFields.remove(field);
                      }
                    }),
                    title: Text(_fieldLabel(field), style: text.bodySmall),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _fieldLabel(PropagableField field) {
    final l = AppLocalizations.of(context);
    return switch (field) {
      PropagableField.name => l.pills_fieldName,
      PropagableField.dosage => l.pills_fieldDosage,
      PropagableField.notes => l.pills_fieldNotes,
      PropagableField.color => l.pills_fieldColor,
    };
  }

  Future<void> _propagateToSiblings(BuildContext context, WidgetRef ref) async {
    final mode = ref.read(siblingDetectionModeProvider);

    List<Pill> targets;
    if (mode == SiblingDetectionMode.perPill) {
      // In perPill mode, find existing siblings among selected profiles.
      if (_selectedProfileIds.isEmpty) return;
      final userId = ref.read(currentUserIdProvider);
      try {
        final allSiblings = await ref
            .read(databaseProvider)
            .pillsDao
            .getSiblings(widget.pill!.id, userId, widget.pill!.name);
        targets = allSiblings
            .where((s) => _selectedProfileIds.contains(s.profileId))
            .toList();
      } catch (_) {
        return;
      }
    } else {
      if (!_propagate || _siblings.isEmpty) return;
      targets = _siblings;
    }

    if (targets.isEmpty) return;
    if (_propagateFields.isEmpty) return;

    final name = _nameController.text.trim();
    final dosage = _dosageController.text.trim().isEmpty
        ? null
        : _dosageController.text.trim();
    final notes = _notesController.text.trim().isEmpty
        ? null
        : _notesController.text.trim();
    final color = _selectedColor;
    // Colour travels only when it was actually picked in this sheet.
    final copyColor =
        _colorTouched && _propagateFields.contains(PropagableField.color);

    final db = ref.read(databaseProvider);
    final repo = ref.read(pillRepositoryProvider);
    int failCount = 0;

    for (final stale in targets) {
      try {
        // Re-read so fields that are not propagated keep their current value.
        final sibling = await db.pillsDao.getById(stale.id);
        if (sibling == null || sibling.isDeleted) {
          failCount++;
          continue;
        }
        final result = await repo.update(
          sibling.id,
          name: _propagateFields.contains(PropagableField.name)
              ? name
              : sibling.name,
          dosage: _propagateFields.contains(PropagableField.dosage)
              ? dosage
              : sibling.dosage,
          notes: _propagateFields.contains(PropagableField.notes)
              ? notes
              : sibling.notes,
          color: copyColor ? color : sibling.color,
          currentStock: sibling.stockUnit == null ? sibling.currentStock : null,
          stockQuantity: sibling.stockUnit == null
              ? null
              : exactStockOf(sibling),
          stockUnit: sibling.stockUnit,
          lowStockThreshold: sibling.lowStockThreshold,
          isPrn: sibling.isPrn,
        );
        if (result is Err) failCount++;
      } catch (_) {
        failCount++;
      }
    }

    if (failCount > 0 && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(
              context,
            ).pills_savedCouldNotUpdateSiblings(failCount),
          ),
        ),
      );
    }
  }

  String _errorMessage(AppError error, AppLocalizations l) => switch (error) {
    NetworkError() => l.error_noConnection,
    UnauthorizedError() => l.error_sessionExpired,
    NotFoundError() => l.error_pillNotFound,
    ServerError(:final statusCode) => l.error_serverError(statusCode),
    _ => l.shared_somethingWentWrong,
  };
}

class _ProfileMultiSelect extends StatelessWidget {
  const _ProfileMultiSelect({
    required this.profiles,
    required this.selected,
    required this.onToggle,
    required this.onSelectNone,
    required this.onSelectAll,
  });

  final List<ProfileWithCount> profiles;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final VoidCallback onSelectNone;
  final VoidCallback onSelectAll;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    if (profiles.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          AppLocalizations.of(context).pills_noProfilesAvailable,
          style: text.bodySmall,
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TextButton(
                onPressed: onSelectAll,
                child: Text(AppLocalizations.of(context).shared_all),
              ),
              TextButton(
                onPressed: onSelectNone,
                child: Text(AppLocalizations.of(context).shared_none),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in profiles)
                FilterChip(
                  selected: selected.contains(item.profile.id),
                  onSelected: (_) => onToggle(item.profile.id),
                  label: Text(
                    '${item.profile.avatarEmoji} ${item.profile.name}',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
