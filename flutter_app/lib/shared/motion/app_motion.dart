import 'package:flutter/material.dart';

/// Shared motion vocabulary.
///
/// Two voices: *physics* (immediate, proportional, answers a touch) and
/// *weather* (slow, scene only). Every primitive has a quiet variant that
/// shows the final frame when the platform asks for reduced motion (Android's
/// "Remove animations"); words and haptics never depend on motion.
///
/// Accessible navigation alone does not quiet motion: Android reports it for
/// any running accessibility service (password managers, automation apps),
/// not only for screen readers. People who want stillness with TalkBack use
/// this app's own Reduce motion switch.
abstract final class AppMotion {
  /// Press feedback, chip crossfades, quiet-mode fades.
  static const micro = Duration(milliseconds: 120);

  /// Default transition between two states of the same surface.
  static const standard = Duration(milliseconds: 240);

  /// Moments that deserve attention (receipt ring, nav capsule).
  static const emphasis = Duration(milliseconds: 320);

  /// Scene entry and other weather-voice motion.
  static const ambient = Duration(milliseconds: 900);

  static const curve = Curves.easeOutCubic;

  /// Slightly under-damped (critical damping is ~41): settles in about
  /// 300 ms with a barely visible overshoot, so presses feel physical.
  static const spring = SpringDescription(mass: 1, stiffness: 420, damping: 32);

  /// True when motion should collapse to its final frame.
  ///
  /// Safe to call without a [MediaQuery] ancestor (treated as not quiet).
  static bool quiet(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  static Duration duration(BuildContext context, {int milliseconds = 240}) =>
      quiet(context) ? Duration.zero : Duration(milliseconds: milliseconds);

  /// True when the phone itself disables animations, whatever this app's own
  /// setting says. Outside [ReducedMotionScope] it is the same as [quiet].
  static bool quietByPhone(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PhoneMotion>()?.quiet ??
      quiet(context);
}

/// The app's own "reduce motion" choice. When [reduce] is on, everything below
/// sees the platform's reduced-motion flag, so every motion takes its quiet
/// variant exactly as it does for the phone's setting. The tree below keeps
/// its shape either way, so flipping the choice never rebuilds a route.
class ReducedMotionScope extends StatelessWidget {
  const ReducedMotionScope({
    super.key,
    required this.reduce,
    required this.child,
  });

  final bool reduce;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return _PhoneMotion(
      quiet: AppMotion.quiet(context),
      child: MediaQuery(
        data: media.copyWith(
          disableAnimations: media.disableAnimations || reduce,
        ),
        child: child,
      ),
    );
  }
}

class _PhoneMotion extends InheritedWidget {
  const _PhoneMotion({required this.quiet, required super.child});

  final bool quiet;

  @override
  bool updateShouldNotify(_PhoneMotion old) => old.quiet != quiet;
}

/// Keyed content changes communicate place without changing keyboard focus.
class CareTransition extends StatelessWidget {
  const CareTransition({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.duration(context);
    if (duration == Duration.zero) return child;
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.linear,
      switchOutCurve: Curves.linear,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topCenter,
        children: [
          for (final outgoing in previous)
            ExcludeSemantics(child: IgnorePointer(child: outgoing)),
          ?current,
        ],
      ),
      transitionBuilder: (child, animation) {
        // Incoming text starts after the outgoing text has disappeared. Applying
        // the same interval in reverse gives each half of the fade-through.
        final opacity = animation.drive(
          CurveTween(curve: const Interval(.5, 1, curve: AppMotion.curve)),
        );
        return AnimatedBuilder(
          animation: opacity,
          builder: (context, child) =>
              IgnorePointer(ignoring: opacity.value == 0, child: child),
          child: FadeTransition(
            opacity: opacity,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, .025),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
        );
      },
      child: child,
    );
  }
}
