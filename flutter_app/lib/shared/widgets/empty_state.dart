import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../motion/app_motion.dart';
import '../theme/focus_tokens.dart';
import 'capsule_mark.dart';
import 'person_avatar.dart';

/// What the small scene above an empty state shows.
enum EmptyStateArt {
  /// The capsule resting on a dawn horizon.
  capsule,

  /// Two faces waiting beside the capsule, for empty lists of people.
  people,
}

/// A calm, light empty state: a small dawn scene with the capsule mark, a
/// headline, an optional explanation and an optional action.
///
/// The scene rises in once (the capsule settles onto the horizon); reduced
/// motion shows the final frame. The scene is decorative, so screen readers
/// hear only the words and the action. The content scrolls when there is not
/// enough room (large text, landscape) and still lets a surrounding
/// [RefreshIndicator] receive pulls.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.subtitle,
    this.ctaLabel,
    this.onCta,
    this.ctaIcon = Icons.add_rounded,
    this.art = EmptyStateArt.capsule,
  });

  final String title;
  final String? subtitle;
  final String? ctaLabel;
  final VoidCallback? onCta;
  final IconData ctaIcon;
  final EmptyStateArt art;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final cs = theme.colorScheme;
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            EmptyStateScene(art: art),
            const SizedBox(height: 20),
            Text(
              title,
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                style: text.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
            if (ctaLabel != null && onCta != null) ...[
              const SizedBox(height: 28),
              FilledButton.icon(
                key: const ValueKey('empty-state-cta'),
                onPressed: onCta,
                icon: Icon(ctaIcon),
                label: Text(ctaLabel!, textAlign: TextAlign.center),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 52),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, bounds) {
        if (!bounds.hasBoundedHeight) return Center(child: content);
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: bounds.maxHeight),
            child: Center(child: content),
          ),
        );
      },
    );
  }
}

/// The decorative dawn scene of [EmptyState]: a soft sun glow on a curved
/// horizon, a dotted arc for the day and the capsule mark resting on it.
class EmptyStateScene extends StatelessWidget {
  const EmptyStateScene({super.key, this.art = EmptyStateArt.capsule});

  final EmptyStateArt art;

  static const size = Size(200, 124);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final quiet = AppMotion.quiet(context);
    return ExcludeSemantics(
      child: TweenAnimationBuilder<double>(
        key: const ValueKey('empty-state-scene'),
        tween: Tween(begin: quiet ? 1 : 0, end: 1),
        duration: quiet ? Duration.zero : AppMotion.ambient,
        curve: AppMotion.curve,
        builder: (context, t, _) {
          return SizedBox.fromSize(
            size: size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: EmptyStatePainter(
                      progress: t,
                      glow: dark
                          ? cs.primary.withValues(alpha: .30)
                          : FocusTokens.lavender,
                      horizon: cs.outlineVariant,
                      arc: cs.primary.withValues(alpha: dark ? .55 : .45),
                      ground: Color.alphaBlend(
                        FocusTokens.sage.withValues(alpha: dark ? .22 : .16),
                        cs.surface,
                      ),
                    ),
                  ),
                ),
                if (art == EmptyStateArt.people) ...[
                  Positioned(
                    left: 34,
                    top: 58 + 6 * (1 - t),
                    child: Opacity(
                      opacity: t,
                      child: const PersonAvatar(
                        id: 'empty-a',
                        name: '',
                        size: 34,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 34,
                    top: 58 + 10 * (1 - t),
                    child: Opacity(
                      opacity: t,
                      child: const PersonAvatar(
                        id: 'empty-c',
                        name: '',
                        size: 34,
                      ),
                    ),
                  ),
                ],
                Positioned(
                  left: size.width / 2 - 30,
                  top: 36 + 14 * (1 - t),
                  child: const CapsuleMark(size: 60),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Paints the glow, horizon, ground and day arc of [EmptyStateScene].
class EmptyStatePainter extends CustomPainter {
  const EmptyStatePainter({
    required this.progress,
    required this.glow,
    required this.horizon,
    required this.arc,
    required this.ground,
  });

  final double progress;
  final Color glow, horizon, arc, ground;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final horizonY = h * .78;
    final center = Offset(w / 2, horizonY);
    // Sun glow rising behind the horizon.
    final glowRadius = w * .42;
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, w, horizonY));
    canvas.drawCircle(
      center.translate(0, 10 * (1 - progress)),
      glowRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            glow.withValues(alpha: glow.a * progress),
            glow.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: glowRadius)),
    );
    canvas.restore();
    // Dotted arc of the day, drawn on as the scene rises.
    final arcRect = Rect.fromCenter(
      center: center,
      width: w * .92,
      height: h * 1.25,
    );
    final dots = Paint()..color = arc;
    const count = 15;
    final shown = (count * progress).round();
    for (var i = 0; i < shown; i++) {
      final angle = math.pi + math.pi * (i + .5) / count;
      final p = Offset(
        arcRect.center.dx + arcRect.width / 2 * math.cos(angle),
        arcRect.center.dy + arcRect.height / 2 * math.sin(angle),
      );
      canvas.drawCircle(p, i.isEven ? 1.6 : 1.1, dots);
    }
    // Gentle ground and horizon line.
    final ground = Path()
      ..moveTo(0, horizonY + 6)
      ..quadraticBezierTo(w / 2, horizonY - 6, w, horizonY + 6)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(
      ground,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [this.ground, this.ground.withValues(alpha: 0)],
        ).createShader(Rect.fromLTRB(0, horizonY - 6, w, h)),
    );
    canvas.drawPath(
      Path()
        ..moveTo(8, horizonY + 6)
        ..quadraticBezierTo(w / 2, horizonY - 6, w - 8, horizonY + 6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..color = horizon,
    );
  }

  @override
  bool shouldRepaint(EmptyStatePainter old) =>
      old.progress != progress ||
      old.glow != glow ||
      old.horizon != horizon ||
      old.arc != arc ||
      old.ground != ground;
}
