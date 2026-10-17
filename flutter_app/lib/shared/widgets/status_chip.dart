import 'package:flutter/material.dart';

import '../motion/app_motion.dart';
import '../theme/app_theme.dart';

/// How a status should feel. Tones only colour the chip; the words always
/// say what happened, so nothing depends on colour alone.
enum StatusTone {
  /// Done and confirmed (checked, shared, saved).
  good,

  /// Under way (syncing, saving).
  working,

  /// Worth a look, nothing lost (waiting changes, review needed).
  attention,

  /// Failed or unavailable.
  problem,

  /// Plain fact with no judgement (none yet, inactive).
  neutral,
}

/// The ink colour for [tone] on the current theme.
Color statusToneColor(ThemeData theme, StatusTone tone) {
  final cs = theme.colorScheme;
  final semantic = theme.extension<AppSemanticColors>();
  return switch (tone) {
    StatusTone.good => semantic?.statusTaken ?? cs.tertiary,
    StatusTone.working => cs.primary,
    StatusTone.attention =>
      semantic?.statusWarning ??
          (theme.brightness == Brightness.dark
              ? const Color(0xFFE6B566)
              : const Color(0xFF8A5A00)),
    StatusTone.problem => cs.error,
    StatusTone.neutral => cs.onSurfaceVariant,
  };
}

IconData statusToneIcon(StatusTone tone) => switch (tone) {
  StatusTone.good => Icons.check_circle_outline_rounded,
  StatusTone.working => Icons.autorenew_rounded,
  StatusTone.attention => Icons.error_outline_rounded,
  StatusTone.problem => Icons.cloud_off_outlined,
  StatusTone.neutral => Icons.radio_button_unchecked_rounded,
};

/// A small rounded status label with a tone dot or icon. Text wraps instead
/// of truncating so longer wording survives large text sizes.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.tone,
    this.icon,
    this.dense = false,
  });

  final String label;
  final StatusTone tone;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = statusToneColor(theme, tone);
    final surface = Color.alphaBlend(
      base.withValues(alpha: theme.brightness == Brightness.dark ? .18 : .12),
      theme.colorScheme.surface,
    );
    final ink = AppTheme.readable(base, [surface], minimum: 4.5);
    return AnimatedContainer(
      duration: AppMotion.duration(context, milliseconds: 160),
      curve: AppMotion.curve,
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: base.withValues(alpha: .28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: Icon(
              icon ?? statusToneIcon(tone),
              size: dense ? 14 : 16,
              color: ink,
            ),
          ),
          SizedBox(width: dense ? 4 : 6),
          Flexible(
            child: Text(
              label,
              style:
                  (dense
                          ? theme.textTheme.labelMedium
                          : theme.textTheme.labelLarge)
                      ?.copyWith(color: ink, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// A soft explanatory note with an icon, for consequences and reassurance
/// ("Nothing changes until you apply"). Optionally read out when it changes.
class CalmNotice extends StatelessWidget {
  const CalmNotice({
    super.key,
    required this.text,
    this.icon = Icons.info_outline_rounded,
    this.tone = StatusTone.working,
    this.live = false,
  });

  final String text;
  final IconData icon;
  final StatusTone tone;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = statusToneColor(theme, tone);
    final dark = theme.brightness == Brightness.dark;
    // A neutral note borrows the faint brand wash of the grouped surfaces so
    // it sits with them instead of reading as a grey, disabled box.
    final surface = Color.alphaBlend(
      tone == StatusTone.neutral
          ? theme.colorScheme.primary.withValues(alpha: dark ? .08 : .05)
          : base.withValues(alpha: dark ? .14 : .08),
      theme.colorScheme.surface,
    );
    return Semantics(
      liveRegion: live,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  icon,
                  size: 20,
                  color: AppTheme.readable(base, [surface], minimum: 3),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
