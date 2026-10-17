import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../core/notifications/reminder_copy.dart';
import '../../l10n/app_localizations.dart';
import '../motion/app_motion.dart';
import '../theme/app_theme.dart';
import '../theme/focus_tokens.dart';
import 'capsule_mark.dart';

/// A calm picture of one Simpastil notification: the violet capsule, the
/// app name and header, the title, the body and the action labels.
///
/// It is a sample, never a live alert, and it is read out as one sentence
/// ("Sample reminder: …"). Text wraps at any size; nothing is truncated.
///
/// It slides in once when it first appears. When the privacy choice
/// changes, ink sweeps across the details: going [private], the private
/// wording appears under the ink and the ink dissolves; coming back, the
/// ink wipes off the names. Nothing else moves, and quiet motion simply
/// shows the new wording.
class ReminderNotificationPreview extends StatefulWidget {
  const ReminderNotificationPreview({
    super.key,
    required this.copy,
    this.header,
    this.when,
    this.actions = const [],
    this.elevated = true,
    this.private = false,
  });

  /// A sample dose reminder that follows the privacy choice: with
  /// [fullDetails] off it shows the generic copy and only "Open".
  factory ReminderNotificationPreview.sample(
    AppLocalizations l, {
    Key? key,
    bool fullDetails = true,
    bool elevated = true,
  }) => ReminderNotificationPreview(
    key: key,
    elevated: elevated,
    private: !fullDetails,
    copy: doseReminderCopy(
      l,
      fullDetails: fullDetails,
      pillName: l.r6_sampleMedicine,
      dosage: l.r6_sampleDose,
    ),
    header: fullDetails ? l.r6_notifSubText : null,
    actions: fullDetails
        ? [
            l.core_notifActionTaken,
            l.core_notifActionSnooze,
            l.core_notifActionSkip,
          ]
        : [l.core_notifActionOpen],
  );

  /// A real planned reminder: its own [copy] (already made with the privacy
  /// choice) at the time it will fire. With [fullDetails] off it shows only
  /// "Open", as the notification does.
  factory ReminderNotificationPreview.planned(
    AppLocalizations l, {
    Key? key,
    required ReminderCopy copy,
    required String when,
    bool fullDetails = true,
    bool elevated = true,
  }) => ReminderNotificationPreview(
    key: key,
    elevated: elevated,
    private: !fullDetails,
    copy: copy,
    header: fullDetails ? l.r6_notifSubText : null,
    when: when,
    actions: fullDetails
        ? [
            l.core_notifActionTaken,
            l.core_notifActionSnooze,
            l.core_notifActionSkip,
          ]
        : [l.core_notifActionOpen],
  );

  /// The reminder check exactly as it is sent.
  factory ReminderNotificationPreview.check(
    AppLocalizations l, {
    Key? key,
    bool elevated = true,
  }) => ReminderNotificationPreview(
    key: key,
    elevated: elevated,
    copy: ReminderCopy(
      title: l.core_notifTestTitle,
      body: l.core_notifTestBody,
    ),
    actions: [l.core_notifActionOpen],
  );

  final ReminderCopy copy;
  final String? header;

  /// The time shown in the header, such as "23:00". Null reads "now".
  final String? when;
  final List<String> actions;

  /// Lifted with a soft shadow, to stand off the page.
  final bool elevated;

  /// The wording keeps names off the lock screen.
  final bool private;

  /// The first appearance.
  static const entry = AppMotion.emphasis;

  /// Ink across the details, the change of wording, and the ink leaving.
  static const inking = Duration(milliseconds: 680);

  @override
  State<ReminderNotificationPreview> createState() =>
      _ReminderNotificationPreviewState();
}

class _ReminderNotificationPreviewState
    extends State<ReminderNotificationPreview>
    with TickerProviderStateMixin {
  late final AnimationController _entry = AnimationController(
    vsync: this,
    duration: ReminderNotificationPreview.entry,
  );
  late final AnimationController _ink =
      AnimationController(
          vsync: this,
          duration: ReminderNotificationPreview.inking,
        )
        ..addListener(_inkTick)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) {
            setState(() {
              _from = null;
              _fromSizes = const [null, null, null];
            });
          }
        });

  /// Title, body and actions: the blocks the ink passes over.
  final _blocks = List.generate(3, (_) => GlobalKey());
  bool _started = false;

  /// What was shown before the privacy choice changed, until the ink
  /// covers it.
  ReminderNotificationPreview? _from;
  List<Size?> _fromSizes = const [null, null, null];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (AppMotion.quiet(context)) {
      _entry.value = 1;
    } else {
      _entry.forward();
    }
  }

  @override
  void didUpdateWidget(ReminderNotificationPreview old) {
    super.didUpdateWidget(old);
    if (old.private == widget.private) return;
    if (AppMotion.quiet(context)) {
      // Stopping does not notify, which would rebuild during this build.
      _ink.stop();
      _from = null;
      return;
    }
    // A change mid-sweep starts over from whatever is on screen now.
    _from = _ink.isAnimating && _ink.value < InkBarPainter.swap ? _from : old;
    _fromSizes = const [null, null, null];
    _ink.forward(from: 0);
  }

  void _inkTick() {
    // Just before the wording changes, note how big each covered block is,
    // so the ink can ease to the size of the new words.
    if (_from != null &&
        _ink.value >= InkBarPainter.swap &&
        _fromSizes.every((s) => s == null)) {
      _fromSizes = [
        for (final key in _blocks)
          (key.currentContext?.findRenderObject() as RenderBox?)?.size,
      ];
    }
  }

  @override
  void dispose() {
    _entry.dispose();
    _ink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final card = dark ? cs.surfaceContainerHigh : cs.surface;
    final quiet = AppMotion.quiet(context);
    final content = AnimatedBuilder(
      animation: _ink,
      builder: (context, _) => _content(context, card),
    );
    return Semantics(
      container: true,
      // Read the choice as it is now, not the wording under the ink.
      label: l.r6_previewSemantics(widget.copy.title, widget.copy.body),
      excludeSemantics: true,
      child: AnimatedBuilder(
        animation: _entry,
        builder: (context, child) {
          final e = AppMotion.curve.transform(_entry.value);
          return Opacity(
            opacity: e,
            child: Transform.translate(
              offset: Offset(0, 16 * (1 - e)),
              child: child,
            ),
          );
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: dark ? .5 : .7),
            ),
            boxShadow: widget.elevated
                ? [
                    BoxShadow(
                      color: (dark ? Colors.black : FocusTokens.violet)
                          .withValues(alpha: dark ? .35 : .12),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          // A zero-length AnimatedSize re-dirties itself mid-layout, so
          // quiet motion leaves it out.
          child: quiet
              ? content
              : AnimatedSize(
                  duration: AppMotion.standard,
                  curve: AppMotion.curve,
                  alignment: Alignment.topCenter,
                  child: content,
                ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, Color card) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final text = theme.textTheme;
    final t = _ink.value;
    final inking = _from != null;
    final shown = inking && t < InkBarPainter.swap ? _from! : widget;
    // Text uses the brand violet where it is readable, otherwise the theme's
    // own primary (a lighter violet in dark mode), never plain white.
    final accent = AppTheme.contrast(FocusTokens.violet, card) >= 4.5
        ? FocusTokens.violet
        : cs.primary;
    // The time ("8:00 PM") is one unit: in a narrow card the line may wrap
    // between the parts but never inside the time.
    final meta = [
      'Simpastil',
      if (shown.header != null) shown.header!,
      (shown.when ?? l.r6_previewNow).replaceAll(' ', '\u00A0'),
    ].join(' · ');
    Widget inked(int i, Widget child) => CustomPaint(
      key: _blocks[i],
      foregroundPainter: inking
          ? InkBarPainter(
              t: t,
              index: i,
              redact: widget.private,
              from: _fromSizes[i],
              // Ink reads dark on any card: near-black on a light page,
              // the deepest surface on a dark one.
              color: theme.brightness == Brightness.dark
                  ? cs.surfaceContainerLowest
                  : cs.onSurface,
            )
          : null,
      child: child,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _SmallIcon(color: FocusTokens.violet),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  meta,
                  style: text.labelMedium?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          inked(
            0,
            Text(
              shown.copy.title,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 2),
          inked(
            1,
            Text(
              shown.copy.body,
              style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          if (shown.actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            inked(
              2,
              Wrap(
                spacing: 20,
                runSpacing: 6,
                children: [
                  for (final action in shown.actions)
                    Text(
                      action,
                      style: text.labelLarge?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The ink over one block of a [ReminderNotificationPreview] while the
/// privacy choice changes. Over [t] (0 to 1) the bar sweeps across from the
/// left, block after block; at [swap] the wording under it changes and the
/// bar eases to the new words' size; then it dissolves when the change
/// [redact]s, or wipes off to the right when the names come back.
class InkBarPainter extends CustomPainter {
  const InkBarPainter({
    required this.t,
    required this.index,
    required this.redact,
    required this.color,
    this.from,
  });

  final double t;
  final int index;
  final bool redact;
  final Color color;

  /// The block's size before the wording changed, if it was measured.
  final Size? from;

  /// When the covered wording changes.
  static const swap = .44;
  static const _stagger = .06, _cover = .28, _leave = .36;

  /// How far the ink has covered block [i], 0 to 1.
  @visibleForTesting
  static double coverAt(double t, int i) => Curves.easeInOutCubic.transform(
    ((t - i * _stagger) / _cover).clamp(0.0, 1.0),
  );

  /// How far the ink has left block [i], 0 to 1.
  @visibleForTesting
  static double leaveAt(double t, int i) => Curves.easeInOutCubic.transform(
    ((t - .5 - i * _stagger) / _leave).clamp(0.0, 1.0),
  );

  /// The ink's extent over a block of [size] that measured [from] before
  /// the wording changed. It eases down onto shorter new words, but never
  /// leaves longer ones showing past its end.
  @visibleForTesting
  static Size boxAt(double t, Size? from, Size size) {
    if (t < swap || from == null) return size;
    final grow = Curves.easeOutCubic.transform(
      ((t - swap) / .16).clamp(0.0, 1.0),
    );
    final eased = Size.lerp(from, size, grow)!;
    return Size(
      math.max(eased.width, size.width),
      math.max(eased.height, size.height),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cover = coverAt(t, index), leave = leaveAt(t, index);
    if (cover <= 0 || leave >= 1) return;
    final box = boxAt(t, from, size);
    final w = box.width, h = box.height;
    final left = redact ? 0.0 : w * leave;
    final right = w * cover;
    if (right <= left) return;
    final alpha = redact ? 1 - leave : 1.0;
    final pad = (h * .08).clamp(1.0, 3.0);
    canvas.drawRRect(
      RRect.fromLTRBR(
        left - 2,
        pad,
        right + 2,
        h - pad,
        Radius.circular(lerpDouble(3, 6, (h / 40).clamp(0.0, 1.0))!),
      ),
      Paint()..color = color.withValues(alpha: color.a * alpha),
    );
  }

  @override
  bool shouldRepaint(InkBarPainter old) =>
      old.t != t ||
      old.index != index ||
      old.redact != redact ||
      old.color != color ||
      old.from != from;
}

/// The notification's small icon: a white capsule on a violet disc, as the
/// system draws the tinted small icon.
class _SmallIcon extends StatelessWidget {
  const _SmallIcon({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: CustomPaint(
        size: const Size.square(18),
        painter: CapsuleMarkPainter(
          progress: 0,
          fill: color,
          accent: FocusTokens.white,
          done: FocusTokens.white,
        ),
      ),
    );
  }
}
