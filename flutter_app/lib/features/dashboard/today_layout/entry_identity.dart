import 'package:flutter/material.dart';

import '../../../core/medication/care_day.dart';
import '../../../shared/widgets/person_avatar.dart';
import '../../pills/presentation/medication_identity.dart';
import '../../../shared/motion/pressable.dart';

/// The medication's own colour and shape mark for [entry], the same mark the
/// Focus deck card and the medication tile show.
class EntryMedicationMark extends StatelessWidget {
  const EntryMedicationMark({super.key, required this.entry, this.size = 22});

  final CareDayEntry entry;
  final double size;

  @override
  Widget build(BuildContext context) => PillMark(
    key: ValueKey('entry-mark-${entry.occurrence.id}'),
    size: size,
    pillId: entry.pill.id,
    name: entry.snapshot.pillName,
    color: medicationTint(id: entry.pill.id, color: entry.pill.color),
    fallbackShape: medicationShapeOf(entry.plannedAmount.unit),
  );
}

/// A medication name led by its mark, so every Today layout identifies a
/// medication the same way.
class EntryMedicationName extends StatelessWidget {
  const EntryMedicationName({super.key, required this.entry, this.style});

  final CareDayEntry entry;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.textScalerOf(context).scale(22).clamp(22.0, 30.0);
    return Row(
      children: [
        EntryMedicationMark(entry: entry, size: size),
        const SizedBox(width: 8),
        Flexible(child: Text(entry.snapshot.pillName, style: style)),
      ],
    );
  }
}

/// "For Casey" led by Casey's face, as on People and the person picker.
class EntryPersonLine extends StatelessWidget {
  const EntryPersonLine({
    super.key,
    required this.entry,
    required this.label,
    this.style,
  });

  final CareDayEntry entry;
  final String label;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.textScalerOf(context).scale(18).clamp(18.0, 28.0);
    return Row(
      children: [
        PersonAvatar(
          key: ValueKey('entry-face-${entry.occurrence.id}'),
          id: entry.person.id,
          name: entry.person.name,
          emoji: entry.person.avatarEmoji,
          size: size,
        ),
        const SizedBox(width: 6),
        Flexible(child: Text(label, style: style)),
      ],
    );
  }
}

/// A [Pressable] around a take or undo button that stays calm and legible
/// while the receipt is being saved. The button is disabled during the save,
/// and Material would fade it to a barely visible grey for that moment; here
/// a disabled button keeps its colours, a little softer, so "Saving…" reads.
class SavingPressable extends StatelessWidget {
  const SavingPressable({
    super.key,
    required this.saving,
    required this.radius,
    required this.child,
  });

  final bool saving;
  final BorderRadius radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final pressable = Pressable(radius: radius, child: child);
    if (!saving) return pressable;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fill = colors.primary.withValues(alpha: .78);
    return Theme(
      data: theme.copyWith(
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            disabledBackgroundColor: fill,
            disabledForegroundColor: colors.onPrimary,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            disabledForegroundColor: colors.onSurface.withValues(alpha: .8),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            disabledForegroundColor: colors.onSurface.withValues(alpha: .8),
          ),
        ),
      ),
      child: pressable,
    );
  }
}
