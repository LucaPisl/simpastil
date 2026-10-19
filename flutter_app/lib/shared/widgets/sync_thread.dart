import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/medication/care_sharing_provider.dart';
import '../../core/medication/care_sharing_status.dart';
import '../../core/sync/sync_status_notifier.dart';
import '../../l10n/app_localizations.dart';
import '../motion/app_motion.dart';
import '../theme/focus_tokens.dart';

/// What the thread between this phone and the server shows.
enum SyncThreadKind {
  hidden,

  /// Changes saved here, not yet sent: dots wait at the phone end.
  waiting,

  /// Nothing has been received from the server yet: a dashed thread.
  unverified,

  /// Records need review; that is not a sync matter, so no thread.
  attention,

  /// A sync is carrying this phone's changes: dots travel to the server.
  sending,

  /// A sync is reading the server: dots travel to the phone.
  receiving,

  /// A sync the person was watching ended well: the thread pulls taut.
  settled,

  /// An attempt the person was watching, or one with changes waiting,
  /// failed: the thread parts in the middle.
  broken,
}

@immutable
class SyncThreadLook {
  const SyncThreadLook(this.kind, {this.count = 0});
  final SyncThreadKind kind;

  /// Changes saved on this phone and not yet accepted by the server.
  final int count;

  @override
  bool operator ==(Object other) =>
      other is SyncThreadLook && other.kind == kind && other.count == count;

  @override
  int get hashCode => Object.hash(kind, count);

  @override
  String toString() => 'SyncThreadLook($kind, $count)';
}

/// Decides the thread from evidence only.
///
/// [sharing] is the workspace's own record of what is pending and received;
/// [phase] is the live sync attempt. [watching] says the person can see this
/// attempt (they pulled to refresh, or the thread was already showing), so a
/// background sync never makes Today shift under them. [settling] and
/// [faltered] are the short moments after a watched attempt ends.
SyncThreadLook syncThreadLook({
  required CareSharingStatus? sharing,
  required SyncPhase phase,
  bool watching = false,
  bool settling = false,
  bool faltered = false,
}) {
  if (sharing == null || sharing.isLocalOnly) {
    return const SyncThreadLook(SyncThreadKind.hidden);
  }
  final pending = sharing.pendingCount;
  final unknown = sharing.lastCarePullAt == null;
  if (sharing.needsReviewCount + sharing.uncertainCount > 0) {
    return const SyncThreadLook(SyncThreadKind.attention);
  }
  if (phase == SyncPhase.syncing) {
    if (pending > 0) {
      return SyncThreadLook(SyncThreadKind.sending, count: pending);
    }
    if (watching || unknown) {
      return const SyncThreadLook(SyncThreadKind.receiving);
    }
    return const SyncThreadLook(SyncThreadKind.hidden);
  }
  if (phase == SyncPhase.failure && (pending > 0 || unknown || faltered)) {
    return SyncThreadLook(SyncThreadKind.broken, count: pending);
  }
  if (pending > 0) {
    return SyncThreadLook(SyncThreadKind.waiting, count: pending);
  }
  if (settling) return const SyncThreadLook(SyncThreadKind.settled);
  if (unknown) return const SyncThreadLook(SyncThreadKind.unverified);
  return const SyncThreadLook(SyncThreadKind.hidden);
}

/// The compact sharing line on Today, History and People, drawn as a thread
/// from this phone to the server. It folds in when there is something to
/// say and folds away after a watched sync settles.
class SyncThreadSummary extends ConsumerStatefulWidget {
  const SyncThreadSummary({super.key, this.refreshing, required this.onOpen});

  /// True while the person's own pull to refresh is running.
  final ValueListenable<bool>? refreshing;

  /// Opens the Sync details.
  final VoidCallback onOpen;

  /// How long a settled or faltered moment stays before the thread folds.
  static const settleHold = Duration(milliseconds: 1800);
  static const falterHold = Duration(milliseconds: 3200);

  @override
  ConsumerState<SyncThreadSummary> createState() => _SyncThreadSummaryState();
}

class _SyncThreadSummaryState extends ConsumerState<SyncThreadSummary>
    with TickerProviderStateMixin {
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  late final AnimationController _moment = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 640),
    value: 1,
  );
  bool _watching = false;
  bool _settling = false;
  bool _faltered = false;
  bool _showing = false;
  Timer? _hold;
  SyncThreadKind? _lastKind;
  ProviderSubscription<SyncPhase>? _phases;

  @override
  void initState() {
    super.initState();
    widget.refreshing?.addListener(_onRefreshing);
    _phases = ref.listenManual<SyncPhase>(
      syncStatusProvider.select((s) => s.phase),
      _onPhase,
    );
  }

  @override
  void didUpdateWidget(SyncThreadSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshing != widget.refreshing) {
      oldWidget.refreshing?.removeListener(_onRefreshing);
      widget.refreshing?.addListener(_onRefreshing);
    }
  }

  void _onRefreshing() {
    if (widget.refreshing?.value == true && !_watching) {
      setState(() => _watching = true);
    }
  }

  void _onPhase(SyncPhase? previous, SyncPhase next) {
    if (next == SyncPhase.syncing) {
      _hold?.cancel();
      setState(() {
        _watching =
            _watching || _showing || (widget.refreshing?.value ?? false);
        _settling = false;
        _faltered = false;
      });
      return;
    }
    if (previous != SyncPhase.syncing) return;
    final watched = _watching;
    setState(() {
      _watching = false;
      _settling = watched && next == SyncPhase.idle;
      _faltered = watched && next == SyncPhase.failure;
    });
    if (!watched) return;
    _hold?.cancel();
    _hold = Timer(
      next == SyncPhase.idle
          ? SyncThreadSummary.settleHold
          : SyncThreadSummary.falterHold,
      () {
        if (mounted) {
          setState(() => _settling = _faltered = false);
        }
      },
    );
  }

  void _animateFor(SyncThreadKind kind, bool quiet) {
    final travelling =
        kind == SyncThreadKind.sending || kind == SyncThreadKind.receiving;
    if (travelling && !quiet) {
      if (!_flow.isAnimating) _flow.repeat();
    } else if (_flow.isAnimating) {
      _flow.stop();
    }
    if (kind != _lastKind) {
      final marked =
          kind == SyncThreadKind.settled || kind == SyncThreadKind.broken;
      if (marked && !quiet && _lastKind != null) {
        _moment.forward(from: 0);
      } else {
        _moment.value = 1;
      }
      _lastKind = kind;
    }
  }

  @override
  void dispose() {
    _hold?.cancel();
    _phases?.close();
    widget.refreshing?.removeListener(_onRefreshing);
    _flow.dispose();
    _moment.dispose();
    super.dispose();
  }

  String _label(AppLocalizations l, SyncThreadLook look) => switch (look.kind) {
    SyncThreadKind.waiting => l.sync_todayPending,
    SyncThreadKind.unverified => l.sync_todayUnverified,
    SyncThreadKind.attention => l.sync_todayAttention,
    SyncThreadKind.sending => l.thread_sending,
    SyncThreadKind.receiving => l.t10_syncing,
    SyncThreadKind.settled => l.thread_settled,
    SyncThreadKind.broken =>
      look.count > 0 ? l.thread_falteredSaved : l.thread_faltered,
    SyncThreadKind.hidden => '',
  };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final sharing = ref.watch(careSharingStatusProvider);
    final phase = ref.watch(syncStatusProvider.select((s) => s.phase));
    final quiet = AppMotion.quiet(context);
    final look = sharing.isLoading && !sharing.hasValue
        ? const SyncThreadLook(SyncThreadKind.hidden)
        : syncThreadLook(
            sharing: sharing.asData?.value,
            phase: phase,
            watching: _watching,
            settling: _settling,
            faltered: _faltered,
          );
    _showing = look.kind != SyncThreadKind.hidden;
    _animateFor(look.kind, quiet);

    final scheme = Theme.of(context).colorScheme;
    final Widget content = !_showing
        ? const SizedBox(width: double.infinity, key: ValueKey('thread-off'))
        : Padding(
            key: const ValueKey('thread-on'),
            padding: const EdgeInsets.only(bottom: 8),
            child: TextButton.icon(
              style: TextButton.styleFrom(
                alignment: AlignmentDirectional.centerStart,
              ),
              icon: look.kind == SyncThreadKind.attention
                  ? const Icon(Icons.info_outline, size: 18)
                  : ExcludeSemantics(
                      child: SizedBox(
                        width: 58,
                        height: 24,
                        child: CustomPaint(
                          key: const ValueKey('sync-thread'),
                          painter: SyncThreadPainter(
                            look: look,
                            flow: _flow,
                            moment: _moment,
                            line: scheme.primary,
                            node: scheme.onSurfaceVariant,
                            settled: FocusTokens.sage,
                            quiet: quiet,
                          ),
                        ),
                      ),
                    ),
              label: Semantics(
                liveRegion:
                    look.kind == SyncThreadKind.settled ||
                    look.kind == SyncThreadKind.broken,
                child: AnimatedSwitcher(
                  duration: AppMotion.duration(context, milliseconds: 360),
                  // Fade through: the old words leave before the new arrive,
                  // so two wrapped lines never smear over each other.
                  switchInCurve: const Interval(.5, 1),
                  switchOutCurve: const Interval(.5, 1),
                  layoutBuilder: (current, previous) => Stack(
                    alignment: AlignmentDirectional.centerStart,
                    children: [...previous, ?current],
                  ),
                  child: Text(
                    _label(l, look),
                    key: ValueKey(
                      look.kind == SyncThreadKind.broken
                          ? '${look.kind}/${look.count > 0}'
                          : look.kind,
                    ),
                  ),
                ),
              ),
              onPressed: widget.onOpen,
            ),
          );

    return AnimatedSwitcher(
      duration: AppMotion.duration(context, milliseconds: 360),
      switchInCurve: AppMotion.curve,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        alignment: Alignment.topLeft,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: content,
    );
  }
}

/// The thread: a phone on the left, the server on the right, and a hanging
/// line between them that carries one dot per waiting change.
class SyncThreadPainter extends CustomPainter {
  SyncThreadPainter({
    required this.look,
    required this.flow,
    required this.moment,
    required this.line,
    required this.node,
    required this.settled,
    required this.quiet,
  }) : super(repaint: Listenable.merge([flow, moment]));

  final SyncThreadLook look;
  final Animation<double> flow;
  final Animation<double> moment;
  final Color line;
  final Color node;
  final Color settled;
  final bool quiet;

  static const _maxDots = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final kind = look.kind;
    final m = Curves.easeOutCubic.transform(moment.value);
    final midY = size.height / 2;

    // Phone: a small rounded slab with a home dot.
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = node;
    final phone = RRect.fromRectAndRadius(
      Rect.fromLTWH(1, midY - 7.5, 9.5, 15),
      const Radius.circular(2.6),
    );
    canvas.drawRRect(phone, stroke);
    canvas.drawCircle(Offset(5.75, midY + 4.8), 1.1, Paint()..color = node);

    // Server: a ring that fills sage, with a drawn check, when settled.
    final server = Offset(size.width - 7, midY);
    final isSettled = kind == SyncThreadKind.settled;
    if (isSettled) {
      canvas.drawCircle(
        server,
        6.2 + 1.8 * math.sin(m * math.pi),
        Paint()..color = settled.withValues(alpha: m),
      );
      _check(canvas, server, m);
    }
    canvas.drawCircle(server, 6, stroke..color = isSettled ? settled : node);

    // The thread hangs; settling pulls it taut, breaking lets it drop.
    final start = Offset(phone.right + 2.5, midY);
    final end = Offset(server.dx - 8.5, midY);
    final sag = switch (kind) {
      SyncThreadKind.settled => lerpDouble(3.2, 0, m)!,
      SyncThreadKind.broken => lerpDouble(3.2, 5.2, m)!,
      _ => 3.2,
    };
    Offset at(double t) {
      final x = lerpDouble(start.dx, end.dx, t)!;
      return Offset(x, midY + sag * 4 * t * (1 - t));
    }

    final threadColor = switch (kind) {
      SyncThreadKind.settled => Color.lerp(line, settled, m)!,
      SyncThreadKind.broken => node.withValues(alpha: .7),
      SyncThreadKind.unverified => node.withValues(alpha: .6),
      _ => line.withValues(alpha: .55),
    };
    final threadPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = threadColor;
    if (kind == SyncThreadKind.unverified) {
      for (var t = 0.0; t < 1; t += .2) {
        canvas.drawLine(at(t), at(math.min(1, t + .1)), threadPaint);
      }
    } else if (kind == SyncThreadKind.broken) {
      // The two halves part and their ends curl down.
      final gap = .03 + .07 * m;
      _segment(canvas, at, 0, .5 - gap, threadPaint, curl: 1.4 * m);
      _segment(
        canvas,
        at,
        .5 + gap,
        1,
        threadPaint,
        curl: 1.4 * m,
        fromEnd: true,
      );
    } else {
      _segment(canvas, at, 0, 1, threadPaint);
    }

    // One dot per waiting change, up to three.
    final dots = math.min(look.count, _maxDots);
    final dotPaint = Paint()..color = line;
    switch (kind) {
      case SyncThreadKind.waiting:
      case SyncThreadKind.broken:
        for (var i = 0; i < dots; i++) {
          canvas.drawCircle(at(.16 + .15 * i), 2.3, dotPaint);
        }
      case SyncThreadKind.sending:
      case SyncThreadKind.receiving:
        final carried = math.max(1, dots);
        for (var i = 0; i < carried; i++) {
          final phase = quiet ? .5 : (flow.value + i / 3) % 1;
          final t = kind == SyncThreadKind.sending ? phase : 1 - phase;
          // Fade at both ends so a dot leaves the phone and enters the server.
          final alpha = math.min(1.0, math.min(phase, 1 - phase) * 6);
          canvas.drawCircle(
            at(t),
            2.3,
            Paint()..color = line.withValues(alpha: alpha),
          );
        }
      default:
        break;
    }
  }

  void _segment(
    Canvas canvas,
    Offset Function(double) at,
    double from,
    double to,
    Paint paint, {
    double curl = 0,
    bool fromEnd = false,
  }) {
    final path = Path();
    const steps = 12;
    for (var i = 0; i <= steps; i++) {
      final t = from + (to - from) * i / steps;
      // Only the parted end droops: weight 1 at the gap, 0 at the node.
      final w = fromEnd ? 1 - i / steps : i / steps;
      final p = at(t) + Offset(0, curl * w * w);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(path, paint);
  }

  void _check(Canvas canvas, Offset c, double m) {
    final a = c + const Offset(-2.8, .2);
    final b = c + const Offset(-.7, 2.3);
    final d = c + const Offset(3, -2.1);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.white;
    final first = (m / .4).clamp(0.0, 1.0);
    final second = ((m - .4) / .6).clamp(0.0, 1.0);
    if (first > 0) canvas.drawLine(a, Offset.lerp(a, b, first)!, paint);
    if (second > 0) canvas.drawLine(b, Offset.lerp(b, d, second)!, paint);
  }

  @override
  bool shouldRepaint(SyncThreadPainter old) =>
      old.look != look ||
      old.line != line ||
      old.node != node ||
      old.settled != settled ||
      old.quiet != quiet;
}
