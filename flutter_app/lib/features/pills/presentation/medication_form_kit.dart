import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/motion/staggered_entrance.dart';
import '../../../shared/theme/pill_colors.dart';
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
    this.caption,
  });

  final Listenable listenable;
  final String Function() name;
  final String Function() detail;
  final String Function() form;
  final Color tint;
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
                    shape: medicationShapeOf(form()),
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
              final isSelected =
                  pc.hex.toUpperCase() == (selected ?? '').toUpperCase();
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
                                : cs.outline.withValues(alpha: .35),
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
  });

  final TextEditingController controller;
  final String label;
  final Color tint;
  final Key? fieldKey;
  final FocusNode? focusNode;
  final int? threshold;
  final bool enabled;
  final String? Function(String?)? validator;

  void _step(int delta) {
    final current = int.tryParse(controller.text.trim()) ?? 0;
    final next = current + delta;
    controller.value = TextEditingValue(
      text: '$next',
      selection: TextSelection.collapsed(offset: '$next'.length),
    );
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final value = int.tryParse(controller.text.trim());
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
                    child: TextFormField(
                      key: fieldKey,
                      controller: controller,
                      focusNode: focusNode,
                      enabled: enabled,
                      textAlign: TextAlign.center,
                      keyboardType: const TextInputType.numberWithOptions(
                        signed: true,
                      ),
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
            if (value != null) ...[
              const SizedBox(height: 12),
              StockCapsule(stock: value, threshold: threshold, color: tint),
            ],
          ],
        );
      },
    );
  }
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
