import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart'
    show HapticFeedback, KeyDownEvent, KeyUpEvent, LogicalKeyboardKey;

import '../../../l10n/app_localizations.dart';
import '../../../shared/format/clock.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/theme/app_theme.dart';
import '../../pills/presentation/medication_identity.dart';
import '../care_record_form.dart' show careAmountLabel;
import 'as_needed_controller.dart';
import 'as_needed_option.dart';
import 'as_needed_summary.dart';

/// How long a finger must stay down to record a dose.
const asNeededHoldDuration = Duration(milliseconds: 800);

/// A press shorter than this is a tap and opens the details.
const asNeededTapLimit = Duration(milliseconds: 250);

/// The ring only shows once the press has lasted this long, so a plain tap
/// never flashes it.
const _ringShowAfter = Duration(milliseconds: 150);

/// Finger travel that turns a press into a scroll or a drag.
const _slop = 12.0;

/// The colour of a recorded dose, from the theme.
Color asNeededTakenColor(BuildContext context) {
  final theme = Theme.of(context);
  return theme.extension<AppSemanticColors>()?.statusTaken ??
      theme.colorScheme.primary;
}

/// How long ago [at] was, in words that need no clock.
String asNeededAgo(AppLocalizations l, DateTime at, DateTime now) {
  final minutes = now.difference(at).inMinutes;
  if (minutes < 1) return l.asn_agoJustNow;
  if (minutes < 60) return l.asn_agoMinutes(minutes);
  if (minutes < 60 * 24) return l.asn_agoHours(minutes ~/ 60);
  return l.asn_agoDays(minutes ~/ (60 * 24));
}

/// The plain-text state line of a card: what was last taken, or why it cannot
/// be recorded yet.
String asNeededInfo(
  BuildContext context,
  AppLocalizations l,
  AsNeededOption option,
  AsNeededSummary summary,
) {
  switch (option.review) {
    case AsNeededReview.ambiguous:
      return l.prn_reviewAmbiguous;
    case AsNeededReview.routine:
      return l.prn_reviewRoutine;
    case AsNeededReview.zone:
      return l.prn_reviewZone;
    case null:
      break;
  }
  final today = summary.todayCount;
  if (today > 0) {
    final at = summary.lastTakenToday;
    return at == null
        ? '${l.asn_takenToday} · ${l.asn_todayCount(today)}'
        : l.asn_takenAtToday(clockAt(context, at), today);
  }
  final last = summary.lastTakenAt;
  if (last == null) return l.asn_notTakenYet;
  return l.asn_amountAgo(
    careAmountLabel(l, option.usualAmount),
    asNeededAgo(l, last, DateTime.now()),
  );
}

/// One as-needed medication as a square card with a progress ring: hold it to
/// record a dose, tap it for details.
///
/// The hold is a deliberate act, so a brush, a scroll or a pocket cannot
/// record a dose. Releasing early drains the ring and says so. With motion
/// reduced the hold is still required; only the ring, the check and the halo
/// stop moving.
class AsNeededRingCard extends StatefulWidget {
  const AsNeededRingCard({
    super.key,
    required this.option,
    required this.summary,
    required this.run,
    required this.compact,
    this.minHeight = 150,
    required this.onHoldComplete,
    required this.onUndo,
    required this.onDetails,
    required this.onReview,
  });

  final AsNeededOption option;
  final AsNeededSummary summary;
  final AsNeededRun run;

  /// One column at large text: ring beside the words.
  final bool compact;

  /// The least height in the two-column grid; a square at most widths.
  final double minHeight;
  final VoidCallback onHoldComplete;
  final VoidCallback onUndo;
  final VoidCallback onDetails;
  final VoidCallback onReview;

  @override
  State<AsNeededRingCard> createState() => _AsNeededRingCardState();
}

class _AsNeededRingCardState extends State<AsNeededRingCard>
    with TickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: asNeededHoldDuration,
  );
  late final AnimationController _done = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final AnimationController _bar = AnimationController(
    vsync: this,
    duration: asNeededUndoWindow,
  );
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  int? _pointer;
  Offset _downAt = Offset.zero;
  Timer? _tapTimer;
  bool _pastTap = false;
  bool _fired = false;
  bool _pressing = false;
  bool _feltRing = false;
  bool _pointerOnPill = false;
  bool _nudge = false;
  Timer? _nudgeTimer;
  bool _focused = false;

  AsNeededRun get _run => widget.run;
  bool get _canHold =>
      !widget.option.needsReview &&
      (_run.phase == AsNeededPhase.idle || _run.phase == AsNeededPhase.error);

  @override
  void initState() {
    super.initState();
    _hold.addListener(_onHoldTick);
    _hold.addStatusListener(_onHoldStatus);
    if (_run.showsTaken) {
      _done.value = 1;
      _syncBar(initial: true);
    }
  }

  @override
  void didUpdateWidget(AsNeededRingCard old) {
    super.didUpdateWidget(old);
    final quiet = AppMotion.quiet(context);
    final was = old.run.showsTaken;
    final now = _run.showsTaken;
    if (now && (!was || old.run.token != _run.token)) {
      _hold.value = 0;
      _pressing = false;
      if (quiet) {
        _done.value = 1;
      } else {
        _done.forward(from: 0);
      }
      _syncBar();
    } else if (!now && was) {
      if (quiet) {
        _done.value = 0;
      } else {
        _done.animateBack(
          0,
          duration: AppMotion.standard,
          curve: Curves.easeIn,
        );
      }
      _bar.stop();
    }
    // A hold that did not record (error, stale session) lets go of the ring.
    if (old.run.busy && !_run.busy && !now) {
      _releaseRing(silent: true);
    }
  }

  @override
  void dispose() {
    _nudgeTimer?.cancel();
    _tapTimer?.cancel();
    _hold.dispose();
    _done.dispose();
    _bar.dispose();
    _shake.dispose();
    super.dispose();
  }

  void _syncBar({bool initial = false}) {
    if (AppMotion.quiet(context) && !initial) return;
    final started = _run.undoStartedAt;
    final elapsed = started == null
        ? 0.0
        : DateTime.now().difference(started).inMilliseconds /
              asNeededUndoWindow.inMilliseconds;
    _bar.forward(from: elapsed.clamp(0.0, 1.0));
  }

  bool get _canFeel =>
      mounted &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.isCurrentOf(context) ?? true);

  void _onHoldTick() {
    final ms = _hold.value * asNeededHoldDuration.inMilliseconds;
    if (!_feltRing && ms >= _ringShowAfter.inMilliseconds && _pressing) {
      setState(() => _feltRing = true);
      if (_canFeel) HapticFeedback.selectionClick();
    }
  }

  void _onHoldStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed &&
        _pointer != null &&
        !_fired &&
        _canHold) {
      _fired = true;
      widget.onHoldComplete();
    }
  }

  void _releaseRing({required bool silent}) {
    final p = _hold.value;
    _feltRing = false;
    if (mounted) setState(() => _pressing = false);
    if (AppMotion.quiet(context) || p == 0) {
      _hold.value = 0;
    } else {
      _hold.animateBack(
        0,
        duration: Duration(milliseconds: math.max(200, (380 * p).round())),
        curve: Curves.easeOut,
      );
    }
    if (!silent) {
      _nudgeTimer?.cancel();
      setState(() => _nudge = true);
      if (!AppMotion.quiet(context)) _shake.forward(from: 0);
      _nudgeTimer = Timer(const Duration(milliseconds: 1700), () {
        if (mounted) setState(() => _nudge = false);
      });
    }
  }

  void _start() {
    _fired = false;
    _feltRing = false;
    _nudgeTimer?.cancel();
    _pastTap = false;
    _tapTimer?.cancel();
    _tapTimer = Timer(asNeededTapLimit, () => _pastTap = true);
    if (_canHold) {
      setState(() {
        _pressing = true;
        _nudge = false;
      });
      _hold.forward(from: 0);
    }
  }

  void _onDown(PointerDownEvent e) {
    if (_pointerOnPill) {
      _pointerOnPill = false;
      return;
    }
    if (_pointer != null) return;
    _pointer = e.pointer;
    _downAt = e.position;
    _start();
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    if ((e.position - _downAt).distance > _slop) {
      _pointer = null;
      if (_pressing && !_fired) _releaseRing(silent: true);
    }
  }

  void _onCancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    if (_pressing && !_fired) _releaseRing(silent: true);
  }

  void _onUp(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    _finish();
  }

  void _finish() {
    _tapTimer?.cancel();
    if (_fired) {
      setState(() => _pressing = false);
      return;
    }
    final tap = !_pastTap;
    if (widget.option.needsReview) {
      if (tap) widget.onReview();
      return;
    }
    if (_pressing) _releaseRing(silent: tap);
    if (tap) {
      widget.onDetails();
    } else if (!_canHold) {
      // A long press on a card that cannot record (saving, undo showing).
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (event is KeyDownEvent) {
        widget.option.needsReview ? widget.onReview() : widget.onDetails();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent && _pointer == null && !_pressing) {
        _pointer = -1;
        _start();
      } else if (event is KeyUpEvent && _pointer == -1) {
        _pointer = null;
        _finish();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final quiet = AppMotion.quiet(context);
    final ok = asNeededTakenColor(context);
    final option = widget.option;
    final showsTaken = _run.showsTaken;
    final holding = _pressing && !showsTaken;
    final info = asNeededInfo(context, l, option, widget.summary);
    final tint = medicationTint(id: option.pill.id, color: option.pill.color);
    final duration = quiet ? Duration.zero : AppMotion.standard;
    final border = Color.lerp(
      colors.outlineVariant.withValues(alpha: .5),
      ok,
      holding ? .62 : (_focused ? 1 : 0),
    )!;

    final ring = _Ring(
      size: widget.compact ? 56 : 68,
      hold: _hold,
      done: _done,
      quiet: quiet,
      tint: tint,
      ok: ok,
      surface: colors.surface,
      shape: option.shape,
      review: option.needsReview,
      reviewColor: colors.error,
    );

    // The count of doses today is already in the line under the name
    // ("Taken 7:40 AM · 1 today"); a second chip beside the person only cut
    // their name short.
    final badge = option.needsReview
        ? _Badge(
            label: l.asn_needsReview,
            color: colors.errorContainer,
            textColor: colors.onErrorContainer,
          )
        : null;

    final nameText = Text(
      option.pill.name,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: widget.compact ? TextAlign.start : TextAlign.center,
      style: theme.textTheme.titleSmall?.copyWith(
        fontSize: 14,
        height: 1.2,
        fontWeight: FontWeight.w700,
      ),
    );
    final eyebrow = Text(
      l.t08_forPerson(option.person.name),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(
        fontSize: 11,
        color: colors.onSurfaceVariant,
      ),
    );

    final String line;
    final Color lineColor;
    final bool lineBold;
    IconData? lineIcon;
    if (_run.phase == AsNeededPhase.error) {
      line = _run.saveFailed ? l.t08_saveError : l.t08_recordError;
      lineColor = colors.error;
      lineBold = true;
    } else if (holding && _feltRing) {
      line = l.asn_keepHolding;
      lineColor = ok;
      lineBold = true;
    } else if (_nudge) {
      line = l.asn_holdToRecord;
      lineColor = colors.onSurface;
      lineBold = true;
      lineIcon = Icons.touch_app_outlined;
    } else {
      line = info;
      lineColor = option.needsReview ? colors.error : colors.onSurfaceVariant;
      lineBold = false;
    }
    final infoStyle = theme.textTheme.bodySmall?.copyWith(
      fontSize: 11.5,
      height: 1.25,
      color: lineColor,
      fontWeight: lineBold ? FontWeight.w700 : FontWeight.w500,
    );
    final infoWidget = AnimatedSwitcher(
      duration: quiet ? Duration.zero : AppMotion.micro,
      child: Opacity(
        key: ValueKey(line),
        opacity: showsTaken ? 0 : 1,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: widget.compact
              ? MainAxisAlignment.start
              : MainAxisAlignment.center,
          children: [
            if (lineIcon != null) ...[
              Icon(lineIcon, size: 13, color: lineColor),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                line,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: widget.compact ? TextAlign.start : TextAlign.center,
                style: infoStyle,
              ),
            ),
          ],
        ),
      ),
    );

    final Widget body;
    if (widget.compact) {
      body = Row(
        children: [
          ring,
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(child: eyebrow),
                    if (badge != null) ...[const SizedBox(width: 6), badge],
                  ],
                ),
                const SizedBox(height: 2),
                nameText,
                const SizedBox(height: 4),
                infoWidget,
                if (showsTaken) const SizedBox(height: 18),
              ],
            ),
          ),
        ],
      );
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.max,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: eyebrow),
              if (badge != null) ...[const SizedBox(width: 4), badge],
            ],
          ),
          Expanded(child: Center(child: ring)),
          // Two lines are always reserved for the name, so the rings of
          // cards side by side sit on one line whether a name wraps or not.
          SizedBox(
            height: MediaQuery.textScalerOf(context).scale(14) * 1.2 * 2,
            child: Align(alignment: Alignment.center, child: nameText),
          ),
          const SizedBox(height: 3),
          infoWidget,
        ],
      );
    }

    final takenAt = _run.takenAt;
    // The pill may reach a little into the card's padding, so the time fits.
    final pill = Positioned(
      left: -8,
      right: -8,
      bottom: -6,
      child: IgnorePointer(
        ignoring: !showsTaken,
        child: AnimatedOpacity(
          opacity: showsTaken ? 1 : 0,
          duration: duration,
          curve: AppMotion.curve,
          child: AnimatedSlide(
            offset: showsTaken ? Offset.zero : const Offset(0, .3),
            duration: duration,
            curve: AppMotion.curve,
            child: Center(
              child: Listener(
                onPointerDown: (_) => _pointerOnPill = true,
                child: Semantics(
                  button: true,
                  label: l.t08_undo,
                  excludeSemantics: true,
                  onTap: widget.onUndo,
                  child: GestureDetector(
                    key: ValueKey('as-needed-undo-${option.pill.id}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onUndo,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: _UndoPill(
                        label: takenAt == null
                            ? l.t08_taken
                            : l.asn_takenTime(clockAt(context, takenAt)),
                        undo: l.t08_undo,
                        bar: quiet ? null : _bar,
                        ok: ok,
                        surface: colors.surface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final surface = AnimatedContainer(
      duration: duration,
      curve: AppMotion.curve,
      constraints: BoxConstraints(
        minHeight: widget.compact ? 96 : widget.minHeight,
      ),
      padding: EdgeInsets.fromLTRB(14, 12, 14, widget.compact ? 12 : 12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: border, width: _focused ? 2 : 1),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: .045),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
          if (holding)
            BoxShadow(color: ok.withValues(alpha: .14), spreadRadius: 3),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.passthrough,
        children: [
          ExcludeSemantics(child: body),
          pill,
        ],
      ),
    );

    final shaken = AnimatedBuilder(
      animation: _shake,
      builder: (context, child) => Transform.translate(
        offset: Offset(
          math.sin(_shake.value * math.pi * 4) * (1 - _shake.value) * 4,
          0,
        ),
        child: child,
      ),
      child: AnimatedScale(
        scale: holding ? .98 : 1,
        duration: quiet ? Duration.zero : AppMotion.micro,
        curve: AppMotion.curve,
        child: surface,
      ),
    );

    final label = l.asn_cardLabel(option.pill.name, option.person.name, info);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      button: true,
      label: label,
      onTap: option.needsReview ? widget.onReview : widget.onDetails,
      customSemanticsActions: {
        if (_canHold)
          CustomSemanticsAction(label: l.asn_recordAction):
              widget.onHoldComplete,
      },
      child: Focus(
        onKeyEvent: _onKey,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: _onUp,
          onPointerCancel: _onCancel,
          child: shaken,
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.color,
    required this.textColor,
  });
  final String label;
  final Color color;
  final Color textColor;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      label,
      maxLines: 1,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        color: textColor,
      ),
    ),
  );
}

class _UndoPill extends StatelessWidget {
  const _UndoPill({
    required this.label,
    required this.undo,
    required this.bar,
    required this.ok,
    required this.surface,
  });
  final String label;
  final String undo;
  final Animation<double>? bar;
  final Color ok;
  final Color surface;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final style = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(fontSize: 11, color: onSurface);
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color.alphaBlend(ok.withValues(alpha: .2), surface),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
              // The time and "Undo" are one short phrase: when the card is
              // narrow it shrinks a little instead of cutting the time off.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, maxLines: 1, style: style),
                    const SizedBox(width: 6),
                    Text(
                      undo,
                      maxLines: 1,
                      style: style?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
            ),
            if (bar != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 2.5,
                child: AnimatedBuilder(
                  animation: bar!,
                  builder: (context, _) => Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FractionallySizedBox(
                      widthFactor: (1 - bar!.value).clamp(0.0, 1.0),
                      child: ColoredBox(color: ok),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({
    required this.size,
    required this.hold,
    required this.done,
    required this.quiet,
    required this.tint,
    required this.ok,
    required this.surface,
    required this.shape,
    required this.review,
    required this.reviewColor,
  });
  final double size;
  final Animation<double> hold;
  final Animation<double> done;
  final bool quiet;
  final Color tint;
  final Color ok;
  final Color surface;
  final MedicationShape shape;
  final bool review;
  final Color reviewColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: Listenable.merge([hold, done]),
          builder: (context, _) {
            final d = done.value;
            // The mark shrinks and fades as the check draws in.
            final markT = Curves.easeIn.transform((d / .3).clamp(0.0, 1.0));
            return Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                CustomPaint(
                  size: Size.square(size),
                  painter: _RingPainter(
                    track: (review ? reviewColor : tint).withValues(alpha: .24),
                    arc: ok,
                    surface: surface,
                    progress: quiet ? 0 : hold.value,
                    arcOpacity: quiet
                        ? 0
                        : (((hold.value * asNeededHoldDuration.inMilliseconds) -
                                      _ringShowAfter.inMilliseconds) /
                                  120)
                              .clamp(0.0, 1.0),
                    done: d,
                    haloActive: done.status == AnimationStatus.forward,
                  ),
                ),
                Opacity(
                  opacity: 1 - markT,
                  child: Transform.scale(
                    scale: 1 - .8 * markT,
                    child: review
                        ? Icon(
                            Icons.report_gmailerrorred_outlined,
                            size: size * .46,
                            color: reviewColor,
                          )
                        : MedicationMark(
                            color: tint,
                            shape: shape,
                            size: size * .5,
                          ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.track,
    required this.arc,
    required this.surface,
    required this.progress,
    required this.arcOpacity,
    required this.done,
    required this.haloActive,
  });
  final Color track;
  final Color arc;
  final Color surface;
  final double progress;
  final double arcOpacity;
  final double done;
  final bool haloActive;

  static const _stroke = 5.0;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.width - _stroke) / 2;
    // Track, then the arc that fills while holding.
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..color = track;
    if (done < 1) canvas.drawCircle(center, radius, trackPaint);
    if (progress > 0 && arcOpacity > 0 && done == 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = _stroke
          ..color = arc.withValues(alpha: arcOpacity),
      );
    }
    if (done > 0) {
      // A solid disc springs in over the ring, then a check draws on it.
      final discT = Curves.easeOutBack.transform((done / .55).clamp(0.0, 1.0));
      canvas.drawCircle(
        center,
        size.width / 2 * discT.clamp(0.0, 1.2),
        Paint()..color = arc,
      );
      final checkT = Curves.easeOut.transform(
        ((done - .18) / .42).clamp(0.0, 1.0),
      );
      if (checkT > 0) {
        final w = size.width;
        final points = [
          Offset(w * .30, w * .52),
          Offset(w * .44, w * .66),
          Offset(w * .70, w * .37),
        ];
        final first = (points[1] - points[0]).distance;
        final second = (points[2] - points[1]).distance;
        var left = checkT * (first + second);
        final path = Path()..moveTo(points[0].dx, points[0].dy);
        final toMid = math.min(left, first);
        path.lineTo(
          points[0].dx + (points[1].dx - points[0].dx) * toMid / first,
          points[0].dy + (points[1].dy - points[0].dy) * toMid / first,
        );
        left -= toMid;
        if (left > 0) {
          path.lineTo(
            points[1].dx + (points[2].dx - points[1].dx) * left / second,
            points[1].dy + (points[2].dy - points[1].dy) * left / second,
          );
        }
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = w * .085
            ..color = surface,
        );
      }
      // One halo leaves the disc and fades.
      final haloT = ((done) / .95).clamp(0.0, 1.0);
      if (haloActive && haloT < 1) {
        canvas.drawCircle(
          center,
          size.width / 2 * (.95 + .8 * Curves.easeOut.transform(haloT)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = arc.withValues(alpha: (1 - haloT) * .8),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.arcOpacity != arcOpacity ||
      old.done != done ||
      old.haloActive != haloActive ||
      old.track != track ||
      old.arc != arc ||
      old.surface != surface;
}
