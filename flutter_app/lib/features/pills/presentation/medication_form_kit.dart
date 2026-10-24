import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/inventory/exact_stock.dart';
import '../../../core/inventory/stock_format.dart';
import '../../../core/medication/unit_names.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/motion/staggered_entrance.dart';
import '../../../shared/theme/pill_colors.dart';
import 'package:simpastil/core/medication/stock_effect.dart'
    show canonicalStockUnit;
import 'medication_identity.dart';
import 'stock_capsule.dart';

/// Shared pieces of the add/edit medication, schedule and person forms:
/// friendly grouped sections, a live identity preview, a colour picker and an
/// inline stock control. Everything here is presentation only; saving stays
/// with the owning sheet and its repository.

/// A titled group of fields on a soft surface. Sections rise in one after
/// another (once per [identity]); validation messages inside wrap instead of
/// truncating, so calm, longer sentences stay readable at large text sizes.
class FormSection extends StatelessWidget {
  const FormSection({
    super.key,
    required this.title,
    required this.children,
    required this.index,
    required this.identity,
    this.icon,
    this.hint,
  });

  final String title;
  final String? hint;
  final IconData? icon;
  final List<Widget> children;
  final int index;
  final Object identity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final text = theme.textTheme;
    return StaggeredEntrance(
      index: index,
      identity: identity,
      child: Theme(
        data: theme.copyWith(
          inputDecorationTheme: theme.inputDecorationTheme.copyWith(
            errorMaxLines: 3,
            errorStyle: text.bodySmall?.copyWith(color: cs.error, height: 1.3),
          ),
        ),
        child: Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: .5)),
          ),
          // The tinted card is a plain DecoratedBox, so the list tiles inside
          // it need their own Material to paint ink and selection on.
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Row(
                    children: [
                      if (icon != null) ...[
                        ExcludeSemantics(
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: cs.primaryContainer,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              icon,
                              size: 17,
                              color: cs.onPrimaryContainer,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Text(
                          title,
                          style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (hint != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    hint!,
                    style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: 12),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A live preview of the medication being written: its mark takes the shape
/// read from the form text and the chosen colour while the person types.
///
/// Decorative: every value it shows is also in a labelled field, so it is
/// hidden from assistive technology.
class MedicationPreview extends StatelessWidget {
  const MedicationPreview({
    super.key,
    required this.listenable,
    required this.name,
    required this.detail,
    required this.form,
    required this.tint,
    this.shape,
    this.imprint,
    this.caption,
  });

  final Listenable listenable;
  final String Function() name;
  final String Function() detail;
  final String Function() form;
  final Color tint;

  /// The picked shape and the imprint it gets; when absent the shape is read
  /// from [form] and the imprint is the first letter of [name].
  final MedicationShape Function()? shape;
  final String Function()? imprint;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ExcludeSemantics(
      child: ListenableBuilder(
        listenable: listenable,
        builder: (context, _) {
          final title = name().trim();
          final line = detail().trim();
          return AnimatedContainer(
            duration: AppMotion.duration(context),
            curve: AppMotion.curve,
            padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: LinearGradient(
                begin: AlignmentDirectional.centerStart,
                end: AlignmentDirectional.centerEnd,
                colors: [
                  Color.alphaBlend(tint.withValues(alpha: .22), cs.surface),
                  Color.alphaBlend(tint.withValues(alpha: .06), cs.surface),
                ],
              ),
              border: Border.all(color: tint.withValues(alpha: .45)),
            ),
            child: Row(
              children: [
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    color: cs.surface.withValues(alpha: .75),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: MedicationMark(
                    key: const ValueKey('medication-preview-mark'),
                    color: tint,
                    shape: shape?.call() ?? medicationShapeOf(form()),
                    imprint: imprint?.call() ?? imprintInitial(title),
                    size: 54,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title.isEmpty ? l.mf_previewPlaceholder : title,
                        key: const ValueKey('medication-preview-name'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: title.isEmpty
                              ? cs.onSurfaceVariant
                              : cs.onSurface,
                        ),
                      ),
                      if (line.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          line,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (caption != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          caption!,
                          style: text.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Joins the non-empty parts of a preview line with a middle dot.
String previewLine(Iterable<String?> parts) =>
    parts.map((p) => p?.trim() ?? '').where((p) => p.isNotEmpty).join(' · ');

/// Colour swatches for a medication. Each swatch is a real button with its
/// colour name spoken and its selected state exposed.
class TintPicker extends StatelessWidget {
  const TintPicker({
    super.key,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
  });

  final String? selected;
  final ValueChanged<String> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final pc in kPillColors)
          Builder(
            builder: (context) {
              final color = colorFromHex(pc.hex);
              final isSelected = isSamePillColor(pc.hex, selected);
              final ink = color.computeLuminance() > .4
                  ? const Color(0xFF141414)
                  : Colors.white;
              void choose() {
                HapticFeedback.selectionClick();
                onSelected(pc.hex);
              }

              return Semantics(
                button: true,
                selected: isSelected,
                enabled: enabled,
                label: l.mf_colorSwatch(localizedColorLabel(l, pc.label)),
                onTap: enabled ? choose : null,
                excludeSemantics: true,
                child: Pressable(
                  key: ValueKey('tint-${pc.hex}'),
                  radius: BorderRadius.circular(24),
                  onTap: enabled ? choose : () {},
                  child: SizedBox.square(
                    dimension: 48,
                    child: Center(
                      child: AnimatedContainer(
                        duration: AppMotion.duration(
                          context,
                          milliseconds: 160,
                        ),
                        curve: AppMotion.curve,
                        width: isSelected ? 42 : 34,
                        height: isSelected ? 42 : 34,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected
                                ? cs.onSurface
                                : pillOutlineColor(color),
                            width: isSelected ? 2.5 : 1,
                          ),
                        ),
                        child: isSelected
                            ? Icon(Icons.check_rounded, size: 22, color: ink)
                            : null,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// The nine silhouettes as buttons, beside the colour swatches. Each shows the
/// medication's own colour and imprint so the choice reads as the pill will.
/// When another of the person's medications already has this shape and first
/// letter it says so, since the imprint then grows to two letters.
class ShapePicker extends StatelessWidget {
  const ShapePicker({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.tint,
    required this.imprint,
    this.collisionName,
    this.suggested = false,
    this.enabled = true,
  });

  final MedicationShape selected;
  final ValueChanged<MedicationShape> onSelected;
  final Color tint;

  /// The letter shown on every option.
  final String imprint;

  /// The name of the medication that shares [selected] and the first letter.
  final String? collisionName;

  /// Whether [selected] is the app's own suggestion, not yet changed.
  final bool suggested;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final shape in MedicationShape.values)
              Builder(
                builder: (context) {
                  final isSelected = shape == selected;
                  void choose() {
                    HapticFeedback.selectionClick();
                    onSelected(shape);
                  }

                  return Semantics(
                    button: true,
                    selected: isSelected,
                    enabled: enabled,
                    label: l.mf_shapeSwatch(medicationShapeLabel(l, shape)),
                    onTap: enabled ? choose : null,
                    excludeSemantics: true,
                    child: Pressable(
                      key: ValueKey('shape-${shape.wire}'),
                      radius: BorderRadius.circular(14),
                      onTap: enabled ? choose : () {},
                      child: SizedBox.square(
                        dimension: 52,
                        child: Center(
                          child: Container(
                            width: 46,
                            height: 46,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? cs.surfaceContainerHighest
                                  : null,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isSelected
                                    ? cs.onSurface
                                    : cs.outlineVariant,
                                width: isSelected ? 2.5 : 1,
                              ),
                            ),
                            child: MedicationMark(
                              color: tint,
                              shape: shape,
                              imprint: imprint,
                              size: 34,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
        if (suggested) ...[
          const SizedBox(height: 8),
          Text(
            l.mf_shapeSuggested,
            key: const ValueKey('shape-suggested'),
            style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
        if (collisionName != null) ...[
          const SizedBox(height: 8),
          Row(
            key: const ValueKey('shape-collision'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, size: 18, color: cs.onSurface),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.mf_shapeCollision(collisionName!),
                  style: text.bodySmall?.copyWith(color: cs.onSurface),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The spoken and written name of [shape].
String medicationShapeLabel(AppLocalizations l, MedicationShape shape) =>
    switch (shape) {
      MedicationShape.round => l.mf_shapeRound,
      MedicationShape.caplet => l.mf_shapeCaplet,
      MedicationShape.oval => l.mf_shapeOval,
      MedicationShape.softgel => l.mf_shapeSoftgel,
      MedicationShape.capsule => l.mf_shapeCapsule,
      MedicationShape.triangle => l.mf_shapeTriangle,
      MedicationShape.square => l.mf_shapeSquare,
      MedicationShape.diamond => l.mf_shapeDiamond,
      MedicationShape.drop => l.mf_shapeDrop,
    };

/// Inline stock control: one fewer / number / one more, with the stock
/// capsule beneath following the typed value. The number field stays the
/// source of truth and keeps its own validator.
class StockStepper extends StatelessWidget {
  const StockStepper({
    super.key,
    required this.controller,
    required this.label,
    required this.tint,
    this.fieldKey,
    this.focusNode,
    this.threshold,
    this.enabled = true,
    this.validator,
    this.parts = false,
    this.unit,
  });

  final TextEditingController controller;
  final String label;
  final Color tint;
  final Key? fieldKey;
  final FocusNode? focusNode;
  final int? threshold;
  final bool enabled;
  final String? Function(String?)? validator;

  /// Offers the "Add a part" button, for a count kept in a unit.
  final bool parts;

  /// What the count is kept in (`tablet`, `capsules`), which names the part
  /// pop-up. Null when the unit is not known.
  final String? unit;

  void _step(int delta) {
    final current =
        ExactStock.tryParseInput(controller.text) ?? ExactStock.zero;
    // A part tablet steps to the next whole one, so 7.5 goes to 8 and 7.
    final base = delta > 0
        ? (current.isWhole ? current : ExactStock.fromInt(current.floor))
        : (current.isWhole ? current : ExactStock.fromInt(current.floor + 1));
    final next = (base + ExactStock.fromInt(delta)).toWire();
    controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final exact = ExactStock.tryParseInput(controller.text);
        final value = exact?.floor;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The label sits above the row: between the two step buttons a
            // floating label truncates at large text sizes.
            ExcludeSemantics(
              child: Text(label, style: Theme.of(context).textTheme.labelLarge),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _StepButton(
                  icon: Icons.remove_rounded,
                  tooltip: l.mf_fewer,
                  onTap: enabled && value != null && value > 0
                      ? () => _step(-1)
                      : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Semantics(
                    label: label,
                    child: StockWholeField(
                      key: fieldKey,
                      controller: controller,
                      focusNode: focusNode,
                      enabled: enabled,
                      wholeOnly: parts,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      decoration: const InputDecoration(hintText: '0'),
                      validator: validator,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _StepButton(
                  icon: Icons.add_rounded,
                  tooltip: l.mf_more,
                  onTap: enabled ? () => _step(1) : null,
                ),
              ],
            ),
            if (parts) ...[
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: StockPartButton(
                  controller: controller,
                  enabled: enabled,
                  unit: unit,
                ),
              ),
            ],
            if (value != null) ...[
              const SizedBox(height: 12),
              StockCapsule(
                stock: value,
                // What was typed, exactly: "7 1/2" reads "7½ left", not "7".
                stockText: exact != null && !exact.isWhole
                    ? formatExactStock(
                        exact,
                        languageCode: Localizations.localeOf(
                          context,
                        ).languageCode,
                      )
                    : null,
                threshold: threshold,
                color: tint,
              ),
            ],
          ],
        );
      },
    );
  }
}

/// The text field of a stock count. With [wholeOnly] it shows just the whole
/// number ("7") and leaves the part to [StockPartButton] ("Part: ½"), so the
/// count is never written twice as "7.5" and "7½". [controller] always holds
/// the full count ("7 1/2"), which every caller reads and saves unchanged.
/// A count whose part is not a quarter, or text that is not a plain whole
/// number, is shown and edited as typed.
class StockWholeField extends StatefulWidget {
  const StockWholeField({
    super.key,
    required this.controller,
    this.focusNode,
    this.enabled = true,
    this.wholeOnly = false,
    this.textAlign = TextAlign.start,
    this.style,
    this.decoration = const InputDecoration(),
    this.validator,
    this.autofocus = false,
    this.textInputAction,
    this.onFieldSubmitted,
    this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool enabled;
  final bool wholeOnly;
  final TextAlign textAlign;
  final TextStyle? style;
  final InputDecoration decoration;
  final String? Function(String?)? validator;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onFieldSubmitted;
  final ValueChanged<String>? onChanged;

  /// The text the field shows for the full count [text].
  static String shownFor(String text, {required bool wholeOnly}) {
    if (!wholeOnly) return text;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';
    final quarters = StockPartButton.quartersIn(trimmed);
    final count = ExactStock.tryParseInput(trimmed);
    if (quarters == null || count == null || count.isNegative) return text;
    return '${count.floor}';
  }

  @override
  State<StockWholeField> createState() => _StockWholeFieldState();
}

class _StockWholeFieldState extends State<StockWholeField> {
  late final TextEditingController _own;
  bool _writing = false;

  @override
  void initState() {
    super.initState();
    _own = TextEditingController(text: _shown());
    widget.controller.addListener(_fromCount);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_fromCount);
    _own.dispose();
    super.dispose();
  }

  String _shown() => StockWholeField.shownFor(
    widget.controller.text,
    wholeOnly: widget.wholeOnly,
  );

  /// The full count changed elsewhere (a step, the part pop-up).
  void _fromCount() {
    if (_writing) return;
    final shown = _shown();
    if (_own.text != shown) {
      _own.value = TextEditingValue(
        text: shown,
        selection: TextSelection.collapsed(offset: shown.length),
      );
    }
  }

  /// Joins the typed whole number with the part already set.
  String _compose(String typed) {
    if (!widget.wholeOnly || !RegExp(r'^\d*$').hasMatch(typed)) return typed;
    final quarters = StockPartButton.quartersIn(widget.controller.text) ?? 0;
    if (quarters == 0) return typed;
    final part = const ['', '1/4', '1/2', '3/4'][quarters];
    return typed.isEmpty ? part : '$typed $part';
  }

  void _toCount(String typed) {
    _writing = true;
    widget.controller.text = _compose(typed);
    _writing = false;
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.wholeOnly ? _own : widget.controller,
      focusNode: widget.focusNode,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      textAlign: widget.textAlign,
      textInputAction: widget.textInputAction,
      onFieldSubmitted: widget.onFieldSubmitted,
      keyboardType: const TextInputType.numberWithOptions(
        signed: true,
        decimal: true,
      ),
      style: widget.style,
      decoration: widget.decoration,
      onChanged: (typed) {
        if (widget.wholeOnly) _toCount(typed);
        widget.onChanged?.call(typed);
      },
      validator: widget.validator == null
          ? null
          : (typed) => widget.validator!(_compose(typed ?? '')),
    );
  }
}

/// One button under the stock count that opens a small pop-up for the part
/// of one after the whole count (a quarter, a half or three quarters), for
/// keyboards without a "/" key. The button names the part already typed. A
/// third has no exact stock, so it is not offered: a third-tablet dose asks
/// for a recount instead.
class StockPartButton extends StatelessWidget {
  const StockPartButton({
    super.key,
    required this.controller,
    this.enabled = true,
    this.unit,
  });

  final TextEditingController controller;
  final bool enabled;

  /// What the count is kept in; names the pop-up ("Part of a tablet").
  final String? unit;

  /// The part after the whole count in [text], in quarters (0 to 3). Empty,
  /// unreadable and negative text return 0; null means a readable count whose
  /// part is not a whole quarter (such as 0.125).
  static int? quartersIn(String text) {
    final current = ExactStock.tryParseInput(text);
    if (current == null || current.isNegative) return 0;
    final part = current - ExactStock.fromInt(current.floor);
    for (var q = 0; q < 4; q++) {
      if (part == ExactStock.fromRatio(BigInt.from(q), BigInt.from(4))) {
        return q;
      }
    }
    return null;
  }

  void _apply(int quarters) {
    final current = ExactStock.tryParseInput(controller.text);
    final whole = current == null || current.isNegative ? 0 : current.floor;
    final (n, d) = switch (quarters) {
      1 => (1, 4),
      2 => (1, 2),
      3 => (3, 4),
      _ => (0, 1),
    };
    final text = n == 0
        ? '$whole'
        : whole == 0
        ? '$n/$d'
        : '$whole $n/$d';
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    HapticFeedback.selectionClick();
  }

  Future<void> _open(BuildContext context, int? current) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (_) => _StockPartDialog(current: current, unit: unit),
    );
    if (picked != null) _apply(picked);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final current = quartersIn(controller.text);
        final set = current != null && current > 0;
        final text = set
            ? l.stock_partButtonSet(stockPartFraction(current))
            : l.stock_partButtonAdd;
        return OutlinedButton.icon(
          key: const ValueKey('stock-part-button'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(48, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
          onPressed: enabled ? () => _open(context, current) : null,
          icon: StockPartGlyph(quarters: set ? current : 2, size: 20),
          label: Text(text),
        );
      },
    );
  }
}

/// [quarters] of one as a fraction sign: ¼, ½ or ¾.
String stockPartFraction(int quarters) => const ['0', '¼', '½', '¾'][quarters];

/// The spoken and written word for [quarters] of one.
String stockPartWord(AppLocalizations l, int quarters) => switch (quarters) {
  1 => l.stock_partQuarter,
  2 => l.stock_partHalf,
  3 => l.stock_partThreeQuarters,
  _ => l.stock_partNone,
};

const _sachetWords = {'sachet', 'sachets', 'plic', 'plicuri'};

/// The part pop-up's title for [unit]: it names what the medication is
/// counted in ("Part of a tablet"), and says "Part of one" for a unit the app
/// has no word for or no unit at all. Gender follows the unit in Romanian.
String stockPartTitle(AppLocalizations l, String? unit) {
  final key = unit == null || unit.trim().isEmpty
      ? null
      : canonicalStockUnit(unit);
  return l.rvm_partOfUnit(switch (key) {
    'tablet' => 'tablet',
    'capsule' => 'capsule',
    'comprimat' => 'comprimat',
    'pastilă' => 'pill',
    // Not a unit the stock counts in, but one the title can name (neuter in
    // Romanian: "dintr-un plic").
    _ when _sachetWords.contains(key?.toLowerCase()) => 'sachet',
    _ => 'other',
  });
}

/// The unit as the amount field's suffix: a countable unit (tablet, capsule,
/// comprimat, pastilă) in the app's language, singular for one and plural
/// otherwise ([quantity] is the number typed so far, null for none), any
/// other unit as it was stored.
String stockUnitSuffix(AppLocalizations l, String unit, {double? quantity}) =>
    medicationUnitName(l, unit, unitCountFor(quantity)) ?? unit;

class _StockPartDialog extends StatelessWidget {
  const _StockPartDialog({required this.current, this.unit});

  final String? unit;

  /// The part typed now, in quarters, or null when it is none of them.
  final int? current;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    Widget tile(int q) => Expanded(
      child: _StockPartTile(
        quarters: q,
        selected: current == q,
        onTap: () => Navigator.of(context).pop(q),
      ),
    );
    return AlertDialog(
      title: Text(stockPartTitle(l, unit)),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l.stock_partHint,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [tile(0), const SizedBox(width: 12), tile(1)],
              ),
            ),
            const SizedBox(height: 12),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [tile(2), const SizedBox(width: 12), tile(3)],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.shared_cancel),
        ),
      ],
    );
  }
}

/// One choice in the part pop-up: a drawn tablet showing how much of it is
/// left, the fraction and its word. Selection shows as a fill, a thicker
/// border and a check mark, so it never rests on colour alone.
class _StockPartTile extends StatelessWidget {
  const _StockPartTile({
    required this.quarters,
    required this.selected,
    required this.onTap,
  });

  final int quarters;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final word = stockPartWord(l, quarters);
    final radius = BorderRadius.circular(14);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: word,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? cs.primaryContainer : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected ? cs.primary : cs.outline,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          key: ValueKey('stock-part-$quarters'),
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 96),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 14, 8, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      StockPartGlyph(quarters: quarters, size: 32),
                      const SizedBox(height: 8),
                      if (quarters > 0)
                        Text(
                          stockPartFraction(quarters),
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: selected
                                ? cs.onPrimaryContainer
                                : cs.onSurface,
                            fontWeight: FontWeight.w600,
                            height: 1.1,
                          ),
                        ),
                      Text(
                        word,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: selected
                              ? cs.onPrimaryContainer
                              : cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  PositionedDirectional(
                    top: 6,
                    end: 6,
                    child: Icon(
                      Icons.check_circle_rounded,
                      size: 20,
                      color: cs.primary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A round scored tablet with [quarters] of it filled, drawn in the theme's
/// action colour over an outline that holds 3:1 against the surface. Zero
/// draws the empty outline. Purely decorative: the words carry the meaning.
class StockPartGlyph extends StatelessWidget {
  const StockPartGlyph({super.key, required this.quarters, this.size = 24});

  final int quarters;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(size),
        painter: _PartTabletPainter(
          quarters: quarters,
          fill: cs.primary,
          line: cs.outline,
        ),
      ),
    );
  }
}

class _PartTabletPainter extends CustomPainter {
  _PartTabletPainter({
    required this.quarters,
    required this.fill,
    required this.line,
  });

  final int quarters;
  final Color fill;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width / 14;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final c = rect.center;
    final r = rect.width / 2;
    if (quarters > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi / 2 * quarters,
        true,
        Paint()..color = fill,
      );
    }
    final pen = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    // The score lines a quartered tablet breaks along.
    canvas
      ..drawLine(c.translate(0, -r), c.translate(0, r), pen)
      ..drawLine(c.translate(-r, 0), c.translate(r, 0), pen)
      ..drawCircle(c, r, pen);
  }

  @override
  bool shouldRepaint(_PartTabletPainter old) =>
      old.quarters != quarters || old.fill != fill || old.line != line;
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.tooltip, this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final on = onTap != null;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: on,
        label: tooltip,
        onTap: onTap,
        excludeSemantics: true,
        child: Pressable(
          radius: BorderRadius.circular(16),
          // A no-op keeps a disabled button from passing taps through.
          onTap: onTap ?? () {},
          child: AnimatedContainer(
            duration: AppMotion.duration(context, milliseconds: 120),
            width: 52,
            height: 56,
            decoration: BoxDecoration(
              color: on
                  ? cs.secondaryContainer
                  : cs.surfaceContainerHighest.withValues(alpha: .5),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              icon,
              color: on
                  ? cs.onSecondaryContainer
                  : cs.onSurface.withValues(alpha: .38),
            ),
          ),
        ),
      ),
    );
  }
}
